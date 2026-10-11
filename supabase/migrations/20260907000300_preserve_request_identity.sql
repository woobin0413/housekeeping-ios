begin;

-- Attribution can be cleared on account removal; the original request identity cannot.
-- Deliberately no auth.users FK: the retry key must outlive that identity.
alter table public.items add column creation_requester_id uuid;
update public.items set creation_requester_id = created_by;
-- Fail rather than guess if a preexisting unattributed row cannot be backfilled.
alter table public.items alter column creation_requester_id set not null;
alter table public.items drop constraint items_household_id_created_by_creation_request_id_key;
alter table public.items add constraint items_creation_request_key
  unique (household_id, creation_requester_id, creation_request_id);
alter table public.items add constraint items_creator_matches_requester
  check (created_by is null or created_by = creation_requester_id);

commit;
