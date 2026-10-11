begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select has_table('public', 'photos', 'photos exists');
select has_function('public', 'reserve_photo', array['jsonb'], 'reservation RPC exists');
select is((select public from storage.buckets where id = 'purchase-photos'), false, 'photo bucket is private');
select is((select file_size_limit from storage.buckets where id = 'purchase-photos'), 5242880::bigint, 'bucket enforces five MiB');
select is((select allowed_mime_types from storage.buckets where id = 'purchase-photos'), array['image/jpeg']::text[], 'bucket accepts JPEG only');

insert into auth.users (id, email, email_confirmed_at) values
  ('81000000-0000-0000-0000-000000000001', 'photo-a@example.invalid', now()),
  ('81000000-0000-0000-0000-000000000002', 'photo-b@example.invalid', now()),
  ('81000000-0000-0000-0000-000000000003', 'photo-out@example.invalid', now()),
  ('81000000-0000-0000-0000-000000000004', 'photo-out-b@example.invalid', now());
select private.provision_household(
  '82000000-0000-0000-0000-000000000001', 'Photo home',
  '81000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000002'
);
select private.provision_household(
  '82000000-0000-0000-0000-000000000002', 'Outside home',
  '81000000-0000-0000-0000-000000000003', '81000000-0000-0000-0000-000000000004'
);
insert into public.items (
  id, household_id, name, created_by, creation_requester_id, creation_request_id
) values (
  '83000000-0000-0000-0000-000000000001',
  '82000000-0000-0000-0000-000000000001',
  'Photo kettle',
  '81000000-0000-0000-0000-000000000001',
  '81000000-0000-0000-0000-000000000001',
  '84000000-0000-0000-0000-000000000001'
);
create temp table photo_state (reservation jsonb);
insert into photo_state default values;
grant all on photo_state to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000001', true);
update photo_state set reservation = public.reserve_photo(
  '{"householdId":"82000000-0000-0000-0000-000000000001","requestId":"85000000-0000-0000-0000-000000000001"}'
);
select ok(
  (select reservation->>'objectKey' from photo_state) like
    '82000000-0000-0000-0000-000000000001/81000000-0000-0000-0000-000000000001/%.jpg',
  'server reserves a household and uploader scoped JPEG path'
);
select is(
  public.reserve_photo('{"householdId":"82000000-0000-0000-0000-000000000001","requestId":"85000000-0000-0000-0000-000000000001"}') ->> 'photoId',
  (select reservation->>'photoId' from photo_state),
  'same requester and request ID returns the reservation'
);
select is((select count(*) from public.photos), 1::bigint, 'reservation retry creates one row');
select ok((select (reservation->>'expiresAt')::timestamptz > now() + interval '23 hours' from photo_state), 'reservation has a bounded future expiry');
select is((select count(*) from public.photos), 1::bigint, 'uploader reads unfinished metadata');
select throws_ok(
  $$insert into public.photos (id, household_id, uploader_user_id, request_id, object_key, expires_at)
    values (gen_random_uuid(), '82000000-0000-0000-0000-000000000001',
      '81000000-0000-0000-0000-000000000001', gen_random_uuid(), 'forged.jpg', now() + interval '1 day')$$,
  '42501', null, 'client cannot forge photo metadata'
);

insert into storage.objects (bucket_id, name, owner_id) values (
  'purchase-photos', (select reservation->>'objectKey' from photo_state),
  '81000000-0000-0000-0000-000000000001'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id) values
    ('purchase-photos', '82000000-0000-0000-0000-000000000001/81000000-0000-0000-0000-000000000001/86000000-0000-0000-0000-000000000001.jpg',
      '81000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'uploader cannot forge an unreserved path'
);
select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id) values
    ('purchase-photos', (select reservation->>'objectKey' from photo_state),
      '81000000-0000-0000-0000-000000000001')$$,
  '23505', null, 'a reserved path cannot be overwritten'
);
select set_config('storage.operation', 'object.get_authenticated', true);
update storage.objects set version = 'forged' where bucket_id = 'purchase-photos';
select isnt(
  (select version from storage.objects where bucket_id = 'purchase-photos'),
  'forged',
  'client has no effective Storage overwrite policy'
);
select throws_ok(
  $$delete from storage.objects where bucket_id = 'purchase-photos'$$,
  '42501',
  'Direct deletion from storage tables is not allowed. Use the Storage API instead.',
  'client has no direct Storage deletion policy'
);

select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.photos), 0::bigint, 'spouse cannot read unfinished metadata');
select set_config('storage.operation', 'object.get_authenticated', true);
select is((select count(*) from storage.objects where bucket_id = 'purchase-photos'), 0::bigint, 'spouse cannot read unfinished bytes');
select throws_ok(
  $$insert into storage.objects (bucket_id, name, owner_id) values
    ('purchase-photos', (select reservation->>'objectKey' from photo_state),
      '81000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'spouse cannot upload to another member reservation'
);

reset role;
update public.photos set state = 'ATTACHED', item_id = '83000000-0000-0000-0000-000000000001';
select throws_ok(
  $$update public.photos set object_key = 'changed.jpg'$$,
  'PT409', 'IMMUTABLE_PHOTO_IDENTITY', 'even privileged lifecycle work cannot change the reserved key'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000002', true);
select is((select count(*) from public.photos), 1::bigint, 'spouse reads attached metadata');
select set_config('storage.operation', 'object.get_authenticated', true);
select is((select count(*) from storage.objects where bucket_id = 'purchase-photos'), 1::bigint, 'spouse reads attached bytes');
select set_config('storage.operation', 'object.list', true);
select is((select count(*) from storage.objects where bucket_id = 'purchase-photos'), 0::bigint, 'bucket listing does not reveal attached object keys');

select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000003', true);
select set_config('storage.operation', 'object.get_authenticated', true);
select is((select count(*) from public.photos), 0::bigint, 'outsider cannot read attached metadata');
select is((select count(*) from storage.objects where bucket_id = 'purchase-photos'), 0::bigint, 'outsider cannot read attached bytes');
select throws_ok(
  $$select public.reserve_photo('{"householdId":"82000000-0000-0000-0000-000000000001","requestId":"85000000-0000-0000-0000-000000000002"}')$$,
  'PT404', 'NOT_FOUND', 'outsider cannot reserve into the known household'
);

reset role;
delete from public.household_members where user_id = '81000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000002', true);
select set_config('storage.operation', 'object.get_authenticated', true);
select is((select count(*) from storage.objects where bucket_id = 'purchase-photos'), 0::bigint, 'revoked spouse loses attached photo access');
reset role;

set local role anon;
select throws_ok(
  $$select public.reserve_photo('{}')$$,
  '42501', null, 'anonymous reservation is denied'
);
reset role;
set local role service_role;
select throws_ok(
  $$select public.reserve_photo('{}')$$,
  '42501', null, 'service role has no implicit app reservation RPC'
);
reset role;

select * from finish();
rollback;
