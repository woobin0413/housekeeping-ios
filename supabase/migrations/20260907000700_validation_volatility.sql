begin;
-- Pure validators must not be declared VOLATILE when called by snapshot-consistent reads.
alter function private.validate_keys(jsonb,text[],text[]) immutable;
alter function private.input_uuid(jsonb) immutable;
alter function private.input_version(jsonb) immutable;
alter function private.item_fields(jsonb,boolean) stable;
commit;
