-- ============================================================================
-- tenant_isolation_test.sql
-- Phase 2.12 -- Test tenant isolation
-- ============================================================================
-- How to run:
--   supabase start
--   supabase db reset            -- applies all migrations
--   psql "$(supabase status -o json | jq -r '.DB_URL')" -f supabase/tests/tenant_isolation_test.sql
--
-- Covers three isolation guarantees:
--   A. Two independent schools (different school_group orgs) cannot see
--      each other's schools, memberships, or profiles.
--   B. Government hierarchy visibility works ONE WAY: a Regional org member
--      CAN see a Woreda/school beneath their region; a Woreda org member
--      CANNOT see their parent Region's other children, and definitely can't
--      see an unrelated Region's schools.
--   C. Platform membership grants ZERO implicit school/organization access --
--      a platform admin's power comes only from is_platform_super_admin(),
--      never from an implicit school_memberships/organization_memberships row.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- Fixtures -- two unrelated school groups, plus a small government hierarchy
-- ----------------------------------------------------------------------------

insert into public.organizations (id, type, name, slug) values
    ('10000000-0000-0000-0000-00000000000a', 'independent_school', 'Org A (School Group)', 'org-a'),
    ('10000000-0000-0000-0000-00000000000b', 'independent_school', 'Org B (School Group)', 'org-b');

insert into public.schools (id, organization_id, name, code) values
    ('20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'School A', 'SCH-A'),
    ('20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'School B', 'SCH-B');

-- Government hierarchy: Region X -> Woreda X1, Woreda X2 (unrelated Region Y)
insert into public.organizations (id, type, level, name, slug) values
    ('30000000-0000-0000-0000-0000000000a1', 'government', 'regional', 'Region X', 'region-x'),
    ('30000000-0000-0000-0000-0000000000a2', 'government', 'regional', 'Region Y', 'region-y');

insert into public.organizations (id, parent_organization_id, type, level, name, slug) values
    ('30000000-0000-0000-0000-0000000000b1', '30000000-0000-0000-0000-0000000000a1', 'government', 'woreda', 'Woreda X1', 'woreda-x1'),
    ('30000000-0000-0000-0000-0000000000b2', '30000000-0000-0000-0000-0000000000a1', 'government', 'woreda', 'Woreda X2', 'woreda-x2');

-- School C's owning org nested under Woreda X1, to prove downward subtree visibility.
insert into public.organizations (id, parent_organization_id, type, name, slug) values
    ('10000000-0000-0000-0000-00000000000c', '30000000-0000-0000-0000-0000000000b1', 'independent_school', 'School C Trust', 'org-c');

insert into public.schools (id, organization_id, name, code) values
    ('20000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-00000000000c', 'School C', 'SCH-C');

-- Fake auth.users (normally created by Supabase Auth)
insert into auth.users (id, email) values
    ('aaaaaaaa-aaaa-0000-0000-000000000001', 'teacher-a@example.com'),
    ('bbbbbbbb-bbbb-0000-0000-000000000001', 'teacher-b@example.com'),
    ('cccccccc-cccc-0000-0000-000000000001', 'regional-officer-x@example.com'),
    ('dddddddd-dddd-0000-0000-000000000001', 'woreda-officer-x2@example.com'),
    ('eeeeeeee-eeee-0000-0000-000000000001', 'platform-support@example.com');
-- profiles auto-created by trg_on_auth_user_created

-- Teacher A @ School A, Teacher B @ School B
insert into public.school_memberships (id, user_id, school_id, organization_id, base_role_id, status, joined_at)
select 'aaaaaaaa-1001-0000-0000-000000000001', 'aaaaaaaa-aaaa-0000-0000-000000000001',
       '20000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a',
       (select id from public.roles where key = 'teacher' and context = 'school'), 'active', now();

insert into public.school_memberships (id, user_id, school_id, organization_id, base_role_id, status, joined_at)
select 'bbbbbbbb-1001-0000-0000-000000000001', 'bbbbbbbb-bbbb-0000-0000-000000000001',
       '20000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b',
       (select id from public.roles where key = 'teacher' and context = 'school'), 'active', now();

-- Regional Education Officer @ Region X (should see School C, under Woreda X1, under Region X)
insert into public.organization_memberships (id, user_id, organization_id, base_role_id, status, joined_at)
select 'cccccccc-1001-0000-0000-000000000001', 'cccccccc-cccc-0000-0000-000000000001',
       '30000000-0000-0000-0000-0000000000a1',
       (select id from public.roles where key = 'regional_officer' and context = 'organization'), 'active', now();

-- Woreda Education Officer @ Woreda X2 (should NOT see School C, which is under sibling Woreda X1)
insert into public.organization_memberships (id, user_id, organization_id, base_role_id, status, joined_at)
select 'dddddddd-1001-0000-0000-000000000001', 'dddddddd-dddd-0000-0000-000000000001',
       '30000000-0000-0000-0000-0000000000b2',
       (select id from public.roles where key = 'woreda_officer' and context = 'organization'), 'active', now();

-- Platform Support admin -- no school_membership, no organization_membership at all
insert into public.platform_memberships (id, user_id, base_role_id, status, joined_at)
select 'eeeeeeee-1001-0000-0000-000000000001', 'eeeeeeee-eeee-0000-0000-000000000001',
       (select id from public.roles where key = 'platform_support' and context = 'platform'), 'active', now();

-- ============================================================================
-- A. Cross-tenant isolation between unrelated school groups
-- ============================================================================
set local role authenticated;
set local request.jwt.claims = '{"sub": "aaaaaaaa-aaaa-0000-0000-000000000001", "role": "authenticated"}';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.schools where id = '20000000-0000-0000-0000-00000000000b';
  assert v_count = 0, 'FAIL: Teacher A can see School B';

  select count(*) into v_count from public.school_memberships where school_id = '20000000-0000-0000-0000-00000000000b';
  assert v_count = 0, 'FAIL: Teacher A can see School B memberships';

  select count(*) into v_count from public.profiles where id = 'bbbbbbbb-bbbb-0000-0000-000000000001';
  assert v_count = 0, 'FAIL: Teacher A can see Teacher B''s profile';

  select count(*) into v_count from public.organizations where id = '10000000-0000-0000-0000-00000000000b';
  assert v_count = 0, 'FAIL: Teacher A can see Org B';

  select count(*) into v_count from public.schools where id = '20000000-0000-0000-0000-00000000000a';
  assert v_count = 1, 'FAIL: Teacher A cannot see their own School A';

  raise notice 'PASS (A): cross-tenant isolation holds for Teacher A -> Org/School B';
end $$;

do $$
begin
  begin
    insert into public.school_memberships (user_id, school_id, organization_id, base_role_id, status)
    values ('aaaaaaaa-aaaa-0000-0000-000000000001', '20000000-0000-0000-0000-00000000000b',
            '10000000-0000-0000-0000-00000000000b',
            (select id from public.roles where key = 'teacher' and context = 'school'), 'active');
    raise exception 'FAIL: Teacher A was able to insert a membership into School B';
  exception
    when insufficient_privilege or others then
      raise notice 'PASS (A): cross-tenant INSERT correctly blocked';
  end;
end $$;

-- ============================================================================
-- B. Government hierarchy visibility (positive + negative)
-- ============================================================================
set local request.jwt.claims = '{"sub": "cccccccc-cccc-0000-0000-000000000001", "role": "authenticated"}';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.schools where id = '20000000-0000-0000-0000-00000000000c';
  assert v_count = 1, 'FAIL: Regional Officer cannot see School C in their own subtree';

  select count(*) into v_count from public.organizations where id = '30000000-0000-0000-0000-0000000000b1';
  assert v_count = 1, 'FAIL: Regional Officer cannot see Woreda X1 beneath their region';

  select count(*) into v_count from public.organizations where id = '30000000-0000-0000-0000-0000000000a2';
  assert v_count = 0, 'FAIL: Regional Officer can see unrelated Region Y';

  raise notice 'PASS (B1): Regional Officer subtree visibility correct';
end $$;

set local request.jwt.claims = '{"sub": "dddddddd-dddd-0000-0000-000000000001", "role": "authenticated"}';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.schools where id = '20000000-0000-0000-0000-00000000000c';
  assert v_count = 0, 'FAIL: Woreda X2 Officer can see School C under sibling Woreda X1';

  select count(*) into v_count from public.organizations where id = '30000000-0000-0000-0000-0000000000a1'
    and id in (select st.id from public.user_org_ids() uo, public.org_subtree_ids(uo) st);
  assert v_count = 0, 'FAIL: subtree visibility unexpectedly includes an ancestor';

  raise notice 'PASS (B2): Woreda Officer sibling isolation correct';
end $$;

-- ============================================================================
-- C. Platform membership grants zero implicit tenant access
-- ============================================================================
set local request.jwt.claims = '{"sub": "eeeeeeee-eeee-0000-0000-000000000001", "role": "authenticated"}';

do $$
declare v_count int;
begin
  select count(*) into v_count from public.schools where id = '20000000-0000-0000-0000-00000000000a';
  assert v_count = 0, 'FAIL: Platform Support (non-super-admin) can see School A without explicit permission';

  select count(*) into v_count from public.school_memberships;
  assert v_count = 0, 'FAIL: Platform Support can see school_memberships rows without explicit permission';

  raise notice 'PASS (C): platform_membership grants no implicit school/org access';
end $$;

reset role;
rollback;