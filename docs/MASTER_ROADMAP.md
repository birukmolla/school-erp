# School ERP Platform
## Master Development Roadmap

*Last verified against the repository: `develop` branch, `birukmolla/school-erp`.*
*This document is meant to be re-opened and updated as phases complete — treat it as a living project plan, not a one-time artifact.*

---

## 1. Executive Summary

This is a multi-tenant, production-grade School ERP platform for the Ethiopian education sector, built by a two-person team (you and your cousin). It is currently in early foundation stage: the monorepo, application shells, and — as of the most recent work — the complete multi-tenant/RBAC database foundation are in place. No feature module (students, attendance, exams, finance, etc.) has been built yet, and none of the five web applications contain real UI beyond their default scaffolds.

**Where the project realistically stands right now:** foundation phase ~35% complete. The hardest architectural decisions (tenancy model, authorization model) are made and verified. Everything from here is largely additive — each module follows an established pattern rather than inventing a new one.

**Bottom line time estimate** (assumptions detailed in Section 12): a realistic **first pilot school onboarding around month 7–8**, a **feature-complete core ERP around month 13–15**, and a **Django-migrated, multi-school-ready platform around month 18–20** — assuming both developers sustain near-full-time effort. Section 25 gives the full breakdown and shows how these numbers move if your actual weekly hours are lower.

---

## 2. Product Vision

A single SaaS codebase serving many independent schools, school groups, and eventually government education bodies — without a fork or redeploy per school. A school's identity, branding, and feature set come from tenant configuration, not from custom code. The platform must feel like dedicated software to every school while being one shared system underneath, and it must be trustworthy enough that a Ministry-adjacent government user can be given scoped visibility into it without any risk of cross-tenant leakage.

---

## 3. Product Scope

The final platform is not "a school management website." It is a full operational ERP spanning: multi-tenant identity and authorization; academic structure; student lifecycle management; a learning management system; two independent attendance systems (student and staff); examinations and report cards; HR/staff management; finance and billing; library; inventory and procurement; facilities; communication (in-app, email, SMS, push); role-aware AI assistance; a platform administration console; a government oversight portal with hierarchy-based access; and a branded mobile app for students and parents. Section 9 is the complete feature inventory.

---

## 4. Current Project State *(source of truth: the repository itself)*

### 4.1 What exists and works today

| Area | State |
|---|---|
| Monorepo | Turborepo + pnpm workspace, correctly configured (`apps/*`, `packages/*`). |
| Web applications | Five Next.js apps exist as directories with correct config: `school-portal`, `staff-portal`, `school-admin`, `platform-admin`, `government-portal`. **Every one of them is still the unmodified `create-next-app` starter page** — no real screen has been built in any app yet. |
| Session middleware | Present and correct in all five apps — each calls Supabase's `getUser()` (not the insecure `getSession()`) to refresh auth state. This is the one piece of application-layer auth logic that already exists and is already correct. |
| Mobile app | `apps/mobile` is an Expo project, but it is still the **unmodified Expo starter template** (default tabs, theming demo, example screens) — not yet adapted to this product. |
| `packages/supabase` | The only package with real implementation: browser and server Supabase client factories. Its `package.json` also declares a `middleware` export that does not exist as a file yet — a small inconsistency to clean up when Phase 3 (Auth) starts. |
| All other packages | `ui`, `auth`, `permissions`, `api-client`, `types`, `validation`, `i18n`, `config`, `utils` — every one of these is an **empty scaffold**: a `package.json` only, no `src/` directory, no code. This is expected at this stage, not a gap to panic about — but it means "shared infrastructure" is a real phase, not already done. |
| Database — Multi-tenancy & RBAC | **Complete and verified.** Six migrations (`0001`–`0006`) implementing: organization hierarchy (government/school-group/independent-school, arbitrary depth), the physical `schools` table, three separate membership contexts (school, organization/government, platform — deliberately never conflated), ~50 seeded default roles, a permission catalog, role-permission mappings, two scoped-permission systems (school-level and organization/government-level), two parallel "extra bundle" systems (`responsibilities` for staff, `positions` for students — kept intentionally separate), a custom-role system with protected system defaults, and Row Level Security across all 17 tenant tables. A tenant-isolation test suite exists and **passes** locally, covering cross-tenant isolation, government-hierarchy visibility (including sibling/ancestor negative cases), and confirmation that platform admin membership grants zero implicit school/organization access. |
| Documentation | `docs/architecture/multi-tenancy.md` and `docs/architecture/rbac.md` exist and accurately describe the implemented model. |

### 4.2 Known gaps and immediate housekeeping

- **The Phase 2 database work is merged to `develop` but not yet to `main`.** This is the single most important immediate action — treat "get it reviewed and merged to `main`" as step zero of everything below, not an afterthought.
- No CI/CD exists yet (no `.github/workflows`). No `.env.example`. No root `README.md`. These are cheap to add and belong in Phase 4 (Shared Infrastructure), not deferred indefinitely.
- `scoped_permissions.scope_id`, `responsibilities.scope_id`, and `positions.scope_id` are intentionally un-constrained (polymorphic) right now because their target tables (grades, sections, departments, clubs) don't exist yet. This gets tightened with real foreign keys in Phase 6 (School Foundation) — not a bug, a deliberate sequencing decision already documented in `multi-tenancy.md`.
- No responsibilities or positions have real seed data yet, for the same reason.

### 4.3 Discrepancy note

An earlier planning document referenced this project describing a different package list (including a `backend/django` folder from day one) and a six-application split with a combined `packages/supabase` layout. **The actual repository does not have a `backend/` directory at all**, and Django does not enter the picture until its own dedicated migration phase (Section 21). Where planning documents and the repository disagree, this roadmap follows the repository.

---

## 5. Architecture Overview

```
Client layer   →  school-portal · staff-portal · school-admin ·
                   platform-admin · government-portal · mobile (Expo)
                            │
Shared layer   →  packages/ui, auth, permissions, api-client,
                   types, validation, i18n, config, utils
                            │
Data layer     →  Supabase (Postgres + Auth + Storage + Realtime)
                   — RLS as the final authorization boundary
                            │
(Later)        →  Django REST API replaces the Supabase data layer;
                   PostgreSQL and the tenant/RBAC schema carry over
```

The authorization model (Section 7) is deliberately backend-agnostic at the concept level — `has_permission()` / `has_org_permission()` as the single source of truth is a pattern that survives the eventual Django migration, even though its *implementation* moves from a Postgres function to Django application logic (or a Postgres function Django calls — decided in Section 21).

---

## 6. Application Scope

| Application | Audience | Core purpose |
|---|---|---|
| `school-portal` | Students, parents/guardians, applicants, alumni | Academic self-service: grades, attendance, assignments, fees, announcements |
| `staff-portal` | Teachers and all non-admin staff | Daily operational workspace scoped to each person's role/responsibilities |
| `school-admin` | School leadership and administrators | Full control of one school's configuration, users, roles, academic structure |
| `platform-admin` | Platform operations team | Tenant onboarding, subscriptions, platform-wide monitoring and support |
| `government-portal` | Federal/regional/zonal/woreda officials | Hierarchy-scoped oversight and analytics — never operational school data entry |
| `mobile` (Expo) | Students and parents (teachers later) | Branded, tenant-aware companion app; one codebase for every school |

---

## 7. User & Permission Model *(as actually implemented)*

Three membership contexts, never conflated:

- **`school_memberships`** — students, parents, teachers, staff, school leadership. Scoped to one school.
- **`organization_memberships`** — government officials and school-group-level admins. Scoped to one organization node; visibility cascades *downward only* through the org hierarchy (a Regional official sees everything beneath their region; a Woreda official does not see a sibling woreda or their own parent region's other children).
- **`platform_memberships`** — platform operations roles. Carries **no** organization or school scope at all — granting a platform role never implicitly grants tenant access, by design and by test.

On top of a base role, two "extra bundle" mechanisms exist and are deliberately kept apart:

- **Responsibilities** (staff only) — e.g. a Teacher who is also Mathematics Department Head and Grade 12-B Class Advisor. Each responsibility bundles permissions, scoped to a specific department/grade/section, with a start/end date.
- **Positions** (students only) — e.g. a Student who is also Student Council President and Robotics Club President. Structurally similar to responsibilities but intentionally a separate system, since student leadership is not a staff job function and may later need election/term tracking staff responsibilities never will.

Custom roles: a school or organization admin can create a role scoped to their own tenant, either from scratch or by cloning a system default. System default roles are protected from edit/delete.

Every authorization decision — in the database today, and in the eventual Django backend — should route through the equivalent of `has_permission(key, school_id)` / `has_org_permission(key, org_id)`. New modules must not invent new authorization logic; they extend the permission catalog and, where relevant, add responsibility/position templates.

---

## 8. Ethiopian Education Organization Model

The organization hierarchy is a plain self-referencing tree with no fixed depth — this is intentional, because administrative structure genuinely differs across Ethiopia (a city administration like Addis Ababa is not shaped like a rural woreda hierarchy). A government node's `level` field (federal/regional/zonal/woreda, or a locally accurate equivalent) is descriptive only; nothing in the schema assumes exactly four levels always exist. Schools attach to `school_group` or `independent_school` organization nodes, which may themselves sit anywhere in a government subtree for administrative-reporting purposes, or entirely outside government structure for a purely private school group.

This means onboarding a region whose administrative structure differs from another region requires **zero schema changes** — only new organization rows.

---

## 9. Complete Feature Inventory

| Domain | Key capabilities |
|---|---|
| Platform foundation | Multi-tenancy, org hierarchy, auth, RBAC, scoped permissions, responsibilities, positions, custom roles, RLS, audit logging, user/membership management |
| School foundation | Academic years, terms, grades, sections, subjects, departments, classrooms, teaching assignments, timetables, calendar, branding, settings |
| Student management | Profiles, guardians, enrollment, IDs, documents, transfers, status, discipline, clubs/committees, student council, class reps |
| LMS | Courses, lessons, materials, assignments, quizzes, submissions, grading, progress tracking, teacher feedback |
| Attendance | **Student** (daily/period, absence, late, excused) and **staff** (check-in/out, QR-based later, leave integration) as two independent systems |
| Examination | Question bank, exam creation/scheduling/rooms, grading, results, report cards, publication, academic reports |
| Teacher & staff management | Employee profiles, employment records, contracts, teaching assignments, responsibilities, leave, staff attendance, payroll-ready structure |
| Finance | Fee structures, invoices, payments, receipts, discounts, scholarships, refunds, expenses, budgets, accounting foundations, financial reports |
| Library | Books, copies, categories, authors, borrowing, returns, fines, digital resources |
| Inventory & procurement | Items, stock, stores, suppliers, purchase requests/orders, receiving, stock movements, reports |
| Facilities | Buildings, rooms, assets, maintenance requests, work orders, facility status |
| Communication | Announcements, messaging, parent-teacher channels, email, SMS, push, in-app notifications, calendar |
| Reports & analytics | School/student/academic/attendance/finance/staff/government dashboards, exportable reports, advanced filtering, audit history |
| AI layer | Role-aware assistance for teachers, principals, finance, HR, government, platform admin — always authorized through the same permission model, never a bypass |
| Platform-wide enhancements | Advanced search, global filters, bulk/CSV/Excel import-export, activity timelines, attachments, comments, approval workflows, dark mode, accessibility, English/Amharic localization, offline support where appropriate, feature flags |
| Mobile | Branded student/parent companion app; teacher functionality and QR attendance later |

---

## 10. Development Principles

These carry forward unchanged from the foundation work already done — restated here because every future phase should be checked against them:

1. Tenant isolation is a **database-level** guarantee, never a frontend-only check.
2. Users, memberships, roles, permissions, responsibilities, and positions stay conceptually and structurally separate — do not collapse them into one generic table for convenience.
3. A recurring job function (Department Head, Exam Coordinator, Club President) is a responsibility or position layered on a stable base role — not a new primary role.
4. Every module routes authorization through the existing permission-check functions; no module invents its own access-control logic.
5. Every new domain table follows the established tenant-column pattern (`school_id` + denormalized `organization_id`) so RLS stays consistent and shallow.
6. `packages/api-client` is the only thing UI components talk to for data — never call Supabase directly from a component. This is what makes the eventual Django migration a service-layer swap instead of a rewrite.
7. Don't build a module's UI before its data model and RLS are settled, the same discipline that was applied to Phase 2 before any school-facing feature began.

---

## 11. Phase-by-Phase Roadmap

> Status legend: ✅ done · 🔶 in progress / needs final merge · ⬜ not started

| # | Phase | Status | Depends on |
|---|---|---|---|
| 0 | Vision & Product Definition | ✅ | — |
| 1 | System Architecture & Monorepo Scaffold | ✅ | 0 |
| 2 | Multi-Tenant Foundation & RBAC | 🔶 *(done on `develop`, needs merge to `main`)* | 1 |
| 3 | Authentication & Session Management | ⬜ | 2 |
| 4 | Shared Platform Infrastructure | ⬜ | 3 |
| 5 | School Foundation | ⬜ | 4 |
| 6 | Student Management | ⬜ | 5 |
| 7 | Learning Management System | ⬜ | 6 |
| 8 | Attendance (student + staff) | ⬜ | 6 |
| 9 | Examination | ⬜ | 7, 8 |
| 10 | Teacher & Staff Management | ⬜ | 5 |
| 11 | Finance | ⬜ | 6, 10 |
| 12 | Library | ⬜ | 6 |
| 13 | Inventory & Procurement | ⬜ | 5 |
| 14 | Facilities | ⬜ | 5 |
| 15 | Communication | ⬜ | 4, 6 |
| 16 | Mobile Application (v1) | ⬜ | 6, 8, 9 (needs real data to display) |
| 17 | Reports & Cross-Module Analytics | ⬜ | 8, 9, 11 |
| 18 | AI Layer | ⬜ | 17 |
| 19 | Platform Admin (full build-out) | ⬜ | 2, 4 |
| 20 | Government Portal (full build-out) | ⬜ | 2, 17 |
| 21 | School Onboarding, Domains & Branding | ⬜ | 5, 19 |
| 22 | Platform-Wide Enhancements | ⬜ | most core modules |
| 23 | Security & Compliance Hardening | ⬜ | all above |
| 24 | Testing, Performance & Load | ⬜ | all above |
| 25 | Django Migration | ⬜ | 23, 24 |
| 26 | Production Launch & First Pilot | ⬜ | 24 (25 optional before pilot — see Section 21) |
| 27 | Multi-School Scaling | ⬜ | 26 |

---

## 12. Phase Estimates

**Assumptions behind every number below:**
- Two developers, both contributing consistently.
- "Working day" = one focused person-day (~5–6 hours of actual building, not calendar availability).
- Two-developer parallelization is modeled at **~1.6×** speedup over one developer working alone — not 2×, because integration, code review, and unavoidable sequential dependencies eat into raw parallelism. Section 14 explains where each phase actually splits.
- Optimistic assumes clean execution and few surprises. Realistic assumes normal friction (debugging, minor rework, review cycles). Conservative assumes a meaningfully harder module, illness/unavailability, or an architecture wrinkle that needs a second pass.
- If your real weekly commitment is less than near-full-time (very likely for a side project), **multiply every calendar-week figure by (your target full-time weeks ÷ actual hours-equivalent weeks)** — e.g. if you're each realistically doing 15 hours/week instead of ~30, roughly double every calendar-week number.

| # | Phase | Person-days (realistic) | Calendar weeks — Optimistic | Realistic | Conservative |
|---|---|---|---|---|---|
| 2 | *(remaining: merge + review only)* | 1 | <1 | <1 | 1 |
| 3 | Authentication & Sessions | 8 | 0.5 | 1 | 1.5 |
| 4 | Shared Infrastructure | 12 | 1 | 1.5 | 2.5 |
| 5 | School Foundation | 14 | 1 | 1.5 | 2.5 |
| 6 | Student Management | 16 | 1.5 | 2 | 3 |
| 7 | LMS | 20 | 1.5 | 2.5 | 4 |
| 8 | Attendance | 12 | 1 | 1.5 | 2.5 |
| 9 | Examination | 18 | 1.5 | 2 | 3.5 |
| 10 | Teacher & Staff Mgmt | 14 | 1 | 1.5 | 2.5 |
| 11 | Finance | 22 | 2 | 3 | 4.5 |
| 12 | Library | 8 | 0.5 | 1 | 1.5 |
| 13 | Inventory & Procurement | 10 | 1 | 1.5 | 2 |
| 14 | Facilities | 8 | 0.5 | 1 | 1.5 |
| 15 | Communication | 14 | 1 | 1.5 | 2.5 |
| 16 | Mobile v1 | 24 | 2 | 3 | 4.5 |
| 17 | Reports & Analytics | 14 | 1 | 1.5 | 2.5 |
| 18 | AI Layer | 12 | 1 | 1.5 | 2.5 |
| 19 | Platform Admin | 16 | 1.5 | 2 | 3 |
| 20 | Government Portal | 16 | 1.5 | 2 | 3 |
| 21 | Onboarding/Domains/Branding | 10 | 1 | 1.5 | 2 |
| 22 | Platform-Wide Enhancements | 18 | 1.5 | 2.5 | 4 |
| 23 | Security & Compliance | 12 | 1 | 1.5 | 2.5 |
| 24 | Testing, Perf & Load | 14 | 1 | 1.5 | 2.5 |
| 25 | Django Migration | 30 | 2.5 | 4 | 6 |
| 26 | Production Launch & Pilot | 10 | 1 | 1.5 | 3 *(includes real-world feedback lag)* |
| 27 | Multi-School Scaling | 16 | 1.5 | 2 | 3.5 |

**Totals (Phases 3–27, i.e. everything remaining):**

| Scenario | Total calendar time |
|---|---|
| Optimistic | ~30 weeks (≈ 7 months) |
| **Realistic** | **~42 weeks (≈ 9.5–10 months)** |
| Conservative | ~62 weeks (≈ 14 months) |

Add Phase 25 (Django Migration) *before* Phase 27 always, but it can be sequenced either right after Phase 24 or deferred until just before multi-school scaling — see Section 21 for the trade-off. The totals above already include it once.

---

## 13. Dependencies

The dependency table in Section 11 is the authoritative map; the practical implications:

- **Nothing school-facing can start before Phase 5 (School Foundation)** — it's the first phase where `scope_id` polymorphic columns get real foreign keys (grades, sections, departments), which every later scoped permission, responsibility, and position depends on.
- **Finance, LMS, Attendance, Examination all depend on Student Management (6)**, but are otherwise independent of each other — genuine parallelization opportunity for two developers.
- **Mobile (16)** should not start in earnest until Student Management + Attendance + Examination have real data to display — starting mobile UI against empty/fake data usually means rebuilding screens once real APIs land.
- **Government Portal (20)** is mostly a UI layer on top of authorization that already exists (Phase 2) plus analytics that need Phase 17 — it is lighter than it looks precisely because the hard part (hierarchy-based access) is already done.
- **Django Migration (25)** should not start until the Supabase-based product has had real usage (ideally through Phase 26's pilot) — migrating a backend that hasn't been validated by a real school risks migrating the wrong thing.

---

## 14. Two-Developer Execution Plan

**General pattern, not a rigid rule:** rather than a permanent "backend dev / frontend dev" split, assign by *module*, with one developer owning a module's data model + API + core screens, and the other picking up a different, non-blocking module in parallel. Swap who does data-layer vs. UI-heavy work across phases so both of you stay fluent in the whole stack — useful insurance for a two-person team where either person being unavailable shouldn't stall everything.

| Phase type | Recommended split |
|---|---|
| Phase 3 (Auth) | Sequential — both should understand this deeply before splitting off; don't parallelize this one. |
| Phase 4 (Shared Infra) | Split by package: one owns `api-client` + `validation`, the other owns `ui` + `i18n`/`config`. |
| Phases 5–15 (feature modules) | One developer per module where possible, run two modules in parallel once dependencies allow (e.g. Library and Facilities have no cross-dependency and can run fully in parallel). |
| Phase 16 (Mobile) | One developer leads mobile while the other continues a web module — mobile is naturally isolated by codebase. |
| Phases 19–20 (Platform Admin, Government Portal) | Can run in parallel — different apps, same underlying auth data, minimal collision risk. |
| Phase 23–24 (Security, Testing) | Both developers, but split by *type*: one drives security review + RLS audit, the other drives test coverage + load testing. |
| Phase 25 (Django) | Highest coordination cost in the whole roadmap — do not split by "backend/frontend" here; split by *domain* (one owns auth/RBAC parity, the other owns module-by-module data migration), with frequent sync points. |

**Coordination mechanics that matter more than the split itself:**
- **Git workflow:** feature branches off `develop`, PR review required before merge (you've already established this pattern for Phase 2 — keep it for everything).
- **Migration coordination:** only one developer should author a given migration file at a time; if both are touching schema in the same week, agree on file-numbering order before either starts, to avoid merge conflicts in `supabase/migrations/`.
- **Shared package changes:** anything touched in `packages/*` should be flagged in a quick sync before merging — a change to `packages/ui` or `packages/api-client` affects every app, unlike a change scoped to one app directory.
- **Integration points:** treat the end of every phase as an integration checkpoint — both developers should be able to run the whole `pnpm dev` workspace and click through the new feature before calling a phase done, not just review the diff.

---

## 15. Milestones

| Milestone | Phases included | What's available | Definition of success | Est. time from now |
|---|---|---|---|---|
| **M1 — Foundation Complete** | 2, 3, 4 | Auth works end to end, shared packages have real code, tenant/RBAC verified | A user can sign up, get invited to a school, log in, and see only what their role allows — proven against the actual DB, not just the UI | ~5–6 weeks |
| **M2 — Core School Platform** | 5, 6, 8, 10 | Academic structure, students, attendance, staff exist | A school admin can set up a school's structure and enroll real students/staff | ~13–15 weeks |
| **M3 — First Usable ERP** | +7, 9, 11 (partial), 15 | LMS, exams, basic finance, communication | A teacher can run a full term: assignments → attendance → exams → report cards, with parents notified | ~24–27 weeks |
| **M4 — Complete School ERP** | +12, 13, 14, 17 | Library, inventory, facilities, analytics | Every module in Section 9 (excluding mobile/AI/government) is usable | ~32–36 weeks |
| **M5 — Mobile Application** | 16 | Branded parent/student app live | A parent can check grades/attendance/fees from the app | overlaps M3–M4, live by ~30 weeks |
| **M6 — Government Platform** | 19, 20 | Platform admin + government portal live | A regional official can see aggregate data for their subtree with zero cross-region leakage | ~40–44 weeks |
| **M7 — Production-Ready Platform** | 21, 22, 23, 24 | Onboarding flow, hardening, full test coverage | Passes a full security/RLS audit and load test; ready for a real school's data | ~48–52 weeks |
| **M8 — First School Pilot** | 26 | One real school live on the platform | A real school runs at least one full term without a critical incident | ~50–56 weeks |
| **M9 — Multi-School SaaS** | 25, 27 | Django-migrated, scale-tested | Platform verified stable with multiple concurrent real schools | ~65–75 weeks |

---

## 16. Testing Strategy

| Layer | Covers |
|---|---|
| Unit | Business logic in `packages/*`, especially `permissions` and `validation` |
| Integration | API-client ↔ database round-trips per module |
| Database / RLS | Every new table gets isolation assertions in the style already established by `tenant_isolation_test.sql` |
| RBAC / scoped permission | Explicit scenarios (see below) — not just "does the happy path work" |
| E2E | Critical user journeys per app (enrollment, attendance marking, exam publication, fee payment) |
| Mobile | Device/simulator pass on both platforms before each release |
| Performance / load | Query performance under realistic school counts, especially anything using `org_subtree_ids()` |
| Security | Formal review pass before Phase 26, not an afterthought |
| Regression | Re-run the full RLS/tenant-isolation suite before every release, permanently |

**Required security scenarios, explicitly tested, forever:**
- School A cannot access School B's data.
- A teacher cannot access students outside their scoped grade/section.
- A Department Head cannot manage an unrelated department.
- A Woreda officer cannot access an unrelated woreda.
- A school admin cannot access another school.
- A platform membership never leaks into school- or organization-level access.

These are not new — they extend the pattern already proven in Phase 2's test suite to every module that adds scoped data.

---

## 17. Security Strategy

Security is continuous, not a single phase — Phase 23 is a *hardening and audit* pass, not the first time security is considered. Every phase's Definition of Done (Section 26) includes a permissions/security check. Phase 23 specifically adds: OWASP-style review, rate limiting, secrets management audit, secure file upload review, dependency vulnerability scanning, and a full walkthrough of the security scenarios in Section 16 against the *complete* system rather than module-by-module.

---

## 18. Environment Strategy

```
Local  →  Development (shared Supabase dev project)  →  Staging  →  Production
```

- **Local** is what exists today (each developer's own `supabase start`).
- **Development** becomes necessary once both developers need to see the same data — introduce this no later than Phase 5, once real feature work starts colliding.
- **Staging** becomes necessary once external stakeholders (a pilot school, a government contact) need to see progress — introduce around Phase 21–23.
- **Production** is Phase 26.

Each environment needs its own secrets, its own `.env` file (never committed — add `.env.example` in Phase 4), its own backup schedule, and its own monitoring once it holds real data (Staging and Production only — Local/Development don't need production-grade monitoring).

---

## 19. Deployment Strategy

Web apps: Vercel (or equivalent) per app, environment-variable-driven per stage. Mobile: Expo's build/submit pipeline once Phase 16 nears completion. Database: Supabase-hosted through Phase 24, Django + managed PostgreSQL from Phase 25 onward. CI (add in Phase 4): lint → typecheck → test → build → preview deploy on every PR; production deploy gated on `main`.

---

## 20. Mobile Application Roadmap

The Expo scaffold exists but is unmodified. Real mobile work starts in Phase 16, once Student Management, Attendance, and Examination have real data to bind to — building mobile screens earlier against placeholder data tends to require a full rebuild once real APIs exist, which is more expensive than waiting. One shared codebase throughout; a school's branding/logo/feature-set comes from tenant configuration fetched at runtime, not from a per-school build — this means onboarding School #50 never requires a new app store submission, only a config change (a code change and a new store submission are only needed when the app's own functionality changes). Teacher functionality and QR-based staff attendance are explicitly deferred to a later mobile iteration, after the core student/parent experience is stable.

---

## 21. Django Migration Strategy

This is not a backend rewrite — it's a **replacement of the data-access layer behind an interface that already exists**, provided `packages/api-client` was used consistently (Principle 6, Section 10) throughout every module phase. What actually needs to happen:

1. Django project + models generated to match the existing PostgreSQL schema (the schema itself largely survives unchanged — it's Postgres either way).
2. Django REST (or GraphQL) API layer replicating what PostgREST/Supabase currently expose.
3. **Authorization parity is the hardest part, not a footnote.** `has_permission()`/`has_org_permission()` either stay as Postgres functions Django calls, or get reimplemented in Django with byte-for-byte equivalent behavior — verified by re-running the *entire* tenant-isolation and RBAC test suite against the Django-backed API before cutover.
4. Auth: Supabase Auth is replaced or fronted — decide whether Django owns auth directly or continues delegating to Supabase Auth as an identity provider; this decision should be made early in this phase, not mid-way.
5. Data migration: schema is largely shared, so this is primarily about connection/ownership cutover, not a data transformation project — but must be rehearsed on a full copy of production data before the real cutover.
6. **Run Django and Supabase in parallel against a staging copy** before any production cutover, with the full test suite green on both, and a rollback plan that doesn't require a second migration to execute.
7. Cut over outside of a school's active term/exam period if at all possible — timing this against the academic calendar matters more than almost any other technical decision in this phase.

**Sequencing recommendation:** run the first pilot school (Phase 26) on Supabase, not Django. Validate the product with a real school before paying the migration cost — Django migration is expensive enough that it should be justified by proven need (imminent multi-school scale, cost, or a hard platform limitation), not done speculatively.

---

## 22. Production Launch Plan

```
Testing → Staging → Security review → Performance testing →
Production preparation → Pilot school → Monitoring → Feedback → Fixes → Multi-school rollout
```

Production preparation includes: domain + SSL, monitoring/alerting (uptime, error rate, query performance), structured logging, error tracking, automated backups with a tested restore procedure, and a documented incident response process — even a lightweight one — before the first real school's data goes in.

---

## 23. Multi-School Scaling Plan

This is the phase that validates every tenancy decision made all the way back in Phase 2. Before onboarding school #2 while school #1 is live: load-test the recursive `org_subtree_ids()` pattern (or its Django equivalent) at realistic organization counts, confirm RLS policy performance holds under concurrent multi-tenant load, and rehearse onboarding a brand-new school end-to-end (org creation → school creation → admin invite → branding → first users) as a repeatable, ideally largely self-service, process rather than a manual one-off.

---

## 24. Risk Register

| Risk | Probability | Impact | Mitigation | Warning signs |
|---|---|---|---|---|
| Scope creep (building modules not yet needed) | High | Medium | Stick to the phase order in Section 11; resist starting Phase 12 while Phase 8 is unfinished | Multiple modules simultaneously "80% done" |
| Over-engineering (repeating the Phase 2 depth on every module) | Medium | Medium | Phase 2's rigor was justified because it's the security foundation — later modules can move faster and iterate | A simple module taking as long as Phase 2 did |
| RBAC/permission complexity creeping back in | Medium | High | Every new permission need should map to an existing mechanism (scoped permission, responsibility, or position) before a new mechanism is considered | A module proposing a brand-new authorization pattern |
| Tenant isolation regressions | Medium | Critical | Re-run the isolation test suite before every release, forever, not just once | Any new table without RLS enabled |
| Django migration complexity underestimated | High | High | Treat Section 21's sequencing recommendation seriously; don't start until product-validated | Migration phase stretching past 6 weeks with no clear end |
| Performance problems at scale | Medium | High | Load-test Phase 24 and Phase 27 explicitly against realistic tenant counts, not just functional correctness | Query times degrading as test data grows |
| Mobile complexity/timeline slip | Medium | Medium | Don't start mobile before real APIs exist (Section 20) | Mobile screens being rebuilt more than once against changing APIs |
| Government requirements changing mid-build | Medium | Medium | The org hierarchy is already flexible by design (Section 8) — lean on that rather than hard-coding new assumptions | A new region needing a schema change, not just new rows |
| Payment integration issues (Finance module) | Medium | Medium | Research Ethiopian payment gateway options early in Phase 11 planning, before writing code | Payment provider API limitations discovered mid-build |
| SMS/email infrastructure reliability | Medium | Low–Medium | Treat notification channels as pluggable from Phase 4 onward (already a stated principle) | Hard-coded dependency on a single provider |
| Two-developer bottleneck (illness, unavailability) | Medium | Medium | Keep both developers rotating across data-layer and UI work (Section 14) so neither is a single point of failure | One person being the only one who understands a whole module |
| Security vulnerabilities missed pre-launch | Low–Medium | Critical | Formal Phase 23 review is non-negotiable before Phase 26 | Skipping straight from "it works" to "it's live" |

---

## 25. Overall Timeline

| Milestone | Realistic estimate from today |
|---|---|
| M1 — Foundation Complete | ~5–6 weeks |
| M2 — Core School Platform | ~13–15 weeks |
| M3 — First Usable ERP (**MVP**) | **~24–27 weeks (≈ 6 months)** |
| M4 — Complete School ERP | ~32–36 weeks |
| M5 — Mobile Live | ~30 weeks (overlaps M3–M4) |
| M6 — Government Platform | ~40–44 weeks |
| M7 — Production-Ready | ~48–52 weeks |
| M8 — **First Pilot School** | **~50–56 weeks (≈ 12–13 months)** |
| M9 — **Multi-School SaaS** | **~65–75 weeks (≈ 15–17 months)** |

These are the *realistic* scenario numbers from Section 12's totals, mapped onto milestones. Optimistic scenario compresses this by roughly 25–30%; conservative extends it by 40–50%. Reassess this table honestly every 4–6 weeks against actual progress — a roadmap that's never revisited stops being useful within a month or two of real development.

---

## 26. Definition of Done

No phase is complete on UI existing alone. Every phase must satisfy, where applicable to that phase:

- [ ] Data model reviewed against Principle 5 (tenant columns, RLS-ready)
- [ ] RLS policies written and covered by isolation-style tests
- [ ] Permissions integrated through the existing `has_permission`/`has_org_permission` pattern — no new authorization mechanism invented
- [ ] API layer routes through `packages/api-client`, not direct database calls from UI
- [ ] Input validation via `packages/validation`
- [ ] Error handling covers both expected failure states and permission-denied states distinctly
- [ ] Unit + integration tests for new logic
- [ ] E2E coverage for the phase's critical user journey
- [ ] Accessibility pass for any new UI (keyboard nav, contrast, labels)
- [ ] Mobile equivalent considered (built now, or explicitly deferred with a note — not silently forgotten)
- [ ] Performance sanity check on anything querying across scope/hierarchy
- [ ] Documentation updated (`docs/architecture/*` if the phase touches architecture, otherwise a short module note)
- [ ] Both developers have run the feature end-to-end locally before merge

---

## 27. Final Master Checklist

**Do this now, before anything else in this document:**
- [ ] Open a PR merging `develop` → `main` for the Phase 2 tenant/RBAC work
- [ ] Have both of you review it, specifically the RLS policy file
- [ ] Merge it — `main` should reflect that Phase 2 is genuinely done, not just `develop`

**Then, in order:**
- [ ] Phase 3 — Authentication & Sessions
- [ ] Phase 4 — Shared Infrastructure (including the CI/CD, `.env.example`, and root README housekeeping noted in Section 4.2)
- [ ] Phase 5 — School Foundation
- [ ] Phases 6–15 — feature modules, parallelized per Section 14
- [ ] Phase 16 — Mobile v1 (once real data exists to build against)
- [ ] Phases 17–20 — analytics, AI, platform admin, government portal
- [ ] Phase 21 — Onboarding, domains, branding
- [ ] Phase 22 — Platform-wide enhancements
- [ ] Phases 23–24 — Security hardening and full test/performance pass
- [ ] Phase 25 — Django migration *(sequence per Section 21's recommendation — likely after the pilot, not before)*
- [ ] Phase 26 — Production launch and first real school
- [ ] Phase 27 — Multi-school scaling

**Revisit this document every 4–6 weeks.** Update the status column in Section 11, re-check the timeline in Section 25 against actual progress, and don't let it go stale — a roadmap nobody updates becomes fiction within a month.

---

## 28. Quick-Reference Q&A

Everything below is answered in more depth elsewhere in this document — this section exists so you can get a direct answer without hunting through sections when someone (including future-you) just wants the bottom line.

### What are we building?

A multi-tenant, production-grade School ERP platform for the Ethiopian education sector — one shared codebase serving many independent schools, school groups, and eventually government education bodies, where each school's identity, branding, and feature set come from tenant configuration rather than a custom deploy per school. See Section 2 (Product Vision).

### What is the complete scope?

Platform foundation (multi-tenancy, auth, RBAC) → school academic structure → student lifecycle → LMS → two independent attendance systems (student and staff) → examinations → HR/staff management → finance → library → inventory/procurement → facilities → communication → role-aware AI → a platform admin console → a government oversight portal with hierarchy-based access → a branded mobile app for students and parents. Full breakdown in Section 3 and Section 9.

### What features will the final platform contain?

The complete inventory is Section 9's table — every domain from platform foundation through mobile, with the specific capabilities listed per domain (e.g. Finance includes fee structures, invoices, payments, receipts, discounts, scholarships, refunds, expenses, budgets, and reports; Attendance explicitly keeps student and staff attendance as two separate systems). Nothing in this roadmap trims that list — it's what "complete" means for this platform.

### What do we build first?

Right now: **merge Phase 2 to `main`**, then **Phase 3 (Authentication & Sessions)**. After that, **Phase 4 (Shared Infrastructure)** — the packages every later module depends on (`api-client`, `validation`, `ui`, `permissions` glue code) — and **Phase 5 (School Foundation)**, since it's the first phase where academic structure (grades, sections, departments) exists for anything else to attach to. No feature module (students, attendance, finance, etc.) should start before Phase 5 is done. See Section 27's checklist for the exact ordered sequence.

### What comes next?

After School Foundation (5): Student Management (6), then the modules that depend on it — LMS (7), Attendance (8), Examination (9), Teacher/Staff Management (10) — several of which can run in parallel across the two of you (Section 13, Section 14). Finance (11), Library (12), Inventory (13), and Facilities (14) follow. Communication (15) and Mobile (16) come once there's real data to plug into them. The full ordered list is Section 11's table and Section 27's checklist.

### What depends on what?

The dependency table lives in Section 11; the practical implications are spelled out in Section 13. The short version: everything school-facing depends on Phase 5. Finance, LMS, Attendance, and Examination all depend on Student Management (6) but not on each other — that's your main parallelization opportunity. Mobile (16) should wait until Student Management + Attendance + Examination have real data. Government Portal (20) is lighter than it looks because the hard part — hierarchy-based access — was already built in Phase 2. Django Migration (25) shouldn't start until the product has been validated by a real pilot school.

### How long should each phase take?

Section 12 has the full table — every phase from 3 through 27, with optimistic/realistic/conservative estimates in both person-days and calendar weeks, plus the assumptions those numbers rest on (near-full-time effort from both of you, ~1.6× two-developer speedup rather than a naive 2×). If your actual weekly hours are lower than "near-full-time," Section 12 tells you exactly how to rescale every number.

### How long should the entire project take for two developers?

**Realistic: ~42 calendar weeks (≈ 9.5–10 months) for everything from today through Phase 27 (multi-school scaling), including the Django migration.** Optimistic compresses that to ~30 weeks (≈ 7 months); conservative stretches it to ~62 weeks (≈ 14 months). See Section 12's totals table and Section 25's milestone-mapped version of the same numbers.

### What should my cousin and I work on in parallel?

Section 14 has the full breakdown per phase type, but the core idea: don't lock into a permanent "backend person / frontend person" split — assign by *module* instead, with one of you owning a module's data model + API + core screens while the other picks up an independent module. Library and Facilities have zero cross-dependency and can run fully in parallel, for example. Swap who does data-layer vs. UI-heavy work across phases so neither of you becomes a single point of failure for a whole module (also flagged as a risk in Section 24). The one phase to explicitly *not* parallelize is Authentication (3) — go through that together.

### What are the major milestones?

Nine of them, M1 through M9, detailed in Section 15: Foundation Complete → Core School Platform → First Usable ERP (this is the MVP, see below) → Complete School ERP → Mobile Live → Government Platform → Production-Ready → First School Pilot → Multi-School SaaS. Each has its included phases, what becomes usable, and a concrete definition of success — not just "the code exists."

### When do we reach an MVP?

**Milestone M3 — First Usable ERP, at roughly 24–27 weeks (≈ 6 months) from today, realistic scenario.** This is defined as: a teacher can run a full term end-to-end — assignments, attendance, exams, report cards — with parents notified along the way. It includes Phases 5–9 plus a first pass at Finance (11) and Communication (15). This is the earliest point where the platform is genuinely usable by a real school for real work, not just a demo. See Section 15's M3 row and Section 25's timeline table.

### When do we have a complete School ERP?

**Milestone M4 — Complete School ERP, at roughly 32–36 weeks (≈ 7.5–8.5 months).** This adds Library (12), Inventory (13), Facilities (14), and cross-module Reports & Analytics (17) on top of M3 — at this point every module in Section 9 is usable *except* mobile, AI, and the government portal, which have their own milestones below.

### When do we build the mobile application?

Real mobile work — beyond the current unmodified Expo scaffold — starts in **Phase 16**, and deliberately not before Student Management, Attendance, and Examination have real APIs and real data (Section 20 explains why: building mobile screens against placeholder data almost always means rebuilding them once real data exists, which costs more than waiting). It overlaps M3–M4 development and goes live around **~30 weeks**, tracked as **Milestone M5**. One shared codebase for every school throughout — a new school never needs a new app store submission, only a tenant-config change.

### When do we build the government platform?

**Phases 19 (Platform Admin) and 20 (Government Portal), landing around Milestone M6 at roughly 40–44 weeks (≈ 9.5–10 months).** It's scheduled later than the core modules deliberately, but it's genuinely lighter work than it looks — the authorization foundation (organization hierarchy, subtree-based visibility, the three separate membership contexts) was already built and tested back in Phase 2. This phase is largely UI and analytics on top of access control that already exists.

### When do we become production-ready?

**Milestone M7, at roughly 48–52 weeks (≈ 11–12 months).** This requires Phases 21–24: onboarding flow, domains/branding, platform-wide enhancements, security hardening, and a full test/performance pass — including a formal security review (Section 17) and the complete tenant-isolation/RBAC regression suite (Section 16) run against the *entire* system, not module-by-module. "Production-ready" here specifically means passing that audit and load test, not just "the features exist."

### When do we migrate from Supabase to Django?

**Phase 25**, and the explicit recommendation in Section 21 is: **not before the first pilot school (Phase 26) has validated the product on Supabase.** Migrating a backend that hasn't been proven by real usage risks migrating the wrong thing. In the realistic timeline this lands the Django migration somewhere between the pilot (~50–56 weeks) and full multi-school readiness (~65–75 weeks) — Section 25 estimates the migration itself at ~4 realistic calendar weeks once it starts, but flags it as the single highest-coordination-cost phase in the entire roadmap (Section 14), so budget real buffer around it.

### When can we onboard the first school?

**Milestone M8 — First School Pilot, at roughly 50–56 weeks (≈ 12–13 months), immediately after Production-Ready (M7).** Success here is defined narrowly and honestly: a real school runs at least one full term on the platform without a critical incident — not just "we deployed it."

### When can we scale to multiple schools?

**Milestone M9 — Multi-School SaaS, at roughly 65–75 weeks (≈ 15–17 months).** This is Phase 27, and it's explicitly the phase that validates every tenancy decision made all the way back in Phase 2 (Section 23): load-testing the organization-hierarchy visibility pattern at realistic scale, confirming RLS performance holds under concurrent multi-tenant load, and turning school onboarding into a repeatable process rather than a manual one-off, before taking on school #2 while school #1 is live.
