begin;

-- Original normalized input is private, so ordinary reads cannot disclose old field values.
create table private.item_creation_requests (
  household_id uuid not null references public.households(id),
  requester_id uuid not null,
  request_id uuid not null,
  item_id uuid not null unique references public.items(id) on delete cascade,
  input jsonb not null,
  primary key (household_id, requester_id, request_id)
);
revoke all on private.item_creation_requests from public, anon, authenticated, service_role;

create function private.item_json(p_item public.items)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id',p_item.id,'householdId',p_item.household_id,'name',p_item.name,
    'description',p_item.description,'brand',p_item.brand,'model',p_item.model,
    'purchasedOn',p_item.purchased_on,'photoId',p_item.photo_id,
    'createdAt',p_item.created_at,'updatedAt',p_item.updated_at,'version',p_item.version);
$$;

-- Hold membership through each write, serializing it with operator revocation.
create function private.lock_household()
returns uuid language plpgsql security definer set search_path = '' as $$
declare result uuid;
begin
  if auth.uid() is null then
    raise sqlstate 'PT401' using message = 'UNAUTHENTICATED';
  end if;
  select household_id into result from public.household_members
    where user_id = auth.uid() for share;
  if result is null then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  return result;
end;
$$;

create function private.validate_keys(p_input jsonb, p_allowed text[], p_required text[])
returns void language plpgsql set search_path = '' as $$
begin
  if p_input is null or jsonb_typeof(p_input) <> 'object' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  if not (p_input ?& p_required) or exists (
    select 1 from jsonb_object_keys(p_input) as k where not (k = any(p_allowed))
  ) then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
end;
$$;

create function private.item_fields(p_fields jsonb, p_create boolean)
returns jsonb language plpgsql set search_path = '' as $$
declare
  result jsonb := p_fields;
  key text;
  value text;
  date_value date;
begin
  perform private.validate_keys(p_fields,array['name','description','brand','model','purchasedOn'],
    case when p_create then array['name'] else array[]::text[] end);
  if p_fields = '{}'::jsonb then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
  foreach key in array array['name','description','brand','model','purchasedOn'] loop
    if not (p_fields ? key) then
      if p_create then result := result || jsonb_build_object(key,null); end if;
      continue;
    end if;
    if jsonb_typeof(p_fields->key) = 'null' and key <> 'name' then continue; end if;
    if jsonb_typeof(p_fields->key) <> 'string' then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    value := p_fields->>key;
    if key = 'name' then
      value := btrim(value);
      if char_length(value) not between 1 and 200 or value ~ '^[[:space:]]*$' then
        raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
      end if;
      result := result || jsonb_build_object(key,value);
    elsif key = 'purchasedOn' then
      if value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
      end if;
      date_value := value::date;
      if to_char(date_value,'YYYY-MM-DD') <> value then
        raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
      end if;
    elsif char_length(value) > (case when key = 'description' then 2000 else 100 end) then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
  end loop;
  return result;
exception when invalid_datetime_format or datetime_field_overflow then
  raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
end;
$$;

create function private.input_uuid(p_value jsonb)
returns uuid language plpgsql set search_path = '' as $$
begin
  if p_value is null or jsonb_typeof(p_value) <> 'string' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  return (p_value #>> '{}')::uuid;
exception when invalid_text_representation then
  raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
end;
$$;

create function private.input_version(p_value jsonb)
returns bigint language plpgsql set search_path = '' as $$
declare result numeric;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'number' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  result := (p_value #>> '{}')::numeric;
  if result < 1 or result > 9007199254740991 or trunc(result) <> result then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  return result::bigint;
end;
$$;

create function public.create_item(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  requester uuid := auth.uid();
  request uuid;
  fields jsonb;
  original private.item_creation_requests;
  item public.items;
begin
  perform private.validate_keys(p_input,
    array['householdId','requestId','name','description','brand','model','purchasedOn','photoId'],
    array['householdId','requestId','name']);
  if private.input_uuid(p_input->'householdId') <> household then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  request := private.input_uuid(p_input->'requestId');
  if p_input ? 'photoId' and p_input->'photoId' <> 'null'::jsonb then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  fields := private.item_fields(p_input - array['householdId','requestId','photoId'],true);
  -- Serialize this caller's retries; a hash collision only serializes unrelated requests.
  perform pg_advisory_xact_lock(hashtextextended(household::text || requester::text || request::text,1));
  select * into original from private.item_creation_requests
    where household_id = household and requester_id = requester and request_id = request;
  if found then
    if original.input <> fields then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
    select * into item from public.items where id = original.item_id for update;
    if item.deleted_at is not null then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
    return private.item_json(item);
  end if;
  insert into public.items (household_id,name,description,brand,model,purchased_on,
      created_by,creation_requester_id,creation_request_id)
    values (household,fields->>'name',fields->>'description',fields->>'brand',fields->>'model',
      (fields->>'purchasedOn')::date,requester,requester,request) returning * into item;
  insert into private.item_creation_requests values (household,requester,request,item.id,fields);
  return private.item_json(item);
exception when unique_violation then
  -- A legacy row without a recorded payload must never be silently duplicated.
  raise sqlstate 'PT409' using message = 'CONFLICT';
end;
$$;

create function public.update_item(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  item_id uuid;
  expected bigint;
  fields jsonb;
  item public.items;
begin
  perform private.validate_keys(p_input,array['id','expectedVersion','fields'],array['id','expectedVersion','fields']);
  item_id := private.input_uuid(p_input->'id');
  expected := private.input_version(p_input->'expectedVersion');
  fields := private.item_fields(p_input->'fields',false);
  select * into item from public.items where id = item_id and household_id = household for update;
  if not found or item.deleted_at is not null then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if item.version <> expected then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
  update public.items set
    name = case when fields ? 'name' then fields->>'name' else name end,
    description = case when fields ? 'description' then fields->>'description' else description end,
    brand = case when fields ? 'brand' then fields->>'brand' else brand end,
    model = case when fields ? 'model' then fields->>'model' else model end,
    purchased_on = case when fields ? 'purchasedOn' then (fields->>'purchasedOn')::date else purchased_on end,
    version = version + 1, updated_at = clock_timestamp()
    where id = item_id returning * into item;
  return private.item_json(item);
end;
$$;

create function public.delete_item(p_input jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  item_id uuid;
  expected bigint;
  item public.items;
begin
  perform private.validate_keys(p_input,array['id','expectedVersion'],array['id','expectedVersion']);
  item_id := private.input_uuid(p_input->'id');
  expected := private.input_version(p_input->'expectedVersion');
  select * into item from public.items where id = item_id and household_id = household for update;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if item.deleted_at is not null then return; end if;
  if item.version <> expected then raise sqlstate 'PT409' using message = 'CONFLICT'; end if;
  -- No cleanup job is needed until photos can be attached; retain the tombstone/retry ledger.
  update public.items set deleted_at = clock_timestamp(), updated_at = clock_timestamp(), version = version + 1
    where id = item_id;
end;
$$;

revoke all on function private.item_json(public.items), private.lock_household(),
  private.validate_keys(jsonb,text[],text[]), private.item_fields(jsonb,boolean),
  private.input_uuid(jsonb), private.input_version(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.create_item(jsonb), public.update_item(jsonb), public.delete_item(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.create_item(jsonb), public.update_item(jsonb), public.delete_item(jsonb)
  to authenticated;
commit;
