begin;
-- Normalize all PostgreSQL whitespace at the boundary, including tabs and newlines.
create function private.trim_item_name(p_name text)
returns text language sql immutable set search_path = '' as $$
  select regexp_replace(p_name,'^[[:space:]]+|[[:space:]]+$','','g');
$$;
revoke all on function private.trim_item_name(text) from public, anon, authenticated, service_role;
create or replace function private.item_fields(p_fields jsonb, p_create boolean)
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
  return result;
exception when invalid_datetime_format or datetime_field_overflow then
  raise sqlstate 'PT422' using message = 'VALIDATION_ERROR';
end;
$$;
-- Existing names came from the earlier schema-only phase; fail safely if whitespace-only.
update public.items set name = private.trim_item_name(name);
alter table public.items add constraint items_name_edges_trimmed
  check (name !~ '^[[:space:]]|[[:space:]]$');
-- Existing retry fingerprints must use the same canonicalization as new calls.
update private.item_creation_requests set input = jsonb_set(input,'{name}',to_jsonb(private.trim_item_name(input->>'name')));
commit;
