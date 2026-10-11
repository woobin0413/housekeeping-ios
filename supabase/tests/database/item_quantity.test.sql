begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();
insert into auth.users (id,email,email_confirmed_at) values
 ('81000000-0000-0000-0000-000000000001','quantity-a@example.invalid',now()),
 ('81000000-0000-0000-0000-000000000002','quantity-b@example.invalid',now());
select private.provision_household('82000000-0000-0000-0000-000000000001','Quantity home',
 '81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000002');
create temp table quantity_state (input jsonb, item jsonb);
insert into quantity_state (input) values
 ('{"householdId":"82000000-0000-0000-0000-000000000001","requestId":"83000000-0000-0000-0000-000000000001","name":"Soap"}');
grant all on quantity_state to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000001',true);
update quantity_state set item = public.create_item(input);
select is((select item->>'quantity' from quantity_state),'1','omitted quantity defaults to one');
select is((select public.create_item(input || '{"quantity":1}')->>'id' from quantity_state),
 (select item->>'id' from quantity_state),'explicit default replays omitted quantity');
select throws_ok($$select public.create_item(input || '{"quantity":0}') from quantity_state$$,
 'PT409','CONFLICT','changed quantity cannot reuse creation request');
select throws_ok(format('select public.create_item(input || %L::jsonb) from quantity_state',invalid::text),
 'PT422','VALIDATION_ERROR','reject invalid create quantity ' || invalid::text)
 from unnest(array['{"quantity":-1}','{"quantity":1.5}','{"quantity":null}',
 '{"quantity":"2"}','{"quantity":true}','{"quantity":2147483648}']::jsonb[]) invalid;

select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000002',true);
update quantity_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',1,'fields','{"quantity":0}'::jsonb));
select is((select item->>'quantity' from quantity_state),'0','spouse can mark item out of stock');
select is((select item->>'version' from quantity_state),'2','quantity update increments version');
select is((select public.get_item(jsonb_build_object('id',item->'id'))->>'quantity' from quantity_state),
 '0','detail reload returns zero');
select is(public.search_items('{"householdId":"82000000-0000-0000-0000-000000000001","query":"Soap"}')
 #>> '{data,0,quantity}','0','search returns quantity');
select throws_ok($$select public.update_item(jsonb_build_object('id',item->'id',
 'expectedVersion',1,'fields','{"quantity":7}'::jsonb)) from quantity_state$$,
 'PT409','CONFLICT','stale quantity edit cannot overwrite another spouse');
select throws_ok(format('select public.update_item(jsonb_build_object(''id'',item->''id'',
 ''expectedVersion'',2,''fields'',%L::jsonb)) from quantity_state',invalid::text),
 'PT422','VALIDATION_ERROR','reject invalid update quantity ' || invalid::text)
 from unnest(array['{"quantity":-1}','{"quantity":1.5}','{"quantity":null}',
 '{"quantity":"2"}','{"quantity":false}','{"quantity":2147483648}']::jsonb[]) invalid;
update quantity_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',2,'fields','{"name":"Hand soap"}'::jsonb));
select is((select item->>'quantity' from quantity_state),'0','unrelated edit preserves zero');
update quantity_state set item = public.update_item(jsonb_build_object(
 'id',item->'id','expectedVersion',3,'fields','{"quantity":12.0}'::jsonb));
select is((select item->>'quantity' from quantity_state),'12','whole numeric quantity can be restocked');
select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000001',true);
select is((select public.create_item(input)->>'quantity' from quantity_state),'12',
 'original create retry returns current stock without resetting it');
select is((select public.create_item(input || jsonb_build_object('requestId',gen_random_uuid(),'quantity',0))->>'quantity'
 from quantity_state),'0','new item can start out of stock');
select is((select public.create_item(input || jsonb_build_object('requestId',gen_random_uuid(),'quantity',2147483647))->>'quantity'
 from quantity_state),'2147483647','maximum quantity is accepted');
reset role;
select * from finish();
rollback;
