begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (id, email, email_confirmed_at) values
  ('a0100000-0000-4000-8000-000000000001', 'remove-a@example.invalid', now()),
  ('a0100000-0000-4000-8000-000000000002', 'remove-b@example.invalid', now());
select private.provision_household(
  'a0200000-0000-4000-8000-000000000001', 'Removal home',
  'a0100000-0000-4000-8000-000000000001', 'a0100000-0000-4000-8000-000000000002'
);
insert into public.photos (
  id, household_id, uploader_user_id, request_id, object_key, state,
  byte_size, mime_type, checksum, expires_at
) values
  (
    'a0300000-0000-4000-8000-000000000001', 'a0200000-0000-4000-8000-000000000001',
    'a0100000-0000-4000-8000-000000000001', 'a0400000-0000-4000-8000-000000000001',
    'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000001.jpg',
    'READY', 100, 'image/jpeg', repeat('a', 64), now() + interval '1 hour'
  ),
  (
    'a0300000-0000-4000-8000-000000000002', 'a0200000-0000-4000-8000-000000000001',
    'a0100000-0000-4000-8000-000000000001', 'a0400000-0000-4000-8000-000000000002',
    'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000002.jpg',
    'READY', 101, 'image/jpeg', repeat('b', 64), now() + interval '1 hour'
  );
insert into storage.objects (bucket_id, name, owner_id) values
  ('purchase-photos',
    'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000001.jpg',
    'a0100000-0000-4000-8000-000000000001'),
  ('purchase-photos',
    'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000002.jpg',
    'a0100000-0000-4000-8000-000000000001');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a0100000-0000-4000-8000-000000000001', true);
create temp table removal_item as select public.create_item(
  '{"householdId":"a0200000-0000-4000-8000-000000000001","requestId":"a0500000-0000-4000-8000-000000000001","name":"Shared camera","photoId":"a0300000-0000-4000-8000-000000000001"}'
) as value;
select throws_ok(
  $$select public.begin_member_removal('{"operationId":"a0600000-0000-4000-8000-000000000001","householdId":"a0200000-0000-4000-8000-000000000001","userId":"a0100000-0000-4000-8000-000000000001"}')$$,
  '42501', null, 'ordinary member cannot invoke removal'
);
reset role;

set local role service_role;
select is(
  public.begin_member_removal(
    '{"operationId":"a0600000-0000-4000-8000-000000000001","householdId":"a0200000-0000-4000-8000-000000000001","userId":"a0100000-0000-4000-8000-000000000001"}'
  )->>'state', 'TRANSFERRING', 'removal begins with attached-photo transfer'
);
select lives_ok(
  $$select public.begin_member_removal('{"operationId":"a0600000-0000-4000-8000-000000000001","householdId":"a0200000-0000-4000-8000-000000000001","userId":"a0100000-0000-4000-8000-000000000001"}')$$,
  'same removal operation is idempotent'
);
reset role;
select is((select count(*) from public.household_members where user_id =
  'a0100000-0000-4000-8000-000000000001'), 0::bigint, 'membership is revoked first');
select is((select count(*) from private.account_photo_transfers), 1::bigint,
  'attached departing-user photo gets one transfer job');
select is((select state from public.photos where id =
  'a0300000-0000-4000-8000-000000000002'), 'DELETE_PENDING',
  'unattached departing-user photo enters retry cleanup');

set local role authenticated;
select set_config('request.jwt.claim.sub', 'a0100000-0000-4000-8000-000000000001', true);
select throws_ok($$select public.get_household()$$, 'PT404', 'NOT_FOUND',
  'old departing-member JWT loses authorization immediately');
select set_config('request.jwt.claim.sub', 'a0100000-0000-4000-8000-000000000002', true);
select is((select count(*) from public.items), 1::bigint, 'remaining member retains purchase');
select is((select count(*) from public.photos where state = 'ATTACHED'), 1::bigint,
  'remaining member retains attached photo metadata');
reset role;

set local role service_role;
create temp table transfer_claim as select public.claim_account_photo_transfers(
  '{"operationId":"a0600000-0000-4000-8000-000000000001","limit":1}'
) as jobs;
select is(jsonb_array_length((select jobs from transfer_claim)), 1, 'transfer worker claims one job');
reset role;
update storage.objects set owner_id = null where name =
  'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000001.jpg';
set local role service_role;
select lives_ok(format(
  $sql$select public.finish_account_photo_transfer('{"jobId":"%s","succeeded":true}')$sql$,
  (select jobs->0->>'jobId' from transfer_claim)
), 'service-owned verified object completes transfer');
create temp table cleanup_claim as select public.claim_photo_cleanup('{"limit":25}') as jobs;
reset role;
-- Model a successful Storage API deletion without invoking network I/O from pgTAP.
set local session_replication_role = replica;
delete from storage.objects where name =
  'a0200000-0000-4000-8000-000000000001/a0100000-0000-4000-8000-000000000001/a0300000-0000-4000-8000-000000000002.jpg';
set local session_replication_role = origin;
set local role service_role;
select lives_ok(format(
  $sql$select public.finish_photo_cleanup('{"jobId":"%s","succeeded":true}')$sql$,
  (select jobs->0->>'jobId' from cleanup_claim)
), 'unattached object cleanup completes');
reset role;

insert into storage.objects (bucket_id, name, owner_id) values
  ('purchase-photos', 'untracked-object.jpg', 'a0100000-0000-4000-8000-000000000001');
set local role service_role;
select is(
  public.account_operation_readiness('{"operationId":"a0600000-0000-4000-8000-000000000001"}')
    ->>'readyForIdentityDeletion', 'false', 'unknown user-owned object blocks identity deletion'
);
reset role;
set local session_replication_role = replica;
delete from storage.objects where name = 'untracked-object.jpg';
set local session_replication_role = origin;
set local role service_role;
select is(
  public.account_operation_readiness('{"operationId":"a0600000-0000-4000-8000-000000000001"}')
    ->>'readyForIdentityDeletion', 'true', 'all transfer and cleanup evidence permits identity deletion'
);
select throws_ok(
  $$select public.finish_account_operation('{"operationId":"a0600000-0000-4000-8000-000000000001"}')$$,
  'PT409', 'OPERATION_NOT_READY', 'identity must be deleted before operation completion'
);
reset role;
delete from auth.users where id = 'a0100000-0000-4000-8000-000000000001';
set local role service_role;
select lives_ok(
  $$select public.finish_account_operation('{"operationId":"a0600000-0000-4000-8000-000000000001"}')$$,
  'member removal completes after Auth deletion'
);
reset role;
select is((select state from private.account_operations where id =
  'a0600000-0000-4000-8000-000000000001'), 'COMPLETED', 'removal has durable completion evidence');
select is((select count(*) from public.items), 1::bigint, 'shared purchase survives identity deletion');
select is((select count(*) from public.photos where state = 'ATTACHED'), 1::bigint,
  'attached photo survives identity deletion');
select is((select created_by from public.items), null, 'departing creator attribution becomes former member');

insert into auth.users (id, email, email_confirmed_at) values
  ('b0100000-0000-4000-8000-000000000001', 'close-a@example.invalid', now()),
  ('b0100000-0000-4000-8000-000000000002', 'close-b@example.invalid', now());
select private.provision_household(
  'b0200000-0000-4000-8000-000000000001', 'Closure home',
  'b0100000-0000-4000-8000-000000000001', 'b0100000-0000-4000-8000-000000000002'
);
insert into public.photos (
  id, household_id, uploader_user_id, request_id, object_key, state,
  byte_size, mime_type, checksum, expires_at
) values (
  'b0300000-0000-4000-8000-000000000001', 'b0200000-0000-4000-8000-000000000001',
  'b0100000-0000-4000-8000-000000000001', 'b0400000-0000-4000-8000-000000000001',
  'b0200000-0000-4000-8000-000000000001/b0100000-0000-4000-8000-000000000001/b0300000-0000-4000-8000-000000000001.jpg',
  'READY', 200, 'image/jpeg', repeat('c', 64), now() + interval '1 hour'
);
insert into storage.objects (bucket_id, name, owner_id) values (
  'purchase-photos',
  'b0200000-0000-4000-8000-000000000001/b0100000-0000-4000-8000-000000000001/b0300000-0000-4000-8000-000000000001.jpg',
  'b0100000-0000-4000-8000-000000000001'
);
set local role authenticated;
select set_config('request.jwt.claim.sub', 'b0100000-0000-4000-8000-000000000001', true);
select public.create_item(
  '{"householdId":"b0200000-0000-4000-8000-000000000001","requestId":"b0500000-0000-4000-8000-000000000001","name":"Closed item","photoId":"b0300000-0000-4000-8000-000000000001"}'
);
reset role;
set local role service_role;
select is(
  public.begin_household_closure(
    '{"operationId":"b0600000-0000-4000-8000-000000000001","householdId":"b0200000-0000-4000-8000-000000000001"}'
  )->>'cleanupPending', '1', 'closure detaches and queues every household photo'
);
create temp table closure_claim as select public.claim_photo_cleanup('{"limit":25}') as jobs;
reset role;
select is((select count(*) from public.household_members where household_id =
  'b0200000-0000-4000-8000-000000000001'), 0::bigint, 'closure revokes every membership first');
select is((select count(*) from public.items where household_id =
  'b0200000-0000-4000-8000-000000000001'), 1::bigint, 'closure retains records until object cleanup');
set local session_replication_role = replica;
delete from storage.objects where name =
  'b0200000-0000-4000-8000-000000000001/b0100000-0000-4000-8000-000000000001/b0300000-0000-4000-8000-000000000001.jpg';
set local session_replication_role = origin;
set local role service_role;
select lives_ok(format(
  $sql$select public.finish_photo_cleanup('{"jobId":"%s","succeeded":true}')$sql$,
  (select jobs->0->>'jobId' from closure_claim)
), 'closure photo metadata is purged only after object deletion');
reset role;
delete from auth.users where id in (
  'b0100000-0000-4000-8000-000000000001', 'b0100000-0000-4000-8000-000000000002'
);
set local role service_role;
select lives_ok(
  $$select public.finish_account_operation('{"operationId":"b0600000-0000-4000-8000-000000000001"}')$$,
  'closure purges records after objects and identities'
);
select lives_ok(
  $$select public.finish_account_operation('{"operationId":"b0600000-0000-4000-8000-000000000001"}')$$,
  'completed closure retry is idempotent'
);
reset role;
select is((select count(*) from public.households where id =
  'b0200000-0000-4000-8000-000000000001'), 0::bigint, 'closed household is purged');
select is((select count(*) from public.items where household_id =
  'b0200000-0000-4000-8000-000000000001'), 0::bigint, 'closed household records are purged');
select is((select state from private.account_operations where id =
  'b0600000-0000-4000-8000-000000000001'), 'COMPLETED', 'closure keeps an operation tombstone');

select * from finish();
rollback;
