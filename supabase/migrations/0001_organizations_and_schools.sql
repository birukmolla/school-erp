-- ============================================================================
-- 0001_organizations_and_schools.sql
-- Phase 2.1 — Organization hierarchy
-- Phase 2.2 — Schools table
-- ============================================================================
-- Design note:
--   "organizations" models the ADMINISTRATIVE / OWNERSHIP hierarchy, not
--   physical schools. A row can be:
--     - a government body       (type = 'government', level free-text:
--                                 'federal' | 'regional' | 'zonal' | 'woreda'
--                                 | anything else a region actually uses)
--     - a school group / trust  (type = 'school_group') owning many schools
--     - an independent school's owning entity (type = 'independent_school')
--
--   Depth and shape of the hierarchy are NOT hard-coded — parent_organization_id
--   is a simple self-reference, so Addis Ababa's city-administration structure
--   and a rural woreda structure can both be represented without special-casing
--   either. `level` is a free-text label for display/reporting only; nothing
--   in the schema requires exactly 4 levels or a specific label set.
--
--   Physical schools live in a SEPARATE `schools` table, each pointing at the
--   organization that owns it (a school_group or independent_school node).
--   Government nodes typically own zero schools directly — their authority
--   over schools comes from the hierarchy (see org_subtree_ids() in
--   0006_rls_policies.sql), not from direct ownership.
-- ============================================================================

create extension if not exists "pgcrypto"; -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- organizations
-- ----------------------------------------------------------------------------
create table public.organizations (
    id                      uuid primary key default gen_random_uuid(),
    parent_organization_id  uuid references public.organizations(id) on delete restrict,
    type                    text not null
                                check (type in ('government', 'school_group', 'independent_school')),
    level                   text, -- free-text label, e.g. 'federal' | 'regional' | 'zonal' | 'woreda' | null
    name                    text not null,
    slug                    text not null unique,
    status                  text not null default 'active'
                                check (status in ('active', 'suspended', 'archived')),
    settings                jsonb not null default '{}'::jsonb,
    metadata                jsonb not null default '{}'::jsonb,
    created_at              timestamptz not null default now(),
    updated_at              timestamptz not null default now()
);

comment on table public.organizations is
  'Administrative/ownership hierarchy node. Government bodies, school groups, '
  'and independent schools'' owning entities all live here, distinguished by '
  '`type`. Arbitrary depth via parent_organization_id — do not assume a fixed '
  'number of levels between "federal" and "school".';

comment on column public.organizations.level is
  'Free-text hierarchy label for government nodes (federal/regional/zonal/'
  'woreda or a region-specific equivalent). Purely descriptive — authorization '
  'scope comes from the parent_organization_id chain, not from this value.';

create index idx_organizations_parent on public.organizations(parent_organization_id);
create index idx_organizations_type on public.organizations(type);
create index idx_organizations_status on public.organizations(status);

-- A government node should never have a school_group/independent_school parent,
-- and vice versa is allowed (a school_group could conceivably sit under a
-- regulatory government node for reporting purposes) — so we only guard the
-- one direction that would be a modeling error.
create or replace function public.validate_organization_parent()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_parent_type text;
begin
  if new.parent_organization_id is null then
    return new;
  end if;

  select type into v_parent_type from public.organizations where id = new.parent_organization_id;

  if new.type = 'government' and v_parent_type is not null and v_parent_type <> 'government' then
    raise exception 'A government organization cannot be nested under a % organization.', v_parent_type;
  end if;

  return new;
end;
$$;

create trigger trg_validate_organization_parent
    before insert or update of parent_organization_id, type on public.organizations
    for each row execute function public.validate_organization_parent();

-- ----------------------------------------------------------------------------
-- schools — the physical/tenant entity that domain data (students,
-- attendance, exams, ...) will actually be scoped to.
-- ----------------------------------------------------------------------------
create table public.schools (
    id                  uuid primary key default gen_random_uuid(),
    organization_id     uuid not null references public.organizations(id) on delete restrict,
    name                text not null,
    code                text not null, -- short code, unique within the owning organization
    school_type         text not null default 'k12'
                            check (school_type in ('k12', 'primary', 'secondary', 'college', 'vocational')),
    timezone            text not null default 'Africa/Addis_Ababa',
    locale              text not null default 'en',
    address             jsonb not null default '{}'::jsonb,
    contact_email       text,
    contact_phone       text,
    status              text not null default 'active'
                            check (status in ('active', 'suspended', 'archived')),
    settings            jsonb not null default '{}'::jsonb, -- branding, feature flags, academic config
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now(),

    unique (organization_id, code)
);

comment on table public.schools is
  'A single physical school. organization_id must point at a school_group or '
  'independent_school organization (enforced by trigger below) — never at a '
  'government node directly.';

create index idx_schools_organization on public.schools(organization_id);
create index idx_schools_status on public.schools(status);

create or replace function public.validate_school_organization_type()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_type text;
begin
  select type into v_type from public.organizations where id = new.organization_id;
  if v_type not in ('school_group', 'independent_school') then
    raise exception 'schools.organization_id must reference a school_group or independent_school organization, got %.', v_type;
  end if;
  return new;
end;
$$;

create trigger trg_validate_school_organization_type
    before insert or update of organization_id on public.schools
    for each row execute function public.validate_school_organization_type();

-- ----------------------------------------------------------------------------
-- Recursive hierarchy helper — used throughout RLS (0006) for government
-- scope checks ("does my organization's subtree contain this school").
-- ----------------------------------------------------------------------------
create or replace function public.org_subtree_ids(p_root_org_id uuid)
returns table (id uuid)
language sql stable security definer set search_path = public
as $$
  with recursive subtree as (
    select o.id from public.organizations o where o.id = p_root_org_id
    union all
    select o.id from public.organizations o
    join subtree s on o.parent_organization_id = s.id
  )
  select id from subtree;
$$;

comment on function public.org_subtree_ids is
  'Returns p_root_org_id plus every descendant organization id. Used to give '
  'a government official at e.g. a regional org visibility into every zone, '
  'woreda, school_group and school beneath it — without hard-coding depth. '
  'MUST be security definer: it queries organizations directly, and RLS on '
  'organizations calls this function to decide row visibility — without '
  'security definer, that becomes infinite self-recursion (stack depth '
  'exceeded). Security definer makes this function''s internal query bypass '
  'RLS entirely, which is safe here since it only ever returns bare ids '
  'derived from a caller-supplied root, never row contents.';

-- ----------------------------------------------------------------------------
-- updated_at trigger helper (reused by every table going forward)
-- ----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_organizations_updated_at
    before update on public.organizations
    for each row execute function public.set_updated_at();

create trigger trg_schools_updated_at
    before update on public.schools
    for each row execute function public.set_updated_at();