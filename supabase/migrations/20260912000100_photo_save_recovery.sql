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
      raise sqlstate 'PT409' using message = 'PHOTO_NOT_READY';
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
