# Local backend: setup and verification

Status (2026-09-14): the localhost stack implements authentication/recovery, two-member households,
shared inventory, private photos, cleanup, recognition authorization/manual fallback, and
service-role-only member-removal/household-closure operations. All evidence below uses generated
identities and bytes. No cloud project, real account, personal image, provider call, or paid service
was used.

For a short start-to-finish procedure, use the [local run guide](local-user-guide.md). This page
records the safety boundary, test commands, and verified scope.

## Prerequisites

- macOS and Xcode with an iOS 18-or-later simulator
- Docker Desktop or a compatible Docker Engine
- Node.js 22
- Supabase CLI 2.109.1, including its matching `supabase-go` helper
- Deno 2.9.5

Set `HK_SUPABASE_CLI` to a complete trusted Supabase executable if `supabase` is not on `PATH`.
The startup wrapper reads that variable; for direct CLI commands, invoke the same executable by its
absolute path. Do not reference a temporary path from an earlier development session.

The local project ID is `housekeeping-local`; ports 55320–55329 are reserved for its services.
Public signup, anonymous login, unused identity providers, Realtime, and analytics are disabled.
Email confirmation and secure password changes are enabled, with local messages captured by
Mailpit. Recognition has no provider key or model configuration.

## Localhost-only startup

Run:

```sh
node scripts/start-local.mjs
node --test scripts/local-safety.test.mjs
```

Use this wrapper instead of bare `supabase start`. On the tested CLI, bare startup and
`supabase db reset --local` can publish container ports on wildcard IPv4/IPv6 interfaces. The
wrapper intercepts project-scoped container creation, binds each published port to `127.0.0.1`,
then verifies the requested and actual bindings. It does not change global Docker settings or
stop unrelated projects.

Successful startup exposes the local API at `http://127.0.0.1:55321`, PostgreSQL at port 55322,
Studio at `http://127.0.0.1:55323`, and Mailpit at `http://127.0.0.1:55324`. These services use
development credentials. Loopback binding is a local safeguard, not production hardening.

Avoid reset as a routine workflow. Migrations and SQL tests are repeatable without it. If an
isolated reset is required, stop the stack first and follow a reviewed project-volume procedure;
never prune Docker globally or remove an unrelated volume.

## Verification commands

Run commands from the repository root. Do not add `--linked`, a cloud database URL, real email
addresses, or personal images.

```sh
node scripts/start-local.mjs
node --test scripts/local-safety.test.mjs
supabase migration up --local
supabase test db
node supabase/tests/concurrency/households.mjs

node --test supabase/tests/integration/inventory.test.mjs
node --test supabase/tests/integration/recovery.test.mjs
node --test supabase/tests/integration/photos.test.ts
node --test supabase/tests/integration/account-maintenance.test.ts

deno check --config supabase/functions/media/deno.json supabase/functions/media/index.ts
deno test --config supabase/functions/media/deno.json supabase/tests/functions/media.test.ts
deno test --config supabase/functions/cleanup/deno.json supabase/tests/functions/cleanup.test.ts
deno check --config supabase/functions/recognitions/deno.json supabase/functions/recognitions/index.ts
deno test --config supabase/functions/recognitions/deno.json supabase/tests/functions/recognition.test.ts
deno check --config supabase/functions/account-maintenance/deno.json supabase/functions/account-maintenance/index.ts
deno test --config supabase/functions/account-maintenance/deno.json supabase/tests/functions/account-maintenance.test.ts

supabase db lint --local --schema public,private --fail-on warning
supabase stop
```

The optional real Swift SDK exercise creates and removes disposable local accounts:

```sh
# Set HK_SIMULATOR_ID to an installed simulator UUID first.
node scripts/test-ios-local-auth.mjs
```

The 10,000-record benchmark restarts only this project's database and should run separately:

```sh
node supabase/tests/performance/search.mjs
```

See the [integration-fixture guide](../supabase/tests/integration/README.md) for exact isolation and
cleanup guarantees.

## Verified evidence

- All **254 database assertions** pass, including household isolation, transactional inventory,
  private photo state, recognition quota, member removal, old-session denial, continuing-spouse
  preservation, household closure, and retry ledgers.
- Nine competing-session scenarios pass for provisioning, inventory writes/revocation, photo
  lifecycle, and recognition quota reservation.
- Inventory, recovery, private-photo, and account-maintenance HTTP suites pass through actual local
  Auth, PostgREST, Storage, and Edge Functions. The account suite contains three tests using actual
  Storage copy/move/delete and Auth Admin operations.
- Account maintenance has five isolated Deno tests for ownership transfer and repeat-safe failures.
  The media, cleanup, recognition, and provider suites also pass without external provider calls.
- Strict database lint passes for the `public` and `private` schemas.
- The guarded-startup suite has five passing tests and verifies all published project ports are
  loopback-only.
- The 10,000-record warm baseline measured database p95 at 5.616 ms and local HTTP p95 at 8.600 ms
  over 100 requests each. Cold/cloud/device AC-09 evidence remains part of task 27; see
  [search performance](search-performance.md).

The [iOS status](ios-development.md) records the separate app, simulator, Keychain, recovery, and
two-account SDK evidence. The [release acceptance matrix](acceptance-results.md) distinguishes these
local passes from hosted and physical-device proof.

## Remaining critical work

Only tasks 24–27 are on the [critical release path](release-criticality.md): identify and audit the
cloud target, complete hosted account-removal/closure and separate record/image restore exercises,
configure private installation, and execute the two-phone acceptance matrix. Recognition evaluation
is deferred while the provider remains unconfigured and manual entry/photo saving remain available.
