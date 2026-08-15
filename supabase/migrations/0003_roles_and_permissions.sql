-- ============================================================================
-- 0003_roles_and_permissions.sql
-- Phase 2.5 — Default roles
-- Phase 2.6 — Permissions
-- Phase 2.7 — Role-permission relationships
-- ============================================================================
-- Design note:
--   roles.context tells you WHICH membership table a role is assignable
--   through: 'school' -> school_memberships.base_role_id,
--            'organization' -> organization_memberships.base_role_id,
--            'platform' -> platform_memberships.base_role_id.
--   This stops someone from accidentally wiring "Teacher" into
--   platform_memberships or "Platform Auditor" into school_memberships.
--
--   roles.organization_id = NULL  -> system role template, usable everywhere
--                                    within its context.
--   roles.organization_id = <id>  -> custom role, private to that org
--                                    (Phase 2.10, 0005_custom_roles.sql).
--
--   Per your explicit instruction: department heads, class advisors, exam
--   coordinators, club coordinators, student council positions etc. are
--   NOT seeded here as roles. They are responsibilities (staff, 0004) or
--   positions (students, 0004), layered on top of one of the base roles
--   below. This file only seeds primary identities.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- roles
-- ----------------------------------------------------------------------------
create table public.roles (
    id                  uuid primary key default gen_random_uuid(),
    organization_id     uuid references public.organizations(id) on delete cascade,
    context             text not null check (context in ('school', 'organization', 'platform')),
    key                 text not null,
    name                text not null,
    description         text,
    system_default      boolean not null default false, -- seeded, not user-editable
    editable             boolean not null default false,  -- can an org admin edit its permission set
    deletable            boolean not null default false,  -- can an org admin delete it
    created_at          timestamptz not null default now(),
    updated_at          timestamptz not null default now()
);

comment on table public.roles is
  'Base role catalog, partitioned by context. system_default rows are seeded '
  'by migration and protected from edit/delete (see protect_system_roles in '
  '0005_custom_roles.sql). Custom roles (organization_id not null) are always '
  'editable/deletable by definition — enforced by chk_custom_role_flags below.';

create unique index uq_roles_system_key
    on public.roles(context, key) where organization_id is null;
create unique index uq_roles_org_key
    on public.roles(organization_id, context, key) where organization_id is not null;

alter table public.roles add constraint chk_custom_role_flags
    check (organization_id is null or (editable and deletable));

create trigger trg_roles_updated_at
    before update on public.roles
    for each row execute function public.set_updated_at();

-- Attach the base_role_id FKs deferred from 0002, each constrained by context
-- via trigger (a plain FK can't check roles.context, so we enforce it below).
alter table public.school_memberships       add column base_role_id uuid not null references public.roles(id);
alter table public.organization_memberships add column base_role_id uuid not null references public.roles(id);
alter table public.platform_memberships     add column base_role_id uuid not null references public.roles(id);

create index idx_school_memberships_role on public.school_memberships(base_role_id);
create index idx_org_memberships_role on public.organization_memberships(base_role_id);
create index idx_platform_memberships_role on public.platform_memberships(base_role_id);

create or replace function public.validate_role_context()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_context text;
  v_expected text;
begin
  select context into v_context from public.roles where id = new.base_role_id;
  v_expected := case TG_TABLE_NAME
                  when 'school_memberships' then 'school'
                  when 'organization_memberships' then 'organization'
                  when 'platform_memberships' then 'platform'
                end;
  if v_context <> v_expected then
    raise exception '% requires a role with context = %, got %.', TG_TABLE_NAME, v_expected, v_context;
  end if;
  return new;
end;
$$;

create trigger trg_school_memberships_role_context
    before insert or update of base_role_id on public.school_memberships
    for each row execute function public.validate_role_context();
create trigger trg_org_memberships_role_context
    before insert or update of base_role_id on public.organization_memberships
    for each row execute function public.validate_role_context();
create trigger trg_platform_memberships_role_context
    before insert or update of base_role_id on public.platform_memberships
    for each row execute function public.validate_role_context();

-- ----------------------------------------------------------------------------
-- permissions — global catalog, org-agnostic
-- ----------------------------------------------------------------------------
create table public.permissions (
    id                  uuid primary key default gen_random_uuid(),
    key                 text not null unique, -- 'module.action'
    module              text not null,
    description         text,
    created_at          timestamptz not null default now()
);

comment on table public.permissions is
  'Flat "module.action" catalog. Phase 2 only seeds what the tenant/RBAC/'
  'admin surface itself needs — each future module (Section 21+) adds its '
  'own rows here as it ships.';

create index idx_permissions_module on public.permissions(module);

-- ----------------------------------------------------------------------------
-- role_permissions
-- ----------------------------------------------------------------------------
create table public.role_permissions (
    id                  uuid primary key default gen_random_uuid(),
    role_id             uuid not null references public.roles(id) on delete cascade,
    permission_id       uuid not null references public.permissions(id) on delete cascade,
    created_at          timestamptz not null default now(),

    unique (role_id, permission_id)
);

create index idx_role_permissions_role on public.role_permissions(role_id);
create index idx_role_permissions_permission on public.role_permissions(permission_id);

-- ============================================================================
-- SEED — permission catalog (Phase-2-relevant only)
-- ============================================================================
insert into public.permissions (key, module, description) values
    -- tenant / platform admin
    ('platform.tenants.manage',    'platform', 'Onboard/suspend organizations at the platform level'),
    ('platform.subscriptions.manage','platform', 'Manage subscription/billing state for organizations'),
    ('platform.security.manage',   'platform', 'Manage platform-wide security settings'),
    ('platform.audit.view',        'platform', 'View platform-wide audit logs'),
    ('platform.analytics.view',    'platform', 'View system-wide analytics'),
    -- org / school admin
    ('organizations.manage',       'tenant', 'Create/edit organizations'),
    ('schools.manage',             'tenant', 'Create/edit schools within an organization'),
    ('schools.analytics.view',     'tenant', 'View aggregate analytics for schools in scope'),
    -- users & membership
    ('users.view',                 'users', 'View user profiles within scope'),
    ('users.manage',                'users', 'Invite/edit/suspend users within scope'),
    ('memberships.manage',          'users', 'Manage school/organization membership rows'),
    -- rbac administration
    ('roles.manage',                'rbac', 'Create/edit custom roles within an organization'),
    ('permissions.assign',          'rbac', 'Assign scoped permissions to a membership'),
    ('responsibilities.manage',     'rbac', 'Create/assign staff responsibilities'),
    ('positions.manage',            'rbac', 'Create/assign student positions'),
    -- early placeholders other modules will extend
    ('attendance.manage',           'attendance', 'Mark/edit attendance'),
    ('attendance.view',             'attendance', 'View attendance records'),
    ('students.manage',             'students', 'Create/edit student records'),
    ('students.view',               'students', 'View student records'),
    ('teachers.manage',             'staff', 'Manage teacher records'),
    ('club.members.manage',         'clubs', 'Manage membership of a club/society')
on conflict (key) do nothing;

-- ============================================================================
-- SEED — default roles
-- ============================================================================

-- ---- context: school -------------------------------------------------------
insert into public.roles (context, key, name, description, system_default) values
    ('school', 'student',              'Student',                        'Enrolled student.', true),
    ('school', 'parent',               'Parent / Guardian',              'Guardian linked to one or more students.', true),
    ('school', 'applicant',            'Applicant',                      'Prospective student in the admissions pipeline.', true),
    ('school', 'alumni',               'Alumni',                         'Former student with limited continued access.', true),
    ('school', 'teacher',              'Teacher',                        'Teaching staff.', true),
    ('school', 'accountant',           'Accountant',                     'Accounting and reconciliation.', true),
    ('school', 'finance_officer',      'Finance Officer',                'Operational financial work.', true),
    ('school', 'cashier',              'Cashier',                        'Physical payment collection.', true),
    ('school', 'hr_officer',           'HR Officer',                     'Day-to-day HR operations.', true),
    ('school', 'librarian',            'Librarian',                      'Library operations.', true),
    ('school', 'procurement_officer',  'Procurement Officer',            'Purchasing and supplier operations.', true),
    ('school', 'inventory_officer',    'Inventory Officer',              'Stock and inventory operations.', true),
    ('school', 'facilities_officer',   'Facilities Officer',             'Buildings, rooms, maintenance.', true),
    ('school', 'it_officer',           'IT Officer',                     'School-level IT operations.', true),
    ('school', 'counselor',            'School Counselor',               'Student counseling.', true),
    ('school', 'nurse',                'Nurse / Health Officer',         'Student health services.', true),
    ('school', 'registrar',            'Registrar',                      'Enrollment and academic records.', true),
    ('school', 'secretary',            'Secretary',                      'Administrative support.', true),
    ('school', 'principal',            'Principal / Head of School',     'Top school leadership.', true),
    ('school', 'vice_principal',       'Vice Principal / Deputy Principal', 'Deputy school leadership.', true),
    ('school', 'school_admin',         'School Administrator',           'Full administrative control of one school.', true),
    ('school', 'academic_director',    'Academic Director',              'Oversees academic program.', true),
    ('school', 'finance_manager',      'Finance Manager',                'Supervision, approvals, budgeting.', true),
    ('school', 'hr_manager',           'HR Manager',                     'HR supervision and policy.', true),
    ('school', 'operations_manager',   'Operations Manager',             'Day-to-day operational oversight.', true)
on conflict do nothing;

-- ---- context: platform ------------------------------------------------------
insert into public.roles (context, key, name, description, system_default) values
    ('platform', 'platform_super_admin', 'Platform Super Administrator',  'Unrestricted platform access.', true),
    ('platform', 'platform_admin',       'Platform Administrator',        'General platform administration.', true),
    ('platform', 'platform_support',     'Platform Support Administrator','Customer support tooling.', true),
    ('platform', 'platform_security',    'Platform Security Administrator','Platform security operations.', true),
    ('platform', 'platform_finance',     'Platform Finance Administrator','Billing/subscriptions across tenants.', true),
    ('platform', 'platform_operations',  'Platform Operations Administrator','Platform operational tooling.', true),
    ('platform', 'platform_developer',   'Platform Developer',            'Engineering access to platform tooling.', true),
    ('platform', 'platform_auditor',     'Platform Auditor',              'Read-only platform-wide audit access.', true)
on conflict do nothing;

-- ---- context: organization (government + school-group level) --------------
insert into public.roles (context, key, name, description, system_default) values
    ('organization', 'org_administrator',      'Organization Administrator',            'Group/trust-level admin over multiple schools.', true),
    ('organization', 'federal_admin',          'Federal Education Administrator',        null, true),
    ('organization', 'federal_officer',        'Federal Education Officer',              null, true),
    ('organization', 'federal_analyst',        'Federal Education Analyst',              null, true),
    ('organization', 'federal_auditor',        'Federal Education Auditor',              null, true),
    ('organization', 'regional_admin',         'Regional Education Bureau Administrator', null, true),
    ('organization', 'regional_officer',       'Regional Education Officer',              null, true),
    ('organization', 'regional_analyst',       'Regional Education Analyst',              null, true),
    ('organization', 'regional_inspector',     'Regional Education Inspector',            null, true),
    ('organization', 'regional_auditor',       'Regional Education Auditor',              null, true),
    ('organization', 'zonal_admin',            'Zonal Education Administrator',           null, true),
    ('organization', 'zonal_officer',          'Zonal Education Officer',                 null, true),
    ('organization', 'zonal_analyst',          'Zonal Education Analyst',                 null, true),
    ('organization', 'zonal_inspector',        'Zonal Education Inspector',               null, true),
    ('organization', 'woreda_admin',           'Woreda Education Administrator',          null, true),
    ('organization', 'woreda_officer',         'Woreda Education Officer',                null, true),
    ('organization', 'woreda_analyst',         'Woreda Education Analyst',                null, true),
    ('organization', 'woreda_inspector',       'Woreda Education Inspector',              null, true),
    ('organization', 'woreda_auditor',         'Woreda Education Auditor',                null, true)
on conflict do nothing;

-- ============================================================================
-- SEED — baseline role_permissions
-- ============================================================================
-- Full per-module permission grants will grow as each module ships (Sections
-- 21+). Phase 2 wires only the tenant/RBAC/admin-surface permissions seeded
-- above, using pattern groups so this stays maintainable at ~50 roles.
do $$
begin
  -- platform_super_admin: everything
  insert into public.role_permissions (role_id, permission_id)
  select (select id from public.roles where key = 'platform_super_admin' and context = 'platform'), id
  from public.permissions
  on conflict do nothing;

  -- other platform admin roles: platform module permissions, minus security/finance
  -- for the ones that shouldn't default to holding those (least privilege default;
  -- an org can still grant more via scoped/custom roles later).
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'platform' and r.key in ('platform_admin', 'platform_operations', 'platform_support')
    and p.module = 'platform' and p.key not in ('platform.security.manage')
  on conflict do nothing;

  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'platform' and r.key = 'platform_security'
    and p.module = 'platform'
  on conflict do nothing;

  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'platform' and r.key = 'platform_finance'
    and p.key in ('platform.subscriptions.manage', 'platform.analytics.view')
  on conflict do nothing;

  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'platform' and r.key in ('platform_auditor', 'platform_developer')
    and p.key in ('platform.audit.view', 'platform.analytics.view')
  on conflict do nothing;

  -- school_admin / principal: full school-scoped admin set
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'school' and r.key in ('school_admin', 'principal', 'vice_principal')
    and p.key in ('schools.manage','users.view','users.manage','memberships.manage',
                  'roles.manage','permissions.assign','responsibilities.manage','positions.manage',
                  'attendance.manage','attendance.view','students.manage','students.view','teachers.manage')
  on conflict do nothing;

  -- academic_director / registrar: academic + student data, no rbac admin
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'school' and r.key in ('academic_director', 'registrar')
    and p.key in ('students.manage','students.view','attendance.view','users.view')
  on conflict do nothing;

  -- finance_manager: finance-adjacent tenant permissions (module-specific
  -- finance.* permissions will be added when the Finance module, Section 27, ships)
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'school' and r.key in ('finance_manager', 'hr_manager', 'operations_manager')
    and p.key in ('users.view')
  on conflict do nothing;

  -- teacher: view students, manage attendance for own scope (fine-grained
  -- section/grade limits come from scoped_permissions, 0004)
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'school' and r.key = 'teacher'
    and p.key in ('students.view','attendance.manage','attendance.view')
  on conflict do nothing;

  -- general school staff baseline: view-only, scoped_permissions add specifics
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'school'
    and r.key in ('accountant','finance_officer','cashier','hr_officer','librarian',
                  'procurement_officer','inventory_officer','facilities_officer',
                  'it_officer','counselor','nurse','secretary')
    and p.key in ('students.view')
  on conflict do nothing;

  -- student / parent / applicant / alumni: intentionally zero base permissions.
  -- They rely entirely on positions (students) or scoped_permissions.

  -- government roles: view/analytics only at Phase 2 — module-specific
  -- government reporting permissions land with the Government Portal (Section 18).
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'organization'
    and r.key like '%_admin' and r.key <> 'org_administrator'
    and p.key in ('schools.analytics.view', 'users.view')
  on conflict do nothing;

  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'organization'
    and (r.key like '%_officer' or r.key like '%_analyst' or r.key like '%_inspector' or r.key like '%_auditor')
    and p.key in ('schools.analytics.view')
  on conflict do nothing;

  -- org_administrator (school-group level): manage schools/users within their group
  insert into public.role_permissions (role_id, permission_id)
  select r.id, p.id
  from public.roles r, public.permissions p
  where r.context = 'organization' and r.key = 'org_administrator'
    and p.key in ('schools.manage','users.view','users.manage','memberships.manage',
                  'roles.manage','schools.analytics.view')
  on conflict do nothing;
end $$;