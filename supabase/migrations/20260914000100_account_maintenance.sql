begin;

-- Uploader identity remains as durable request attribution after Auth deletion, just as
-- items.creation_requester_id does. Storage ownership is removed separately before deletion.
alter table public.photos drop constraint photos_uploader_user_id_fkey;
comment on column public.photos.uploader_user_id is
  'Original uploader UUID retained after account deletion; deliberately has no auth.users FK.';

create table private.account_operations (
  id uuid primary key,
  kind text not null check (kind in ('MEMBER_REMOVAL', 'HOUSEHOLD_CLOSURE')),
  household_id uuid not null,
  subject_user_ids uuid[] not null check (cardinality(subject_user_ids) between 1 and 2),
  state text not null check (state in ('TRANSFERRING', 'CLEANUP_PENDING', 'COMPLETED')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create unique index account_operation_active_household
  on private.account_operations (household_id) where state <> 'COMPLETED';

create table private.account_photo_transfers (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null references private.account_operations(id) on delete cascade,
  photo_id uuid not null,
  source_object_key text not null,
  staging_object_key text not null unique,
  checksum text not null check (checksum ~ '^[0-9a-f]{64}$'),
  byte_size bigint not null check (byte_size between 1 and 5242880),
  state text not null default 'PENDING'
    check (state in ('PENDING', 'RUNNING', 'FAILED', 'SUCCEEDED')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error_code text check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (operation_id, photo_id),
  unique (operation_id, source_object_key)
);
create index account_photo_transfer_due
  on private.account_photo_transfers (next_attempt_at, created_at)
  where state in ('PENDING', 'FAILED', 'RUNNING');

revoke all on private.account_operations, private.account_photo_transfers
  from public, anon, authenticated, service_role;

create function private.account_operation_json(p_operation private.account_operations)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'operationId', p_operation.id,
    'kind', p_operation.kind,
    'state', p_operation.state,
    'transferPending', (
      select count(*) from private.account_photo_transfers
      where operation_id = p_operation.id and state <> 'SUCCEEDED'
    ),
    'cleanupPending', (
      select count(*) from public.photos
      where household_id = p_operation.household_id and state = 'DELETE_PENDING'
    )
  );
$$;

create function public.begin_member_removal(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  v_household_id uuid;
  v_subject_user_id uuid;
  operation private.account_operations;
  transfer_count integer;
begin
  perform private.validate_keys(
    p_input,
    array['operationId', 'householdId', 'userId'],
    array['operationId', 'householdId', 'userId']
  );
  v_operation_id := private.input_uuid(p_input->'operationId');
  v_household_id := private.input_uuid(p_input->'householdId');
  v_subject_user_id := private.input_uuid(p_input->'userId');

  perform pg_advisory_xact_lock(hashtextextended(v_household_id::text, 4));
  select * into operation from private.account_operations where id = v_operation_id for update;
  if found then
    if operation.kind <> 'MEMBER_REMOVAL'
        or operation.household_id <> v_household_id
        or operation.subject_user_ids <> array[v_subject_user_id] then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
    return private.account_operation_json(operation);
  end if;

  perform 1 from public.households where id = v_household_id for update;
  if not found or (select count(*) from public.household_members
      where household_members.household_id = v_household_id) <> 2 then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;
  perform 1 from public.household_members
    where household_members.household_id = v_household_id
      and user_id = v_subject_user_id for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;

  insert into private.account_operations (id, kind, household_id, subject_user_ids, state)
    values (v_operation_id, 'MEMBER_REMOVAL', v_household_id, array[v_subject_user_id], 'CLEANUP_PENDING')
    returning * into operation;

  insert into private.account_photo_transfers (
    operation_id, photo_id, source_object_key, staging_object_key, checksum, byte_size
  )
  select v_operation_id, id, object_key,
    '.account-transfer/' || v_operation_id::text || '/' || id::text || '.jpg', checksum, byte_size
  from public.photos
  where photos.household_id = v_household_id
    and uploader_user_id = v_subject_user_id and state = 'ATTACHED'
  order by id;
  get diagnostics transfer_count = row_count;

  delete from public.photo_analyses where requested_by = v_subject_user_id;

  with candidates as (
    select * from public.photos
    where photos.household_id = v_household_id
      and uploader_user_id = v_subject_user_id and state in ('RESERVED', 'READY')
    for update
  ), changed as (
    update public.photos p set state = 'DELETE_PENDING'
      from candidates c where p.id = c.id returning p.*
  )
  insert into private.photo_cleanup_jobs (household_id, photo_id, object_key)
    select household_id, id, object_key from changed on conflict (object_key) do nothing;

  -- Membership is the request-time authorization boundary. Deleting it first immediately
  -- denies an already-issued JWT while object and identity cleanup continue.
  delete from public.household_members
    where household_members.household_id = v_household_id
      and user_id = v_subject_user_id;

  update private.account_operations set
    state = case when transfer_count > 0 then 'TRANSFERRING' else 'CLEANUP_PENDING' end,
    updated_at = clock_timestamp()
    where id = v_operation_id returning * into operation;
  return private.account_operation_json(operation);
exception when unique_violation then
  raise sqlstate 'PT409' using message = 'CONFLICT';
end;
$$;

create function public.claim_account_photo_transfers(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  requested_limit integer;
  result jsonb;
begin
  perform private.validate_keys(p_input, array['operationId', 'limit'], array['operationId', 'limit']);
  v_operation_id := private.input_uuid(p_input->'operationId');
  requested_limit := private.input_cleanup_limit(p_input->'limit');
  if not exists (
    select 1 from private.account_operations
    where id = v_operation_id and kind = 'MEMBER_REMOVAL' and state <> 'COMPLETED'
  ) then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;

  with due as (
    select id from private.account_photo_transfers
    where account_photo_transfers.operation_id = v_operation_id
      and (
        (state in ('PENDING', 'FAILED') and next_attempt_at <= statement_timestamp())
        or (state = 'RUNNING' and updated_at <= statement_timestamp() - interval '5 minutes')
      )
    order by next_attempt_at, created_at for update skip locked limit requested_limit
  ), claimed as (
    update private.account_photo_transfers t set
      state = 'RUNNING', attempts = attempts + 1, last_error_code = null,
      updated_at = clock_timestamp()
    from due where t.id = due.id
    returning t.id, t.source_object_key, t.staging_object_key, t.checksum, t.byte_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'jobId', id,
    'sourceObjectKey', source_object_key,
    'stagingObjectKey', staging_object_key,
    'checksum', checksum,
    'byteSize', byte_size
  ) order by id), '[]'::jsonb) into result from claimed;
  return result;
end;
$$;

create function public.finish_account_photo_transfer(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  job_id uuid;
  succeeded boolean;
  error_code text;
  job private.account_photo_transfers;
begin
  perform private.validate_keys(
    p_input,
    array['jobId', 'succeeded', 'errorCode'],
    array['jobId', 'succeeded']
  );
  job_id := private.input_uuid(p_input->'jobId');
  if jsonb_typeof(p_input->'succeeded') <> 'boolean' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  succeeded := (p_input->>'succeeded')::boolean;
  error_code := p_input->>'errorCode';
  if (succeeded and p_input ? 'errorCode')
      or (not succeeded and (error_code is null or error_code !~ '^[A-Z0-9_]{1,64}$')) then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;

  select * into job from private.account_photo_transfers where id = job_id for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if job.state = 'SUCCEEDED' then return; end if;
  if job.state <> 'RUNNING' then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;

  if succeeded then
    if not exists (
      select 1 from public.photos p join storage.objects o
        on o.bucket_id = 'purchase-photos' and o.name = p.object_key
      where p.id = job.photo_id and p.state = 'ATTACHED'
        and p.object_key = job.source_object_key and p.checksum = job.checksum
        and p.byte_size = job.byte_size and o.owner_id is null
    ) or exists (
      select 1 from storage.objects
      where bucket_id = 'purchase-photos' and name = job.staging_object_key
    ) then raise sqlstate 'PT409' using message = 'TRANSFER_NOT_VERIFIED'; end if;
    update private.account_photo_transfers set
      state = 'SUCCEEDED', last_error_code = null, updated_at = clock_timestamp()
      where id = job.id;
    if not exists (
      select 1 from private.account_photo_transfers
      where operation_id = job.operation_id and state <> 'SUCCEEDED'
    ) then
      update private.account_operations set state = 'CLEANUP_PENDING', updated_at = clock_timestamp()
        where id = job.operation_id;
    end if;
  else
    update private.account_photo_transfers set
      state = 'FAILED', last_error_code = error_code,
      next_attempt_at = clock_timestamp()
        + least(3600, power(2, least(attempts, 10))::integer * 30) * interval '1 second',
      updated_at = clock_timestamp()
      where id = job.id;
  end if;
end;
$$;

create function public.account_operation_readiness(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  operation private.account_operations;
  transfer_pending bigint;
  photo_pending bigint;
  owned_objects bigint;
  auth_users bigint;
begin
  perform private.validate_keys(p_input, array['operationId'], array['operationId']);
  v_operation_id := private.input_uuid(p_input->'operationId');
  select * into operation from private.account_operations where id = v_operation_id;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  select count(*) into transfer_pending from private.account_photo_transfers
    where operation_id = v_operation_id and state <> 'SUCCEEDED';
  select count(*) into photo_pending from public.photos
    where household_id = operation.household_id and (
      operation.kind = 'HOUSEHOLD_CLOSURE'
      or (uploader_user_id = operation.subject_user_ids[1] and state <> 'ATTACHED')
    );
  select count(*) into owned_objects from storage.objects
    where owner_id = any(operation.subject_user_ids::text[])
      or (
        operation.kind = 'HOUSEHOLD_CLOSURE'
        and bucket_id = 'purchase-photos'
        and left(name, 37) = operation.household_id::text || '/'
      );
  select count(*) into auth_users from auth.users where id = any(operation.subject_user_ids);
  return jsonb_build_object(
    'operationId', operation.id,
    'kind', operation.kind,
    'state', operation.state,
    'readyForIdentityDeletion', operation.state <> 'COMPLETED'
      and transfer_pending = 0 and photo_pending = 0 and owned_objects = 0,
    'transferPending', transfer_pending,
    'photoPending', photo_pending,
    'ownedObjectCount', owned_objects,
    'identityCount', auth_users,
    'subjectUserIds', to_jsonb(operation.subject_user_ids)
  );
end;
$$;

create function public.begin_household_closure(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  v_household_id uuid;
  operation private.account_operations;
  subjects uuid[];
begin
  perform private.validate_keys(p_input, array['operationId', 'householdId'], array['operationId', 'householdId']);
  v_operation_id := private.input_uuid(p_input->'operationId');
  v_household_id := private.input_uuid(p_input->'householdId');
  perform pg_advisory_xact_lock(hashtextextended(v_household_id::text, 4));
  select * into operation from private.account_operations where id = v_operation_id for update;
  if found then
    if operation.kind <> 'HOUSEHOLD_CLOSURE' or operation.household_id <> v_household_id then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
    return private.account_operation_json(operation);
  end if;
  perform 1 from public.households where id = v_household_id for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  select array_agg(user_id order by user_id) into subjects from public.household_members
    where household_members.household_id = v_household_id;
  if cardinality(subjects) not between 1 and 2 then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;
  insert into private.account_operations (id, kind, household_id, subject_user_ids, state)
    values (v_operation_id, 'HOUSEHOLD_CLOSURE', v_household_id, subjects, 'CLEANUP_PENDING')
    returning * into operation;

  delete from public.photo_analyses
    where photo_analyses.household_id = v_household_id;
  update public.items set photo_id = null
    where items.household_id = v_household_id and photo_id is not null;
  with changed as (
    update public.photos set state = 'DELETE_PENDING', item_id = null
    where photos.household_id = v_household_id
      and state <> 'DELETE_PENDING' returning *
  )
  insert into private.photo_cleanup_jobs (household_id, photo_id, object_key)
    select household_id, id, object_key from changed on conflict (object_key) do nothing;
  insert into private.photo_cleanup_jobs (household_id, photo_id, object_key)
    select household_id, id, object_key from public.photos
    where photos.household_id = v_household_id
      and state = 'DELETE_PENDING' on conflict (object_key) do nothing;
  delete from public.household_members
    where household_members.household_id = v_household_id;
  return private.account_operation_json(operation);
exception when unique_violation then
  raise sqlstate 'PT409' using message = 'CONFLICT';
end;
$$;

create function public.finish_account_operation(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_operation_id uuid;
  operation private.account_operations;
  readiness jsonb;
begin
  perform private.validate_keys(p_input, array['operationId'], array['operationId']);
  v_operation_id := private.input_uuid(p_input->'operationId');
  select * into operation from private.account_operations where id = v_operation_id for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if operation.state = 'COMPLETED' then return; end if;
  readiness := public.account_operation_readiness(jsonb_build_object('operationId', v_operation_id));
  if not (readiness->>'readyForIdentityDeletion')::boolean
      or (readiness->>'identityCount')::bigint <> 0 then
    raise sqlstate 'PT409' using message = 'OPERATION_NOT_READY';
  end if;
  if operation.kind = 'HOUSEHOLD_CLOSURE' then
    delete from public.items where household_id = operation.household_id;
    delete from public.households where id = operation.household_id;
  end if;
  update private.account_operations set
    state = 'COMPLETED', completed_at = clock_timestamp(), updated_at = clock_timestamp()
    where id = v_operation_id;
end;
$$;

revoke all on function private.account_operation_json(private.account_operations)
  from public, anon, authenticated, service_role;
revoke all on function public.begin_member_removal(jsonb),
  public.claim_account_photo_transfers(jsonb), public.finish_account_photo_transfer(jsonb),
  public.account_operation_readiness(jsonb), public.begin_household_closure(jsonb),
  public.finish_account_operation(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.begin_member_removal(jsonb),
  public.claim_account_photo_transfers(jsonb), public.finish_account_photo_transfer(jsonb),
  public.account_operation_readiness(jsonb), public.begin_household_closure(jsonb),
  public.finish_account_operation(jsonb)
  to service_role;

commit;
