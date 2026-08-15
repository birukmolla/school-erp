# RBAC Architecture

## The composition model

```
User
 ├─ school_membership (per school)
 │    ├─ base_role                  → role_permissions        (broad, stable)
 │    ├─ scoped_permissions         → one permission, one scope instance
 │    ├─ responsibility_assignments → responsibility_permissions (staff bundle)
 │    └─ position_assignments       → position_permissions       (student bundle)
 ├─ organization_membership (per organization, government/school-group)
 │    ├─ base_role                  → role_permissions
 │    └─ organization_scoped_permissions
 └─ platform_membership (global, at most one)
      └─ base_role                  → role_permissions
```

A user's *effective* permission at a school is the union of everything
under `school_memberships` **plus** any org-level oversight authority
reaching that school (`has_org_permission`). This union lives in one
function, `has_permission(key, school_id)` — RLS and application code both
call it rather than re-implementing the logic. The organization-level
equivalent is `has_org_permission(key, org_id)`; the platform-level
equivalent is `has_platform_permission(key)`.

## Why three separate role *contexts*

`roles.context` is `'school' | 'organization' | 'platform'`, and a
membership table can only reference a role from its matching context
(enforced by trigger, `validate_role_context`). This stops "Teacher" from
ever being wired into `platform_memberships`, or "Platform Auditor" into
`school_memberships` — the three identity worlds (school staff/students,
government/school-group officials, platform operators) never bleed into
each other by accident.

## Why four grant layers instead of "just add more roles"

The naive approach — a role per job title (Department Head, Class
Advisor, Exam Coordinator, Club President, Woreda Inspector, ...) —
explodes combinatorially, because real people hold combinations:

> Teacher **+** Mathematics Department Head **+** Grade 12-B Class Advisor

or, for a student:

> Student **+** Student Council President **+** Robotics Club President
> **+** Grade 12-B Class Representative

Modeling every combination as a distinct role is unmaintainable and (per
your explicit instruction) not how this system works. Instead:

| Layer | Answers | Example | Lifetime |
|---|---|---|---|
| **base_role** | "What kind of person are you here, broadly?" | Teacher, Student, Regional Education Officer | Stable, rarely changes |
| **scoped_permissions** | "What extra thing can you do, and where?" | `attendance.manage` limited to Grade 12 / Section B | Ad hoc, admin-granted |
| **responsibilities** (staff only) | "What position do you hold, and where?" | Mathematics Department Head → bundles `teachers.manage` + scope = Mathematics dept | Has a start/end date |
| **positions** (students only) | "What leadership role do you hold, and where?" | Robotics Club President → bundles `club.members.manage` + scope = Robotics Club | Has a start/end date, may later track elections/terms |

**Responsibilities and positions are deliberately two separate table
sets**, not one generic "extra role" table shared by staff and students —
per your instruction to keep student leadership conceptually distinct from
staff job functions, even though the underlying pattern (a bundle of
permissions, assigned to a membership, for a scope, for a time window) is
structurally similar.

Government scope (region/zone/woreda) is handled differently again — not
through `scoped_permissions`, but through the organization hierarchy
itself (`org_subtree_ids`) plus `organization_scoped_permissions` for the
rare case of a grant that doesn't follow the normal subtree (e.g. a
Regional Officer additionally granted visibility into one specific woreda
outside their own region).

## Default (system) roles vs custom roles

- `roles.organization_id IS NULL` → a **system role template**, seeded by
  migration, visible everywhere within its context, and protected from
  edits (`protect_system_roles` trigger blocks UPDATE/DELETE on
  `system_default` rows).
- `roles.organization_id = <org>` → a **custom role**, private to that
  org, always `editable = true, deletable = true` (enforced by a check
  constraint). Created from scratch or by cloning a template with
  `clone_role_for_org()`, which copies the source role's
  `role_permissions` as a starting point and inherits its `context`.

Phase 2 seeds roughly 50 system roles across the three contexts:

- **school** (25): Student, Parent/Guardian, Applicant, Alumni, Teacher,
  Accountant, Finance Officer, Cashier, HR Officer, Librarian, Procurement
  Officer, Inventory Officer, Facilities Officer, IT Officer, Counselor,
  Nurse/Health Officer, Registrar, Secretary, Principal, Vice Principal,
  School Administrator, Academic Director, Finance Manager, HR Manager,
  Operations Manager.
- **platform** (8): Platform Super Administrator, Administrator, Support
  Administrator, Security Administrator, Finance Administrator, Operations
  Administrator, Developer, Auditor.
- **organization** (19): Organization Administrator (school-group level),
  plus Federal/Regional/Zonal/Woreda Education Administrator, Officer,
  Analyst, Inspector, Auditor (not every level has every sub-role — see
  the seed data in `0003_roles_and_permissions.sql` for the exact set).

Everything else — the long tail of "50+ roles" that's really about job
*functions*, not identities — is built as a responsibility or position
layered on top of one of these, or as a genuinely new custom role per org
where a different base identity is truly warranted.

## Permission naming convention

`module.action`, e.g. `attendance.manage`, `students.view`,
`club.members.manage`, `platform.tenants.manage`. Every new module adds
its own rows to the `permissions` catalog as it ships — the catalog table
itself never needs a schema change.

## Testing

`supabase/tests/tenant_isolation_test.sql` covers three isolation
guarantees (Phase 2.12):

1. Two unrelated school groups can't see each other's schools,
   memberships, or profiles (SELECT and INSERT).
2. Government hierarchy visibility is correct and one-directional: a
   Regional Officer sees a school nested three levels down in their
   subtree; a Woreda Officer does **not** see a sibling woreda's school,
   and subtree visibility never extends upward to an ancestor.
3. A platform membership grants zero implicit school/organization access
   — a non-super-admin platform role sees nothing outside what it's
   explicitly been granted.

Not yet covered (add once the relevant module ships): permission-boundary
cases within a single school (e.g. "Teacher A, scoped to Grade 10, cannot
touch Grade 12 attendance"), and responsibility/position expiry
(`end_date` in the past should stop granting access — the logic is in
`has_permission()` already, but there's no test asserting it yet).
