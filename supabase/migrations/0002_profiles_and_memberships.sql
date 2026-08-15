-- ============================================================================
-- 0002_profiles_and_memberships.sql
-- Phase 2.3 — Users / profile foundation
-- Phase 2.4 — School memberships
-- ============================================================================
-- Design note — THREE membership tables, not one:
--   school_memberships        → student / parent / teacher / staff / school
--                                leadership identity, scoped to ONE school.
--   organization_memberships  → government officials (federal/regional/
--                                zonal/woreda) AND school-group-level staff,
--                                scoped to ONE organization node.
--   platform_memberships      → platform admin roles. NOT scoped to any
--                                organization or school at all — a platform
--                                admin does not automatically become a member
--                                of a school (explicit product requirement).
--
--   These are deliberately kept separate rather than one polymorphic
--   "memberships" table: the three contexts have different scope shapes
--   (school vs. organization-subtree vs. global) and mixing them behind a
--   generic FK would make RLS harder to reason about and easier to get wrong.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- profiles — 1:1 extension of auth.users, NOT tenant-scoped
-- ----------------------------------------------------------------------------
create table public.profiles (
    id                  uuid primary key references auth.users(id) on delete cascade,
    full_name           text not null,
    preferred_name      text,
    email               text not null,
    phone               text,
    avatar_url          text,
    default_locale      text not null default 'en' check (default_locale in ('en', 'am')),
    status               text not null default 'active'
                            check (status in ('active', 'suspended', 'deactivated')),
    metadata             jsonb not null default '{}'::jsonb,
    created_at           timestamptz not null default now(),
    updated_at           timestamptz not null default now()
);

comment on table public.profiles is
  'Tenant-agnostic identity, shared across all three membership contexts. '
  'A single human can simultaneously be a parent at School A (school_membership), '
  'a Woreda Education Officer (organization_membership), and never a platform '
  'admin — all pointing back to one profiles row.';

create trigger trg_profiles_updated_at
    before update on public.profiles
    for each row execute function public.set_updated_at();

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    new.email
  );
  return new;
end;
$$;

create trigger trg_on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_auth_user();

-- ----------------------------------------------------------------------------
-- school_memberships — student / parent / teacher / staff / school leadership
-- ----------------------------------------------------------------------------
-- base_role_id FK is attached in 0003 once roles exists.
create table public.school_memberships (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references public.profiles(id) on delete cascade,
    school_id           uuid not null references public.schools(id) on delete cascade,
    organization_id     uuid not null references public.organizations(id) on delete cascade, -- denormalized from schools.organization_id
    status              text not null default 'invited'
                            check (status in ('invited', 'active', 'suspended', 'left')),
    invited_by          uuid references public.profiles(id),
    joined_at           timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    unique (user_id, school_id)
);

comment on table public.school_memberships is
  'One row per (user, school). Anchor for base_role, scoped_permissions, '
  'responsibilities (staff), and positions (students) — all defined in later '
  'migrations. organization_id is denormalized from schools.organization_id.';

create index idx_school_memberships_user on public.school_memberships(user_id);
create index idx_school_memberships_school on public.school_memberships(school_id);
create index idx_school_memberships_org on public.school_memberships(organization_id);
create index idx_school_memberships_status on public.school_memberships(status);

create trigger trg_school_memberships_updated_at
    before update on public.school_memberships
    for each row execute function public.set_updated_at();

create or replace function public.sync_school_membership_org_id()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  select organization_id into new.organization_id from public.schools where id = new.school_id;
  return new;
end;
$$;

create trigger trg_school_memberships_sync_org
    before insert or update of school_id on public.school_memberships
    for each row execute function public.sync_school_membership_org_id();

-- ----------------------------------------------------------------------------
-- organization_memberships — government officials + school-group-level staff
-- ----------------------------------------------------------------------------
create table public.organization_memberships (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references public.profiles(id) on delete cascade,
    organization_id     uuid not null references public.organizations(id) on delete cascade,
    status              text not null default 'invited'
                            check (status in ('invited', 'active', 'suspended', 'left')),
    invited_by          uuid references public.profiles(id),
    joined_at           timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    unique (user_id, organization_id)
);

comment on table public.organization_memberships is
  'One row per (user, organization). A Regional Education Bureau Administrator '
  'has a row here with organization_id = their regional org — their visibility '
  'into descendant zones/woredas/schools comes from org_subtree_ids(), not from '
  'having a row per descendant. base_role_id FK attached in 0003.';

create index idx_org_memberships_user on public.organization_memberships(user_id);
create index idx_org_memberships_org on public.organization_memberships(organization_id);
create index idx_org_memberships_status on public.organization_memberships(status);

create trigger trg_org_memberships_updated_at
    before update on public.organization_memberships
    for each row execute function public.set_updated_at();

-- ----------------------------------------------------------------------------
-- platform_memberships — platform admin roles, global, no tenant scope at all
-- ----------------------------------------------------------------------------
create table public.platform_memberships (
    id                  uuid primary key default gen_random_uuid(),
    user_id             uuid not null references public.profiles(id) on delete cascade,
    status              text not null default 'invited'
                            check (status in ('invited', 'active', 'suspended', 'left')),
    invited_by          uuid references public.profiles(id),
    joined_at           timestamptz,
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    unique (user_id) -- a person holds at most one platform-level role at a time
);

comment on table public.platform_memberships is
  'Platform admin identity. Deliberately carries NO organization_id / school_id '
  '— granting someone a platform role must never implicitly grant school or '
  'organization access. base_role_id FK attached in 0003, and roles usable '
  'here are restricted to roles.context = ''platform''.';

create trigger trg_platform_memberships_updated_at
    before update on public.platform_memberships
    for each row execute function public.set_updated_at();