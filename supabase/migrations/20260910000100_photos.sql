begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('purchase-photos', 'purchase-photos', false, 5242880, array['image/jpeg'])
on conflict (id) do update set
  name = excluded.name,
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table public.photos (
  id uuid primary key,
  household_id uuid not null references public.households(id) on delete restrict,
  uploader_user_id uuid not null references auth.users(id) on delete restrict,
  request_id uuid not null,
  item_id uuid,
  object_key text not null unique,
  state text not null default 'RESERVED'
    check (state in ('RESERVED', 'READY', 'ATTACHED', 'DELETE_PENDING')),
  byte_size bigint check (byte_size is null or byte_size between 1 and 5242880),
  mime_type text check (mime_type is null or mime_type = 'image/jpeg'),
  checksum text check (checksum is null or checksum ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  unique (uploader_user_id, request_id),
  check (object_key = household_id::text || '/' || uploader_user_id::text || '/' || id::text || '.jpg'),
  check ((state = 'ATTACHED') = (item_id is not null))
);

alter table public.items add constraint items_household_id_id_key unique (household_id, id);
alter table public.photos add constraint photos_item_household_fkey
  foreign key (household_id, item_id) references public.items(household_id, id) on delete restrict;
create unique index photos_one_per_item on public.photos (item_id) where item_id is not null;
create index photos_household_state on public.photos (household_id, state, expires_at);

alter table public.photos enable row level security;
revoke all on public.photos from public, anon, authenticated, service_role;
grant select on public.photos to authenticated;

create policy photo_read on public.photos for select to authenticated using (
  household_id = (select private.current_household_id()) and (
    (uploader_user_id = (select auth.uid()) and state in ('RESERVED', 'READY'))
    or (
      state = 'ATTACHED' and exists (
        select 1 from public.items
        where items.id = photos.item_id
          and items.household_id = photos.household_id
          and items.deleted_at is null
      )
    )
  )
);

create function private.protect_photo_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id <> old.id
      or new.household_id <> old.household_id
      or new.uploader_user_id <> old.uploader_user_id
      or new.request_id <> old.request_id
      or new.object_key <> old.object_key
      or new.created_at <> old.created_at then
    raise exception using errcode = 'PT409', message = 'IMMUTABLE_PHOTO_IDENTITY';
  end if;
  return new;
end;
$$;
create trigger protect_photo_identity before update on public.photos
  for each row execute function private.protect_photo_identity();

create function private.photo_json(p_photo public.photos)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'photoId', p_photo.id,
    'objectKey', p_photo.object_key,
    'expiresAt', p_photo.expires_at
  );
$$;

create function public.reserve_photo(p_input jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  household uuid := private.lock_household();
  requester uuid := auth.uid();
  requested_household uuid;
  request uuid;
  photo public.photos;
  photo_id uuid;
begin
  perform private.validate_keys(
    p_input,
    array['householdId', 'requestId'],
    array['householdId', 'requestId']
  );
  requested_household := private.input_uuid(p_input->'householdId');
  request := private.input_uuid(p_input->'requestId');
  if requested_household <> household then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(requester::text || request::text, 2));
  select * into photo from public.photos
    where uploader_user_id = requester and request_id = request;
  if found then
    if photo.household_id <> household then
      raise sqlstate 'PT409' using message = 'CONFLICT';
    end if;
    return private.photo_json(photo);
  end if;

  photo_id := gen_random_uuid();
  insert into public.photos (
    id, household_id, uploader_user_id, request_id, object_key, expires_at
  ) values (
    photo_id,
    household,
    requester,
    request,
    household::text || '/' || requester::text || '/' || photo_id::text || '.jpg',
    clock_timestamp() + interval '24 hours'
  ) returning * into photo;
  return private.photo_json(photo);
end;
$$;

revoke all on function private.protect_photo_identity(), private.photo_json(public.photos)
  from public, anon, authenticated, service_role;
revoke all on function public.reserve_photo(jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.reserve_photo(jsonb) to authenticated;

create policy reserved_photo_upload on storage.objects for insert to authenticated with check (
  bucket_id = 'purchase-photos' and exists (
    select 1 from public.photos
    where photos.object_key = objects.name
      and photos.household_id = (select private.current_household_id())
      and photos.uploader_user_id = (select auth.uid())
      and photos.state = 'RESERVED'
      and photos.expires_at > statement_timestamp()
  )
);

create policy private_photo_download on storage.objects for select to authenticated using (
  bucket_id = 'purchase-photos'
  and storage.allow_any_operation(array['object.get_authenticated_info', 'object.get_authenticated'])
  and exists (
    select 1 from public.photos
    where photos.object_key = objects.name
      and photos.household_id = (select private.current_household_id())
      and (
        (photos.uploader_user_id = (select auth.uid()) and photos.state in ('RESERVED', 'READY'))
        or (
          photos.state = 'ATTACHED' and exists (
            select 1 from public.items
            where items.id = photos.item_id
              and items.household_id = photos.household_id
              and items.deleted_at is null
          )
        )
      )
  )
);

commit;
