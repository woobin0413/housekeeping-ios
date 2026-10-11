begin;

create function private.input_photo_size(p_value jsonb)
returns bigint language plpgsql immutable set search_path = '' as $$
declare result numeric;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'number' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  result := (p_value #>> '{}')::numeric;
  if result < 1 or result > 5242880 or trunc(result) <> result then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  return result::bigint;
end;
$$;

-- This function is exposed through PostgREST only for the server-side media handler.
-- It does not trust that handler for authorization or lifecycle consistency.
create function public.finalize_photo(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  photo_id uuid;
  uploader_id uuid;
  validated_size bigint;
  validated_mime text;
  validated_checksum text;
  photo public.photos;
begin
  perform private.validate_keys(
    p_input,
    array['photoId', 'uploaderUserId', 'byteSize', 'mimeType', 'checksum'],
    array['photoId', 'uploaderUserId', 'byteSize', 'mimeType', 'checksum']
  );
  photo_id := private.input_uuid(p_input->'photoId');
  uploader_id := private.input_uuid(p_input->'uploaderUserId');
  validated_size := private.input_photo_size(p_input->'byteSize');
  if jsonb_typeof(p_input->'mimeType') <> 'string' or p_input->>'mimeType' <> 'image/jpeg' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  validated_mime := p_input->>'mimeType';
  if jsonb_typeof(p_input->'checksum') <> 'string'
      or p_input->>'checksum' !~ '^[0-9a-f]{64}$' then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  validated_checksum := p_input->>'checksum';

  select * into photo from public.photos where id = photo_id for update;
  if not found or photo.uploader_user_id <> uploader_id then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  perform 1 from public.household_members
    where household_id = photo.household_id and user_id = uploader_id for share;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'purchase-photos' and name = photo.object_key
  ) then
    raise sqlstate 'PT409' using message = 'UPLOAD_INCOMPLETE';
  end if;

  if photo.state = 'READY' then
    if photo.byte_size <> validated_size
        or photo.mime_type <> validated_mime
        or photo.checksum <> validated_checksum then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
    return jsonb_build_object('photoId', photo.id, 'state', 'READY');
  end if;
  if photo.state <> 'RESERVED' then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;
  if photo.expires_at <= statement_timestamp() then
    raise sqlstate 'PT409' using message = 'RESERVATION_EXPIRED';
  end if;

  update public.photos set
    state = 'READY',
    byte_size = validated_size,
    mime_type = validated_mime,
    checksum = validated_checksum
    where id = photo.id;
  return jsonb_build_object('photoId', photo.id, 'state', 'READY');
end;
$$;

revoke all on function private.input_photo_size(jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.finalize_photo(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.finalize_photo(jsonb) to service_role;

commit;
