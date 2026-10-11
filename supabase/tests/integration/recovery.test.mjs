import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createHash, randomBytes } from 'node:crypto';
import { localHarness, localSQL, uuid } from './local-harness.mjs';

const redirect='housekeeping://auth/recovery';
const mailBase='http://127.0.0.1:55324';

test('local password recovery: PKCE email, replay, wrong verifier, setup, isolation', async t => {
  const h=localHarness();
  const messages=new Set();
  const recipients=[];
  const emailPattern=/^hk-test-[0-9a-f-]{36}@example\.invalid$/;
  async function mail(path, options={}) {
    const url=new URL(path,mailBase);
    assert.equal(url.origin,mailBase);
    const response=await fetch(url,{...options,redirect:'error',signal:AbortSignal.timeout(10000)});
    assert(response.ok,'Local mail capture request failed');
    const body=await response.text();
    return options.method==='DELETE' || !body ? null : JSON.parse(body);
  }
  async function inbox(email) {
    assert.match(email,emailPattern);
    const result=await mail(`/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`);
    for(const message of result.messages) {
      assert.match(message.ID,/^[a-zA-Z0-9-]+$/);
      messages.add(message.ID);
    }
    return result.messages;
  }
  async function requestRecovery(user) {
    recipients.push(user.email);
    const verifier=randomBytes(48).toString('base64url');
    const challenge=createHash('sha256').update(verifier).digest('base64url');
    const result=await h.request(`/auth/v1/recover?redirect_to=${encodeURIComponent(redirect)}`,{
      method:'POST',body:{email:user.email,code_challenge:challenge,code_challenge_method:'s256'}
    });
    assert.equal(result.status,200,'Recovery request rejected');
    let found=[];
    for(let attempt=0;attempt<30;attempt++) {
      found=await inbox(user.email);
      if(found.length) break;
      await new Promise(resolve=>setTimeout(resolve,100));
    }
    assert(found.length>0,'Synthetic recovery email not captured');
    const message=await mail(`/api/v1/message/${found[0].ID}`);
    const content=message.HTML || message.Text;
    assert(typeof content==='string','Email body missing');
    const match=content.match(/https?:\/\/[^\s"<>]+\/auth\/v1\/verify\?[^\s"<>]+/);
    assert(match,'Email verification link missing');
    const url=new URL(match[0].replaceAll('&amp;','&'));
    assert.equal(url.origin,'http://127.0.0.1:55321','Refuse nonlocal email link');
    assert.equal(url.searchParams.get('type'),'recovery');
    assert.equal(url.searchParams.get('redirect_to'),redirect);
    const response=await fetch(url,{redirect:'manual',signal:AbortSignal.timeout(10000)});
    assert.equal(response.status,303,'Expected recovery redirect');
    const callback=new URL(response.headers.get('location'));
    assert.equal(callback.protocol,'housekeeping:');
    assert.equal(callback.host,'auth');
    assert.equal(callback.pathname,'/recovery');
    const code=callback.searchParams.get('code');
    assert(code,'Recovery code missing');
    return {code,verifier};
  }
  const exchange=({code,verifier})=>h.request('/auth/v1/token?grant_type=pkce',{
    method:'POST',body:{auth_code:code,code_verifier:verifier}
  });
  try {
    const a=await h.createUser();
    const b=await h.createUser();
    const unverified=await h.createUser(false);
    const home=h.provision(a,b);
    await t.test('reset request is neutral for an absent account, with no signup',async()=>{
      const email=h.newEmail();
      const result=await h.request('/auth/v1/recover',{method:'POST',body:{email}});
      assert.equal(result.status,200);
      assert.equal((await inbox(email)).length,0);
      const signup=await h.request('/auth/v1/signup',{method:'POST',body:{email,password:randomBytes(24).toString('base64url')}});
      assert.equal(signup.status,422);
    });
    await t.test('captured recovery link changes only the intended password',async()=>{
      const grant=await requestRecovery(a);
      const response=await exchange(grant);
      assert.equal(response.status,200,'PKCE exchange failed');
      assert(response.data.user.id===a.id,'Wrong recovery identity');
      const password=randomBytes(24).toString('base64url');
      const update=await h.request('/auth/v1/user',{method:'PUT',token:response.data.access_token,body:{password}});
      assert.equal(update.status,200,'Password change failed');
      assert.equal((await h.signIn(a)).status,400,'Old password must stop working');
      const login=await h.signIn(a,password);
      assert.equal(login.status,200);
      assert.equal((await h.rpc('get_household',{},login.data.access_token)).data.householdId,home);
      assert.equal((await h.signIn(b)).status,200,'Other spouse credentials changed');
      assert.equal((await exchange(grant)).status,404,'Used code must no longer exist');
    });
    await t.test('code exchange requires the requesting device verifier',async()=>{
      const grant=await requestRecovery(b);
      const wrong=await exchange({...grant,verifier:randomBytes(48).toString('base64url')});
      assert.equal(wrong.status,400);
    });
    await t.test('recovery email proves possession for initial password setup, not membership',async()=>{
      const grant=await requestRecovery(unverified);
      const response=await exchange(grant);
      assert.equal(response.status,200);
      const password=randomBytes(24).toString('base64url');
      assert.equal((await h.request('/auth/v1/user',{method:'PUT',token:response.data.access_token,body:{password}})).status,200);
      assert.equal((await h.signIn(unverified,password)).status,200);
      assert.equal((await h.rpc('get_household',{},response.data.access_token)).status,404);
    });
    await t.test('expired authorization code cannot create a recovery session',async()=>{
      const user=await h.createUser();
      const grant=await requestRecovery(user);
      localSQL(`update auth.flow_state set created_at=now()-interval '2 hours', auth_code_issued_at=now()-interval '2 hours' where user_id='${uuid(user.id)}';`);
      const response=await exchange(grant);
      assert.equal(response.status,422,'Expired-code response must be rejected');
      assert.equal(response.data.error_code || response.data.code,'flow_state_expired');
      assert(!response.data.access_token,'Expired code returned a session');
    });
  } finally {
    // Only generated recipients / exact captured message IDs, never clear the whole mailbox.
    let failed=false;
    for(const email of recipients) { try { await inbox(email); } catch { failed=true; } }
    for(const id of messages) { try { await mail(`/api/v1/messages`,{method:'DELETE',headers:{'Content-Type':'application/json'},body:JSON.stringify({IDs:[id]})}); } catch { failed=true; } }
    await h.cleanup();
    assert(!failed,'Synthetic recovery mail cleanup failed');
  }
});
