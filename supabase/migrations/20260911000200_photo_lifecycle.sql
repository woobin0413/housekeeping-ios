begin;

alter table public.items drop constraint items_photos_not_implemented;
alter table public.photos add constraint photos_household_id_id_key unique (household_id, id);
alter table public.items add constraint items_photo_household_fkey
  foreign key (household_id, photo_id) references public.photos(household_id, id) on delete restrict;

create table private.photo_cleanup_jobs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  photo_id uuid not null,
  object_key text not null unique,
  state text not null default 'PENDING' check (state in ('PENDING', 'RUNNING', 'FAILED', 'SUCCEEDED')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error_code text check (last_error_code is null or last_error_code ~ '^[A-Z0-9_]{1,64}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index photo_cleanup_due on private.photo_cleanup_jobs (next_attempt_at, created_at)
  where state in ('PENDING', 'FAILED');
revoke all on private.photo_cleanup_jobs from public, anon, authenticated, service_role;

create function private.enqueue_photo_cleanup(p_photo public.photos)
returns void language plpgsql set search_path = '' as $$
begin
  insert into private.photo_cleanup_jobs (household_id, photo_id, object_key)
    values (p_photo.household_id, p_photo.id, p_photo.object_key)
    on conflict (object_key) do nothing;
end;
$$;

create function private.input_cleanup_limit(p_value jsonb)
returns integer language plpgsql set search_path = '' as $$
declare result bigint;
begin
  result := private.input_version(p_value);
  if result > 100 then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
  return result::integer;
end;
$$;

create or replace function public.create_item(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  requester uuid := auth.uid();
  request uuid;
  fields jsonb;
  requested_photo uuid;
  original private.item_creation_requests;
  item public.items;
  photo public.photos;
begin
  perform private.validate_keys(p_input,
    array['householdId','requestId','name','description','brand','model','purchasedOn','photoId'],
    array['householdId','requestId','name']);
  if private.input_uuid(p_input->'householdId') <> household then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  request := private.input_uuid(p_input->'requestId');
  fields := private.item_fields(p_input - array['householdId','requestId','photoId'],true);
  if p_input ? 'photoId' and p_input->'photoId' <> 'null'::jsonb then
    requested_photo := private.input_uuid(p_input->'photoId');
    fields := fields || jsonb_build_object('photoId', requested_photo);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(household::text || requester::text || request::text,1));
  select * into original from private.item_creation_requests
    where household_id = household and requester_id = requester and request_id = request;
  if found then
    if original.input <> fields then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
    select * into item from public.items where id = original.item_id for update;
    if item.deleted_at is not null then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
    return private.item_json(item);
  end if;

  if requested_photo is not null then
    select * into photo from public.photos where id = requested_photo for update;
    if not found or photo.household_id <> household or photo.uploader_user_id <> requester then
      raise sqlstate 'PT404' using message = 'NOT_FOUND';
    end if;
    if photo.state <> 'READY' or photo.expires_at <= statement_timestamp() then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
  end if;

  insert into public.items (household_id,name,description,brand,model,purchased_on,photo_id,
      created_by,creation_requester_id,creation_request_id)
    values (household,fields->>'name',fields->>'description',fields->>'brand',fields->>'model',
      (fields->>'purchasedOn')::date,requested_photo,requester,requester,request) returning * into item;
  if requested_photo is not null then
    update public.photos set state = 'ATTACHED', item_id = item.id where id = requested_photo;
  end if;
  insert into private.item_creation_requests values (household,requester,request,item.id,fields);
  return private.item_json(item);
exception when unique_violation then
  raise sqlstate 'PT409' using message = 'CONFLICT';
end;
$$;

create function public.remove_item_photo(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  item_id uuid;
  expected bigint;
  item public.items;
  photo public.photos;
begin
  perform private.validate_keys(p_input,array['itemId','expectedVersion'],array['itemId','expectedVersion']);
  item_id := private.input_uuid(p_input->'itemId');
  expected := private.input_version(p_input->'expectedVersion');
  select * into item from public.items where id = item_id and household_id = household for update;
  if not found or item.deleted_at is not null then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if item.version <> expected then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
  if item.photo_id is null then return private.item_json(item); end if;
  select * into photo from public.photos where id = item.photo_id for update;
  update public.items set photo_id = null, version = version + 1, updated_at = clock_timestamp()
    where id = item.id returning * into item;
  update public.photos set state = 'DELETE_PENDING', item_id = null where id = photo.id;
  perform private.enqueue_photo_cleanup(photo);
  return private.item_json(item);
end;
$$;

create or replace function public.delete_item(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  item_id uuid;
  expected bigint;
  item public.items;
  photo public.photos;
begin
  perform private.validate_keys(p_input,array['id','expectedVersion'],array['id','expectedVersion']);
  item_id := private.input_uuid(p_input->'id');
  expected := private.input_version(p_input->'expectedVersion');
  select * into item from public.items where id = item_id and household_id = household for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if item.deleted_at is not null then return; end if;
  if item.version <> expected then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
  if item.photo_id is not null then
    select * into photo from public.photos where id = item.photo_id for update;
    update public.items set photo_id = null where id = item.id;
    update public.photos set state = 'DELETE_PENDING', item_id = null where id = photo.id;
    perform private.enqueue_photo_cleanup(photo);
  end if;
  update public.items set deleted_at = clock_timestamp(), updated_at = clock_timestamp(), version = version + 1
    where id = item.id;
end;
$$;

create function public.discard_photo(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  photo_id uuid;
  photo public.photos;
begin
  perform private.validate_keys(p_input,array['photoId'],array['photoId']);
  photo_id := private.input_uuid(p_input->'photoId');
  select * into photo from public.photos where id = photo_id for update;
  if not found or photo.household_id <> household or photo.uploader_user_id <> auth.uid() then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  if photo.state = 'DELETE_PENDING' then return; end if;
  if photo.state not in ('RESERVED','READY') then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
  update public.photos set state = 'DELETE_PENDING' where id = photo.id;
  perform private.enqueue_photo_cleanup(photo);
end;
$$;

create function public.enqueue_expired_photos(p_input jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare affected integer;
begin
  perform private.validate_keys(p_input,array['limit'],array['limit']);
  with candidates as (
    select id from public.photos where state in ('RESERVED','READY') and expires_at <= statement_timestamp()
    order by expires_at, id for update skip locked limit private.input_cleanup_limit(p_input->'limit')
  ), changed as (
    update public.photos p set state = 'DELETE_PENDING' from candidates c where p.id = c.id returning p.*
  ), queued as (
    insert into private.photo_cleanup_jobs (household_id,photo_id,object_key)
      select household_id,id,object_key from changed on conflict (object_key) do nothing returning 1
  ) select count(*) into affected from changed;
  return affected;
end;
$$;

create function public.claim_photo_cleanup(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  perform private.validate_keys(p_input,array['limit'],array['limit']);
  with due as (
    select id from private.photo_cleanup_jobs
    where state in ('PENDING','FAILED') and next_attempt_at <= statement_timestamp()
    order by next_attempt_at,created_at for update skip locked limit private.input_cleanup_limit(p_input->'limit')
  ), claimed as (
    update private.photo_cleanup_jobs j set state='RUNNING',attempts=attempts+1,updated_at=clock_timestamp()
    from due where j.id=due.id returning j.id,j.object_key
  ) select coalesce(jsonb_agg(jsonb_build_object('jobId',id,'objectKey',object_key)),'[]'::jsonb)
    into result from claimed;
  return result;
end;
$$;

create function public.finish_photo_cleanup(p_input jsonb)
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
    delete from public.photos where id=job.photo_id and state='DELETE_PENDING';
    update private.photo_cleanup_jobs set state='SUCCEEDED',last_error_code=null,updated_at=clock_timestamp() where id=job.id;
  else
    update private.photo_cleanup_jobs set state='FAILED',last_error_code=error_code,
      next_attempt_at=clock_timestamp()+least(3600,power(2,least(attempts,10))::integer*30)*interval '1 second',
      updated_at=clock_timestamp() where id=job.id;
  end if;
end;
$$;

revoke all on function private.enqueue_photo_cleanup(public.photos),private.input_cleanup_limit(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.remove_item_photo(jsonb),public.discard_photo(jsonb),
  public.enqueue_expired_photos(jsonb),public.claim_photo_cleanup(jsonb),public.finish_photo_cleanup(jsonb)
  from public,anon,authenticated,service_role;
grant execute on function public.remove_item_photo(jsonb),public.discard_photo(jsonb) to authenticated;
grant execute on function public.enqueue_expired_photos(jsonb),public.claim_photo_cleanup(jsonb),
  public.finish_photo_cleanup(jsonb) to service_role;

commit;
