begin;

alter table public.items add column quantity integer not null default 1
  constraint items_quantity_nonnegative check (quantity >= 0);

-- Keep requests saved before this migration replayable by old and updated clients.
update private.item_creation_requests
  set input = input || jsonb_build_object('quantity',1)
  where not (input ? 'quantity');

create or replace function private.item_json(p_item public.items)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'id',p_item.id,'householdId',p_item.household_id,'name',p_item.name,
    'description',p_item.description,'brand',p_item.brand,'model',p_item.model,
    'purchasedOn',p_item.purchased_on,'photoId',p_item.photo_id,'quantity',p_item.quantity,
    'createdAt',p_item.created_at,'updatedAt',p_item.updated_at,'version',p_item.version);
$$;

create or replace function private.item_fields(p_fields jsonb, p_create boolean)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  result jsonb := p_fields;
  key text;
  value text;
  date_value date;
begin
  perform private.validate_keys(p_fields,array['name','description','brand','model','purchasedOn','quantity'],
    case when p_create then array['name'] else array[]::text[] end);
  if p_fields = '{}'::jsonb then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
  foreach key in array array['name','description','brand','model','purchasedOn'] loop
    if not (p_fields ? key) then
      if p_create then result := result || jsonb_build_object(key,null); end if;
      continue;
    end if;
    if jsonb_typeof(p_fields->key) = 'null' and key <> 'name' then continue; end if;
    if jsonb_typeof(p_fields->key) <> 'string' then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
    value := p_fields->>key;
    if key = 'name' then
      value := private.trim_item_name(value);
      if char_length(value) not between 1 and 200 then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
      result := result || jsonb_build_object(key,value);
    elsif key = 'purchasedOn' then
      if value !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
      date_value := value::date;
      if to_char(date_value,'YYYY-MM-DD') <> value then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
    elsif char_length(value) > (case when key = 'description' then 2000 else 100 end) then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
  end loop;
  if p_fields ? 'quantity' then
    if jsonb_typeof(p_fields->'quantity') <> 'number' then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    if (p_fields->>'quantity')::numeric < 0
      or (p_fields->>'quantity')::numeric > 2147483647
      or trunc((p_fields->>'quantity')::numeric) <> (p_fields->>'quantity')::numeric then
      raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
    end if;
    result := result || jsonb_build_object('quantity',(p_fields->>'quantity')::numeric::integer);
  elsif p_create then
    result := result || jsonb_build_object('quantity',1);
  end if;
  return result;
exception when invalid_datetime_format or datetime_field_overflow then
  raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
end;
$$;

-- Distinguish a definite attachment rejection from an uncertain/idempotency conflict.
-- Request replay is checked first: a committed create still returns its original item.
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
    array['householdId','requestId','name','description','brand','model','purchasedOn','photoId','quantity'],
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
      raise sqlstate 'PT409' using message = 'PHOTO_NOT_READY';
    end if;
  end if;
  insert into public.items (household_id,name,description,brand,model,purchased_on,photo_id,quantity,
      created_by,creation_requester_id,creation_request_id)
    values (household,fields->>'name',fields->>'description',fields->>'brand',fields->>'model',
      (fields->>'purchasedOn')::date,requested_photo,(fields->>'quantity')::integer,requester,requester,request) returning * into item;
  if requested_photo is not null then
    update public.photos set state = 'ATTACHED', item_id = item.id where id = requested_photo;
  end if;
  insert into private.item_creation_requests values (household,requester,request,item.id,fields);
  return private.item_json(item);
exception when unique_violation then
  raise sqlstate 'PT409' using message = 'CONFLICT';
end;
$$;

create or replace function public.update_item(p_input jsonb)
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
    quantity = case when fields ? 'quantity' then (fields->>'quantity')::integer else quantity end,
    version = version + 1, updated_at = clock_timestamp()
    where id = item_id returning * into item;
  return private.item_json(item);
end;
$$;

commit;
