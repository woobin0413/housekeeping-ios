import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

// No connection URL or credentials accepted: this test can only use this app's local container.
const container = 'supabase_db_housekeeping-local';
const project = execFileSync('docker', [
  'inspect', container, '--format', '{{index .Config.Labels "com.supabase.cli.project"}}',
], { encoding: 'utf8' }).trim();
assert.equal(project, 'housekeeping-local', 'Refuse any other database container');

function query(sql) {
  const child = spawn('docker', [
    'exec', '-i', container, 'psql', '-X', '-qAt', '-U', 'postgres', '-d', 'postgres',
    '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose',
  ]);
  let output = '';
  let error = '';
  let announceReady;
  const ready = new Promise((resolve) => { announceReady = resolve; });
  child.stdout.on('data', (data) => {
    output += data;
    if (output.includes('locks-held')) announceReady(true);
  });
  child.stderr.on('data', (data) => { error += data; });
  const done = new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', (code) => {
      announceReady(false);
      resolve({ code, output, error });
    });
  });
  child.stdin.end(`set statement_timeout = '10s';\n${sql}`);
  return { ready, done };
}

async function succeeds(sql) {
  const result = await query(sql).done;
  assert.equal(result.code, 0, result.error);
  return result.output.trim();
}

function provision(household, a, b) {
  return `select private.provision_household('${household}', 'Concurrency fixture', '${a}', '${b}');`;
}

async function scenario(kind) {
  // All SQL identifiers below are generated UUIDs, never external input.
  const users = [randomUUID(), randomUUID(), randomUUID()];
  const houses = [randomUUID(), randomUUID()];
  const userList = users.map((id) => `'${id}'`).join(',');
  const houseList = houses.map((id) => `'${id}'`).join(',');
  let first;
  let second;
  try {
    await succeeds(`insert into auth.users (id,email,email_confirmed_at) values ${
      users.map((id) => `('${id}','race-${id}@example.invalid',now())`).join(',')
    };`);
    let firstSQL = provision(houses[0], users[0], users[1]);
    let secondSQL = kind === 'identical retries'
      ? provision(houses[0], users[1], users[0])
      : provision(houses[1], users[1], users[2]);
    if (kind === 'competing member slots') {
      await succeeds(`${firstSQL}
        delete from public.household_members where user_id = '${users[1]}';`);
      // Provisioning assigns slots in UUID order. Reuse the vacated slot in both sessions.
      const slot = users[0] < users[1] ? 2 : 1;
      firstSQL = `insert into public.household_members (household_id,user_id,slot)
        values ('${houses[0]}','${users[1]}',${slot});`;
      secondSQL = `insert into public.household_members (household_id,user_id,slot)
        values ('${houses[0]}','${users[2]}',${slot});`;
    }
    first = query(`begin; ${firstSQL} select 'locks-held'; select pg_sleep(1); commit;`);
    assert.equal(await first.ready, true, 'First transaction must acquire its locks');
    second = query(secondSQL);
    const [a, b] = await Promise.all([first.done, second.done]);
    assert.equal(a.code, 0, a.error);
    if (kind === 'identical retries') {
      assert.equal(b.code, 0, b.error);
    } else {
      assert.notEqual(b.code, 0, 'Competing assignment must fail');
      assert.match(b.error, kind === 'competing member slots' ? /23505/ : /PT409/);
    }
    assert.equal(await succeeds(`select count(*) from public.households where id in (${houseList});`), '1');
    assert.equal(await succeeds(`select count(*) from public.household_members where user_id in (${userList});`), '2');
    console.log(`PASS: ${kind}`);
  } finally {
    // Wait for all test connections before removing exactly this scenario's disposable fixtures.
    await Promise.allSettled([first?.done, second?.done].filter(Boolean));
    await succeeds(`begin;
      delete from public.households where id in (${houseList});
      delete from auth.users where id in (${userList});
      commit;`);
  }
}

for (const kind of ['identical retries', 'competing households', 'competing member slots']) {
  await scenario(kind);
}

async function inventoryScenario(kind) {
  const users = [randomUUID(), randomUUID()];
  const household = randomUUID();
  const request = randomUUID();
  const login = (user) => `set local role authenticated;
    select set_config('request.jwt.claim.sub','${user}',true);`;
  const create = `select public.create_item('{"householdId":"${household}","requestId":"${request}","name":"Race kettle"}') ->> 'id';`;
  let first;
  let second;
  try {
    await succeeds(`insert into auth.users (id,email,email_confirmed_at) values ${
      users.map((id) => `('${id}','race-${id}@example.invalid',now())`).join(',')
    }; ${provision(household,users[0],users[1])}`);
    let firstSQL;
    let secondSQL;
    if (kind === 'concurrent save retries') {
      firstSQL = `${login(users[0])} ${create}`;
      secondSQL = firstSQL;
    } else {
      await succeeds(`begin; ${login(users[0])} ${create} commit;`);
      const item = await succeeds(`select id from public.items where household_id = '${household}';`);
      assert.match(item,/^[0-9a-f-]{36}$/);
      const edit = `select public.update_item('{"id":"${item}","expectedVersion":1,"fields":{"name":"Edited"}}');`;
      firstSQL = `${login(users[0])} ${edit}`;
      secondSQL = `${login(users[1])} ${edit}`;
      if (kind === 'delete versus edit') {
        firstSQL = `${login(users[0])} select public.delete_item('{"id":"${item}","expectedVersion":1}');`;
      } else if (kind === 'revocation before write') {
        firstSQL = `delete from public.household_members where user_id = '${users[0]}';`;
        secondSQL = `${login(users[0])} ${edit}`;
      } else if (kind === 'write before revocation') {
        secondSQL = `delete from public.household_members where user_id = '${users[0]}';`;
      }
    }
    first = query(`begin; ${firstSQL} select 'locks-held'; select pg_sleep(1); commit;`);
    assert.equal(await first.ready,true,'First transaction must hold locks');
    second = query(`begin; ${secondSQL} commit;`);
    const [a,b] = await Promise.all([first.done,second.done]);
    assert.equal(a.code,0,a.error);
    if (kind === 'concurrent save retries' || kind === 'write before revocation') {
      assert.equal(b.code,0,b.error);
    } else {
      assert.notEqual(b.code,0,'Conflicting operation must fail');
      assert.match(b.error,kind === 'competing edits' ? /PT409/ : /PT404/);
    }
    assert.equal(await succeeds(`select count(*) from public.items where household_id = '${household}';`),'1');
    if (kind === 'concurrent save retries') {
      assert.equal(await succeeds(`select count(*) from private.item_creation_requests where household_id = '${household}';`),'1');
    } else {
      const expected = kind === 'revocation before write' ? '1' : '2';
      assert.equal(await succeeds(`select version from public.items where household_id = '${household}';`),expected);
    }
    console.log(`PASS: ${kind}`);
  } finally {
    await Promise.allSettled([first?.done,second?.done].filter(Boolean));
    await succeeds(`begin;
      delete from public.items where household_id = '${household}';
      delete from public.households where id = '${household}';
      delete from auth.users where id in ('${users[0]}','${users[1]}');
      commit;`);
  }
}

for (const kind of ['concurrent save retries','competing edits','delete versus edit',
  'revocation before write','write before revocation']) {
  await inventoryScenario(kind);
}

async function recognitionQuotaScenario() {
  const users = [randomUUID(), randomUUID()];
  const household = randomUUID();
  const photo = randomUUID();
  const uploadRequest = randomUUID();
  const requests = [randomUUID(), randomUUID()];
  const objectKey = `${household}/${users[0]}/${photo}.jpg`;
  let first;
  let second;
  try {
    await succeeds(`begin;
      insert into auth.users (id,email,email_confirmed_at) values
        ('${users[0]}','race-${users[0]}@example.invalid',now()),
        ('${users[1]}','race-${users[1]}@example.invalid',now());
      ${provision(household,users[0],users[1])}
      insert into public.photos (id,household_id,uploader_user_id,request_id,object_key,state,
        byte_size,mime_type,checksum,expires_at) values
        ('${photo}','${household}','${users[0]}','${uploadRequest}','${objectKey}',
        'READY',100,'image/jpeg',repeat('a',64),now()+interval '1 hour');
      update private.recognition_limits set user_daily_attempt_limit=1,
        household_daily_attempt_limit=60,project_daily_spend_limit_microusd=null;
      commit;`);
    const reserve = (request) => `set local role service_role;
      select public.reserve_recognition('{"requesterUserId":"${users[0]}",
        "photoId":"${photo}","requestId":"${request}","estimatedCostMicrousd":0}');`;
    first = query(`begin; ${reserve(requests[0])} select 'locks-held'; select pg_sleep(1); commit;`);
    assert.equal(await first.ready,true,'First recognition reservation must hold quota locks');
    second = query(`begin; ${reserve(requests[1])} commit;`);
    const [a,b] = await Promise.all([first.done,second.done]);
    assert.equal(a.code,0,a.error);
    assert.notEqual(b.code,0,'Concurrent request beyond the daily limit must fail');
    assert.match(b.error,/PT429/);
    assert.equal(await succeeds(`select count(*) from public.photo_analyses
      where requested_by='${users[0]}';`),'1');
    assert.equal(await succeeds(`select attempts from private.recognition_user_daily_usage
      where user_id='${users[0]}';`),'1');
    console.log('PASS: concurrent recognition quota reservation');
  } finally {
    await Promise.allSettled([first?.done,second?.done].filter(Boolean));
    await succeeds(`begin;
      update private.recognition_limits set user_daily_attempt_limit=30,
        household_daily_attempt_limit=60,project_daily_spend_limit_microusd=null;
      delete from public.photos where id='${photo}';
      delete from public.households where id='${household}';
      delete from auth.users where id in ('${users[0]}','${users[1]}');
      commit;`);
  }
}

await recognitionQuotaScenario();
