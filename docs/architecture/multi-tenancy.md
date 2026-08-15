# Multi-Tenancy Architecture

## The core shape

```
organizations (hierarchy: government bodies, school groups, independent schools)
    └── schools (physical tenant, owned by a school_group / independent_school org)
            └── school_memberships (a user's identity AT that school)
```

`organizations` models **administrative/ownership hierarchy**, not physical
schools. A row is one of three types:

- `government` — federal / regional / zonal / woreda (or a region-specific
  equivalent). `level` is a free-text label for display only — nothing in
  the schema assumes a fixed depth, so Addis Ababa's city-administration
  structure and a rural woreda's structure can both be represented without
  special-casing either.
- `school_group` — a trust/chain owning multiple physical schools.
- `independent_school` — the owning entity for a single school.

`parent_organization_id` is a plain self-reference, so the tree can be as
deep or shallow as reality requires. `schools` is a **separate table** —
every physical school points at the `school_group`/`independent_school`
organization that owns it (enforced by a trigger; a school can never point
directly at a `government` node).

## Three membership tables, not one

This is the biggest structural decision in Phase 2, and it comes straight
from your requirement that platform admins and government officials must
never implicitly become members of a school:

| Table | Who | Scoped to |
|---|---|---|
| `school_memberships` | Student, Parent, Teacher, all school staff, school leadership | one `school_id` |
| `organization_memberships` | Government officials, school-group-level admins | one `organization_id` (their subtree cascades down via `org_subtree_ids()`) |
| `platform_memberships` | Platform admin roles | nothing — no `organization_id`, no `school_id` at all |

A person can hold rows in more than one of these simultaneously (rare but
possible — e.g. a platform developer who also volunteers as a school
governor), and each is authorized completely independently. Granting
someone a `platform_memberships` row never grants school or organization
access, and vice versa.

`profiles` sits underneath all three — one row per human, tenant-agnostic,
regardless of how many schools/organizations they belong to or whether
they hold a platform role.

## Government hierarchy visibility, without hard-coding depth

A Regional Education Bureau Administrator has **one row** in
`organization_memberships` pointing at their region. Their visibility into
every zone, woreda, school-group, and school beneath that region comes from
a recursive function, not from a row per descendant:

```sql
org_subtree_ids(p_root_org_id uuid) -- root + every descendant, recursive CTE
```

`has_org_permission(key, target_org_id)` uses this to check "is
`target_org_id` inside the subtree of any organization I belong to" —
which is how a Woreda Officer sees their woreda's schools, a Regional
Officer sees every woreda beneath their region, and a Federal
Administrator sees everything, all through the same mechanism and the same
few rows.

Visibility is **strictly downward**. A Woreda Officer cannot see their
parent Region's other children (sibling woredas) or anything upward —
this is asserted directly in `tenant_isolation_test.sql`, part B.

## Why `organization_id` is denormalized onto `schools` and `school_memberships`

Every domain table going forward (students, attendance, exams, ...) will
carry both `school_id` and, denormalized, `organization_id`. Trade-off:

- RLS policies stay one join deep instead of chaining
  `table -> school -> organization` on every row check.
- `has_permission()` can check org-level oversight authority
  (`has_org_permission`) without an extra join.
- The cost is a sync trigger (`sync_school_membership_org_id`) keeping it
  correct whenever `school_id` changes — cheap, and only needs to exist
  once per table pattern. Every future module table should follow this
  same pattern.

## Isolation guarantee

No table in this system is readable or writable by an authenticated client
by default. Every access path is an explicit RLS policy, built from:

1. `user_school_ids()` / `user_org_ids()` — what tenants does this user
   directly belong to.
2. `org_subtree_ids()` — what does that expand to, downward.
3. `has_permission(key, school_id)` / `has_org_permission(key, org_id)` —
   within a tenant they can reach, are they specifically allowed to do
   this.
4. `is_platform_super_admin()` — the one deliberate global bypass.

`service_role` (server-side code, Edge Functions, migrations) bypasses RLS
entirely, as standard in Supabase — never exposed to a client.

See `docs/architecture/rbac.md` for how roles/permissions/scoped
permissions/responsibilities/positions compose within a tenant.

## What's intentionally deferred past Phase 2

- Scope targets referenced by `scoped_permissions.scope_id`,
  `organization_scoped_permissions.scope_id`, `responsibility_assignments
  .scope_id`, and `position_assignments.scope_id` (grades, sections,
  departments, subjects, clubs, committees) don't exist as tables yet.
  They're polymorphic UUIDs validated at the application layer until the
  owning module (School Foundation, Student Management, ...) ships and can
  add a proper FK + trigger-based validation.
- No responsibilities or positions are seeded with real data in Phase 2 —
  their scope targets don't exist yet. School Foundation (Section 21) is
  where the first real responsibility templates (Department Head, Class
  Advisor) get created, once departments/grades/sections exist.
