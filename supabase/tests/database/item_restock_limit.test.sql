begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

select has_column('public','items','restock_limit','items has a restock limit');
select col_type_is('public','items','restock_limit','integer','restock limit is an integer');
select col_not_null('public','items','restock_limit','restock limit is required');
select col_default_is('public','items','restock_limit','1','restock limit defaults to one');

insert into auth.users (id,email,email_confirmed_at) values
 ('91000000-0000-0000-0000-000000000001','limit-a@example.invalid',now()),
 ('91000000-0000-0000-0000-000000000002','limit-b@example.invalid',now());
select private.provision_household(
 '92000000-0000-0000-0000-000000000001','Restock home',
 '91000000-0000-0000-0000-000000000001','91000000-0000-0000-0000-000000000002');
create temp table restock_state (input jsonb, item jsonb);
insert into restock_state (input) values
 ('{"householdId":"92000000-0000-0000-0000-000000000001","requestId":"93000000-0000-0000-0000-000000000001","name":"Dish soap","quantity":4}');
grant all on restock_state to authenticated;

set local role authenticated;
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
update restock_state set item = public.create_item(input);
select is((select item->>'restockLimit' from restock_state),'1','omitted restock limit defaults to one');
select is((select public.create_item(input || '{"restockLimit":1}')->>'id' from restock_state),
 (select item->>'id' from restock_state),'explicit default replays omitted restock limit');
select throws_ok($$select public.create_item(input || '{"restockLimit":2}') from restock_state$$,
 'PT409','CONFLICT','changed restock limit cannot reuse creation request');
select throws_ok(format('select public.create_item(input || %L::jsonb) from restock_state',invalid::text),
 'PT422','VALIDATION_ERROR','reject invalid create restock limit ' || invalid::text)
 from unnest(array[
  '{"restockLimit":-1}','{"restockLimit":1.5}','{"restockLimit":null}',
  '{"restockLimit":"2"}','{"restockLimit":true}','{"restockLimit":2147483648}'
 ]::jsonb[]) invalid;

select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000002',true);
update restock_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',1,'fields','{"restockLimit":4}'::jsonb));
select is((select item->>'restockLimit' from restock_state),'4','spouse can update the restock limit');
select is((select item->>'version' from restock_state),'2','restock limit update increments version');
select is((select public.get_item(jsonb_build_object('id',item->'id'))->>'restockLimit' from restock_state),
 '4','detail reload returns restock limit');
select is(public.search_items(
 '{"householdId":"92000000-0000-0000-0000-000000000001","query":"Dish"}')
 #>> '{data,0,restockLimit}','4','search returns restock limit');
select throws_ok($$select public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',1,'fields','{"restockLimit":7}'::jsonb)) from restock_state$$,
 'PT409','CONFLICT','stale restock limit edit cannot overwrite another spouse');
select throws_ok(format('select public.update_item(jsonb_build_object(''id'',item->''id'',
 ''expectedVersion'',2,''fields'',%L::jsonb)) from restock_state',invalid::text),
 'PT422','VALIDATION_ERROR','reject invalid update restock limit ' || invalid::text)
 from unnest(array[
  '{"restockLimit":-1}','{"restockLimit":1.5}','{"restockLimit":null}',
  '{"restockLimit":"2"}','{"restockLimit":false}','{"restockLimit":2147483648}'
 ]::jsonb[]) invalid;
update restock_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',2,'fields','{"name":"Hand soap"}'::jsonb));
select is((select item->>'restockLimit' from restock_state),'4','unrelated edit preserves restock limit');
update restock_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',3,'fields','{"restockLimit":2147483647.0}'::jsonb));
select is((select item->>'restockLimit' from restock_state),'2147483647','maximum whole limit is accepted');

reset role;
select throws_ok(
 $$update public.items set restock_limit = -1
   where household_id = '92000000-0000-0000-0000-000000000001'$$,
 '23514',null,'database constraint rejects a negative restock limit');
select * from finish();
rollback;
