begin;
create extension if not exists pg_trgm with schema extensions;
alter table public.items add column search_text text generated always as (
  lower(name || ' ' || coalesce(description,'') || ' ' || coalesce(brand,'') || ' ' || coalesce(model,''))
) stored;
create index items_search_trgm on public.items using gin (search_text extensions.gin_trgm_ops)
  where deleted_at is null;

create function public.get_item(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  household uuid := private.current_household_id();
  item_id uuid;
  item public.items;
begin
  if auth.uid() is null then raise sqlstate 'PT401' using message = 'UNAUTHENTICATED'; end if;
  perform private.validate_keys(p_input,array['id'],array['id']);
  item_id := private.input_uuid(p_input->'id');
  select * into item from public.items where id = item_id and household_id = household and deleted_at is null;
  if not found then raise sqlstate 'PT404' using message = 'NOT_FOUND'; end if;
  return private.item_json(item);
end;
$$;

create function public.search_items(p_input jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  household uuid := private.current_household_id();
  query text;
  tokens text[];
  first_pattern text;
  page_limit numeric := 50;
  page_offset numeric := 0;
  result jsonb;
begin
  if auth.uid() is null then raise sqlstate 'PT401' using message = 'UNAUTHENTICATED'; end if;
  perform private.validate_keys(p_input,array['householdId','query','limit','offset'],array['householdId','query']);
  if household is null or private.input_uuid(p_input->'householdId') <> household then
    raise sqlstate 'PT404' using message = 'NOT_FOUND';
  end if;
  if jsonb_typeof(p_input->'query') <> 'string' or char_length(p_input->>'query') > 200 then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  query := lower(btrim(regexp_replace(p_input->>'query','[[:space:]]+',' ','g')));
  tokens := case when query = '' then array[]::text[] else string_to_array(query,' ') end;
  if cardinality(tokens) > 8 then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
  if p_input ? 'limit' then
    if jsonb_typeof(p_input->'limit') <> 'number' then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
    page_limit := (p_input->>'limit')::numeric;
  end if;
  if p_input ? 'offset' then
    if jsonb_typeof(p_input->'offset') <> 'number' then raise sqlstate 'PT422' using message = 'VALIDATION_ERROR'; end if;
    page_offset := (p_input->>'offset')::numeric;
  end if;
  if page_limit not between 1 and 100 or trunc(page_limit) <> page_limit
    or page_offset not between 0 and 10000 or trunc(page_offset) <> page_offset then
    raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
  end if;
  -- Escape LIKE metacharacters for the indexed first token. Remaining tokens use literal strpos.
  first_pattern := '%' || replace(replace(replace(tokens[1],chr(92),chr(92)||chr(92)),
    '%',chr(92)||'%'),'_',chr(92)||'_') || '%';
  with matches as (
    select i, case when query = '' then 0 when lower(i.name) = query then 0
      when starts_with(lower(i.name),query) then 1 else 2 end as rank
    from public.items i
    where i.household_id = household and i.deleted_at is null
      and (query = '' or (i.search_text like first_pattern escape E'\\'
        and not exists (select 1 from unnest(tokens) t where strpos(i.search_text,t) = 0)))
    order by rank, i.updated_at desc, i.id
    limit (page_limit + 1)::int offset page_offset::int
  ), numbered as (
    select i, row_number() over (order by rank,(i).updated_at desc,(i).id) as n from matches
  )
  select jsonb_build_object(
    'data',coalesce(jsonb_agg(private.item_json(i) order by n) filter (where n <= page_limit),'[]'::jsonb),
    'nextOffset',case when count(*) > page_limit and page_offset + page_limit <= 10000
      then page_offset + page_limit else null end)
    into result from numbered;
  return result;
end;
$$;
revoke all on function public.get_item(jsonb), public.search_items(jsonb) from public, anon, authenticated, service_role;
grant execute on function public.get_item(jsonb), public.search_items(jsonb) to authenticated;
commit;
