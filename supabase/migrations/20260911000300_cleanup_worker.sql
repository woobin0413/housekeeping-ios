begin;

create index photo_cleanup_abandoned on private.photo_cleanup_jobs (updated_at)
  where state = 'RUNNING';

create or replace function private.input_cleanup_limit(p_value jsonb)
returns integer language plpgsql set search_path = '' as $$
declare result bigint;
begin
  result := private.input_version(p_value);
  if result > 25 then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
  return result::integer;
end;
$$;

create or replace function public.claim_photo_cleanup(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  perform private.validate_keys(p_input,array['limit'],array['limit']);
  with due as (
    select id from private.photo_cleanup_jobs
    where (
      state in ('PENDING','FAILED') and next_attempt_at <= statement_timestamp()
    ) or (
      state = 'RUNNING' and updated_at <= statement_timestamp() - interval '5 minutes'
    )
    order by next_attempt_at,created_at
    for update skip locked limit private.input_cleanup_limit(p_input->'limit')
  ), claimed as (
    update private.photo_cleanup_jobs j
      set state='RUNNING',attempts=attempts+1,last_error_code=null,updated_at=clock_timestamp()
    from due where j.id=due.id returning j.id,j.object_key
  ) select coalesce(jsonb_agg(jsonb_build_object('jobId',id,'objectKey',object_key)),'[]'::jsonb)
    into result from claimed;
  return result;
end;
$$;

create or replace function public.finish_photo_cleanup(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare job_id uuid; succeeded boolean; error_code text; job private.photo_cleanup_jobs;
begin
  perform private.validate_keys(p_input,array['jobId','succeeded','errorCode'],array['jobId','succeeded']);
  job_id := private.input_uuid(p_input->'jobId');
  if jsonb_typeof(p_input->'succeeded') <> 'boolean' then raise sqlstate 'PT422' using message='VALIDATION_ERROR'; end if;
  succeeded := (p_input->>'succeeded')::boolean;
  error_code := p_input->>'errorCode';
  if (succeeded and p_input ? 'errorCode') or (not succeeded and (error_code is null or error_code !~ '^[A-Z0-9_]{1,64}$')) then
    raise sqlstate 'PT422' using message='VALIDATION_ERROR';
  end if;
  select * into job from private.photo_cleanup_jobs where id=job_id for update;
  if not found then raise sqlstate 'PT404' using message='NOT_FOUND'; end if;
  if job.state='SUCCEEDED' then return; end if;
  if job.state<>'RUNNING' then raise sqlstate 'PT409' using message='CONFLICT'; end if;
  if succeeded then
    if exists (select 1 from public.photos where id=job.photo_id and state<>'DELETE_PENDING') then
      raise sqlstate 'PT409' using message='CONFLICT';
    end if;
    delete from public.photos where id=job.photo_id and state='DELETE_PENDING';
    update private.photo_cleanup_jobs set state='SUCCEEDED',last_error_code=null,updated_at=clock_timestamp() where id=job.id;
  else
    update private.photo_cleanup_jobs set state='FAILED',last_error_code=error_code,
      next_attempt_at=clock_timestamp()+least(3600,power(2,least(attempts,10))::integer*30)*interval '1 second',
      updated_at=clock_timestamp() where id=job.id;
  end if;
end;
$$;

commit;
