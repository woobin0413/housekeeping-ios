begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

insert into auth.users (id,email,email_confirmed_at) values
 ('a1000000-0000-0000-0000-000000000001','life-a@example.invalid',now()),
 ('a1000000-0000-0000-0000-000000000002','life-b@example.invalid',now());
select private.provision_household('a2000000-0000-0000-0000-000000000001','Lifecycle home',
  'a1000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-000000000002');

insert into public.photos(id,household_id,uploader_user_id,request_id,object_key,state,
    byte_size,mime_type,checksum,expires_at) values
 ('a3000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000001',
  'a2000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/a3000000-0000-0000-0000-000000000001.jpg',
  'READY',100,'image/jpeg',repeat('a',64),now()+interval '1 hour'),
 ('a3000000-0000-0000-0000-000000000002','a2000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000002',
  'a2000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/a3000000-0000-0000-0000-000000000002.jpg',
  'READY',100,'image/jpeg',repeat('b',64),now()+interval '1 hour'),
 ('a3000000-0000-0000-0000-000000000003','a2000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000003',
  'a2000000-0000-0000-0000-000000000001/a1000000-0000-0000-0000-000000000001/a3000000-0000-0000-0000-000000000003.jpg',
  'READY',100,'image/jpeg',repeat('c',64),now()-interval '1 second');

set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
create temp table lifecycle_state as select public.create_item(
  '{"householdId":"a2000000-0000-0000-0000-000000000001","requestId":"a5000000-0000-0000-0000-000000000001","name":"Camera","photoId":"a3000000-0000-0000-0000-000000000001"}'
) as item;
select is((select item->>'photoId' from lifecycle_state),'a3000000-0000-0000-0000-000000000001',
  'creator atomically attaches own ready photo');
select is((select state from public.photos where id='a3000000-0000-0000-0000-000000000001'),'ATTACHED',
  'attachment transitions photo state');
select is(public.create_item(
  '{"householdId":"a2000000-0000-0000-0000-000000000001","requestId":"a5000000-0000-0000-0000-000000000001","name":"Camera","photoId":"a3000000-0000-0000-0000-000000000001"}'
)->>'id',(select item->>'id' from lifecycle_state),'attached create retry is idempotent');
select throws_ok(
  $$select public.create_item('{"householdId":"a2000000-0000-0000-0000-000000000001","requestId":"a5000000-0000-0000-0000-000000000002","name":"Expired","photoId":"a3000000-0000-0000-0000-000000000003"}')$$,
  'PT409','PHOTO_NOT_READY','expired ready photo is a definite attachment rejection');
reset role;
select is((select count(*) from private.item_creation_requests
  where request_id='a5000000-0000-0000-0000-000000000002'),0::bigint,
  'photo-readiness rejection leaves no committed request to duplicate');

set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000002',true);
select throws_ok(
  $$select public.create_item('{"householdId":"a2000000-0000-0000-0000-000000000001","requestId":"a5000000-0000-0000-0000-000000000003","name":"Stolen","photoId":"a3000000-0000-0000-0000-000000000002"}')$$,
  'PT404','NOT_FOUND','spouse cannot attach uploader unfinished photo');
update lifecycle_state set item=public.remove_item_photo(jsonb_build_object(
  'itemId',item->>'id','expectedVersion',1));
select is((select item->>'photoId' from lifecycle_state),null,'either spouse can remove attached photo');
select is((select item->>'version' from lifecycle_state),'2','photo removal versions the item');
select throws_ok($$select public.claim_photo_cleanup('{"limit":1}')$$,'42501',null,
  'ordinary session cannot claim internal cleanup');
select throws_ok($$select public.discard_photo('{"photoId":"a3000000-0000-0000-0000-000000000002"}')$$,
  'PT404','NOT_FOUND','spouse cannot discard uploader photo');
reset role;
select is((select state from public.photos where id='a3000000-0000-0000-0000-000000000001'),'DELETE_PENDING',
  'photo removal enters delete-pending before cleanup');
select is((select count(*) from private.photo_cleanup_jobs where photo_id='a3000000-0000-0000-0000-000000000001'),
  1::bigint,'photo removal enqueues exactly one cleanup job');

set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-0000-0000-000000000001',true);
select lives_ok($$select public.discard_photo('{"photoId":"a3000000-0000-0000-0000-000000000002"}')$$,
  'uploader can discard unattached ready photo');
select lives_ok($$select public.discard_photo('{"photoId":"a3000000-0000-0000-0000-000000000002"}')$$,
  'discard retry is idempotent');
reset role;

set local role service_role;
select throws_ok($$select public.claim_photo_cleanup('{"limit":26}')$$,'PT422','VALIDATION_ERROR',
  'cleanup batch is operationally bounded');
select is(public.enqueue_expired_photos('{"limit":25}'),1,'expired unfinished photos are enqueued');
create temp table claimed as select public.claim_photo_cleanup('{"limit":1}') as jobs;
select is(jsonb_array_length((select jobs from claimed)),1,'worker claims one due job');
select lives_ok(format($sql$select public.finish_photo_cleanup('{"jobId":"%s","succeeded":false,"errorCode":"STORAGE_UNAVAILABLE"}')$sql$,
  (select jobs->0->>'jobId' from claimed)),'transient deletion failure is recorded');
reset role;
select is((select state from private.photo_cleanup_jobs where id=(select (jobs->0->>'jobId')::uuid from claimed)),
  'FAILED','failed cleanup remains retryable');
update private.photo_cleanup_jobs set next_attempt_at=now()-interval '1 second' where state='FAILED';
truncate claimed;
set local role service_role;
insert into claimed select public.claim_photo_cleanup('{"limit":1}');
select lives_ok(format($sql$select public.finish_photo_cleanup('{"jobId":"%s","succeeded":true}')$sql$,
  (select jobs->0->>'jobId' from claimed)),'already-absent object can complete cleanup');
reset role;
select is((select state from private.photo_cleanup_jobs where id=(select (jobs->0->>'jobId')::uuid from claimed)),
  'SUCCEEDED','successful cleanup retains a completion tombstone');
select is((select count(*) from public.photos where id=(
  select photo_id from private.photo_cleanup_jobs where id=(select (jobs->0->>'jobId')::uuid from claimed))),
  0::bigint,'successful object deletion permits photo metadata purge');

update private.photo_cleanup_jobs set state='RUNNING',updated_at=now()-interval '6 minutes'
  where state='PENDING';
set local role service_role;
create temp table reclaimed as select public.claim_photo_cleanup('{"limit":25}') as jobs;
select is(jsonb_array_length((select jobs from reclaimed)),2,
  'worker reclaims abandoned leases without stranding cleanup');
reset role;
update public.photos set state='READY' where id=(
  select photo_id from private.photo_cleanup_jobs
  where id=(select (jobs->0->>'jobId')::uuid from reclaimed)
);
set local role service_role;
select throws_ok(format(
  $sql$select public.finish_photo_cleanup('{"jobId":"%s","succeeded":true}')$sql$,
  (select jobs->0->>'jobId' from reclaimed)
), 'PT409','CONFLICT','cleanup cannot purge metadata that left delete-pending');
reset role;

select * from finish();
rollback;
