begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select has_table('public', 'photo_analyses', 'recognition state exists');
select has_function('public', 'reserve_recognition', array['jsonb'], 'server reservation RPC exists');

insert into auth.users (id, email, email_confirmed_at) values
  ('b1000000-0000-0000-0000-000000000001', 'recognition-a@example.invalid', now()),
  ('b1000000-0000-0000-0000-000000000002', 'recognition-b@example.invalid', now()),
  ('b1000000-0000-0000-0000-000000000003', 'recognition-c@example.invalid', now()),
  ('b1000000-0000-0000-0000-000000000004', 'recognition-d@example.invalid', now());
select private.provision_household(
  'b2000000-0000-0000-0000-000000000001', 'Recognition home',
  'b1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000002'
);
select private.provision_household(
  'b2000000-0000-0000-0000-000000000002', 'Foreign home',
  'b1000000-0000-0000-0000-000000000003', 'b1000000-0000-0000-0000-000000000004'
);

insert into public.photos (
  id, household_id, uploader_user_id, request_id, object_key, state,
  byte_size, mime_type, checksum, expires_at
) values
  (
    'b3000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000001',
    'b2000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000001/b3000000-0000-0000-0000-000000000001.jpg',
    'READY', 100, 'image/jpeg', repeat('a', 64), now() + interval '1 hour'
  ),
  (
    'b3000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000002', 'b4000000-0000-0000-0000-000000000002',
    'b2000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000002/b3000000-0000-0000-0000-000000000002.jpg',
    'READY', 100, 'image/jpeg', repeat('b', 64), now() + interval '1 hour'
  ),
  (
    'b3000000-0000-0000-0000-000000000003', 'b2000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000003',
    'b2000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000001/b3000000-0000-0000-0000-000000000003.jpg',
    'RESERVED', null, null, null, now() + interval '1 hour'
  ),
  (
    'b3000000-0000-0000-0000-000000000004', 'b2000000-0000-0000-0000-000000000002',
    'b1000000-0000-0000-0000-000000000003', 'b4000000-0000-0000-0000-000000000004',
    'b2000000-0000-0000-0000-000000000002/b1000000-0000-0000-0000-000000000003/b3000000-0000-0000-0000-000000000004.jpg',
    'READY', 100, 'image/jpeg', repeat('c', 64), now() + interval '1 hour'
  ),
  (
    'b3000000-0000-0000-0000-000000000005', 'b2000000-0000-0000-0000-000000000001',
    'b1000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000005',
    'b2000000-0000-0000-0000-000000000001/b1000000-0000-0000-0000-000000000001/b3000000-0000-0000-0000-000000000005.jpg',
    'READY', null, null, null, now() + interval '1 hour'
  );

set local role authenticated;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', true);
select throws_ok(
  $$select public.reserve_recognition('{}')$$,
  '42501', null, 'ordinary clients cannot reserve analysis or quota state directly'
);
select throws_ok(
  $$select public.finish_recognition('{}')$$,
  '42501', null, 'ordinary clients cannot write provider completions directly'
);
select throws_ok(
  $$select public.fail_recognition('{}')$$,
  '42501', null, 'ordinary clients cannot write provider failures directly'
);
select throws_ok(
  $$select count(*) from public.photo_analyses$$,
  '42501', null, 'ordinary clients cannot read internal analysis state directly'
);
reset role;

select throws_ok(
  $$select public.reserve_recognition('{}')$$,
  'PT422', 'VALIDATION_ERROR', 'internal boundary validates exact input'
);
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000002","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000001","estimatedCostMicrousd":0}')$$,
  'PT404', 'NOT_FOUND', 'a spouse cannot analyze the uploader unfinished photo'
);
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000004","requestId":"b5000000-0000-0000-0000-000000000002","estimatedCostMicrousd":0}')$$,
  'PT404', 'NOT_FOUND', 'a foreign household photo is hidden'
);
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000003","requestId":"b5000000-0000-0000-0000-000000000003","estimatedCostMicrousd":0}')$$,
  'PT409', 'PHOTO_NOT_READY', 'an unvalidated upload cannot be analyzed'
);
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000005","requestId":"b5000000-0000-0000-0000-000000000004","estimatedCostMicrousd":0}')$$,
  'PT409', 'PHOTO_NOT_READY', 'a forged READY label without validated metadata cannot spend quota'
);

create temp table recognition_state as select public.reserve_recognition(
  '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000010","estimatedCostMicrousd":0}'
) as reservation;
select is(
  (select reservation->>'status' from recognition_state),
  'RESERVED', 'first authorized attempt reserves provider work'
);
select is(
  public.reserve_recognition(
    '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000010","estimatedCostMicrousd":0}'
  )->>'status',
  'IN_FLIGHT', 'an in-flight request ID does not start duplicate work'
);
select is(
  (select attempts from private.recognition_user_daily_usage
    where user_id = 'b1000000-0000-0000-0000-000000000001'),
  1, 'in-flight replay consumes no additional quota'
);
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000003","requestId":"b5000000-0000-0000-0000-000000000010","estimatedCostMicrousd":0}')$$,
  'PT409', 'REQUEST_CONFLICT', 'a request ID cannot be reused for another photo'
);

update public.photo_analyses set
  state = 'SUGGESTED',
  suggestion = '{"name":"Synthetic kettle","description":null,"brand":null,"model":null}'
  where id = (select (reservation->>'analysisId')::uuid from recognition_state);
select is(
  public.reserve_recognition(
    '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000010","estimatedCostMicrousd":0}'
  )->'suggestion'->>'name',
  'Synthetic kettle', 'completed retry returns the sanitized stored result'
);
select is(
  (select attempts from private.recognition_user_daily_usage
    where user_id = 'b1000000-0000-0000-0000-000000000001'),
  1, 'completed replay consumes no additional quota'
);

delete from public.household_members
  where user_id = 'b1000000-0000-0000-0000-000000000001';
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000010","estimatedCostMicrousd":0}')$$,
  'PT404', 'NOT_FOUND', 'membership is rechecked before a completed replay'
);
insert into public.household_members (household_id, user_id, slot) values (
  'b2000000-0000-0000-0000-000000000001',
  'b1000000-0000-0000-0000-000000000001',
  1
);

insert into recognition_state select public.reserve_recognition(
  '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000011","estimatedCostMicrousd":0}'
);
update public.photo_analyses set lease_expires_at = now() - interval '1 second'
  where request_id = 'b5000000-0000-0000-0000-000000000011';
select is(
  public.reserve_recognition(
    '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000011","estimatedCostMicrousd":0}'
  )->>'status',
  'RETRY_REQUIRED', 'expired work becomes an explicit new-request state'
);

update private.recognition_limits set user_daily_attempt_limit = 2;
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000012","estimatedCostMicrousd":0}')$$,
  'PT429', 'QUOTA_EXCEEDED', 'the configured per-user UTC daily limit is enforced'
);
select is(
  (select count(*) from public.photo_analyses
    where requested_by = 'b1000000-0000-0000-0000-000000000001'),
  2::bigint, 'quota rejection creates no analysis row'
);

update private.recognition_limits set
  user_daily_attempt_limit = 30,
  household_daily_attempt_limit = 2;
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000002","photoId":"b3000000-0000-0000-0000-000000000002","requestId":"b5000000-0000-0000-0000-000000000020","estimatedCostMicrousd":0}')$$,
  'PT429', 'QUOTA_EXCEEDED', 'the configurable household UTC daily cap is enforced'
);

update private.recognition_limits set
  household_daily_attempt_limit = 60,
  project_daily_spend_limit_microusd = 5;
select throws_ok(
  $$select public.reserve_recognition('{"requesterUserId":"b1000000-0000-0000-0000-000000000002","photoId":"b3000000-0000-0000-0000-000000000002","requestId":"b5000000-0000-0000-0000-000000000021","estimatedCostMicrousd":6}')$$,
  'PT429', 'QUOTA_EXCEEDED', 'the project spend cutoff rejects an oversized reservation'
);
select is(
  public.reserve_recognition(
    '{"requesterUserId":"b1000000-0000-0000-0000-000000000002","photoId":"b3000000-0000-0000-0000-000000000002","requestId":"b5000000-0000-0000-0000-000000000022","estimatedCostMicrousd":5}'
  )->>'status',
  'RESERVED', 'a reservation at the configured project cutoff succeeds'
);
select is(
  (select reserved_cost_microusd from private.recognition_project_daily_usage),
  5::bigint, 'project spend reservation is recorded atomically with the attempt'
);

create temp table provider_completion as select public.finish_recognition(jsonb_build_object(
  'analysisId', (
    select id from public.photo_analyses
      where request_id = 'b5000000-0000-0000-0000-000000000022'
  ),
  'photoId', 'b3000000-0000-0000-0000-000000000002',
  'state', 'SUGGESTED',
  'suggestion', '{"name":"Synthetic toaster","description":null,"brand":null,"model":null}'::jsonb,
  'reason', null,
  'providerId', 'openai-responses',
  'modelId', 'synthetic-model',
  'promptVersion', 'product-v1',
  'consumption', '{"inputTokens":10,"outputTokens":5,"totalTokens":15,"providerResponseId":"resp_synthetic"}'::jsonb
)) as result;
select is(
  (select result->'suggestion'->>'name' from provider_completion),
  'Synthetic toaster', 'server completion stores a validated suggestion'
);
select lives_ok(
  $$select public.finish_recognition(jsonb_build_object(
    'analysisId', (select id from public.photo_analyses where request_id = 'b5000000-0000-0000-0000-000000000022'),
    'photoId', 'b3000000-0000-0000-0000-000000000002',
    'state', 'SUGGESTED',
    'suggestion', '{"name":"Synthetic toaster","description":null,"brand":null,"model":null}'::jsonb,
    'reason', null, 'providerId', 'openai-responses', 'modelId', 'synthetic-model',
    'promptVersion', 'product-v1',
    'consumption', '{"inputTokens":10,"outputTokens":5,"totalTokens":15,"providerResponseId":"resp_synthetic"}'::jsonb
  ))$$,
  'identical completion retry is safe'
);
select throws_ok(
  $$select public.finish_recognition(jsonb_build_object(
    'analysisId', (select id from public.photo_analyses where request_id = 'b5000000-0000-0000-0000-000000000022'),
    'photoId', 'b3000000-0000-0000-0000-000000000002',
    'state', 'SUGGESTED',
    'suggestion', '{"name":"Changed toaster","description":null,"brand":null,"model":null}'::jsonb,
    'reason', null, 'providerId', 'openai-responses', 'modelId', 'synthetic-model',
    'promptVersion', 'product-v1',
    'consumption', '{"inputTokens":10,"outputTokens":5,"totalTokens":15,"providerResponseId":"resp_synthetic"}'::jsonb
  ))$$,
  'PT409', 'CONFLICT', 'completed suggestion cannot be changed by a retry'
);
select throws_ok(
  $$select public.finish_recognition(jsonb_build_object(
    'analysisId', (select id from public.photo_analyses where request_id = 'b5000000-0000-0000-0000-000000000022'),
    'photoId', 'b3000000-0000-0000-0000-000000000002',
    'state', 'SUGGESTED',
    'suggestion', '{"name":"Synthetic toaster","description":null,"brand":null,"model":null}'::jsonb,
    'reason', null, 'providerId', 'openai-responses', 'modelId', 'synthetic-model',
    'promptVersion', 'product-v1',
    'consumption', '{"inputTokens":10,"outputTokens":5,"totalTokens":99,"providerResponseId":"resp_synthetic"}'::jsonb
  ))$$,
  'PT422', 'VALIDATION_ERROR', 'completion rejects inconsistent provider usage'
);

update private.recognition_limits set
  user_daily_attempt_limit = 30,
  household_daily_attempt_limit = 60,
  project_daily_spend_limit_microusd = null;
create temp table provider_failures (reservation jsonb);
insert into provider_failures select public.reserve_recognition(
  '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000030","estimatedCostMicrousd":1}'
);
select is(
  public.fail_recognition(jsonb_build_object(
    'analysisId', (select reservation->>'analysisId' from provider_failures),
    'photoId', 'b3000000-0000-0000-0000-000000000001',
    'failureCode', 'PROVIDER_REFUSAL'
  ))->>'status',
  'FAILED', 'a definite provider refusal is stored for safe replay'
);
select is(
  public.reserve_recognition(
    '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000030","estimatedCostMicrousd":1}'
  )->>'failureCode',
  'PROVIDER_REFUSAL', 'refusal replay does not call the provider again'
);
truncate provider_failures;
insert into provider_failures select public.reserve_recognition(
  '{"requesterUserId":"b1000000-0000-0000-0000-000000000001","photoId":"b3000000-0000-0000-0000-000000000001","requestId":"b5000000-0000-0000-0000-000000000031","estimatedCostMicrousd":1}'
);
select is(
  public.fail_recognition(jsonb_build_object(
    'analysisId', (select reservation->>'analysisId' from provider_failures),
    'photoId', 'b3000000-0000-0000-0000-000000000001',
    'failureCode', 'PROVIDER_TIMEOUT'
  ))->>'status',
  'RETRY_REQUIRED', 'timeout ambiguity requires a new request ID'
);
select is(
  (select attempts from private.recognition_user_daily_usage
    where user_id = 'b1000000-0000-0000-0000-000000000001'),
  4, 'provider failures retain their consumed quota reservations'
);
select * from finish();
rollback;
