begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select has_function('public', 'finalize_photo', array['jsonb'], 'server finalization RPC exists');
insert into auth.users (id, email, email_confirmed_at) values
  ('91000000-0000-0000-0000-000000000001', 'finalize-a@example.invalid', now()),
  ('91000000-0000-0000-0000-000000000002', 'finalize-b@example.invalid', now());
select private.provision_household(
  '92000000-0000-0000-0000-000000000001', 'Finalize home',
  '91000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000002'
);
create temp table finalization_state (reservation jsonb);
insert into finalization_state default values;
grant all on finalization_state to authenticated, service_role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '91000000-0000-0000-0000-000000000001', true);
update finalization_state set reservation = public.reserve_photo(
  '{"householdId":"92000000-0000-0000-0000-000000000001","requestId":"93000000-0000-0000-0000-000000000001"}'
);
insert into storage.objects (bucket_id, name, owner_id) values (
  'purchase-photos', (select reservation->>'objectKey' from finalization_state),
  '91000000-0000-0000-0000-000000000001'
);
select throws_ok(
  $$select public.finalize_photo('{}')$$,
  '42501', null, 'ordinary authenticated clients cannot bypass byte validation'
);
reset role;

set local role service_role;
select is(
  public.finalize_photo(jsonb_build_object(
    'photoId', (select reservation->>'photoId' from finalization_state),
    'uploaderUserId', '91000000-0000-0000-0000-000000000001',
    'byteSize', 511,
    'mimeType', 'image/jpeg',
    'checksum', repeat('a', 64)
  ))->>'state',
  'READY',
  'server transition marks validated upload ready'
);
reset role;
select is(
  (select byte_size from public.photos where id = (select (reservation->>'photoId')::uuid from finalization_state)),
  511::bigint,
  'server stores validated byte size'
);
select is(
  (select checksum from public.photos where id = (select (reservation->>'photoId')::uuid from finalization_state)),
  repeat('a', 64),
  'server stores validated checksum'
);
set local role service_role;
select is(
  public.finalize_photo(jsonb_build_object(
    'photoId', (select reservation->>'photoId' from finalization_state),
    'uploaderUserId', '91000000-0000-0000-0000-000000000001',
    'byteSize', 511,
    'mimeType', 'image/jpeg',
    'checksum', repeat('a', 64)
  ))->>'state',
  'READY',
  'identical repeated completion is safe'
);
select throws_ok(
  format(
    $sql$select public.finalize_photo('{"photoId":"%s","uploaderUserId":"91000000-0000-0000-0000-000000000001","byteSize":511,"mimeType":"image/jpeg","checksum":"%s"}')$sql$,
    (select reservation->>'photoId' from finalization_state), repeat('b', 64)
  ),
  'PT409', 'CONFLICT', 'completed metadata cannot be changed by retry'
);
select throws_ok(
  format(
    $sql$select public.finalize_photo('{"photoId":"%s","uploaderUserId":"91000000-0000-0000-0000-000000000002","byteSize":511,"mimeType":"image/jpeg","checksum":"%s"}')$sql$,
    (select reservation->>'photoId' from finalization_state), repeat('a', 64)
  ),
  'PT404', 'NOT_FOUND', 'server operation cannot finalize for a different uploader'
);
select throws_ok(
  $$select public.finalize_photo('{"photoId":"91000000-0000-0000-0000-000000000001","uploaderUserId":"91000000-0000-0000-0000-000000000001","byteSize":0,"mimeType":"image/jpeg","checksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}')$$,
  'PT422', 'VALIDATION_ERROR', 'server metadata boundary rejects invalid byte size'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '91000000-0000-0000-0000-000000000001', true);
update finalization_state set reservation = public.reserve_photo(
  '{"householdId":"92000000-0000-0000-0000-000000000001","requestId":"93000000-0000-0000-0000-000000000002"}'
);
reset role;
set local role service_role;
select throws_ok(
  format(
    $sql$select public.finalize_photo('{"photoId":"%s","uploaderUserId":"91000000-0000-0000-0000-000000000001","byteSize":511,"mimeType":"image/jpeg","checksum":"%s"}')$sql$,
    (select reservation->>'photoId' from finalization_state), repeat('a', 64)
  ),
  'PT409', 'UPLOAD_INCOMPLETE', 'metadata cannot become ready before object upload'
);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '91000000-0000-0000-0000-000000000001', true);
update finalization_state set reservation = public.reserve_photo(
  '{"householdId":"92000000-0000-0000-0000-000000000001","requestId":"93000000-0000-0000-0000-000000000003"}'
);
insert into storage.objects (bucket_id, name, owner_id) values (
  'purchase-photos', (select reservation->>'objectKey' from finalization_state),
  '91000000-0000-0000-0000-000000000001'
);
reset role;
update public.photos set expires_at = now() - interval '1 second'
  where id = (select (reservation->>'photoId')::uuid from finalization_state);
set local role service_role;
select throws_ok(
  format(
    $sql$select public.finalize_photo('{"photoId":"%s","uploaderUserId":"91000000-0000-0000-0000-000000000001","byteSize":511,"mimeType":"image/jpeg","checksum":"%s"}')$sql$,
    (select reservation->>'photoId' from finalization_state), repeat('a', 64)
  ),
  'PT409', 'RESERVATION_EXPIRED', 'expired upload cannot become ready'
);
reset role;

delete from public.household_members where user_id = '91000000-0000-0000-0000-000000000001';
set local role service_role;
select throws_ok(
  format(
    $sql$select public.finalize_photo('{"photoId":"%s","uploaderUserId":"91000000-0000-0000-0000-000000000001","byteSize":511,"mimeType":"image/jpeg","checksum":"%s"}')$sql$,
    (select reservation->>'photoId' from finalization_state), repeat('a', 64)
  ),
  'PT404', 'NOT_FOUND', 'revoked uploader cannot complete a reservation'
);
reset role;

select * from finish();
rollback;
