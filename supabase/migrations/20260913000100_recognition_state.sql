begin;

create table public.photo_analyses (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  photo_id uuid not null,
  requested_by uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  state text not null default 'PROCESSING'
    check (state in ('PROCESSING', 'SUGGESTED', 'UNRECOGNIZED', 'RETRY_REQUIRED')),
  suggestion jsonb,
  reason text check (reason is null or reason in ('UNCLEAR_IMAGE', 'MULTIPLE_PRODUCTS', 'NO_PRODUCT')),
  provider_id text check (provider_id is null or char_length(provider_id) between 1 and 100),
  model_id text check (model_id is null or char_length(model_id) between 1 and 200),
  prompt_version text check (prompt_version is null or char_length(prompt_version) between 1 and 100),
  reserved_cost_microusd bigint not null default 0 check (reserved_cost_microusd >= 0),
  consumption jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  lease_expires_at timestamptz not null,
  expires_at timestamptz not null,
  unique (requested_by, request_id),
  unique (household_id, id),
  foreign key (household_id, photo_id)
    references public.photos(household_id, id) on delete cascade,
  check (
    (state in ('PROCESSING', 'RETRY_REQUIRED') and suggestion is null and reason is null)
    or (state = 'SUGGESTED' and suggestion is not null and reason is null)
    or (state = 'UNRECOGNIZED' and suggestion is null and reason is not null)
  )
);
create index photo_analyses_expiry on public.photo_analyses (expires_at, id);

alter table public.photo_analyses enable row level security;
revoke all on public.photo_analyses from public, anon, authenticated, service_role;

create table private.recognition_limits (
  singleton boolean primary key default true check (singleton),
  user_daily_attempt_limit integer not null default 30
    check (user_daily_attempt_limit between 1 and 1000),
  household_daily_attempt_limit integer not null default 60
    check (household_daily_attempt_limit between 1 and 2000),
  project_daily_spend_limit_microusd bigint
    check (project_daily_spend_limit_microusd is null or project_daily_spend_limit_microusd > 0)
);
insert into private.recognition_limits default values;

create table private.recognition_user_daily_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_day date not null,
  attempts integer not null default 0 check (attempts >= 0),
  primary key (user_id, usage_day)
);

create table private.recognition_household_daily_usage (
  household_id uuid not null references public.households(id) on delete cascade,
  usage_day date not null,
  attempts integer not null default 0 check (attempts >= 0),
  primary key (household_id, usage_day)
);

create table private.recognition_project_daily_usage (
  usage_day date primary key,
  attempts integer not null default 0 check (attempts >= 0),
  reserved_cost_microusd bigint not null default 0 check (reserved_cost_microusd >= 0),
  actual_cost_microusd bigint not null default 0 check (actual_cost_microusd >= 0)
);

revoke all on private.recognition_limits, private.recognition_user_daily_usage,
  private.recognition_household_daily_usage, private.recognition_project_daily_usage
  from public, anon, authenticated, service_role;

create function private.recognition_result(p_analysis public.photo_analyses)
returns jsonb language plpgsql stable set search_path = '' as $$
begin
  if p_analysis.state = 'SUGGESTED' then
    return jsonb_build_object(
      'status', 'SUGGESTED',
      'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id,
      'suggestion', p_analysis.suggestion
    );
  end if;
  if p_analysis.state = 'UNRECOGNIZED' then
    return jsonb_build_object(
      'status', 'UNRECOGNIZED',
      'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id,
      'suggestion', null,
      'reason', p_analysis.reason
    );
  end if;
  if p_analysis.state = 'RETRY_REQUIRED' then
    return jsonb_build_object(
      'status', 'RETRY_REQUIRED',
      'analysisId', p_analysis.id,
      'photoId', p_analysis.photo_id
    );
  end if;
  return jsonb_build_object(
    'status', 'IN_FLIGHT',
    'analysisId', p_analysis.id,
    'photoId', p_analysis.photo_id
  );
end;
$$;

-- Internal Edge Function boundary. The verified caller identity is explicit because this RPC is
-- executable only by service_role; authorization is still rechecked inside this transaction.
create function public.reserve_recognition(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  requester uuid;
  requested_photo uuid;
  request uuid;
  estimated_cost bigint;
  household uuid;
  quota_day date := (clock_timestamp() at time zone 'UTC')::date;
  limits private.recognition_limits;
  user_attempts integer;
  household_attempts integer;
  project_reserved bigint;
  photo public.photos;
  analysis public.photo_analyses;
begin
  perform private.validate_keys(
    p_input,
    array['requesterUserId', 'photoId', 'requestId', 'estimatedCostMicrousd'],
    array['requesterUserId', 'photoId', 'requestId', 'estimatedCostMicrousd']
  );
  requester := private.input_uuid(p_input->'requesterUserId');
  requested_photo := private.input_uuid(p_input->'photoId');
  request := private.input_uuid(p_input->'requestId');
  if jsonb_typeof(p_input->'estimatedCostMicrousd') <> 'number'
      or (p_input->>'estimatedCostMicrousd') !~ '^[0-9]+$' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  begin
    estimated_cost := (p_input->>'estimatedCostMicrousd')::bigint;
  exception when numeric_value_out_of_range then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end;
  if estimated_cost > 1000000000 then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;

  select household_id into household from public.household_members
    where user_id = requester for share;
  if household is null then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(requester::text || request::text, 3));
  select * into analysis from public.photo_analyses
    where requested_by = requester and request_id = request for update;
  if found and analysis.photo_id <> requested_photo then
    raise sqlstate 'PT409' using message = 'REQUEST_CONFLICT';
  end if;

  select * into photo from public.photos where id = requested_photo for update;
  if not found or photo.household_id <> household or photo.uploader_user_id <> requester then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  if photo.state <> 'READY' or photo.expires_at <= statement_timestamp()
      or photo.byte_size is null or photo.mime_type <> 'image/jpeg' or photo.checksum is null then
    raise sqlstate 'PT409' using message = 'PHOTO_NOT_READY';
  end if;

  if analysis.id is not null then
    if analysis.state = 'PROCESSING' and analysis.lease_expires_at <= statement_timestamp() then
      update public.photo_analyses set state = 'RETRY_REQUIRED', updated_at = clock_timestamp()
        where id = analysis.id returning * into analysis;
    end if;
    return private.recognition_result(analysis);
  end if;

  select * into limits from private.recognition_limits where singleton for share;
  if limits.singleton is null then
    raise exception using message = 'RECOGNITION_LIMITS_MISSING';
  end if;
  insert into private.recognition_project_daily_usage (usage_day)
    values (quota_day) on conflict (usage_day) do nothing;
  insert into private.recognition_household_daily_usage (household_id, usage_day)
    values (household, quota_day) on conflict (household_id, usage_day) do nothing;
  insert into private.recognition_user_daily_usage (user_id, usage_day)
    values (requester, quota_day) on conflict (user_id, usage_day) do nothing;

  select reserved_cost_microusd into project_reserved
    from private.recognition_project_daily_usage where usage_day = quota_day for update;
  select attempts into household_attempts from private.recognition_household_daily_usage
    where household_id = household and usage_day = quota_day for update;
  select attempts into user_attempts from private.recognition_user_daily_usage
    where user_id = requester and usage_day = quota_day for update;

  if user_attempts >= limits.user_daily_attempt_limit
      or household_attempts >= limits.household_daily_attempt_limit
      or (
        limits.project_daily_spend_limit_microusd is not null
        and project_reserved + estimated_cost > limits.project_daily_spend_limit_microusd
      ) then
    raise sqlstate 'PT429' using message = 'QUOTA_EXCEEDED';
  end if;

  update private.recognition_project_daily_usage set
    attempts = attempts + 1,
    reserved_cost_microusd = reserved_cost_microusd + estimated_cost
    where recognition_project_daily_usage.usage_day = quota_day;
  update private.recognition_household_daily_usage set attempts = attempts + 1
    where household_id = household and recognition_household_daily_usage.usage_day = quota_day;
  update private.recognition_user_daily_usage set attempts = attempts + 1
    where user_id = requester and recognition_user_daily_usage.usage_day = quota_day;

  insert into public.photo_analyses (
    household_id, photo_id, requested_by, request_id, reserved_cost_microusd,
    lease_expires_at, expires_at
  ) values (
    household, photo.id, requester, request, estimated_cost,
    clock_timestamp() + interval '90 seconds', photo.expires_at
  ) returning * into analysis;

  return jsonb_build_object(
    'status', 'RESERVED',
    'analysisId', analysis.id,
    'photoId', analysis.photo_id,
    'objectKey', photo.object_key,
    'checksum', photo.checksum
  );
end;
$$;

revoke all on function private.recognition_result(public.photo_analyses)
  from public, anon, authenticated, service_role;
revoke all on function public.reserve_recognition(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.reserve_recognition(jsonb) to service_role;

commit;
