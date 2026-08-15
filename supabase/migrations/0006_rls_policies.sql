-- ============================================================================
-- 0006_rls_policies.sql
-- Phase 2.11 — Implement RLS
-- ============================================================================
-- Helper functions first (single source of truth for every policy below),
-- then RLS enabled + policies for every table. Nothing is readable/writable
-- by an authenticated client unless an explicit policy grants it.
-- service_role (server-side code, Edge Functions, migrations) bypasses RLS
-- entirely, as standard in Supabase.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Helpers: platform context
-- ----------------------------------------------------------------------------
create or replace function public.is_platform_super_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.platform_memberships m
    join public.roles r on r.id = m.base_role_id
    where m.user_id = auth.uid() and m.status = 'active' and r.key = 'platform_super_admin'
  );
$$;

create or replace function public.has_platform_permission(p_permission_key text)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare v_has boolean;
begin
  if public.is_platform_super_admin() then
    return true;
  end if;
  select exists (
    select 1 from public.platform_memberships m
    join public.role_permissions rp on rp.role_id = m.base_role_id
    join public.permissions p on p.id = rp.permission_id
    where m.user_id = auth.uid() and m.status = 'active' and p.key = p_permission_key
  ) into v_has;
  return v_has;
end;
$$;

-- ----------------------------------------------------------------------------
-- Helpers: organization context (government + school-group)
-- ----------------------------------------------------------------------------
create or replace function public.user_org_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select organization_id from public.organization_memberships
  where user_id = auth.uid() and status = 'active';
$$;

-- Does the current user have `p_permission_key` reaching `p_target_org_id`,
-- either via a direct organization_membership whose subtree contains the
-- target org, or a scoped grant whose scope's subtree contains it?
create or replace function public.has_org_permission(p_permission_key text, p_target_org_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare v_has boolean;
begin
  if public.is_platform_super_admin() then
    return true;
  end if;

  select exists (
    select 1
    from public.organization_memberships m
    join public.role_permissions rp on rp.role_id = m.base_role_id
    join public.permissions p on p.id = rp.permission_id
    join public.org_subtree_ids(m.organization_id) st on st.id = p_target_org_id
    where m.user_id = auth.uid() and m.status = 'active' and p.key = p_permission_key
  ) into v_has;
  if v_has then return true; end if;

  select exists (
    select 1
    from public.organization_memberships m
    join public.organization_scoped_permissions osp on osp.organization_membership_id = m.id
    join public.permissions p on p.id = osp.permission_id
    join public.org_subtree_ids(osp.scope_id) st on st.id = p_target_org_id
    where m.user_id = auth.uid() and m.status = 'active' and p.key = p_permission_key
      and (osp.expires_at is null or osp.expires_at > now())
  ) into v_has;

  return v_has;
end;
$$;

comment on function public.has_org_permission is
  'Handles government hierarchy visibility: a Regional Officer''s organization_'
  'membership.organization_id is their region; org_subtree_ids() walks down to '
  'every zone/woreda/school_group/school beneath it. A woreda deep in that '
  'subtree passes has_org_permission(...) for the regional officer without a '
  'row existing per descendant.';

-- ----------------------------------------------------------------------------
-- Helpers: school context
-- ----------------------------------------------------------------------------
create or replace function public.user_school_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select school_id from public.school_memberships
  where user_id = auth.uid() and status = 'active';
$$;

-- Effective permission at a school: base role + scoped grant + active
-- responsibility (staff) + active position (students) + org-level authority
-- reaching this school's organization (government / school-group oversight).
create or replace function public.has_permission(p_permission_key text, p_school_id uuid)
returns boolean
language plpgsql stable security definer set search_path = public
as $$
declare
  v_membership_id uuid;
  v_org_id uuid;
  v_has boolean;
begin
  if public.is_platform_super_admin() then
    return true;
  end if;

  select organization_id into v_org_id from public.schools where id = p_school_id;
  if v_org_id is not null and public.has_org_permission(p_permission_key, v_org_id) then
    return true;
  end if;

  select id into v_membership_id from public.school_memberships
  where user_id = auth.uid() and school_id = p_school_id and status = 'active';
  if v_membership_id is null then
    return false;
  end if;

  select exists (
    select 1 from public.school_memberships m
    join public.role_permissions rp on rp.role_id = m.base_role_id
    join public.permissions p on p.id = rp.permission_id
    where m.id = v_membership_id and p.key = p_permission_key
  ) into v_has;
  if v_has then return true; end if;

  select exists (
    select 1 from public.scoped_permissions sp
    join public.permissions p on p.id = sp.permission_id
    where sp.school_membership_id = v_membership_id and p.key = p_permission_key
      and (sp.expires_at is null or sp.expires_at > now())
  ) into v_has;
  if v_has then return true; end if;

  select exists (
    select 1 from public.responsibility_assignments ra
    join public.responsibility_permissions rpm on rpm.responsibility_id = ra.responsibility_id
    join public.permissions p on p.id = rpm.permission_id
    where ra.school_membership_id = v_membership_id and p.key = p_permission_key
      and ra.start_date <= current_date and (ra.end_date is null or ra.end_date >= current_date)
  ) into v_has;
  if v_has then return true; end if;

  select exists (
    select 1 from public.position_assignments pa
    join public.position_permissions ppm on ppm.position_id = pa.position_id
    join public.permissions p on p.id = ppm.permission_id
    where pa.school_membership_id = v_membership_id and p.key = p_permission_key
      and pa.start_date <= current_date and (pa.end_date is null or pa.end_date >= current_date)
  ) into v_has;

  return v_has;
end;
$$;

comment on function public.has_permission is
  'Single source of truth for "can this user do X at this school", covering '
  'all four grant paths (base role, scoped_permissions, responsibilities, '
  'positions) plus org-level oversight authority. Call this from the API '
  'layer too, before any mutation — RLS alone will not cover business-logic '
  'validation such as date ranges.';

-- ----------------------------------------------------------------------------
-- Enable RLS everywhere
-- ----------------------------------------------------------------------------
alter table public.organizations                     enable row level security;
alter table public.schools                            enable row level security;
alter table public.profiles                            enable row level security;
alter table public.school_memberships                  enable row level security;
alter table public.organization_memberships             enable row level security;
alter table public.platform_memberships                 enable row level security;
alter table public.roles                                enable row level security;
alter table public.permissions                          enable row level security;
alter table public.role_permissions                     enable row level security;
alter table public.scoped_permissions                   enable row level security;
alter table public.organization_scoped_permissions       enable row level security;
alter table public.responsibilities                      enable row level security;
alter table public.responsibility_permissions             enable row level security;
alter table public.responsibility_assignments              enable row level security;
alter table public.positions                              enable row level security;
alter table public.position_permissions                    enable row level security;
alter table public.position_assignments                     enable row level security;

-- ----------------------------------------------------------------------------
-- organizations
-- ----------------------------------------------------------------------------
create policy organizations_select on public.organizations for select
    using (
      public.is_platform_super_admin()
      or id in (select st.id from public.user_org_ids() uo, public.org_subtree_ids(uo) st)
      or id in (select organization_id from public.school_memberships where user_id = auth.uid() and status = 'active')
    );

create policy organizations_update on public.organizations for update
    using (public.has_org_permission('organizations.manage', id));

-- (No INSERT/DELETE policy for `authenticated` — org creation/deletion is
-- platform-tooling-only via service_role.)

-- ----------------------------------------------------------------------------
-- schools
-- ----------------------------------------------------------------------------
create policy schools_select on public.schools for select
    using (
      public.is_platform_super_admin()
      or id in (select public.user_school_ids())
      or public.has_org_permission('schools.analytics.view', organization_id)
      or organization_id in (select st.id from public.user_org_ids() uo, public.org_subtree_ids(uo) st)
    );

create policy schools_insert on public.schools for insert
    with check (public.has_org_permission('schools.manage', organization_id));

create policy schools_update on public.schools for update
    using (public.has_permission('schools.manage', id) or public.has_org_permission('schools.manage', organization_id));

-- ----------------------------------------------------------------------------
-- profiles
-- ----------------------------------------------------------------------------
create policy profiles_select_self on public.profiles for select
    using (id = auth.uid());

create policy profiles_update_self on public.profiles for update
    using (id = auth.uid());

create policy profiles_select_same_school on public.profiles for select
    using (exists (
      select 1 from public.school_memberships m
      where m.user_id = profiles.id and m.school_id in (select public.user_school_ids())
    ));

create policy profiles_select_org_oversight on public.profiles for select
    using (
      exists (select 1 from public.school_memberships m
              where m.user_id = profiles.id and public.has_org_permission('users.view', m.organization_id))
      or exists (select 1 from public.organization_memberships om
                 where om.user_id = profiles.id and public.has_org_permission('users.view', om.organization_id))
    );

-- ----------------------------------------------------------------------------
-- school_memberships
-- ----------------------------------------------------------------------------
create policy school_memberships_select on public.school_memberships for select
    using (
      user_id = auth.uid()
      or public.has_permission('users.view', school_id)
      or public.has_org_permission('users.view', organization_id)
    );

create policy school_memberships_insert on public.school_memberships for insert
    with check (public.has_permission('memberships.manage', school_id) or public.has_org_permission('memberships.manage', organization_id));

create policy school_memberships_update on public.school_memberships for update
    using (public.has_permission('memberships.manage', school_id) or public.has_org_permission('memberships.manage', organization_id));

-- ----------------------------------------------------------------------------
-- organization_memberships
-- ----------------------------------------------------------------------------
create policy organization_memberships_select on public.organization_memberships for select
    using (user_id = auth.uid() or public.has_org_permission('users.view', organization_id));

create policy organization_memberships_insert on public.organization_memberships for insert
    with check (public.has_org_permission('memberships.manage', organization_id));

create policy organization_memberships_update on public.organization_memberships for update
    using (public.has_org_permission('memberships.manage', organization_id));

-- ----------------------------------------------------------------------------
-- platform_memberships — deliberately tight: only platform_super_admin (or
-- someone explicitly granted platform users.manage-equivalent) can touch
-- rows other than their own.
-- ----------------------------------------------------------------------------
create policy platform_memberships_select on public.platform_memberships for select
    using (user_id = auth.uid() or public.is_platform_super_admin());

create policy platform_memberships_write on public.platform_memberships for all
    using (public.is_platform_super_admin());

-- ----------------------------------------------------------------------------
-- roles
-- ----------------------------------------------------------------------------
create policy roles_select on public.roles for select
    using (
      organization_id is null
      or public.is_platform_super_admin()
      or organization_id in (select st.id from public.user_org_ids() uo, public.org_subtree_ids(uo) st)
      or organization_id in (select organization_id from public.school_memberships where user_id = auth.uid() and status = 'active')
    );

create policy roles_insert on public.roles for insert
    with check (organization_id is not null and public.has_org_permission('roles.manage', organization_id));

create policy roles_update on public.roles for update
    using (organization_id is not null and public.has_org_permission('roles.manage', organization_id));

create policy roles_delete on public.roles for delete
    using (organization_id is not null and deletable and public.has_org_permission('roles.manage', organization_id));

-- ----------------------------------------------------------------------------
-- permissions — global read-only catalog
-- ----------------------------------------------------------------------------
create policy permissions_select on public.permissions for select
    using (auth.role() = 'authenticated');

-- ----------------------------------------------------------------------------
-- role_permissions
-- ----------------------------------------------------------------------------
create policy role_permissions_select on public.role_permissions for select
    using (exists (
      select 1 from public.roles r where r.id = role_permissions.role_id
        and (r.organization_id is null or public.is_platform_super_admin()
             or r.organization_id in (select st.id from public.user_org_ids() uo, public.org_subtree_ids(uo) st))
    ));

create policy role_permissions_write on public.role_permissions for all
    using (exists (
      select 1 from public.roles r where r.id = role_permissions.role_id
        and r.organization_id is not null and public.has_org_permission('roles.manage', r.organization_id)
    ));

-- ----------------------------------------------------------------------------
-- scoped_permissions (school-level)
-- ----------------------------------------------------------------------------
create policy scoped_perms_select on public.scoped_permissions for select
    using (
      exists (select 1 from public.school_memberships m where m.id = scoped_permissions.school_membership_id and m.user_id = auth.uid())
      or exists (select 1 from public.school_memberships m where m.id = scoped_permissions.school_membership_id
                 and public.has_permission('permissions.assign', m.school_id))
    );

create policy scoped_perms_write on public.scoped_permissions for all
    using (exists (select 1 from public.school_memberships m where m.id = scoped_permissions.school_membership_id
                   and public.has_permission('permissions.assign', m.school_id)));

-- ----------------------------------------------------------------------------
-- organization_scoped_permissions
-- ----------------------------------------------------------------------------
create policy org_scoped_perms_select on public.organization_scoped_permissions for select
    using (
      exists (select 1 from public.organization_memberships m where m.id = organization_scoped_permissions.organization_membership_id and m.user_id = auth.uid())
      or exists (select 1 from public.organization_memberships m where m.id = organization_scoped_permissions.organization_membership_id
                 and public.has_org_permission('permissions.assign', m.organization_id))
    );

create policy org_scoped_perms_write on public.organization_scoped_permissions for all
    using (exists (select 1 from public.organization_memberships m where m.id = organization_scoped_permissions.organization_membership_id
                   and public.has_org_permission('permissions.assign', m.organization_id)));

-- ----------------------------------------------------------------------------
-- responsibilities / responsibility_permissions / responsibility_assignments
-- ----------------------------------------------------------------------------
create policy responsibilities_select on public.responsibilities for select
    using (public.has_org_permission('responsibilities.manage', organization_id) or organization_id in (select public.user_org_ids())
           or (school_id is not null and school_id in (select public.user_school_ids())));

create policy responsibilities_write on public.responsibilities for all
    using (public.has_org_permission('responsibilities.manage', organization_id));

create policy responsibility_permissions_select on public.responsibility_permissions for select
    using (exists (select 1 from public.responsibilities r where r.id = responsibility_permissions.responsibility_id
                   and r.organization_id in (select public.user_org_ids())));

create policy responsibility_permissions_write on public.responsibility_permissions for all
    using (exists (select 1 from public.responsibilities r where r.id = responsibility_permissions.responsibility_id
                   and public.has_org_permission('responsibilities.manage', r.organization_id)));

create policy responsibility_assignments_select on public.responsibility_assignments for select
    using (
      exists (select 1 from public.school_memberships m where m.id = responsibility_assignments.school_membership_id and m.user_id = auth.uid())
      or exists (select 1 from public.school_memberships m where m.id = responsibility_assignments.school_membership_id
                 and public.has_permission('responsibilities.manage', m.school_id))
    );

create policy responsibility_assignments_write on public.responsibility_assignments for all
    using (exists (select 1 from public.school_memberships m where m.id = responsibility_assignments.school_membership_id
                   and public.has_permission('responsibilities.manage', m.school_id)));

-- ----------------------------------------------------------------------------
-- positions / position_permissions / position_assignments
-- ----------------------------------------------------------------------------
create policy positions_select on public.positions for select
    using (public.has_org_permission('positions.manage', organization_id) or organization_id in (select public.user_org_ids())
           or (school_id is not null and school_id in (select public.user_school_ids())));

create policy positions_write on public.positions for all
    using (public.has_org_permission('positions.manage', organization_id));

create policy position_permissions_select on public.position_permissions for select
    using (exists (select 1 from public.positions p where p.id = position_permissions.position_id
                   and p.organization_id in (select public.user_org_ids())));

create policy position_permissions_write on public.position_permissions for all
    using (exists (select 1 from public.positions p where p.id = position_permissions.position_id
                   and public.has_org_permission('positions.manage', p.organization_id)));

create policy position_assignments_select on public.position_assignments for select
    using (
      exists (select 1 from public.school_memberships m where m.id = position_assignments.school_membership_id and m.user_id = auth.uid())
      or exists (select 1 from public.school_memberships m where m.id = position_assignments.school_membership_id
                 and public.has_permission('positions.manage', m.school_id))
    );

create policy position_assignments_write on public.position_assignments for all
    using (exists (select 1 from public.school_memberships m where m.id = position_assignments.school_membership_id
                   and public.has_permission('positions.manage', m.school_id)));

-- ============================================================================
-- Table-level GRANTs
-- ============================================================================
-- RLS policies above decide which ROWS a role can see/touch, but Postgres
-- checks base table-level privileges FIRST, before RLS is ever evaluated.
-- Without an explicit GRANT, every query from `authenticated` fails with
-- "permission denied for table X" regardless of how permissive the RLS
-- policies are. This is a separate, prerequisite layer to RLS, not a
-- replacement for it — a table with SELECT granted here but NO matching
-- RLS policy still returns zero rows to `authenticated`, never all rows.
--
-- `anon` is deliberately NOT granted anything in Phase 2 — there are no
-- public-facing unauthenticated tables yet (the first one will likely be
-- an admissions/application flow in Student Management, Section 22).
-- ============================================================================

grant usage on schema public to authenticated, service_role;

grant select, insert, update, delete on
    public.organizations,
    public.schools,
    public.profiles,
    public.school_memberships,
    public.organization_memberships,
    public.platform_memberships,
    public.roles,
    public.permissions,
    public.role_permissions,
    public.scoped_permissions,
    public.organization_scoped_permissions,
    public.responsibilities,
    public.responsibility_permissions,
    public.responsibility_assignments,
    public.positions,
    public.position_permissions,
    public.position_assignments
to authenticated;

-- Every table above still has an RLS policy gating each operation (or, for
-- operations with NO policy at all — e.g. organizations has no INSERT/DELETE
-- policy for `authenticated` — RLS blocks it outright regardless of this
-- GRANT). Granting broadly here and letting RLS do the real restriction is
-- the standard Supabase pattern.

-- Make sure any table created by a FUTURE migration (Phase 5+, run by the
-- same owning role) automatically inherits these grants, so this step never
-- has to be manually repeated per new module.
alter default privileges in schema public
    grant select, insert, update, delete on tables to authenticated;

-- Helper functions (has_permission, has_org_permission, org_subtree_ids, ...)
-- are called directly by the application layer in addition to being used
-- inside RLS policies — make EXECUTE explicit rather than relying on
-- Postgres's default PUBLIC execute grant, which some environments revoke.
grant execute on all functions in schema public to authenticated;
alter default privileges in schema public
    grant execute on functions to authenticated;