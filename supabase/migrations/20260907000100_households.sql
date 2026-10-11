begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;
grant usage on schema private to authenticated, service_role;

create table public.households (
  id uuid primary key,
  name text not null check (name = btrim(name) and char_length(name) between 1 and 100),
  created_at timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  slot smallint not null check (slot in (1, 2)),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id),
  unique (user_id),
  unique (household_id, slot)
);

alter table public.households enable row level security;
alter table public.household_members enable row level security;
revoke all on public.households, public.household_members from public, anon, authenticated, service_role;
grant select on public.households, public.household_members to authenticated;

-- A definer lookup avoids recursive membership RLS. It accepts no caller-supplied user ID.
create function private.current_household_id()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select household_id from public.household_members where user_id = (select auth.uid());
$$;
revoke all on function private.current_household_id() from public, anon, authenticated, service_role;
grant execute on function private.current_household_id() to authenticated;

create policy household_read on public.households for select to authenticated
  using (id = (select private.current_household_id()));
create policy membership_read on public.household_members for select to authenticated
  using (household_id = (select private.current_household_id()));

create function public.get_household()
returns jsonb
language plpgsql stable security invoker
set search_path = ''
as $$
declare
  result jsonb;
begin
  select jsonb_build_object('householdId', id, 'name', name)
    into result from public.households;
  if result is null then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  return result;
end;
$$;
revoke all on function public.get_household() from public, anon, authenticated, service_role;
grant execute on function public.get_household() to authenticated;

-- Operator-only operation. Private is not an exposed Data API schema.
create function private.provision_household(
  p_household_id uuid, p_name text, p_user_a uuid, p_user_b uuid
)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  normalized_name text := btrim(p_name);
  existing_name text;
  existing_users uuid[];
  requested_users uuid[];
begin
  if p_household_id is null or p_name is null
      or char_length(normalized_name) not between 1 and 100
      or p_user_a is null or p_user_b is null or p_user_a = p_user_b then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  requested_users := array[least(p_user_a, p_user_b), greatest(p_user_a, p_user_b)];

  -- Serialize retries for this household, then lock identities in a consistent order.
  -- Unique constraints also protect direct privileged inserts and competing assignments.
  perform pg_advisory_xact_lock(hashtextextended(p_household_id::text, 0));
  perform id from auth.users where id = any(requested_users) order by id for update;
  if (select count(*) from auth.users
      where id = any(requested_users) and email_confirmed_at is not null) <> 2 then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;

  select name into existing_name from public.households where id = p_household_id for update;
  if found then
    select array_agg(user_id order by user_id) into existing_users
      from public.household_members where household_id = p_household_id;
    if existing_name = normalized_name and existing_users = requested_users then
      return p_household_id;
    end if;
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;

  if exists (select 1 from public.household_members where user_id = any(requested_users)) then
    raise sqlstate 'PT409' using message = 'CONFLICT';
  end if;
  insert into public.households (id, name) values (p_household_id, normalized_name);
  insert into public.household_members (household_id, user_id, slot) values
    (p_household_id, requested_users[1], 1), (p_household_id, requested_users[2], 2);
  return p_household_id;
end;
$$;
revoke all on function private.provision_household(uuid, text, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.provision_household(uuid, text, uuid, uuid) to service_role;

commit;
