import assert from 'node:assert/strict';
import { mkdtemp, writeFile, unlink, rmdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { localHarness, localSQL, uuid } from '../supabase/tests/integration/local-harness.mjs';

// Uses the same target guard and synthetic-user cleanup as the HTTP suite.
const simulator=process.env.HK_SIMULATOR_ID;
assert(typeof simulator==='string' && /^[0-9a-f-]{36}$/i.test(simulator),'Set an installed HK_SIMULATOR_ID');
const h=localHarness();
let directory;
let fixturePath;
let household;
try {
  const a=await h.createUser();
  const b=await h.createUser();
  household=h.provision(a,b);
  directory=await mkdtemp('/tmp/housekeeping-ios-auth.');
  fixturePath=`${directory}/fixture.json`;
  await writeFile(fixturePath,JSON.stringify({runID:randomUUID(),...h.publicClientConfiguration(),household,a,b}),{mode:0o600,flag:'wx'});
  console.log('Running real Swift SDK login/restore/household/sign-out with disposable localhost accounts…');
  const result=await new Promise((resolve,reject)=>{
    const child=spawn('xcodebuild',[
      '-project','ios/HouseKeeping.xcodeproj','-scheme','HouseKeeping',
      '-destination',`platform=iOS Simulator,id=${simulator}`,
      '-derivedDataPath','/tmp/housekeeping-design-build',
      '-clonedSourcePackagesDirPath','/tmp/housekeeping-swift-packages',
      '-only-testing:HouseKeepingTests/LocalSupabaseTests',
      '-parallel-testing-enabled','NO',
      'CODE_SIGN_IDENTITY=-','test'
    ],{stdio:['ignore','pipe','pipe'],env:{...process.env,TEST_RUNNER_HK_LOCAL_AUTH_FIXTURE:fixturePath}});
    let sawTestPass=false;
    let tail='';
    child.stdout.on('data',chunk=>{
      tail=(tail+chunk.toString()).slice(-8192);
      if(/bothSpousesUseRealSDKAndProtectedSession\(\) passed/.test(tail)) sawTestPass=true;
    });
    child.stderr.resume(); // Never forward build environment or auth response details.
    const timeout=setTimeout(()=>child.kill('SIGTERM'),180000);
    child.on('error',error=>{clearTimeout(timeout);reject(error);});
    child.on('close',code=>{clearTimeout(timeout);resolve(code===0 && sawTestPass);});
  });
  assert(result,'Local Swift SDK test failed or was skipped; inspect its Xcode test result, not credential files');
  console.log('PASS: both spouses, shared inventory, private photo upload/finalization/attachment/download, Keychain restoration, and independent sign-out');
} finally {
  try {
    // Remove only this fixture's bytes through Storage before the harness purges its metadata.
    if(household) {
      const prefixes=JSON.parse(localSQL(`select coalesce(json_agg(object_key),'[]'::json) from public.photos where household_id='${uuid(household)}';`));
      assert(Array.isArray(prefixes),'Invalid synthetic photo cleanup response');
      assert(prefixes.every(key=>typeof key==='string' && key.startsWith(`${household}/`) && /^[0-9a-f/-]+\.jpg$/.test(key)),
        'Refuse unexpected synthetic photo cleanup path');
      if(prefixes.length) {
        const removed=await h.serviceRequest('/storage/v1/object/purchase-photos',{method:'DELETE',body:{prefixes}});
        assert.equal(removed.status,200,'Synthetic photo bytes remain; preserve metadata for cleanup retry');
      }
    }
    await h.cleanup();
  }
  finally {
    try {
      if(fixturePath) await unlink(fixturePath).catch(error=>{if(error.code!=='ENOENT') throw error;});
    } finally {
      if(directory) await rmdir(directory);
    }
  }
}
