import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { verifyLocalStack, database } from '../../../scripts/local-safety.mjs';

const root=fileURLToPath(new URL('../../../',import.meta.url));
const base='http://127.0.0.1:55321';
export function uuid(value) {
  assert(typeof value==='string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value),'Expected fixture UUID');
  return value;
}

export function localSQL(sql) {
  try {
    return execFileSync('docker',['exec','-i',database,'psql','-X','-qAt','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],
      {input:`set statement_timeout='15s';\n${sql}`,encoding:'utf8',stdio:['pipe','pipe','pipe'],timeout:20000}).trim();
  } catch { throw new Error('Local fixture SQL failed; details suppressed'); }
}

export function localHarness() {
  const containers=verifyLocalStack();
  for(const name of ['supabase_kong_housekeeping-local','supabase_auth_housekeeping-local','supabase_rest_housekeeping-local']) {
    assert(containers.some(c=>c.Name===`/${name}` && c.State.Running),'Required local API service is not running');
  }
  let config;
  try {
    config=JSON.parse(execFileSync(process.env.HK_SUPABASE_CLI || 'supabase',['status','-o','json'],
      {cwd:root,encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:15000}));
  } catch { throw new Error('Cannot load local CLI status; credentials are never printed'); }
  assert.equal(config.API_URL,base,'Refuse any nonlocal or different project URL');
  assert(typeof config.ANON_KEY==='string' && typeof config.SERVICE_ROLE_KEY==='string','Missing local keys');
  const emails=[];
  const userIds=new Set();
  const households=[];
  function trackCreatedUser(id) { userIds.add(uuid(id)); }
  function newEmail() {
    const email=`hk-test-${randomUUID()}@example.invalid`;
    emails.push(email);
    return email;
  }

  async function request(path,{method='GET',body,token,key=config.ANON_KEY}={}) {
    const url=new URL(path,base);
    assert.equal(url.origin,base,'Refuse nonlocal request');
    const headers={apikey:key,'Content-Type':'application/json'};
    if(token) headers.Authorization=`Bearer ${token}`;
    let response;
    try {
      response=await fetch(url,{method,headers,body:body===undefined ? undefined : JSON.stringify(body),
        redirect:'error',signal:AbortSignal.timeout(10000)});
    } catch { throw new Error(`Local HTTP ${method} failed; request details suppressed`); }
    const text=await response.text();
    let data;
    try { data=text ? JSON.parse(text) : null; } catch { throw new Error('Local API returned invalid JSON'); }
    return {status:response.status,data};
  }
  async function bytesRequest(path,{method='GET',body,token,key=config.ANON_KEY,headers={}}={}) {
    const url=new URL(path,base);
    assert.equal(url.origin,base,'Refuse nonlocal request');
    const requestHeaders={apikey:key,...headers};
    if(token) requestHeaders.Authorization=`Bearer ${token}`;
    let response;
    try {
      response=await fetch(url,{method,headers:requestHeaders,body,redirect:'error',signal:AbortSignal.timeout(10000)});
    } catch { throw new Error(`Local byte request ${method} failed; request details suppressed`); }
    return {status:response.status,data:new Uint8Array(await response.arrayBuffer()),headers:response.headers};
  }
  const admin=(path,options={})=>request(path,{...options,key:config.SERVICE_ROLE_KEY,token:config.SERVICE_ROLE_KEY});
  const rpc=(name,input,token)=>request(`/rest/v1/rpc/${name}`,{method:'POST',body:name==='get_household' ? {} : {p_input:input},token});

  async function createUser(confirmed=true) {
    const email=newEmail();
    const password=randomBytes(24).toString('base64url');
    const result=await admin('/auth/v1/admin/users',{method:'POST',body:{email,password,email_confirm:confirmed}});
    assert.equal(result.status,200,'Local synthetic user creation failed');
    const user={id:uuid(result.data.id),email,password};
    trackCreatedUser(user.id);
    return user;
  }
  async function signIn(user,password=user.password) {
    return request('/auth/v1/token?grant_type=password',{method:'POST',body:{email:user.email,password}});
  }
  function provision(a,b) {
    const household=randomUUID();
    households.push(household);
    localSQL(`select private.provision_household('${household}','HTTP fixture','${uuid(a.id)}','${uuid(b.id)}');`);
    return household;
  }
  async function cleanup() {
    // Generated exact IDs only; no user lists, broad deletes, or live target overrides.
    let failures=0;
    for(const household of households) {
      try {
        localSQL(`begin;
          set local storage.allow_delete_query='true';
          delete from storage.objects where bucket_id='purchase-photos' and name in
            (select object_key from public.photos where household_id='${uuid(household)}');
          update public.items set photo_id=null where household_id='${uuid(household)}';
          update public.photos set state='DELETE_PENDING',item_id=null
            where household_id='${uuid(household)}';
          delete from public.photos where household_id='${uuid(household)}';
          delete from private.photo_cleanup_jobs where household_id='${uuid(household)}';
          delete from public.items where household_id='${uuid(household)}';
          delete from public.households where id='${household}'; commit;`);
      } catch { failures++; }
    }
    for(const email of emails) {
      try {
        // Register generated emails before sending requests, so a failed response or a
        // signup regression cannot leave an untracked synthetic account behind.
        assert.match(email,/^hk-test-[0-9a-f-]{36}@example\.invalid$/);
        const id=localSQL(`select id from auth.users where email='${email}';`);
        if(id) trackCreatedUser(id);
      } catch { failures++; }
    }
    for(const id of userIds) {
      try {
        // Auth flow_state has no cascading user deletion. Remove only this fixture's PKCE rows.
        localSQL(`delete from auth.flow_state where user_id='${uuid(id)}';`);
        const result=await admin(`/auth/v1/admin/users/${id}`,{method:'DELETE'});
        if(![200,404].includes(result.status)) failures++;
      } catch { failures++; }
    }
    assert.equal(failures,0,'Some synthetic accounts could not be removed; inspect local fixtures before reuse');
  }
  const publicClientConfiguration=()=>({url:base,publishableKey:config.ANON_KEY});
  return {request,bytesRequest,rpc,serviceRequest:admin,createUser,signIn,provision,cleanup,newEmail,trackCreatedUser,publicClientConfiguration};
}
