# iOS configuration and authentication

Status: 2026-09-14. Supabase Swift 2.55.1 is pinned in the Xcode project and Package.resolved. Authentication/recovery, shared inventory writes, private photos, native camera capture, and recognition review/manual fallback are connected. Launch and foreground restoration revalidate the session/household and preserve local drafts before replacing inventory state. No cloud configuration or real accounts were used.

## Configuration

For the project details to share before connecting a hosted backend, see the
[Supabase connection checklist](../README.md#connect-your-supabase-project-what-to-share).

`ios/Configuration/App.xcconfig` optionally includes ignored `Local.xcconfig` from the same directory. When preparing a connected build, copy the contents of `Local.xcconfig.example` into that local file and supply only a project URL and public publishable key (legacy anon keys are also accepted). Use the documented `http:/$()/...` spelling to avoid xcconfig's `//` comment parsing. The database host/password, administrator service-role key, and AI provider key never belong in the iPhone app.

Configuration is not required for the demo or offline tests. Missing/invalid settings show an explicit setup screen with an opt-in, labeled demo. A build guard rejects privileged/malformed keys, URLs containing credentials or query strings, and insecure remote HTTP without printing supplied values. Debug permits only the local HTTP origin `127.0.0.1:55321`; Release requires HTTPS. Actual local SDK-to-server connectivity passed separately using the runner below.

No `Local.xcconfig` has been created. Continue with synthetic local development for persistent inventory; notify the user before the cloud-connection milestone requires their project URL and public key. SwiftUI uses this ignored xcconfig file rather than a JavaScript-style `.env`. There are no separate Storage administrator credentials to embed in the app: database and Storage requests use the signed-in user's session.

Public client settings are embedded in app metadata. The public key is not authorization by itself: user sessions and server-side household membership/RLS enforce access. Do not put secrets in build-setting overrides, which Xcode may include in build logs even though the validation script never echoes them.

## Session boundary

`AuthSession` owns token-free observable account/household states and serializes authentication operations. Restoration hides previous identity while checking current membership. A missing household is distinct from an expired session or unavailable service. No passwords are stored by this model.

`SupabaseAuthService` handles password login, on-demand token refresh, household RPC, and current-session sign-out. Background automatic refresh is disabled; restoration and authenticated operations explicitly await a valid session. `AppConnection` serializes launch/foreground restoration, sign-in/out, and callback routing. The [inventory adapter](inventory-development.md) uses a narrow account-pinned RPC capability with generation checks. The [inventory/draft core](draft-state-development.md) partitions files and rejects late results. Task 13 connects retirement, sign-out warnings/cleanup, foreground refresh, access-error account UI, and durable editor/write recovery. Later photo work adds session-owned image bytes and clears them with account state.

`KeychainSessionStorage` namespaces records by bundle ID and project URL, disables iCloud synchronization, and uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. The SDK swallows storage errors internally, so the adapter explicitly verifies persisted credentials and deletion. Logout lets the SDK capture the token for `/logout?scope=local` before verified local deletion. Failed server revocation is reported as local-only sign-out; failed Keychain deletion blocks instead of claiming success. Device-lock and physical-device behavior still require device testing.

## Password setup and recovery

`SupabaseRecoveryService` uses a separate PKCE client and Keychain namespace. Recovery sessions cannot become normal inventory sessions. Only `housekeeping://auth/recovery?code=…` is accepted, with an exact route and bounded single code; token fragments, duplicate parameters, and foreign routes are rejected. The same redirect is allowlisted in local Supabase configuration and the scheme is registered in the app's Info.plist.

Pending recovery is bound to the requested email, then the verified user ID, with a one-hour local lifetime. Password updates revalidate the server identity. Expired/orphaned state is cleared; interrupted persistence can resume only after identity validation. Callback handling waits for an in-flight recovery operation rather than dropping the link. A successful password update is not repeated if credential cleanup needs retrying. Return to fresh normal sign-in after completion.

Unknown-email requests show neutral confirmation and cannot create accounts or membership. Initial setup uses an already provisioned account; household access still requires trusted provisioning. Local tests capture email in Mailpit, never deliver real email. Cloud onboarding must configure the same redirect and an approved email provider, then be verified on both physical iPhones. See Supabase's [password flows](https://supabase.com/docs/guides/auth/passwords) and [PKCE session flow](https://supabase.com/docs/guides/auth/sessions/pkce-flow).

## Verification

The configuration tests first failed with missing implementation, then passed. Offline transport tests use a private URLProtocol with synthetic credentials and cannot make network requests; they cover authenticated household lookup, session persistence, token rotation, logout requests, offline cleanup, storage failure, and normalized error messages. Separate local backend HTTP tests exercise actual password sessions and both household members.

Run the shared scheme as shown in [README](../README.md). The offline suite covers 36 unit tests, including callback validation/serialization, isolated recovery sessions, storage failures, and cleanup retry. Keychain tests need ad-hoc simulator signing; unsigned tests correctly failed with OSStatus -34018. The three Ruby build-configuration tests pass 92 assertions without network access. See [preview verification](design-preview/README.md) for the latest UI results.

Tasks 11–13 add inventory model/transport, durable file/state, lifecycle/detail, and connected mutation checks: **80 passing offline unit tests** in total. The opt-in local SDK test and physical-device file-protection test are skipped in this simulator run. The original 36-test count above records the authentication milestone. See [inventory verification](inventory-development.md) for real SDK checks, [draft/state verification](draft-state-development.md), and [connected-screen verification](connected-inventory-development.md) for current coverage and limitations.

For the optional real SDK check, start the guarded local stack and set `HK_SIMULATOR_ID` to an installed simulator UUID:

```sh
node scripts/test-ios-local-auth.mjs
node --test supabase/tests/integration/recovery.test.mjs
```

The SDK runner passed on iPhone 17 Pro / iOS 26.5: both synthetic spouses sign in and find the same household; reconstructed services restore Keychain sessions; signing out one leaves the other usable. Task 11 extends it with real bidirectional inventory CRUD/search, retries, stale conflicts, and tombstones. A generated 0700 temporary directory holds a 0600 fixture containing only local public configuration and disposable passwords. Xcode forwards its path through `TEST_RUNNER_HK_LOCAL_AUTH_FIXTURE`; the runner requires the actual test to pass, not skip. It removes its fixture/accounts afterward. Normal unit runs skip this one opt-in integration test. No actual `Local.xcconfig` is required or generated.

Five recovery HTTP scenarios passed (six Node tests including the parent): real captured PKCE email/password change, unknown-account neutrality, replay/wrong-verifier rejection, initial setup without membership bypass, and expired server flow. Offline UI journeys exercise deterministic states; these are complementary checks, not a claim of physical-device email-to-app end-to-end coverage.

Independent review found and fixed logout ordering, recovery cleanup, callback serialization, and acknowledged-save discard reconciliation before this handoff. Persistent inventory, photos, and recognition/manual fallback are complete locally. Manual VoiceOver review, physical-device Keychain/email/camera behavior, and hosted checks remain pending in the release acceptance matrix.
