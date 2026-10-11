begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select has_table('public', 'households', 'households exists');
select has_table('public', 'household_members', 'memberships exists');

-- Synthetic identities only; the entire test rolls back.
insert into auth.users (id, email, email_confirmed_at) values
  ('10000000-0000-0000-0000-000000000001', 'spouse-a@example.invalid', now()),
  ('10000000-0000-0000-0000-000000000002', 'spouse-b@example.invalid', now()),
  ('10000000-0000-0000-0000-000000000003', 'outsider@example.invalid', now()),
  ('10000000-0000-0000-0000-000000000004', 'unverified@example.invalid', null);

select is(private.provision_household(
  '20000000-0000-0000-0000-000000000001', ' Our home ',
  '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002'
), '20000000-0000-0000-0000-000000000001'::uuid, 'provisions the shared household');
select is((select count(*) from public.household_members), 2::bigint, 'exactly two members');
select is((select name from public.households), 'Our home', 'normalizes the name');
select lives_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000001', 'Our home',
  '10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001')$$,
  'retry is safe regardless of user order');
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000001', 'Different',
  '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002')$$,
  'PT409', 'CONFLICT', 'changed name is not a retry');
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000002', 'Other',
  '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003')$$,
  'PT409', 'CONFLICT', 'cannot assign a user to a second household');
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000002', 'Other',
  '10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000004')$$,
  'PT422', 'VALIDATION_ERROR', 'unverified identity rejected');
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000002', 'Other',
  '10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003')$$,
  'PT422', 'VALIDATION_ERROR', 'two distinct identities required');
select throws_ok($$select private.provision_household(
  null, 'Other', '10000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000002')$$,
  'PT422', 'VALIDATION_ERROR', 'null household rejected');
select throws_ok($$insert into public.household_members (household_id, user_id, slot)
  values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 3)$$,
  '23514', null, 'slot constraint rejects a third member even for privileged insert');
select throws_ok($$insert into public.household_members (household_id, user_id, slot)
  values ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000003', 1)$$,
  '23505', null, 'occupied slot cannot be reused');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select is((select count(*) from public.households), 1::bigint, 'spouse A reads household');
select is((select count(*) from public.household_members), 2::bigint, 'spouse A reads both members');
select is(public.get_household()->>'name', 'Our home', 'household RPC returns name');
select is(public.get_household()->>'householdId', '20000000-0000-0000-0000-000000000001', 'RPC uses camelCase');
select throws_ok($$insert into public.household_members (household_id,user_id,slot)
  values ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003',1)$$,
  '42501', null, 'app cannot add membership');
select throws_ok($$delete from public.household_members$$, '42501', null, 'app cannot revoke membership');
select throws_ok($$update public.households set name = 'Forged'$$, '42501', null, 'app cannot mutate household');
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000001', 'Our home',
  '10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'app cannot invoke provisioning');

select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.households), 1::bigint, 'spouse B reads the same household');
select is((select count(*) from public.household_members), 2::bigint, 'spouse B reads both members');
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select is((select count(*) from public.households), 0::bigint, 'outsider sees no households');
select is((select count(*) from public.household_members), 0::bigint, 'outsider sees no memberships');
select throws_ok($$select public.get_household()$$, 'PT404', 'NOT_FOUND', 'outsider receives neutral not-found');

reset role;
delete from public.household_members where user_id = '10000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.households), 0::bigint, 'revoked member loses access with old JWT subject');
select throws_ok($$select public.get_household()$$, 'PT404', 'NOT_FOUND', 'revoked member cannot use RPC');
reset role;
select throws_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000001', 'Our home',
  '10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002')$$,
  'PT409', 'CONFLICT', 'old provisioning retry cannot restore revoked access');
select is((select count(*) from public.households), 1::bigint, 'failed provisioning left no orphan households');

set local role anon;
select throws_ok($$select * from public.households$$, '42501', null, 'anonymous table access denied');
select throws_ok($$select public.get_household()$$, '42501', null, 'anonymous RPC denied');
reset role;
insert into auth.users (id, email, email_confirmed_at) values
  ('10000000-0000-0000-0000-000000000005', 'operator-a@example.invalid', now()),
  ('10000000-0000-0000-0000-000000000006', 'operator-b@example.invalid', now());
set local role service_role;
select lives_ok($$select private.provision_household(
  '20000000-0000-0000-0000-000000000002', 'Operator home',
  '10000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000006')$$,
  'trusted service role can provision');
select throws_ok($$select * from public.households$$, '42501', null, 'service role has no direct household read');
select throws_ok($$select * from public.household_members$$, '42501', null, 'service role has no direct membership read');
select throws_ok($$delete from public.household_members$$, '42501', null, 'service role has no direct membership mutation');
reset role;
select * from finish();
rollback;
