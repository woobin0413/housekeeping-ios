# Local HTTP fixtures

Run from the repository root after the guarded startup:

```sh
node scripts/start-local.mjs
node --test supabase/tests/integration/inventory.test.mjs
node --test supabase/tests/integration/recovery.test.mjs
node --test supabase/tests/integration/photos.test.ts
node --test supabase/tests/integration/account-maintenance.test.ts
```

Node.js 22 runs this dependency-free harness; no SDK package, Deno runtime, `.env`, or real credentials are required. If the complete CLI is not on PATH, set `HK_SUPABASE_CLI` to its trusted executable path for both commands. This is a development tool selection, not a runtime app setting or an untrusted executable sandbox.

The harness checks the local Unix Docker context, project labels, running services, and both requested and actual loopback port bindings. The HTTP target is fixed to `http://127.0.0.1:55321`; other origins/ports and redirects are rejected before credentials can be sent. Local CLI keys are loaded only into memory, with command output/error bodies suppressed. No cloud URL override exists.

Fixtures use Auth's [admin user creation](https://supabase.com/docs/reference/javascript/auth-admin-createuser) for temporary verified/unverified users and random passwords. Normal requests then use actual password-login access tokens through Auth and PostgREST—not hand-forged test JWTs or administrator credentials. The admin key is used only for fixture creation/removal and never belongs in the iPhone app. Email-provider support is enabled; global registration remains closed and is verified through HTTP.

Seventeen scenarios cover target refusal, closed registration, password checks, household lookup/sharing/isolation, direct table and RPC grants, forged metadata, creation retries, version conflicts, deletion, membership revocation, refresh, and sign-out. Node reports eighteen tests including the parent fixture lifecycle.

Cleanup tracks generated emails before creating accounts and records returned user IDs (including unexpected anonymous signup success) before assertions. It removes only this run's exact household/item IDs, then deletes its synthetic auth accounts. SQL/HTTP failures avoid printing credentials or payloads. A forcibly killed process cannot run cleanup; inspect leftover `hk-test-<UUID>@example.invalid` identities before reusing a forcibly interrupted stack. Do not compensate with a broad database reset or global Docker prune.

The recovery suite adds five scenarios (six Node tests including the parent) for actual captured PKCE emails, neutral unknown-account responses, password changes, initial setup without membership, and rejected replay/wrong-verifier/expired flows. Cleanup also removes exact-user PKCE flow records and only this run's captured emails. The installed CLI's local mail capture does not send real emails.

The optional `node scripts/test-ios-local-auth.mjs` runner requires Xcode and `HK_SIMULATOR_ID`, then exercises the actual Swift SDK and simulator Keychain with two disposable spouses. It also verifies shared inventory CRUD/search, pagination, exact and conflicting retries, stale edits, and tombstone behavior through the Swift repository. Its restricted temporary fixture contains no administrator key and is removed afterward. See [iOS verification](../../../docs/ios-development.md) and [inventory adapter verification](../../../docs/inventory-development.md).

The account-maintenance suite uses only generated local identities and JPEG bytes. It proves the
service-role endpoint rejects a member token, removes a member through the actual Storage copy/move
and Auth Admin APIs while the spouse retains exact image bytes, repeats completion safely, and closes
a separate household by deleting its object before records and identities. It removes only its exact
fixtures and operation tombstones.

Not covered yet: physical-device email-to-app journeys, real-device sessions, hosted Storage/Auth,
configured backup export/restore, or cloud configuration.
