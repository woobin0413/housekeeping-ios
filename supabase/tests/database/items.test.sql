begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();
select has_table('public', 'items', 'items exists');

insert into auth.users (id,email,email_confirmed_at) values
  ('30000000-0000-0000-0000-000000000001','item-a@example.invalid',now()),
  ('30000000-0000-0000-0000-000000000002','item-b@example.invalid',now()),
  ('30000000-0000-0000-0000-000000000003','foreign-a@example.invalid',now()),
  ('30000000-0000-0000-0000-000000000004','foreign-b@example.invalid',now());
select private.provision_household('40000000-0000-0000-0000-000000000001','Home',
  '30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002');
select private.provision_household('40000000-0000-0000-0000-000000000002','Foreign home',
  '30000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000004');

insert into public.items (id,household_id,name,created_by,creation_requester_id,creation_request_id) values
  ('50000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','Kettle',
   '30000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000001'),
  ('50000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000002','Foreign lamp',
   '30000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000003','60000000-0000-0000-0000-000000000002'),
  ('50000000-0000-0000-0000-000000000003','40000000-0000-0000-0000-000000000001','Deleted mug',
   '30000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000003');
update public.items set deleted_at = now() where name = 'Deleted mug';

select is((select version from public.items where name = 'Kettle'), 1::bigint, 'version starts at one');
select throws_ok($$update public.items set name = '' where name = 'Kettle'$$, '23514', null, 'blank name rejected');
select throws_ok($$update public.items set name = '  ' where name = 'Kettle'$$, '23514', null, 'space-only name rejected');
select throws_ok($$update public.items set name = E'\t\n' where name = 'Kettle'$$, '23514', null, 'whitespace-only name rejected');
select throws_ok($$update public.items set name = repeat('x',201) where name = 'Kettle'$$, '23514', null, 'overlong name rejected');
select throws_ok($$update public.items set description = repeat('x',2001) where name = 'Kettle'$$, '23514', null, 'overlong description rejected');
select throws_ok($$update public.items set brand = repeat('x',101) where name = 'Kettle'$$, '23514', null, 'overlong brand rejected');
select throws_ok($$update public.items set model = repeat('x',101) where name = 'Kettle'$$, '23514', null, 'overlong model rejected');
select throws_ok($$update public.items set version = 0 where name = 'Kettle'$$, '23514', null, 'invalid version rejected');
select throws_ok($$update public.items set created_by = '30000000-0000-0000-0000-000000000001'
  where name = 'Kettle'$$, '23514', null, 'creator must match the original request identity');
select throws_ok($$update public.items set photo_id = gen_random_uuid() where name = 'Kettle'$$, '23503', null, 'photo references require an existing same-household photo');
select lives_ok($$update public.items set description = repeat('x',2000), brand = repeat('x',100), model = repeat('x',100)
  where name = 'Kettle'$$, 'field limits accepted at boundary');
select throws_ok($$insert into public.items (household_id,name,created_by,creation_requester_id,creation_request_id)
  values ('40000000-0000-0000-0000-000000000001','Duplicate','30000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002',
  '60000000-0000-0000-0000-000000000001')$$, '23505', null, 'creation request uniqueness enforced');

set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000001',true);
select results_eq($$select name from public.items order by name$$, array['Kettle'], 'spouse A sees spouse B purchase but no tombstones or foreign items');
select throws_ok($$update public.items set household_id = '40000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'direct household reassignment denied');
select throws_ok($$update public.items set created_by = '30000000-0000-0000-0000-000000000001'$$,
  '42501', null, 'direct creator forgery denied');
select throws_ok($$insert into public.items (household_id,name,created_by,creation_request_id)
  values ('40000000-0000-0000-0000-000000000001','Forged','30000000-0000-0000-0000-000000000001',gen_random_uuid())$$,
  '42501', null, 'writes must go through transactional RPCs');
select throws_ok($$delete from public.items$$, '42501', null, 'direct hard delete denied');
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000002',true);
select results_eq($$select name from public.items order by name$$, array['Kettle'], 'spouse B sees the same inventory');
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000003',true);
select results_eq($$select name from public.items order by name$$, array['Foreign lamp'], 'foreign member only sees their own household');
select set_config('request.jwt.claim.sub','',true);
select is((select count(*) from public.items), 0::bigint, 'missing identity grants no rows');
reset role;

-- Removing the creator must not erase the remaining spouse's shared history.
delete from auth.users where id = '30000000-0000-0000-0000-000000000002';
select is((select creation_requester_id from public.items where name = 'Kettle'),
  '30000000-0000-0000-0000-000000000002'::uuid, 'request identity survives attribution removal');
select throws_ok($$insert into public.items (household_id,name,created_by,creation_requester_id,creation_request_id)
  values ('40000000-0000-0000-0000-000000000001','Replayed purchase',null,
  '30000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'old save request still conflicts after creator account removal');
set local role authenticated;
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000001',true);
select results_eq($$select name from public.items$$, array['Kettle'], 'purchase survives creator account deletion');
select is((select created_by from public.items), null::uuid, 'historical attribution becomes null');
select set_config('request.jwt.claim.sub','30000000-0000-0000-0000-000000000002',true);
select is((select count(*) from public.items), 0::bigint, 'removed creator has no new reads');
reset role;
set local role anon;
select throws_ok($$select * from public.items$$, '42501', null, 'anonymous inventory access denied');
reset role;
set local role service_role;
select throws_ok($$insert into public.items (household_id,name,creation_request_id)
  values ('40000000-0000-0000-0000-000000000001','Bypass',gen_random_uuid())$$,
  '42501', null, 'no implicit service-role item writes');
reset role;
select * from finish();
rollback;
