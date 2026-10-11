begin;

create table public.items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete restrict,
  name text not null check (
    name = btrim(name) and char_length(name) between 1 and 200 and name !~ '^[[:space:]]*$'
  ),
  description text check (char_length(description) <= 2000),
  brand text check (char_length(brand) <= 100),
  model text check (char_length(model) <= 100),
  purchased_on date,
  -- Replaced with validated attachment constraints when the media lifecycle is implemented.
  photo_id uuid constraint items_photos_not_implemented check (photo_id is null),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version bigint not null default 1 check (version > 0),
  deleted_at timestamptz,
  creation_request_id uuid not null,
  unique (household_id, created_by, creation_request_id)
);

create index items_household_recent on public.items (household_id, updated_at desc, id)
  where deleted_at is null;
create index items_creator on public.items (created_by) where created_by is not null;

alter table public.items enable row level security;
revoke all on public.items from public, anon, authenticated, service_role;
grant select on public.items to authenticated;

-- Shared inventory is household-owned, not restricted to the original creator.
create policy item_read on public.items for select to authenticated
  using (deleted_at is null and household_id = (select private.current_household_id()));

-- Mutating privileges remain closed until the versioned write RPCs are installed.
commit;
