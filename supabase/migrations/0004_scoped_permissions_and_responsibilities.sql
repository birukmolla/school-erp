-- ============================================================================
-- 0004_scoped_permissions_and_responsibilities.sql
-- Phase 2.8 — Scoped permissions
-- Phase 2.9 — Responsibilities (staff) + Positions (students)
-- ============================================================================
-- Design note:
--   Two scoped-permission tables, not one polymorphic table, because the
--   two contexts have genuinely different scope vocabularies:
--     scoped_permissions              → school_membership + grade/section/
--                                        department/subject/class/club
--     organization_scoped_permissions → organization_membership + region/
--                                        zone/woreda/organization
--
--   Two "extra bundle" systems, not one, per your explicit instruction to
--   keep student leadership conceptually separate from staff responsibilities:
--     responsibilities → staff (Department Head, Class Advisor, Examination
--                         Coordinator, ...), attaches to school_membership.
--     positions        → students (Council President, Club President, Class
--                         Representative, ...), also attaches to
--                         school_membership, but through its own tables so the
--                         two concepts never share rows and can evolve
--                         independently (e.g. positions may later need term
--                         limits / election tracking that responsibilities
--                         never will).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- scoped_permissions — fine-grained grants at the SCHOOL level
-- ----------------------------------------------------------------------------
create table public.scoped_permissions (
    id                      uuid primary key default gen_random_uuid(),
    school_membership_id    uuid not null references public.school_memberships(id) on delete cascade,
    permission_id           uuid not null references public.permissions(id) on delete cascade,
    scope_type              text not null
                                check (scope_type in ('grade', 'section', 'department', 'subject', 'class', 'club', 'custom')),
    scope_id                uuid not null, -- polymorphic; target table depends on scope_type, validated at app layer
    granted_by              uuid references public.profiles(id),
    expires_at              timestamptz,
    created_at              timestamptz not null default now(),

    unique (school_membership_id, permission_id, scope_type, scope_id)
);

comment on table public.scoped_permissions is
  'Example: attendance.manage limited to Grade 12 / Section B for one teacher''s '
  'membership. scope_id target table depends on scope_type and doesn''t exist '
  'yet for most types (grades/sections/departments ship with Phase 5, School '
  'Foundation) — validated at the application layer until then.';

create index idx_scoped_perms_membership on public.scoped_permissions(school_membership_id);
create index idx_scoped_perms_permission on public.scoped_permissions(permission_id);
create index idx_scoped_perms_scope on public.scoped_permissions(scope_type, scope_id);

-- ----------------------------------------------------------------------------
-- organization_scoped_permissions — fine-grained grants at the ORGANIZATION
-- (government) level, e.g. a Regional Officer additionally granted a
-- permission scoped to one specific woreda outside their normal subtree.
-- ----------------------------------------------------------------------------
create table public.organization_scoped_permissions (
    id                          uuid primary key default gen_random_uuid(),
    organization_membership_id  uuid not null references public.organization_memberships(id) on delete cascade,
    permission_id                uuid not null references public.permissions(id) on delete cascade,
    scope_type                   text not null
                                    check (scope_type in ('organization', 'region', 'zone', 'woreda', 'custom')),
    scope_id                     uuid not null, -- typically an organizations.id
    granted_by                   uuid references public.profiles(id),
    expires_at                   timestamptz,
    created_at                   timestamptz not null default now(),

    unique (organization_membership_id, permission_id, scope_type, scope_id)
);

comment on table public.organization_scoped_permissions is
  'Example: schools.analytics.view scoped to a specific Woreda organization id, '
  'granted to a Regional Officer in addition to their normal subtree visibility.';

create index idx_org_scoped_perms_membership on public.organization_scoped_permissions(organization_membership_id);
create index idx_org_scoped_perms_permission on public.organization_scoped_permissions(permission_id);
create index idx_org_scoped_perms_scope on public.organization_scoped_permissions(scope_type, scope_id);

-- ============================================================================
-- RESPONSIBILITIES — staff positions layered on top of a base role
-- ============================================================================
create table public.responsibilities (
    id                  uuid primary key default gen_random_uuid(),
    organization_id     uuid not null references public.organizations(id) on delete cascade,
    school_id           uuid references public.schools(id) on delete cascade, -- null = org-wide (school_group level)
    key                 text not null,       -- 'department_head', 'class_advisor'
    name                text not null,       -- 'Mathematics Department Head'
    description         text,
    scope_type          text not null
                            check (scope_type in ('grade', 'section', 'department', 'subject', 'class', 'custom')),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

comment on table public.responsibilities is
  'A named STAFF position template. Layered on top of a base role (e.g. '
  'Teacher + Mathematics Department Head), never a replacement for one.';

-- Postgres does not allow expressions like coalesce() inside an inline
-- UNIQUE table constraint, only plain column names — so this dedupe rule
-- (unique key per organization, treating NULL school_id as a single shared
-- value for org-wide responsibilities) has to be a unique index instead.
create unique index uq_responsibilities_org_school_key
    on public.responsibilities (organization_id, coalesce(school_id, '00000000-0000-0000-0000-000000000000'::uuid), key);

create trigger trg_responsibilities_updated_at
    before update on public.responsibilities
    for each row execute function public.set_updated_at();

create table public.responsibility_permissions (
    id                  uuid primary key default gen_random_uuid(),
    responsibility_id   uuid not null references public.responsibilities(id) on delete cascade,
    permission_id       uuid not null references public.permissions(id) on delete cascade,

    unique (responsibility_id, permission_id)
);

create table public.responsibility_assignments (
    id                      uuid primary key default gen_random_uuid(),
    responsibility_id       uuid not null references public.responsibilities(id) on delete cascade,
    school_membership_id    uuid not null references public.school_memberships(id) on delete cascade,
    scope_id                uuid not null, -- matches responsibility.scope_type
    assigned_by             uuid references public.profiles(id),
    start_date              date not null default current_date,
    end_date                date,
    created_at              timestamptz not null default now(),

    check (end_date is null or end_date >= start_date)
);

comment on table public.responsibility_assignments is
  'Example: Teacher X''s membership + "Mathematics Department Head" + '
  'scope_id = Mathematics department row, active until end_date (null = ongoing).';

create index idx_resp_assignments_membership on public.responsibility_assignments(school_membership_id);
create index idx_resp_assignments_responsibility on public.responsibility_assignments(responsibility_id);
create index idx_resp_assignments_active
    on public.responsibility_assignments(school_membership_id) where end_date is null;

-- ============================================================================
-- POSITIONS — student leadership, intentionally separate from responsibilities
-- ============================================================================
create table public.positions (
    id                  uuid primary key default gen_random_uuid(),
    organization_id     uuid not null references public.organizations(id) on delete cascade,
    school_id           uuid references public.schools(id) on delete cascade,
    key                 text not null,       -- 'club_president', 'class_representative'
    name                text not null,       -- 'Robotics Club President'
    description         text,
    scope_type          text not null
                            check (scope_type in ('school', 'grade', 'section', 'class', 'club', 'committee', 'custom')),
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

comment on table public.positions is
  'A named STUDENT leadership position template — Student Council President, '
  'Club President/VP/Secretary/Member, Class Representative, Committee Member. '
  'Structurally similar to responsibilities but kept in its own tables since '
  'student positions are conceptually distinct (not RBAC roles, and may later '
  'need election/term tracking that staff responsibilities never will).';

-- Same reasoning as uq_responsibilities_org_school_key above: coalesce()
-- can't live inside an inline UNIQUE constraint, so this is a unique index.
create unique index uq_positions_org_school_key
    on public.positions (organization_id, coalesce(school_id, '00000000-0000-0000-0000-000000000000'::uuid), key);

create trigger trg_positions_updated_at
    before update on public.positions
    for each row execute function public.set_updated_at();

create table public.position_permissions (
    id                  uuid primary key default gen_random_uuid(),
    position_id         uuid not null references public.positions(id) on delete cascade,
    permission_id       uuid not null references public.permissions(id) on delete cascade,

    unique (position_id, permission_id)
);

create table public.position_assignments (
    id                      uuid primary key default gen_random_uuid(),
    position_id              uuid not null references public.positions(id) on delete cascade,
    school_membership_id     uuid not null references public.school_memberships(id) on delete cascade,
    scope_id                 uuid, -- nullable: school-wide positions (Council President) have no sub-scope
    assigned_by               uuid references public.profiles(id),
    start_date                date not null default current_date,
    end_date                  date,
    created_at                 timestamptz not null default now(),

    check (end_date is null or end_date >= start_date)
);

comment on table public.position_assignments is
  'Example: Student X''s membership + "Robotics Club President" + '
  'scope_id = Robotics Club row. A student can hold multiple positions '
  'simultaneously (Council President AND Class Representative).';

create index idx_position_assignments_membership on public.position_assignments(school_membership_id);
create index idx_position_assignments_position on public.position_assignments(position_id);
create index idx_position_assignments_active
    on public.position_assignments(school_membership_id) where end_date is null;

-- Seed a starter set of common positions is intentionally NOT done here —
-- clubs/committees (the scope_id targets) don't exist until Student
-- Management (Section 22) ships. Positions are created by school admins once
-- those scope tables exist.

-- Seed a couple of common responsibility templates the same way — deferred to
-- Section 21 (School Foundation), once departments/grades/sections exist to
-- scope them against.