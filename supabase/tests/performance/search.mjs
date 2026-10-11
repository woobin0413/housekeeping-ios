import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { localHarness, localSQL, uuid } from '../integration/local-harness.mjs';
import { verifyLocalStack, database } from '../../../scripts/local-safety.mjs';

// Controlled local benchmark, never a claim about physical-iPhone/cloud latency.
// Restart clears PostgreSQL shared buffers, not Docker VM/host filesystem caches.
const h=localHarness();
const percentile=(values,p)=>[...values].sort((a,b)=>a-b)[Math.ceil(values.length*p)-1];
const stats=values=>({samples:values.length,p50Ms:percentile(values,.5),p95Ms:percentile(values,.95),maxMs:Math.max(...values)});
try {
  const a=await h.createUser();
  const b=await h.createUser();
  const household=h.provision(a,b);
  const session=await h.signIn(a);
  assert.equal(session.status,200);
  localSQL(`insert into public.items (household_id,name,description,brand,model,created_by,creation_requester_id,creation_request_id)
    select '${uuid(household)}',
      (array['Electric kettle','Dishwasher','Dining chair','Cotton towel','Garden lamp','Shelf_A','100% cotton','Vacuum cleaner'])[1+n%8] || ' ' || n,
      (array['Black stainless steel kitchen','White living room furniture','Blue cotton bedroom','Outdoor home tools'])[1+n%4],
      (array['Acme','House brand','HomeWorks'])[1+n%3], 'Model-' || n%100,
      '${uuid(a.id)}','${a.id}',gen_random_uuid() from generate_series(1,10000) n;
    analyze public.items;`);
  const terms=['','kettle','BLACK kettle','dish','cotton','%','_','not-a-real-product','acme model-7','white chair'];
  const queries=Array.from({length:100},(_,n)=>({householdId:household,query:terms[n%terms.length],
    limit:n%4===0 ? 100 : 50,offset:n%5===0 ? 100 : 0}));
  const measuredSQL=()=>{
    // All values are generated IDs or fixed benchmark text, escaped as SQL literals.
    const queryJSON=JSON.stringify(queries).replaceAll("'","''");
    const result=localSQL(`begin;
      set local role authenticated;
      do $bench$ begin perform set_config('request.jwt.claim.sub','${a.id}',true); end $bench$;
      create temp table measurements (milliseconds double precision);
      do $bench$
      declare q jsonb; started timestamptz; response jsonb;
      begin
        for q in select value from jsonb_array_elements('${queryJSON}'::jsonb) loop
          started := clock_timestamp();
          response := public.search_items(q);
          insert into measurements values (extract(epoch from clock_timestamp()-started)*1000);
          if jsonb_typeof(response->'data') <> 'array' then raise exception 'Invalid search result'; end if;
        end loop;
      end $bench$;
      select json_agg(milliseconds) from measurements;
      rollback;`);
    return JSON.parse(result);
  };
  verifyLocalStack();
  execFileSync('docker',['restart',database],{stdio:'ignore',timeout:30000});
  let healthy=false;
  for(let attempt=0;attempt<40;attempt++) {
    const state=execFileSync('docker',['inspect',database,'--format','{{.State.Health.Status}}'],{encoding:'utf8'}).trim();
    if(state==='healthy') { healthy=true;break; }
    await delay(500);
  }
  assert(healthy,'Local benchmark database did not recover');
  const firstPass=measuredSQL();
  const warm=measuredSQL();
  const http=[];
  for(const query of queries) {
    const start=performance.now();
    const result=await h.rpc('search_items',query,session.data.access_token);
    http.push(performance.now()-start);
    assert.equal(result.status,200);
    assert(Array.isArray(result.data.data));
  }
  console.log(JSON.stringify({rows:10000,queryCount:100,
    coldMethod:'Database restarted once before first pass; later queries progressively warm caches. Host/VM caches not cleared.',
    firstSearchAfterRestartMs:firstPass[0],restartFirstPass:stats(firstPass),warmDatabase:stats(warm),warmLocalHTTP:stats(http)},null,2));
  assert(percentile(warm,.95)<=500,'Warm database p95 exceeds 500ms');
  assert(percentile(http,.95)<=1500,'Local HTTP p95 exceeds 1500ms');
} finally {
  await h.cleanup();
}
