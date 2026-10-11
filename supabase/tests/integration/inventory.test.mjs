import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { localHarness, localSQL, uuid } from './local-harness.mjs';

test('local email/password and shared-inventory HTTP boundary',async t=>{
  const h=localHarness();
  t.after(()=>h.cleanup());
  const a=await h.createUser();
  const b=await h.createUser();
  const outsider=await h.createUser();
  const outsiderSpouse=await h.createUser();
  const unverified=await h.createUser(false);
  const household=h.provision(a,b);
  h.provision(outsider,outsiderSpouse);
  const sessions=[];
  for(const user of [a,b,outsider]) {
    const response=await h.signIn(user);
    assert.equal(response.status,200,'Verified synthetic user can sign in');
    assert(typeof response.data.access_token==='string','Access token issued');
    sessions.push(response.data);
  }
  const [sa,sb,so]=sessions;
  await t.test('harness refuses nonlocal targets before sending credentials',async()=>{
    await assert.rejects(()=>h.request('https://example.com/rest/v1/items'),/Refuse nonlocal request/);
    await assert.rejects(()=>h.request('http://127.0.0.1:54321/rest/v1/items'),/Refuse nonlocal request/);
  });
  await t.test('public signup is closed',async()=>{
    const response=await h.request('/auth/v1/signup',{method:'POST',body:{email:h.newEmail(),password:a.password}});
    assert.equal(response.status,422);
    assert.equal(response.data.error_code,'signup_disabled');
  });
  await t.test('anonymous signup is closed',async()=>{
    const response=await h.request('/auth/v1/signup',{method:'POST',body:{}});
    // Register an unexpectedly created anonymous identity before the assertion fails.
    const createdId=response.data?.user?.id ?? response.data?.id;
    if(response.status>=200 && response.status<300 && createdId) h.trackCreatedUser(createdId);
    assert.equal(response.status,422);
  });
  await t.test('wrong password and unverified email cannot sign in',async()=>{
    assert.equal((await h.signIn(a,'Definitely-wrong-password')).status,400);
    assert.equal((await h.signIn(unverified)).status,400);
  });
  await t.test('each spouse resolves the same household',async()=>{
    for(const session of [sa,sb]) {
      const result=await h.rpc('get_household',null,session.access_token);
      assert.equal(result.status,200);
      assert.equal(result.data.householdId,household);
    }
  });
  const input={householdId:household,requestId:randomUUID(),name:'HTTP kettle',description:'Black steel',quantity:3,restockLimit:2};
  const created=await h.rpc('create_item',input,sa.access_token);
  assert.equal(created.status,200);
  const item=created.data;
  assert.equal(item.quantity,3);
  assert.equal(item.restockLimit,2);
  uuid(item.id);
  await t.test('spouse reads the item through RPC and the table API',async()=>{
    const result=await h.rpc('get_item',{id:item.id},sb.access_token);
    assert.equal(result.status,200);
    assert.equal(result.data.name,input.name);
    assert.equal(result.data.quantity,3);
    assert.equal(result.data.restockLimit,2);
    const rows=await h.request('/rest/v1/items?select=id,name',{token:sb.access_token});
    assert.equal(rows.status,200);
    assert.equal(rows.data.length,1);
    assert.equal(rows.data[0].id,item.id);
  });
  await t.test('shared search returns confirmed fields',async()=>{
    const result=await h.rpc('search_items',{householdId:household,query:'BLACK kettle'},sb.access_token);
    assert.equal(result.status,200);
    assert.equal(result.data.data[0].id,item.id);
    assert.equal(result.data.data[0].quantity,3);
    assert.equal(result.data.data[0].restockLimit,2);
  });
  await t.test('another household sees no rows and cannot access a known ID',async()=>{
    assert.equal((await h.request('/rest/v1/items?select=id',{token:so.access_token})).data.length,0);
    assert.equal((await h.rpc('get_item',{id:item.id},so.access_token)).status,404);
    assert.equal((await h.rpc('create_item',input,so.access_token)).status,404);
    assert.equal((await h.rpc('search_items',{householdId:household,query:''},so.access_token)).status,404);
  });
  await t.test('anonymous and invalid-token reads are denied',async()=>{
    assert.equal((await h.request('/rest/v1/items?select=id')).status,401);
    assert.equal((await h.rpc('get_item',{id:item.id})).status,401);
    assert.equal((await h.request('/rest/v1/items?select=id',{token:'invalid.token.value'})).status,401);
  });
  await t.test('direct item and membership mutation is denied',async()=>{
    assert.equal((await h.request('/rest/v1/items',{method:'POST',body:{name:'Bypass'},token:sa.access_token})).status,403);
    assert.equal((await h.request('/rest/v1/household_members',{method:'POST',body:{household_id:household,user_id:outsider.id,slot:2},token:sa.access_token})).status,403);
  });
  await t.test('private provisioning is not exposed as a public RPC',async()=>{
    assert.equal((await h.rpc('provision_household',{},sa.access_token)).status,404);
  });
  await t.test('client metadata cannot grant household access',async()=>{
    assert.equal((await h.request('/auth/v1/user',{method:'PUT',body:{data:{household_id:household}},token:so.access_token})).status,200);
    assert.equal((await h.rpc('get_item',{id:item.id},so.access_token)).status,404);
  });
  await t.test('identical retries succeed and changed retries conflict',async()=>{
    const retry=await h.rpc('create_item',input,sa.access_token);
    assert.equal(retry.status,200);
    assert.equal(retry.data.id,item.id);
    const conflict=await h.rpc('create_item',{...input,name:'Different'},sa.access_token);
    assert.equal(conflict.status,409);
    assert.equal(conflict.data.message,'CONFLICT');
  });
  await t.test('spouse edits, stale version fails, invalid fields return 422',async()=>{
    const edit=await h.rpc('update_item',{id:item.id,expectedVersion:1,fields:{name:'Shared edit',quantity:0,restockLimit:4}},sb.access_token);
    assert.equal(edit.status,200);
    assert.equal(edit.data.version,2);
    assert.equal(edit.data.quantity,0);
    assert.equal(edit.data.restockLimit,4);
    const latest=await h.rpc('get_item',{id:item.id},sa.access_token);
    assert.equal(latest.data.quantity,0);
    assert.equal(latest.data.restockLimit,4);
    assert.equal((await h.rpc('update_item',{id:item.id,expectedVersion:1,fields:{name:'Stale'}},sa.access_token)).status,409);
    assert.equal((await h.rpc('create_item',{...input,createdBy:b.id},sa.access_token)).status,422);
  });
  await t.test('deletion retries succeed and old creates cannot resurrect',async()=>{
    for(let i=0;i<2;i++) assert.equal((await h.rpc('delete_item',{id:item.id,expectedVersion:2},sa.access_token)).status,204);
    assert.equal((await h.rpc('get_item',{id:item.id},sb.access_token)).status,404);
    assert.equal((await h.rpc('create_item',input,sa.access_token)).status,409);
  });
  await t.test('revocation blocks an already-issued access token',async()=>{
    localSQL(`delete from public.household_members where user_id='${uuid(b.id)}';`);
    assert.equal((await h.rpc('get_household',null,sb.access_token)).status,404);
    assert.equal((await h.rpc('create_item',{...input,requestId:randomUUID()},sb.access_token)).status,404);
    assert.equal((await h.request('/rest/v1/items?select=id',{token:sb.access_token})).data.length,0);
  });
  await t.test('session refresh works; sign-out revokes refresh credentials',async()=>{
    const refreshed=await h.request('/auth/v1/token?grant_type=refresh_token',{method:'POST',body:{refresh_token:sa.refresh_token}});
    assert.equal(refreshed.status,200);
    assert(typeof refreshed.data.access_token==='string');
    assert.equal((await h.request('/auth/v1/logout',{method:'POST',token:refreshed.data.access_token})).status,204);
    assert.equal((await h.request('/auth/v1/token?grant_type=refresh_token',{method:'POST',body:{refresh_token:refreshed.data.refresh_token}})).status,400);
  });
});
