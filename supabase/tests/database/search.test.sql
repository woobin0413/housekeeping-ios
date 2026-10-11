begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();
insert into auth.users (id,email,email_confirmed_at) values
 ('81000000-0000-0000-0000-000000000001','search-a@example.invalid',now()),
 ('81000000-0000-0000-0000-000000000002','search-b@example.invalid',now()),
 ('81000000-0000-0000-0000-000000000003','search-out@example.invalid',now()),
 ('81000000-0000-0000-0000-000000000004','search-out-b@example.invalid',now());
select private.provision_household('82000000-0000-0000-0000-000000000001','Search home',
 '81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000002');
select private.provision_household('82000000-0000-0000-0000-000000000002','Other home',
 '81000000-0000-0000-0000-000000000003','81000000-0000-0000-0000-000000000004');
insert into public.items (id,household_id,name,description,brand,model,created_by,creation_requester_id,creation_request_id)
 select ('83000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
 '82000000-0000-0000-0000-000000000001', name, description, 'Acme', 'X100',
 '81000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000001',gen_random_uuid()
 from (values (1,'Kettle','Black steel'),(2,'Kettle stand','Wood'),(3,'Electric kettle','Black steel'),
 (4,'Dishwasher','White'),(5,'100% cotton','Blue'),(6,'Shelf_A',E'Path C:\\home'),(7,'Deleted kettle','Black')) as f(n,name,description);
update public.items set deleted_at = now() where name = 'Deleted kettle';
insert into public.items (household_id,name,created_by,creation_requester_id,creation_request_id)
 values ('82000000-0000-0000-0000-000000000002','Foreign kettle','81000000-0000-0000-0000-000000000003',
 '81000000-0000-0000-0000-000000000003',gen_random_uuid());
create temp table search_state (input jsonb);
insert into search_state values ('{"householdId":"82000000-0000-0000-0000-000000000001","query":"","limit":50,"offset":0}');
grant select on search_state to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000001',true);
select is((select jsonb_array_length(public.search_items(input)->'data') from search_state),6,'empty query returns active shared items');
select is((select public.search_items(input)->'nextOffset' from search_state),'null'::jsonb,'final page has no next offset');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"query":"KETTLE"}')->'data') x$$,
 array['Kettle','Kettle stand','Electric kettle'],'case-insensitive exact then prefix then other ranking');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"query":"black kettle"}')->'data') x$$,
 array['Kettle','Electric kettle'],'tokens match across fields');
select is((select public.search_items(input || '{"query":"black kettle"}') from search_state),
 (select public.search_items(input || '{"query":"kettle black"}') from search_state),'token order does not affect matching');
select is((select jsonb_array_length(public.search_items(input || '{"query":"acme x100"}')->'data') from search_state),6,'brand and model searched');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"query":"dish"}')->'data') x$$,
 array['Dishwasher'],'substring token matches');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"query":"%"}')->'data') x$$,
 array['100% cotton'],'percent is literal');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"query":"_"}')->'data') x$$,
 array['Shelf_A'],'underscore is literal');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || jsonb_build_object('query',chr(92)))->'data') x$$,
 array['Shelf_A'],'backslash is literal');
select is((select jsonb_array_length(public.search_items(input || '{"query":"missing"}')->'data') from search_state),0,'no matches returns empty data');
select is((select public.search_items(input || '{"limit":2}')->>'nextOffset' from search_state),'2','lookahead provides next offset');
select results_eq($$select x->>'name' from search_state, jsonb_array_elements(public.search_items(input || '{"limit":2,"offset":2}')->'data') x$$,
 array['Electric kettle','Dishwasher'],'stable ID tie-break supports second page');
select is((select public.search_items(input || '{"limit":2,"offset":4}')->'nextOffset' from search_state),'null'::jsonb,'exact final page has no phantom page');
select throws_ok($$select public.search_items(input || '{"limit":0}') from search_state$$,'PT422','VALIDATION_ERROR','zero limit rejected');
select throws_ok($$select public.search_items(input || '{"limit":101}') from search_state$$,'PT422','VALIDATION_ERROR','overlarge limit rejected');
select throws_ok($$select public.search_items(input || '{"offset":-1}') from search_state$$,'PT422','VALIDATION_ERROR','negative offset rejected');
select throws_ok($$select public.search_items(input || '{"offset":10001}') from search_state$$,'PT422','VALIDATION_ERROR','overlarge offset rejected');
select throws_ok($$select public.search_items(input || '{"limit":1.5}') from search_state$$,'PT422','VALIDATION_ERROR','fractional page size rejected');
select throws_ok($$select public.search_items(input || jsonb_build_object('query',repeat('a',201))) from search_state$$,'PT422','VALIDATION_ERROR','overlong query rejected');
select throws_ok($$select public.search_items(input || '{"query":"a b c d e f g h i"}') from search_state$$,'PT422','VALIDATION_ERROR','more than eight tokens rejected');
select throws_ok($$select public.search_items(input || '{"query":null}') from search_state$$,'PT422','VALIDATION_ERROR','null query rejected');
select throws_ok($$select public.search_items(input || '{"extra":true}') from search_state$$,'PT422','VALIDATION_ERROR','unknown search keys rejected');
select throws_ok($$select public.search_items(input || '{"householdId":"82000000-0000-0000-0000-000000000002"}') from search_state$$,'PT404','NOT_FOUND','foreign search denied');
select is(public.get_item('{"id":"83000000-0000-0000-0000-000000000001"}')->>'name','Kettle','get returns camelCase item');
select throws_ok($$select public.get_item('{"id":"83000000-0000-0000-0000-000000000007"}')$$,'PT404','NOT_FOUND','get hides tombstone');
select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000002',true);
select is((select jsonb_array_length(public.search_items(input)->'data') from search_state),6,'both spouses search same inventory');
select set_config('request.jwt.claim.sub','81000000-0000-0000-0000-000000000003',true);
select throws_ok($$select public.get_item('{"id":"83000000-0000-0000-0000-000000000001"}')$$,'PT404','NOT_FOUND','foreign get denied');
select throws_ok($$select public.search_items(input) from search_state$$,'PT404','NOT_FOUND','other household member cannot search ours');
reset role;
set local role anon;
select throws_ok($$select public.search_items('{}')$$,'42501',null,'anonymous search denied');
select throws_ok($$select public.get_item('{}')$$,'42501',null,'anonymous get denied');
reset role;
select * from finish();
rollback;
