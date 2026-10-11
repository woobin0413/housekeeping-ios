import { createHash } from "node:crypto";
import { readdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const managementOrigin = "https://api.supabase.com";
const recoveryRedirect = "housekeeping://auth/recovery";
const expectedRelations = [
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
const expectedPolicies = [
  "public.household_members.membership_read",
  "public.households.household_read",
  "public.items.item_read",
  "public.photos.photo_read",
  "storage.objects.private_photo_download",
  "storage.objects.reserved_photo_upload",
];

export const preDeploymentQuery = `
select jsonb_build_object(
  'migrationVersions', '[]'::jsonb,
  'migrationHistoryExists',
    pg_catalog.to_regclass('supabase_migrations.schema_migrations') is not null,
  'appRelations', coalesce((
    select jsonb_agg(format('%I.%I', n.nspname, c.relname) order by n.nspname, c.relname)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    where n.nspname in ('public', 'private')
      and c.relkind in ('r', 'p')
  ), '[]'::jsonb),
  'authUserCount', (select count(*) from auth.users)
) as audit
`;

export const migrationVersionsQuery = `
select jsonb_build_object(
  'migrationVersions', coalesce((
    select jsonb_agg(m.version order by m.version)
    from supabase_migrations.schema_migrations as m
  ), '[]'::jsonb)
) as audit
`;

export const postDeploymentQuery = `
select jsonb_build_object(
  'migrationVersions', coalesce((
    select jsonb_agg(m.version order by m.version)
    from supabase_migrations.schema_migrations as m
  ), '[]'::jsonb),
  'appRelations', coalesce((
    select jsonb_agg(format('%I.%I', n.nspname, c.relname) order by n.nspname, c.relname)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    where n.nspname in ('public', 'private')
      and c.relkind in ('r', 'p')
  ), '[]'::jsonb),
  'authUserCount', (select count(*) from auth.users),
  'confirmedUserCount', (select count(*) from auth.users where email_confirmed_at is not null),
  'householdCount', (select count(*) from public.households),
  'memberCount', (select count(*) from public.household_members),
  'bucket', (select jsonb_build_object(
    'id', b.id,
    'public', b.public,
    'fileSizeLimit', b.file_size_limit,
    'allowedMimeTypes', b.allowed_mime_types
  ) from storage.buckets as b where b.id = 'purchase-photos'),
  'rlsDisabledRelations', coalesce((
    select jsonb_agg(format('%I.%I', n.nspname, c.relname) order by n.nspname, c.relname)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('households', 'household_members', 'items', 'photos', 'photo_analyses')
      and not c.relrowsecurity
  ), '[]'::jsonb),
  'policies', coalesce((
    select jsonb_agg(format('%I.%I.%I', p.schemaname, p.tablename, p.policyname)
      order by p.schemaname, p.tablename, p.policyname)
    from pg_catalog.pg_policies as p
    where (p.schemaname = 'public' and p.tablename in
      ('households', 'household_members', 'items', 'photos', 'photo_analyses'))
      or (p.schemaname = 'storage' and p.tablename = 'objects'
        and p.policyname in ('reserved_photo_upload', 'private_photo_download'))
  ), '[]'::jsonb),
  'anonymousAppPrivileges', coalesce((
    select jsonb_agg(format('%I.%I:%s', n.nspname, c.relname, a.privilege_type)
      order by n.nspname, c.relname, a.privilege_type)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) as a
    join pg_catalog.pg_roles as r on r.oid = a.grantee
    where r.rolname = 'anon'
      and n.nspname in ('public', 'private')
      and c.relname in ('households', 'household_members', 'items', 'photos',
        'photo_analyses', 'account_operations', 'account_photo_transfers',
        'item_creation_requests', 'photo_cleanup_jobs',
        'recognition_limits', 'recognition_user_daily_usage',
        'recognition_household_daily_usage', 'recognition_project_daily_usage')
  ), '[]'::jsonb),
  'authenticatedWritePrivileges', coalesce((
    select jsonb_agg(format('%I.%I:%s', n.nspname, c.relname, a.privilege_type)
      order by n.nspname, c.relname, a.privilege_type)
    from pg_catalog.pg_class as c
    join pg_catalog.pg_namespace as n on n.oid = c.relnamespace
    cross join lateral pg_catalog.aclexplode(
      coalesce(c.relacl, pg_catalog.acldefault('r', c.relowner))
    ) as a
    join pg_catalog.pg_roles as r on r.oid = a.grantee
    where r.rolname = 'authenticated'
      and a.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
      and n.nspname in ('public', 'private')
      and c.relname in ('households', 'household_members', 'items', 'photos',
        'photo_analyses', 'account_operations', 'account_photo_transfers',
        'item_creation_requests', 'photo_cleanup_jobs',
        'recognition_limits', 'recognition_user_daily_usage',
        'recognition_household_daily_usage', 'recognition_project_daily_usage')
  ), '[]'::jsonb)
) as audit
`;

export const currentUnusedQuery = `
select jsonb_build_object(
  'appRowCount',
    (select count(*) from public.households)
    + (select count(*) from public.household_members)
    + (select count(*) from public.items)
    + (select count(*) from public.photos)
    + (select count(*) from public.photo_analyses)
    + (select count(*) from private.account_operations)
    + (select count(*) from private.account_photo_transfers)
    + (select count(*) from private.item_creation_requests)
    + (select count(*) from private.photo_cleanup_jobs)
    + (select count(*) from private.recognition_user_daily_usage)
    + (select count(*) from private.recognition_household_daily_usage)
    + (select count(*) from private.recognition_project_daily_usage)
) as audit
`;

function required(environment, name) {
  const value = environment[name]?.trim();
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

export function parseAuditEnvironment(environment) {
  const projectRef = required(environment, "HK_SUPABASE_PROJECT_REF");
  if (!/^[a-z0-9]{20}$/.test(projectRef)) {
    throw new Error("HK_SUPABASE_PROJECT_REF must be a 20-character lowercase project ref");
  }
  const expectedRegion = required(environment, "HK_SUPABASE_EXPECTED_REGION");
  if (!/^[a-z0-9-]{3,40}$/.test(expectedRegion)) {
    throw new Error("Invalid HK_SUPABASE_EXPECTED_REGION");
  }
  const expectedName = required(environment, "HK_SUPABASE_EXPECTED_NAME");
  if (expectedName.length > 120) throw new Error("Invalid HK_SUPABASE_EXPECTED_NAME");
  const phase = required(environment, "HK_CLOUD_AUDIT_PHASE");
  if (phase !== "pre-deploy" && phase !== "post-deploy") {
    throw new Error("HK_CLOUD_AUDIT_PHASE must be pre-deploy or post-deploy");
  }
  const emailDelivery = required(environment, "HK_EMAIL_DELIVERY_MODE");
  if (emailDelivery !== "custom-smtp" && emailDelivery !== "supabase-team-only") {
    throw new Error(
      "HK_EMAIL_DELIVERY_MODE must be custom-smtp or supabase-team-only",
    );
  }
  return {
    accessToken: required(environment, "SUPABASE_ACCESS_TOKEN"),
    projectRef,
    expectedRegion,
    expectedName,
    phase,
    emailDelivery,
  };
}

export async function loadExpectedMigrationVersions(migrationsDirectory) {
  const names = await readdir(migrationsDirectory);
  const versions = names
    .map((name) => /^(\d{14})_[a-z0-9_]+\.sql$/.exec(name))
    .filter(Boolean)
    .map((match) => match[1])
    .sort();
  if (versions.length === 0 || new Set(versions).size !== versions.length) {
    throw new Error("Expected unique timestamped SQL migrations");
  }
  return versions;
}

function asObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`Invalid ${label} response`);
  }
  return value;
}

function stringArray(value, label) {
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new Error(`Invalid ${label}`);
  }
  return [...value].sort();
}

function integer(value, label) {
  const parsed = typeof value === "string" && /^\d+$/.test(value)
    ? Number(value)
    : value;
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`Invalid ${label}`);
  return parsed;
}

function queryAudit(payload) {
  const candidates = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.result)
    ? payload.result
    : Array.isArray(payload?.data)
    ? payload.data
    : null;
  if (!candidates || candidates.length !== 1) {
    throw new Error("Invalid database audit response");
  }
  const row = asObject(candidates[0], "database audit row");
  const audit = typeof row.audit === "string" ? JSON.parse(row.audit) : row.audit;
  return asObject(audit, "database audit");
}

function redirectURLs(auth) {
  const raw = auth.uri_allow_list;
  if (Array.isArray(raw)) return raw.filter((value) => typeof value === "string");
  if (typeof raw === "string") {
    return raw.split(",").map((value) => value.trim()).filter(Boolean);
  }
  return [];
}

function add(checks, id, passed, actual, expected) {
  checks.push({ id, passed: Boolean(passed), actual, expected });
}

function sameStrings(actual, expected) {
  return actual.length === expected.length && actual.every((value, index) => value === expected[index]);
}

export function inspectCloudSnapshots({
  configuration,
  expectedMigrationVersions,
  projectPayload,
  authPayload,
  bucketsPayload,
  databasePayload,
  currentDatabasePayload = null,
}) {
  const project = asObject(projectPayload, "project");
  const auth = asObject(authPayload, "auth");
  if (!Array.isArray(bucketsPayload)) throw new Error("Invalid buckets response");
  const database = queryAudit(databasePayload);
  const migrations = stringArray(database.migrationVersions, "migration versions");
  const relations = stringArray(database.appRelations, "app relations");
  const redirects = redirectURLs(auth);
  const enabledExternalProviders = Object.entries(auth)
    .filter(([key, value]) => /^external_.+_enabled$/.test(key) && key !== "external_email_enabled" && value === true)
    .map(([key]) => key)
    .sort();
  const enabledOtherAuthModes = [
    "custom_oauth_enabled",
    "oauth_server_enabled",
    "passkey_enabled",
    "saml_enabled",
  ].filter((key) => auth[key] === true);
  const managementBucket = bucketsPayload.find((bucket) => bucket?.id === "purchase-photos");
  const checks = [];

  add(checks, "project-ref", project.ref === configuration.projectRef, project.ref ?? null, configuration.projectRef);
  add(checks, "project-name", project.name === configuration.expectedName, project.name ?? null, configuration.expectedName);
  add(checks, "project-region", project.region === configuration.expectedRegion, project.region ?? null, configuration.expectedRegion);
  add(checks, "project-status", project.status === "ACTIVE_HEALTHY", project.status ?? null, "ACTIVE_HEALTHY");
  add(checks, "signup-closed", auth.disable_signup === true, auth.disable_signup ?? null, true);
  add(checks, "email-password-enabled", auth.external_email_enabled === true, auth.external_email_enabled ?? null, true);
  add(checks, "anonymous-disabled", auth.external_anonymous_users_enabled === false, auth.external_anonymous_users_enabled ?? null, false);
  add(checks, "other-providers-disabled", enabledExternalProviders.length === 0, enabledExternalProviders, []);
  add(checks, "other-auth-modes-disabled", enabledOtherAuthModes.length === 0, enabledOtherAuthModes, []);
  add(checks, "manual-linking-disabled", auth.security_manual_linking_enabled === false, auth.security_manual_linking_enabled ?? null, false);
  add(checks, "email-confirmation-required", auth.mailer_autoconfirm === false, auth.mailer_autoconfirm ?? null, false);
  add(checks, "unverified-signin-disabled", auth.mailer_allow_unverified_email_sign_ins === false, auth.mailer_allow_unverified_email_sign_ins ?? null, false);
  add(checks, "secure-email-change", auth.mailer_secure_email_change_enabled === true, auth.mailer_secure_email_change_enabled ?? null, true);
  add(checks, "secure-password-change", auth.security_update_password_require_reauthentication === true, auth.security_update_password_require_reauthentication ?? null, true);
  add(checks, "refresh-token-rotation", auth.refresh_token_rotation_enabled === true, auth.refresh_token_rotation_enabled ?? null, true);
  add(checks, "password-minimum", Number.isInteger(auth.password_min_length) && auth.password_min_length >= 12, auth.password_min_length ?? null, ">=12");
  add(checks, "recovery-redirect", redirects.includes(recoveryRedirect), redirects.includes(recoveryRedirect), true);
  add(checks, "no-wildcard-redirect", !redirects.some((url) => /[*?\[\]]/.test(url)), redirects.some((url) => /[*?\[\]]/.test(url)), false);
  const customSMTPConfigured = typeof auth.smtp_host === "string" && auth.smtp_host.trim().length > 0;
  add(
    checks,
    "email-delivery-mode",
    configuration.emailDelivery === "custom-smtp" ? customSMTPConfigured : !customSMTPConfigured,
    customSMTPConfigured ? "custom-smtp" : "supabase-team-only",
    configuration.emailDelivery,
  );

  const migrationsMatch = sameStrings(migrations, expectedMigrationVersions);
  const authUserCount = integer(database.authUserCount, "auth user count");
  const isEmptyTarget = migrations.length === 0 && relations.length === 0 && authUserCount === 0;
  const currentDatabase = currentDatabasePayload ? queryAudit(currentDatabasePayload) : null;
  const appRowCount = currentDatabase
    ? integer(currentDatabase.appRowCount, "app row count")
    : null;
  const isCurrentUnusedTarget = migrationsMatch && sameStrings(relations, expectedRelations) &&
    authUserCount === 0 && appRowCount === 0;
  add(
    checks,
    "database-baseline",
    configuration.phase === "pre-deploy" ? (isEmptyTarget || isCurrentUnusedTarget) : migrationsMatch,
    isEmptyTarget ? "empty" : isCurrentUnusedTarget ? "current-unused" : "unexpected-partial-or-populated",
    configuration.phase === "pre-deploy" ? "empty-or-current-unused" : "current",
  );

  if (configuration.phase === "pre-deploy") {
    add(checks, "bucket-before-deploy", !managementBucket || managementBucket.public === false, managementBucket ? (managementBucket.public ? "public" : "private") : "absent", "absent-or-private");
  } else {
    add(checks, "private-photo-bucket", managementBucket?.public === false, managementBucket ? (managementBucket.public ? "public" : "private") : "absent", "private");
    add(checks, "migration-set", migrationsMatch, migrations, expectedMigrationVersions);
    add(checks, "relation-set", sameStrings(relations, expectedRelations), relations, expectedRelations);
    add(checks, "exactly-two-users", authUserCount === 2, authUserCount, 2);
    add(checks, "both-users-confirmed", integer(database.confirmedUserCount, "confirmed user count") === 2, integer(database.confirmedUserCount, "confirmed user count"), 2);
    add(checks, "one-household", integer(database.householdCount, "household count") === 1, integer(database.householdCount, "household count"), 1);
    add(checks, "two-members", integer(database.memberCount, "member count") === 2, integer(database.memberCount, "member count"), 2);
    const bucket = database.bucket ? asObject(database.bucket, "database bucket") : null;
    const mimeTypes = bucket ? stringArray(bucket.allowedMimeTypes, "bucket MIME types") : [];
    add(checks, "bucket-contract", bucket?.id === "purchase-photos" && bucket.public === false && integer(bucket.fileSizeLimit, "bucket file limit") === 5_242_880 && sameStrings(mimeTypes, ["image/jpeg"]), bucket ? { id: bucket.id, public: bucket.public, fileSizeLimit: bucket.fileSizeLimit, allowedMimeTypes: mimeTypes } : null, { id: "purchase-photos", public: false, fileSizeLimit: 5_242_880, allowedMimeTypes: ["image/jpeg"] });
    const rlsDisabled = stringArray(database.rlsDisabledRelations, "disabled RLS relations");
    add(checks, "row-level-security", rlsDisabled.length === 0, rlsDisabled, []);
    const policies = stringArray(database.policies, "policies");
    add(checks, "policy-set", sameStrings(policies, expectedPolicies), policies, expectedPolicies);
    const anonPrivileges = stringArray(database.anonymousAppPrivileges, "anonymous privileges");
    add(checks, "anonymous-table-access", anonPrivileges.length === 0, anonPrivileges, []);
    const authenticatedWrites = stringArray(database.authenticatedWritePrivileges, "authenticated write privileges");
    add(checks, "direct-authenticated-writes", authenticatedWrites.length === 0, authenticatedWrites, []);
  }

  const safeSnapshot = {
    schemaVersion: 1,
    phase: configuration.phase,
    projectRef: configuration.projectRef,
    expectedRegion: configuration.expectedRegion,
    expectedName: configuration.expectedName,
    emailDelivery: configuration.emailDelivery,
    checks,
  };
  const reviewDigest = createHash("sha256").update(JSON.stringify(safeSnapshot)).digest("hex");
  return {
    ...safeSnapshot,
    passed: checks.every((check) => check.passed),
    reviewDigest,
  };
}

async function requestJSON(fetcher, accessToken, path, init = {}) {
  const response = await fetcher(`${managementOrigin}${path}`, {
    ...init,
    redirect: "error",
    signal: AbortSignal.timeout(15_000),
    headers: {
      authorization: `Bearer ${accessToken}`,
      accept: "application/json",
      ...(init.body ? { "content-type": "application/json" } : {}),
    },
  });
  if (!response.ok) {
    const requestId = response.headers.get("x-request-id");
    throw new Error(`Management API ${path} returned ${response.status}${requestId ? ` (request ${requestId})` : ""}`);
  }
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > 1_048_576) {
    throw new Error(`Management API ${path} response is too large`);
  }
  const text = await response.text();
  if (Buffer.byteLength(text) > 1_048_576) throw new Error(`Management API ${path} response is too large`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`Management API ${path} returned invalid JSON`);
  }
}

export async function runCloudAudit({
  environment = process.env,
  fetcher = globalThis.fetch,
  migrationsDirectory = resolve(dirname(fileURLToPath(import.meta.url)), "../supabase/migrations"),
} = {}) {
  const configuration = parseAuditEnvironment(environment);
  const ref = configuration.projectRef;
  const query = configuration.phase === "pre-deploy" ? preDeploymentQuery : postDeploymentQuery;
  const expectedMigrationVersions = await loadExpectedMigrationVersions(migrationsDirectory);
  const [projectPayload, authPayload, bucketsPayload, initialDatabasePayload] = await Promise.all([
    requestJSON(fetcher, configuration.accessToken, `/v1/projects/${ref}`),
    requestJSON(fetcher, configuration.accessToken, `/v1/projects/${ref}/config/auth`),
    requestJSON(fetcher, configuration.accessToken, `/v1/projects/${ref}/storage/buckets`),
    requestJSON(fetcher, configuration.accessToken, `/v1/projects/${ref}/database/query/read-only`, {
      method: "POST",
      body: JSON.stringify({ query }),
    }),
  ]);
  let database = queryAudit(initialDatabasePayload);
  if (configuration.phase === "pre-deploy") {
    if (typeof database.migrationHistoryExists !== "boolean") {
      throw new Error("Invalid migration history status");
    }
    if (database.migrationHistoryExists) {
      const migrationPayload = await requestJSON(
        fetcher,
        configuration.accessToken,
        `/v1/projects/${ref}/database/query/read-only`,
        { method: "POST", body: JSON.stringify({ query: migrationVersionsQuery }) },
      );
      const migrationDatabase = queryAudit(migrationPayload);
      database = {
        ...database,
        migrationVersions: stringArray(
          migrationDatabase.migrationVersions,
          "migration versions",
        ),
      };
    }
  }
  const databasePayload = [{ audit: database }];
  const migrations = stringArray(database.migrationVersions, "migration versions");
  const currentDatabasePayload = configuration.phase === "pre-deploy" &&
      sameStrings(migrations, expectedMigrationVersions)
    ? await requestJSON(
      fetcher,
      configuration.accessToken,
      `/v1/projects/${ref}/database/query/read-only`,
      { method: "POST", body: JSON.stringify({ query: currentUnusedQuery }) },
    )
    : null;
  return inspectCloudSnapshots({
    configuration,
    expectedMigrationVersions,
    projectPayload,
    authPayload,
    bucketsPayload,
    databasePayload,
    currentDatabasePayload,
  });
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href;
if (isMain) {
  try {
    const report = await runCloudAudit();
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    if (!report.passed) process.exitCode = 2;
  } catch (error) {
    process.stderr.write(`Cloud audit failed: ${error instanceof Error ? error.message : "unknown error"}\n`);
    process.exitCode = 1;
  }
}
