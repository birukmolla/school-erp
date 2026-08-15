-- ============================================================================
-- 0005_custom_roles.sql
-- Phase 2.10 — Custom-role system
-- ============================================================================
-- No new tables needed — roles/role_permissions from 0003 already model this
-- via organization_id + editable/deletable. This migration adds:
--   1. A guard so system_default rows can never be mutated/deleted through
--      the normal app path (service_role / migrations bypass this).
--   2. clone_role_for_org() — the "create custom role from template" action
--      a School Administrator or Organization Administrator uses in the UI.
-- ============================================================================

create or replace function public.protect_system_roles()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' and old.system_default then
    raise exception 'System default roles cannot be deleted.';
  end if;
  if TG_OP = 'UPDATE' and old.system_default and new.system_default then
    raise exception 'System default roles cannot be edited directly. Clone it into a custom role instead.';
  end if;
  return coalesce(new, old);
end;
$$;

create trigger trg_protect_system_roles
    before update or delete on public.roles
    for each row execute function public.protect_system_roles();

-- Clone a system (or another org's) role into a new custom role, scoped to
-- one organization, copying its permission set as a starting point.
-- context is inherited from the source role — you can't clone a 'platform'
-- role into a school's custom role catalog.
create or replace function public.clone_role_for_org(
    p_source_role_id   uuid,
    p_organization_id  uuid,
    p_new_key          text,
    p_new_name         text
) returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  v_new_role_id uuid;
  v_context text;
begin
  select context into v_context from public.roles where id = p_source_role_id;

  insert into public.roles (organization_id, context, key, name, description, system_default, editable, deletable)
  select p_organization_id, v_context, p_new_key, p_new_name, description, false, true, true
  from public.roles where id = p_source_role_id;

  select id into v_new_role_id
  from public.roles
  where organization_id = p_organization_id and context = v_context and key = p_new_key;

  insert into public.role_permissions (role_id, permission_id)
  select v_new_role_id, permission_id
  from public.role_permissions
  where role_id = p_source_role_id
  on conflict do nothing;

  return v_new_role_id;
end;
$$;

comment on function public.clone_role_for_org is
  'Used by the "Create custom role from template" UI in School Admin / '
  'Organization Admin. Copies the source role''s permission set (and its '
  'context: school/organization/platform); caller then edits role_permissions '
  'on the returned role to differentiate it. Example: clone "LMS Coordinator" '
  'from a blank school-context role with lms.courses.manage, lms.content.manage, '
  'lms.analytics.view once the LMS module''s permissions exist.';