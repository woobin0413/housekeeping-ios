import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  inspectCloudSnapshots,
  currentUnusedQuery,
  loadExpectedMigrationVersions,
  migrationVersionsQuery,
  parseAuditEnvironment,
  postDeploymentQuery,
  preDeploymentQuery,
  runCloudAudit,
} from "./audit-cloud-target.mjs";

const projectRef = "abcdefghijklmnopqrst";
const migrations = ["20260907000100", "20260907000200"];
const relations = [
  "private.account_operations",
  "private.account_photo_transfers",
  "private.item_creation_requests",
  "private.photo_cleanup_jobs",
  "private.recognition_household_daily_usage",
  "private.recognition_limits",
  "private.recognition_project_daily_usage",
  "private.recognition_user_daily_usage",
  "public.household_members",
  "public.households",
  "public.items",
  "public.photo_analyses",
  "public.photos",
];
const policies = [
  "public.household_members.membership_read",
  "public.households.household_read",
  "public.items.item_read",
  "public.photos.photo_read",
  "storage.objects.private_photo_download",
  "storage.objects.reserved_photo_upload",
];

function configuration(phase = "post-deploy") {
  return {
    accessToken: "secret-never-reported",
    projectRef,
    expectedRegion: "us-east-1",
    expectedName: "HouseKeeping Private",
    phase,
    emailDelivery: "custom-smtp",
  };
}

function project() {
  return {
    ref: projectRef,
    name: "HouseKeeping Private",
    region: "us-east-1",
    status: "ACTIVE_HEALTHY",
  };
}

function auth(overrides = {}) {
  return {
    disable_signup: true,
    external_email_enabled: true,
    external_anonymous_users_enabled: false,
    external_phone_enabled: false,
    external_google_enabled: false,
    custom_oauth_enabled: false,
    oauth_server_enabled: false,
    passkey_enabled: false,
    saml_enabled: false,
    security_manual_linking_enabled: false,
    security_update_password_require_reauthentication: true,
    refresh_token_rotation_enabled: true,
    mailer_autoconfirm: false,
    mailer_allow_unverified_email_sign_ins: false,
    mailer_secure_email_change_enabled: true,
    password_min_length: 12,
    uri_allow_list: "housekeeping://auth/recovery",
    smtp_host: "smtp.example.invalid",
    smtp_pass: "must-never-be-reported",
    ...overrides,
  };
}

function postDatabase(overrides = {}) {
  return [{
    audit: {
      migrationVersions: migrations,
      appRelations: relations,
      authUserCount: 2,
      confirmedUserCount: 2,
      householdCount: 1,
      memberCount: 2,
      bucket: {
        id: "purchase-photos",
        public: false,
        fileSizeLimit: 5_242_880,
        allowedMimeTypes: ["image/jpeg"],
      },
      rlsDisabledRelations: [],
      policies,
      anonymousAppPrivileges: [],
      authenticatedWritePrivileges: [],
      ...overrides,
    },
  }];
}

test("environment parser requires an explicit exact target and delivery mode", () => {
  assert.throws(() => parseAuditEnvironment({}), /SUPABASE_ACCESS_TOKEN|HK_SUPABASE_PROJECT_REF/);
  assert.throws(
    () => parseAuditEnvironment({
      SUPABASE_ACCESS_TOKEN: "token",
      HK_SUPABASE_PROJECT_REF: "too-short",
    }),
    /20-character/,
  );
  assert.equal(parseAuditEnvironment({
    SUPABASE_ACCESS_TOKEN: "token",
    HK_SUPABASE_PROJECT_REF: projectRef,
    HK_SUPABASE_EXPECTED_REGION: "us-east-1",
    HK_SUPABASE_EXPECTED_NAME: "HouseKeeping Private",
    HK_CLOUD_AUDIT_PHASE: "pre-deploy",
    HK_EMAIL_DELIVERY_MODE: "supabase-team-only",
  }).phase, "pre-deploy");
});

test("migration discovery accepts only unique timestamped SQL migrations", async () => {
  const directory = await mkdtemp(join(tmpdir(), "hk-cloud-audit-"));
  await writeFile(join(directory, "20260907000200_second.sql"), "select 2;");
  await writeFile(join(directory, "20260907000100_first.sql"), "select 1;");
  await writeFile(join(directory, "README.md"), "ignored");
  assert.deepEqual(await loadExpectedMigrationVersions(directory), migrations);
});

test("post-deployment snapshot passes only the exact account, bucket, RLS, and policy contract", () => {
  const report = inspectCloudSnapshots({
    configuration: configuration(),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth(),
    bucketsPayload: [{ id: "purchase-photos", public: false }],
    databasePayload: postDatabase(),
  });
  assert.equal(report.passed, true);
  assert.match(report.reviewDigest, /^[a-f0-9]{64}$/);
  assert.equal(JSON.stringify(report).includes("must-never-be-reported"), false);
  assert.equal(JSON.stringify(report).includes("secret-never-reported"), false);
});

test("audit reports unsafe auth and database drift without including secret fields", () => {
  const report = inspectCloudSnapshots({
    configuration: configuration(),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth({
      disable_signup: false,
      external_google_enabled: true,
      uri_allow_list: "housekeeping://auth/*",
    }),
    bucketsPayload: [{ id: "purchase-photos", public: true }],
    databasePayload: postDatabase({
      authUserCount: 3,
      rlsDisabledRelations: ["public.items"],
      anonymousAppPrivileges: ["public.items:SELECT"],
    }),
  });
  assert.equal(report.passed, false);
  const failed = report.checks.filter((check) => !check.passed).map((check) => check.id);
  assert.deepEqual(failed, [
    "signup-closed",
    "other-providers-disabled",
    "recovery-redirect",
    "no-wildcard-redirect",
    "private-photo-bucket",
    "exactly-two-users",
    "row-level-security",
    "anonymous-table-access",
  ]);
  assert.equal(JSON.stringify(report).includes("smtp_pass"), false);
});

test("pre-deployment snapshot accepts a dedicated empty database and absent bucket", () => {
  const report = inspectCloudSnapshots({
    configuration: configuration("pre-deploy"),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth(),
    bucketsPayload: [],
    databasePayload: [{ audit: { migrationVersions: [], appRelations: [], authUserCount: 0 } }],
  });
  assert.equal(report.passed, true);

  const partial = inspectCloudSnapshots({
    configuration: configuration("pre-deploy"),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth(),
    bucketsPayload: [],
    databasePayload: [{ audit: {
      migrationVersions: [migrations[0]],
      appRelations: ["public.households"],
      authUserCount: 0,
    } }],
  });
  assert.equal(partial.passed, false);
  assert.equal(partial.checks.find((check) => check.id === "database-baseline").actual, "unexpected-partial-or-populated");

  const currentUnused = inspectCloudSnapshots({
    configuration: configuration("pre-deploy"),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth(),
    bucketsPayload: [{ id: "purchase-photos", public: false }],
    databasePayload: [{ audit: {
      migrationVersions: migrations,
      appRelations: relations,
      authUserCount: 0,
    } }],
    currentDatabasePayload: [{ audit: { appRowCount: 0 } }],
  });
  assert.equal(currentUnused.passed, true);

  const populated = inspectCloudSnapshots({
    configuration: configuration("pre-deploy"),
    expectedMigrationVersions: migrations,
    projectPayload: project(),
    authPayload: auth(),
    bucketsPayload: [{ id: "purchase-photos", public: false }],
    databasePayload: [{ audit: {
      migrationVersions: migrations,
      appRelations: relations,
      authUserCount: 0,
    } }],
    currentDatabasePayload: [{ audit: { appRowCount: 1 } }],
  });
  assert.equal(populated.passed, false);
});

test("network runner uses only fixed read endpoints and the read-only SQL endpoint", async () => {
  const directory = await mkdtemp(join(tmpdir(), "hk-cloud-audit-"));
  for (const [index, version] of migrations.entries()) {
    await writeFile(join(directory, `${version}_migration_${index}.sql`), "select 1;");
  }
  const requests = [];
  let pristine = false;
  const fetcher = async (url, init) => {
    requests.push({ url, method: init.method ?? "GET", body: init.body, authorization: init.headers.authorization });
    let payload;
    if (url.endsWith("/config/auth")) payload = auth();
    else if (url.endsWith("/storage/buckets")) payload = [{ id: "purchase-photos", public: false }];
    else if (url.endsWith("/database/query/read-only")) {
      const query = JSON.parse(init.body).query;
      if (query === currentUnusedQuery) payload = [{ audit: { appRowCount: 0 } }];
      else if (query === migrationVersionsQuery) {
        payload = [{ audit: { migrationVersions: migrations } }];
      }
      else if (query === preDeploymentQuery) {
        payload = [{ audit: {
          migrationVersions: [],
          migrationHistoryExists: !pristine,
          appRelations: pristine ? [] : relations,
          authUserCount: 0,
        } }];
      } else payload = postDatabase();
    }
    else payload = project();
    return new Response(JSON.stringify(payload), { status: 200, headers: { "content-type": "application/json" } });
  };
  const report = await runCloudAudit({
    environment: {
      SUPABASE_ACCESS_TOKEN: "token-value",
      HK_SUPABASE_PROJECT_REF: projectRef,
      HK_SUPABASE_EXPECTED_REGION: "us-east-1",
      HK_SUPABASE_EXPECTED_NAME: "HouseKeeping Private",
      HK_CLOUD_AUDIT_PHASE: "post-deploy",
      HK_EMAIL_DELIVERY_MODE: "custom-smtp",
    },
    fetcher,
    migrationsDirectory: directory,
  });
  assert.equal(report.passed, true);
  assert.deepEqual(requests.map(({ url, method }) => ({ url, method })), [
    { url: `https://api.supabase.com/v1/projects/${projectRef}`, method: "GET" },
    { url: `https://api.supabase.com/v1/projects/${projectRef}/config/auth`, method: "GET" },
    { url: `https://api.supabase.com/v1/projects/${projectRef}/storage/buckets`, method: "GET" },
    { url: `https://api.supabase.com/v1/projects/${projectRef}/database/query/read-only`, method: "POST" },
  ]);
  assert.equal(JSON.parse(requests[3].body).query, postDeploymentQuery);
  assert.equal(requests.every((request) => request.authorization === "Bearer token-value"), true);

  requests.length = 0;
  const preReport = await runCloudAudit({
    environment: {
      SUPABASE_ACCESS_TOKEN: "token-value",
      HK_SUPABASE_PROJECT_REF: projectRef,
      HK_SUPABASE_EXPECTED_REGION: "us-east-1",
      HK_SUPABASE_EXPECTED_NAME: "HouseKeeping Private",
      HK_CLOUD_AUDIT_PHASE: "pre-deploy",
      HK_EMAIL_DELIVERY_MODE: "custom-smtp",
    },
    fetcher,
    migrationsDirectory: directory,
  });
  assert.equal(preReport.passed, true);
  assert.equal(requests.length, 6);
  assert.equal(JSON.parse(requests[3].body).query, preDeploymentQuery);
  assert.equal(JSON.parse(requests[4].body).query, migrationVersionsQuery);
  assert.equal(JSON.parse(requests[5].body).query, currentUnusedQuery);

  requests.length = 0;
  pristine = true;
  const pristineReport = await runCloudAudit({
    environment: {
      SUPABASE_ACCESS_TOKEN: "token-value",
      HK_SUPABASE_PROJECT_REF: projectRef,
      HK_SUPABASE_EXPECTED_REGION: "us-east-1",
      HK_SUPABASE_EXPECTED_NAME: "HouseKeeping Private",
      HK_CLOUD_AUDIT_PHASE: "pre-deploy",
      HK_EMAIL_DELIVERY_MODE: "custom-smtp",
    },
    fetcher,
    migrationsDirectory: directory,
  });
  assert.equal(pristineReport.passed, true);
  assert.equal(requests.length, 4);
  assert.equal(JSON.parse(requests[3].body).query, preDeploymentQuery);
});

test("hard-coded audit queries contain only one select statement", () => {
  for (const query of [
    preDeploymentQuery,
    migrationVersionsQuery,
    currentUnusedQuery,
    postDeploymentQuery,
  ]) {
    assert.match(query.trim(), /^select\b/i);
    assert.equal((query.match(/;/g) ?? []).length, 0);
    const withoutStringLiterals = query.replace(/'(?:''|[^'])*'/g, "''");
    assert.doesNotMatch(withoutStringLiterals, /\b(insert|update|delete|alter|drop|create|truncate|grant|revoke|copy|call|do)\b/i);
  }
});
