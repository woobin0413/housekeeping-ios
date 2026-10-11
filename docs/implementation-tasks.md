# Implementation tasks: private shared inventory

Status (2026-09-18): the local core through task 22, task 28, and the local portion of critical task 25 are implemented. Shared inventory with stock thresholds, private photos, native camera capture, editable recognition/manual fallback, and operator account-maintenance controls pass locally. Cloud onboarding is partially complete; hosted recovery proof and tasks 24, 26, and 27 remain open. Evidence is in [local-development.md](local-development.md) and the linked feature documents; this is not full release acceptance.

Release triage: the [measured criticality assessment](release-criticality.md) limits current work to
tasks 24–27. Task 05's remaining measurement is folded into critical task 27. Task 23 is deferred
with the provider unconfigured because recognition is optional and manual entry remains available.

## Execution rules

Implement the tasks in dependency order. Each checkbox represents one focused change with its tests, normally no more than five implementation files. Listed future filenames are proposed; use actual unique migration timestamps when creating migrations. Keep documentation/status updates alongside the relevant change. If a task grows beyond one focused session, split it without changing the approved scope.

Use only synthetic identities and non-personal image fixtures locally. Keep the preview runnable and explicitly separate from connected mode. Do not silently fall back to sample purchases after a network/authentication error. Intermediate milestones must clearly report unsupported features rather than pretend to save photos or perform recognition.

Detailed behavior remains governed by [spec.md](spec.md), [contracts.md](contracts.md), and [shared-household.md](shared-household.md). No new architecture or product decisions are introduced by this breakdown.

## Verification commands

Run from the repository root. These are intended commands, not claims of successful execution; some targets, scripts, packages, and backend directories will be created by the tasks below. Resolve local CLI/runtime compatibility first and update these commands if the verified toolchain requires it.

**Backend (DB):**

```sh
node scripts/start-local.mjs
supabase test db
```

**Swift app and UI tests (IOS):** Select an installed simulator and set `HK_SIMULATOR_ID` to its UUID. The shared scheme includes unit tests. Use local ad-hoc signing for real simulator Keychain access; no Apple account is needed.

```sh
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -showdestinations
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -destination "platform=iOS Simulator,id=${HK_SIMULATOR_ID}" -derivedDataPath /tmp/housekeeping-implementation-build CODE_SIGN_IDENTITY=- -parallel-testing-enabled NO test
xcrun swift-format lint --recursive --strict ios/HouseKeeping ios/HouseKeepingTests ios/HouseKeepingUITests
```

**Isolated function tests (FUNCTIONS):** No external provider requests.

```sh
deno fmt --check supabase/functions supabase/tests/functions
deno lint supabase/functions supabase/tests/functions
deno test supabase/tests/functions
```

**Local HTTP integration (HTTP):** The implemented Node harness rejects non-loopback URLs, uses unique fixture IDs, and cleans up only its own records. Local configuration is read into memory from the guarded CLI, with no credential file or token output. No real email or AI calls.

```sh
node --test supabase/tests/integration/inventory.test.mjs
node --test supabase/tests/integration/recovery.test.mjs
node --test supabase/tests/integration/photos.test.ts
node scripts/test-ios-local-auth.mjs
```

## A. Shared backend foundation

- [x] **01 — Verify prerequisites and scaffold the isolated local backend.**
  - Evidence: complete CLI and Docker tested; guarded fresh startup explicitly binds and verifies all published ports at 127.0.0.1 without changing other projects. Startup guard tests pass. At this task-01 checkpoint, Deno was reserved for the later Edge Function tasks.
  - Acceptance: known compatible Supabase CLI and Docker runtime; project-local configuration; signup/anonymous login disabled; no live project linked. Resolve the earlier telemetry sandbox issue safely. Document missing tools rather than substitute a production service.
  - Verify: `supabase --version`, `docker version`, `node scripts/start-local.mjs`, `node --test scripts/local-safety.test.mjs`; inspect only nonsecret health output. Global signup remains disabled while the email provider permits existing-user login.
  - Files: `supabase/config.toml`, `.gitignore`, `scripts/local-safety.mjs`, `scripts/start-local.mjs`, `docs/local-development.md`.

- [x] **02 — Add household membership and restricted provisioning.** Depends on 01.
  - Evidence: 36 pgTAP assertions and 3 real concurrent-session scenarios passed; independent review and SQL lint passed. Local test setup from 01 was sufficient for this synthetic-data verification.
  - Acceptance: unique membership per identity, equal permissions, maximum two members, atomic retry-safe provisioning of verified identities, and no membership writes from ordinary sessions. Revocation blocks new access.
  - Verify: DB tests for positive membership, outsider/anonymous denial, forbidden mutation, duplicate/replayed provisioning, conflicting assignments, and concurrent cap enforcement.
  - Files: household migration, `supabase/tests/database/households.test.sql`, `supabase/tests/database/helpers.sql`.

- [x] **03 — Add purchase constraints and read policies.** Depends on 02.
  - Evidence: 29 purchase-table assertions passed, including bidirectional shared reads, foreign/anonymous denial, tombstones, field constraints, requester/creator consistency, denied direct writes, and preservation of purchases and request uniqueness after creator removal. Independent review found no remaining required changes.
  - Acceptance: validated item fields, immutable household/original requester identity, nullable historical creator attribution, version/tombstone metadata, and shared reads by both spouses. Restrict writes to the intended transactional operations. At this task-03 checkpoint, photo references remained absent and unsupported photo inputs were rejected.
  - Verify: DB tests exercise actual table grants/RLS with both spouses, unrelated and anonymous callers; invalid lengths and forged identity fields fail.
  - Files: items migration, `supabase/tests/database/items.test.sql`.

- [x] **04 — Implement transactional create, update, and delete.** Depends on 03.
  - Evidence: 32 write assertions and five item concurrency scenarios passed, including same-request creates, competing edits, deletion races, and both write/revocation orders. Private original-input ledger preserves retry behavior after edits and deletions. Photo attachment stays disabled until its lifecycle exists.
  - Acceptance: same-request retries create one item; changed payload reuse conflicts; edits check the expected version; deletion is idempotent and cannot be undone by replaying an old create request. Both spouses can change each other's purchases.
  - Verify: DB tests for retries, tombstones, authorization, and competing edits using real transactions.
  - Files: item-write/normalization migrations, `supabase/tests/database/item_writes.test.sql`, `supabase/tests/concurrency/households.mjs` (household and inventory race scenarios).

- [ ] **05 — Implement server search and pagination.** Depends on 03.
  - Progress: lookup/search RPCs and 31 behavioral assertions pass. The 10,000-record benchmark measured warm DB p95 5.616 ms and warm local HTTP p95 8.600 ms over 100 requests each. Restart-first-pass results are separately recorded, but are not independent cold-cache p95; physical-device/cloud AC-09 timing remains pending. See [search-performance.md](search-performance.md).
  - Acceptance: contract-defined token matching, literal wildcard handling, ranking, stable tie-breaks, query/page limits, and household isolation.
  - Verify: DB cases for mixed case, tokens across fields, literal `%`/`_`/backslash, no matches, boundaries, and pagination; record the seeded performance checks from AC-09 separately.
  - Files: search migration, `supabase/tests/database/search.test.sql`, `supabase/tests/performance/search.mjs`.

- [x] **06 — Add local authentication and direct-API integration fixtures.** Depends on functional 02–05; full deployment performance remains a release checkpoint.
  - Evidence: 17 HTTP scenarios pass through actual Auth/PostgREST using password sessions; target refusal, closed signup, sharing/isolation, retry/version behavior, membership revocation, refresh, and sign-out are tested. Fixed local target, in-memory keys, exact generated-fixture cleanup. Node.js built-ins cover this tooling slice without adding a Deno/SDK dependency; Edge Function runtime tests will still use Deno later.
  - Acceptance: isolated synthetic spouses and outsider identities; closed signup tested through HTTP; harness refuses nonlocal targets and never logs credentials.
  - Verify: HTTP tests prove shared item access and denied anonymous/unrelated requests, not only SQL helper behavior.
  - Files: `supabase/tests/integration/local-harness.mjs`, `supabase/tests/integration/inventory.test.mjs`, `supabase/tests/integration/README.md`. No credential `.env` is needed or generated.

## B. Login and persistent inventory

- [x] **07 — Add the Swift dependency, configuration boundary, and unit-test target.** Depends on 01.
  - Evidence: SDK 2.55.1 pinned/resolved, unit target wired, public-key/URL build guard and runtime configuration implemented with explicit setup UI. Simulator configuration/Keychain checks and 92 Ruby assertions pass. See [iOS development status](ios-development.md).
  - Acceptance: compatible pinned Supabase SDK; ignored local configuration with a safe example; only public project configuration reaches the app; missing configuration has an explicit state. Unit tests run in the shared scheme.
  - Verify: package resolution, simulator build, and IOS tests for missing/malformed configuration; retain existing design tests.
  - Files: `ios/HouseKeeping.xcodeproj/project.pbxproj`, shared scheme, generated `Package.resolved`, `ios/HouseKeeping/Data/AppConfiguration.swift`, `ios/HouseKeepingTests/AppConfigurationTests.swift`.

- [x] **08 — Implement authentication and protected sessions.** Depends on 06–07.
  - Evidence: observable session model and adapter support login, launch/foreground restoration, on-demand refresh, household lookup, and verified local sign-out. Unit/transport tests cover failures and token rotation. Actual SDK testing proves both local spouses find the same household, restore Keychain sessions, and sign out independently.
  - Acceptance: separate email/password login, session restoration/refresh, sign-out, normalized errors, and household lookup. Store session credentials in protected storage; never store plaintext passwords.
  - Verify: IOS unit tests for session transitions, absent membership, invalid/expired session, and clearing state; local authentication integration from 06.
  - Files: `Domain/AuthSession.swift`, `Data/SupabaseAuthService.swift`, `Data/KeychainSessionStorage.swift` under the app; `ios/HouseKeepingTests/AuthSessionTests.swift`.

- [x] **09 — Implement initial password setup and recovery.** Depends on 08.
  - Evidence: isolated PKCE recovery client, strict callback/email/user binding, expiry, storage cleanup/retry, and callback serialization pass unit tests. Five local HTTP scenarios verify captured emails, password changes, unknown accounts, wrong verifier/replay/expiry, and no membership bypass. No real email delivery is configured.
  - Acceptance: validated recovery callbacks and expired-link handling, neutral request responses, local email capture, and no signup bypass. Keep local test delivery separate from eventual real email onboarding.
  - Verify: IOS and HTTP tests for valid recovery, mismatched/expired callbacks, password change, and an unrelated account; verify no sensitive URL/token logging.
  - Files: app `Data/SupabaseRecoveryService.swift`, `Services/AuthCallbackHandler.swift`, `Domain/PasswordRecovery.swift`, recovery tests under `ios/HouseKeepingTests`, `supabase/tests/integration/recovery.test.mjs`, `supabase/config.toml`.

- [x] **10 — Connect sign-in, recovery, and account-state screens.** Depends on 08–09.
  - Evidence: setup/sign-in/recovery/account routing and explicit demo are implemented. All 11 UI journeys pass on Pro, including six authentication checks and the original five design checks. Two focused SE checks pass for largest-text sign-in and inventory/review actions. Screenshots and limitations are in [design-preview/README.md](design-preview/README.md).
  - Acceptance: styled native sign-in without registration, recovery/password editor, no-membership state, sign-out, and explicit demo mode. Preserve approved inventory styling.
  - Verify: IOS journeys for login failure/retry, recovery, logout, and account switching; previews stay offline.
  - Files: app `Features/SignInView.swift`, `Features/AccountView.swift`, `Features/PasswordRecoveryView.swift`, `App/HouseKeepingApp.swift`, `ios/HouseKeepingUITests/AuthenticationTests.swift`.

- [x] **11 — Implement typed inventory models and the live adapter.** Depends on 04–05, 07–08.
  - Evidence: typed date/field/query/PATCH models and real SDK repository support search/get/create/update/delete. Offline transport tests cover validation, pagination, retries, normalized failures, cancellation, and late account-switch results. Real local SDK testing proves bidirectional spouse access, edit/delete, create retries, conflicts, and tombstone behavior. UI/store wiring remains in 12–13; see [adapter verification](inventory-development.md).
  - Acceptance: contracts map explicitly between Swift and SQL; cancellation, error normalization, request IDs, and expected versions are preserved. No networking in views.
  - Verify: IOS tests with recorded synthetic responses for field/date decoding, validation, pagination, not-found/conflict, retries, and cancellation.
  - Files: app `Domain/Item.swift`, `Domain/InventoryRepository.swift`, `Data/SupabaseInventoryRepository.swift`, `ios/HouseKeepingTests/InventoryRepositoryTests.swift`.

- [x] **12 — Add live inventory state and durable text drafts.** Depends on 11.
  - Evidence: account/household/project-partitioned atomic text files, ordered autosave, acknowledged cleanup, exact-input retries, explicit conflict rebase, and generation-guarded searches are implemented. Offline tests cover restoration, failures, pagination, stale responses, and failed sign-out cleanup preserving queued edits. Device file-protection verification remains pending. The sign-out warning and actual session/screen wiring belong to 13; see [draft/state verification](draft-state-development.md).
  - Acceptance: stale searches cannot replace newer results; drafts survive relaunch; save acknowledgment is required before clearing a draft; failures preserve edits. Clear account-specific state when signing out, after an unsaved-draft warning.
  - Verify: IOS tests for query races, failed saves, draft restoration, idempotent retry, refresh, and account separation.
  - Files: app `Domain/TextDraft.swift`, `Domain/InventoryDraftController.swift`, `Domain/InventoryStore.swift`, `Data/LocalDraftStore.swift`, `ios/HouseKeepingTests/InventoryStoreTests.swift`, `ios/HouseKeepingTests/LocalDraftStoreTests.swift`.

- [x] **13 — Wire persistent inventory, editor, and details.** Depends on 10–12.
  - Evidence: account-scoped list/search/pagination and fresh details now lead into durable add/edit/delete flows with exact-input retries, conflict review, explicit discard, protected-storage recovery, foreground draft flushing, and acknowledged-save reconciliation. Fifteen Pro UI journeys pass; both connected write/recovery journeys also pass on SE. The real local Swift SDK check proves two-spouse shared CRUD/restoration, and all 18 inventory HTTP tests pass. Details are in [connected inventory status](connected-inventory-development.md).
  - Acceptance: add/search/edit/delete, pull-to-refresh/foreground refresh, loading/retry and conflict recovery work without redesign. Both synthetic spouses find each other's changes after refresh. Demo and connected flows remain distinguishable.
  - Verify: IOS and HTTP suites; connected relaunch and two-user journeys; recheck compact actions on Pro and SE.
  - Files: app `Features/InventoryView.swift`, `Features/PurchaseReviewView.swift`, `App/HouseKeepingApp.swift`, `ios/HouseKeepingUITests/SharedInventoryTests.swift`, `ios/HouseKeepingUITests/DesignPreviewTests.swift`.

**Milestone at task 13:** usable local shared manual inventory. Sections C and D subsequently add private photos, camera capture, and recognition/manual fallback.

## C. Private shared photos

- [x] **14 — Add photo reservations and Storage access policies.** Depends on 04, 06.
  - Evidence: server-generated, retry-safe 24-hour reservations and a private JPEG/5 MiB bucket are installed. SQL and actual Storage HTTP checks prove uploader-only unfinished access, spouse access after a privileged attachment fixture, forged-path/overwrite/direct-delete denial, hidden listing, outsider denial, and immediate revocation. See [photo reservation status](photo-reservations-development.md).
  - Acceptance: private bucket setup via supported tooling, immutable reserved paths, uploader-only unfinished photos, household-readable attached photos, no upload overwrite, and no arbitrary direct object deletion.
  - Verify: DB and HTTP policy tests, including a spouse reading the other's attached image and outsiders forging paths.
  - Files: photos migration, `supabase/functions/media/index.ts`, `supabase/tests/database/photos.test.sql`, `supabase/tests/integration/photos.test.ts`, `supabase/config.toml`.

- [x] **15 — Validate and finalize image bytes.** Depends on 14.
  - Evidence: the pinned pure-JavaScript decoder strictly decodes real JPEG entropy under byte/dimension/memory/time guards, computes SHA-256, and transitions through a service-role-only transaction that rechecks membership, ownership, object existence, expiry, and state. Five function tests, 168 database assertions, and 31 HTTP tests pass, including concurrent completion and malformed/truncated/oversized cases. See [photo validation status](photo-validation-development.md).
  - Acceptance: bounded real JPEG decoding, dimension/size/checksum validation, expiry checks, and readiness transition; reject malformed bytes despite a plausible extension/MIME header. Resolve runtime feasibility before enabling attachment.
  - Verify: FUNCTIONS and HTTP cases for malformed/truncated/oversized images, duplicate completion, unauthorized completion, and time limits.
  - Files: media handler, `supabase/functions/media/validateImage.ts`, `supabase/functions/media/deno.json`, generated Deno lockfile, `supabase/tests/functions/media.test.ts`.

- [x] **16 — Implement atomic attachment and cleanup.** Depends on 15.
  - Evidence: attachment/removal and job creation are transactional; bounded service workers delete Storage first, retry transient failures, reclaim abandoned leases, and then purge metadata. A real simultaneous attach/discard test has one lifecycle winner. See [photo lifecycle status](photo-lifecycle-development.md).
  - Acceptance: attach only own ready unexpired photo in the same household; coordinate attachment/deletion races. Purchase/photo removal and abandoned-upload expiry enqueue retryable Storage API cleanup before metadata purge.
  - Verify: DB, FUNCTIONS, and HTTP checks for competing attach/cleanup, already-deleted objects, transient failures, and both spouses removing shared photos.
  - Files: attachment/cleanup migration, `supabase/functions/cleanup/index.ts`, `supabase/tests/database/photo_lifecycle.test.sql`, `supabase/tests/functions/cleanup.test.ts`, `supabase/tests/integration/photos.test.ts`.

- [x] **17 — Add library selection, photo preparation, and image drafts.** Depends on 12.
  - Evidence: ImageIO fixtures verify orientation, source metadata removal, JPEG/PNG/HEIC preparation, dimension/byte limits, and failure preservation. Protected-file reconstruction and session cleanup tests cover account isolation and late imports. The system-picker/keep-draft UI journey is verified separately. See [photo draft status](photo-drafts-development.md).
  - Acceptance: oriented metadata-free JPEG preparation, upload caps, recoverable image drafts, and explicit discard. Import never changes the source Photos-library image.
  - Verify: IOS fixture tests for orientation, metadata stripping, size limits, relaunch, conversion failure, and account-cache clearing.
  - Files: app `Services/PhotoPreparation.swift`, `Features/PhotoImportView.swift`, `Data/LocalDraftStore.swift`, `ios/HouseKeepingTests/PhotoPreparationTests.swift`, `ios/HouseKeepingTests/LocalDraftStoreTests.swift`.

- [x] **18 — Connect private upload/download to item views.** Depends on 13, 16–17.
  - Evidence: the [private photo adapter and connected screens](photo-service-development.md) provide account-frozen operations, recoverable reservation/readiness checkpoints, exact photo attachment retries, genuine thumbnails/detail images, and confirmed photo removal. Offline lifecycle tests, native synthetic-photo journeys on Pro/SE, and real local-server upload/save/spouse-download checks pass. No personal photos, physical devices, or cloud accounts were used.
  - Acceptance: display genuine attached images; separate upload progress from save state; authenticated downloads for either spouse; expired reservations and failed uploads preserve drafts. Clear or partition all image caches by session/household.
  - Verify: IOS and HTTP end-to-end import/upload/save/download/relaunch flows in both directions and denied foreign access; no fake images in connected mode.
  - Files: app `Data/SupabasePhotoService.swift`, `Features/ConnectedPurchaseEditorView.swift`, `Features/ConnectedInventoryView.swift`, `Domain/PrivatePhotoModel.swift`, `Domain/InventoryStore.swift`, `ios/HouseKeepingTests/PrivatePhotoTests.swift`, `ios/HouseKeepingUITests/SharedInventoryTests.swift`.

**Milestone at the end of section C:** shared inventory and photos, with manual descriptions. Recognition is added by the completed tasks in section D.

## D. Camera and recognition

- [x] **19 — Add native camera capture and permission fallback.** Depends on 17–18.
  - Evidence: the [native camera flow](camera-development.md) requests access only after an explicit camera action, serializes AVFoundation session work, handles denial/interruption/runtime failure, supports preview/retake, and routes accepted bytes through the existing protected preparation/draft pipeline. Four focused unit tests, two synthetic native UI journeys, the full 143-test shared scheme, and a generic iOS build pass. Physical-iPhone permission/capture/orientation/interruption checks remain pending release acceptance.
  - Acceptance: permission requested only when used; capture/preview/retake and denied-permission fallback to import/manual entry; no automatic save to the Photos library.
  - Verify: IOS fixture tests plus authorized physical-iPhone capture, denial, interruption, orientation, and draft recovery checks.
  - Files: app `Services/CameraService.swift`, `Features/CameraCaptureView.swift`, `Features/PurchaseReviewView.swift`, Xcode project, `ios/HouseKeepingTests/CameraFlowTests.swift`.

- [x] **20 — Add recognition authorization, deduplication, and quota records.** Depends on 15–16.
  - Evidence: the [recognition boundary](recognition-boundary-development.md) locks current membership and caller-owned READY photos, serializes request IDs, replays completed results, expires uncertain work into a new-request state, and atomically reserves user/household/project quota. A clean 215-assertion database run, six Deno boundary tests, strict schema/type/format/lint checks, and a real two-session quota race pass. Provider execution stays disabled without consuming quota until task 21.
  - Acceptance: only caller-owned ready uploads may be analyzed; membership checked each time; duplicate/in-flight/replayed requests and limits follow the contract. No direct client writes to analysis/quota state.
  - Verify: DB and FUNCTIONS tests for foreign photo references, revoked membership, concurrent quota reservation, and conflicting request reuse.
  - Files: recognition-state migration, `supabase/functions/recognitions/index.ts`, `supabase/tests/database/recognition.test.sql`, `supabase/tests/functions/recognition.test.ts`.

- [x] **21 — Implement the vision-provider adapter with fake-response tests.** Depends on 20.
  - Evidence: the [recognition provider adapter](recognition-provider-development.md) requires explicit server-only provider/model/key/cost settings, checksum-verifies the authorized private JPEG, uses a strict structured-output schema, bounds the whole provider response to 25 seconds/64 KiB, and persists completed or ambiguous outcomes without touching purchases. A clean 225-assertion database run and 11 offline Deno tests cover refusals, malformed/incomplete output, multiple products, absent brand/model, timeout, and retry ambiguity. No provider request was made.
  - Acceptance: configurable provider/model, validated structured suggestions, bounded timeout, and redacted logs. No saved purchase changes and no unreviewed exact-product claims. No real paid calls during automated testing.
  - Verify: FUNCTIONS cases for refusal, malformed output, multiple products, absent brand/model, timeout, and retry ambiguity.
  - Files: recognition handler, `supabase/functions/recognitions/provider.ts`, `supabase/functions/recognitions/schema.ts`, `supabase/tests/functions/recognition.test.ts`, `fixtures/recognition/README.md`.

- [x] **22 — Connect editable recognition suggestions and fallback.** Depends on 18–21.
  - Evidence: the [editable recognition flow](recognition-flow-development.md) discloses live provider use, explicitly labels offline samples, persists request identity before the call, separates upload/recognition progress, keeps manual save available, and applies a result only to the same unchanged active draft and image. Seven focused tests, the complete unit/UI targets, and a real localhost unconfigured-provider/manual-save journey pass without a provider call.
  - Acceptance: clearly separate sample and real suggestions; show consent/progress/manual continuation; late results never overwrite edits or resurrect a dismissed draft; explicit confirmation still required.
  - Verify: IOS and local HTTP journeys for suggestion review/edit/save, timeout/manual save, stale results, and cancellation.
  - Files: app `Data/RecognitionClient.swift`, `Domain/InventoryStore.swift`, `Features/PurchaseReviewView.swift`, `ios/HouseKeepingTests/RecognitionFlowTests.swift`, `ios/HouseKeepingUITests/SharedInventoryTests.swift`.

- [ ] **23 — Evaluate recognition with authorized photos and budget.** Depends on 21–22; requires provider and spending approval.
  - Progress: the [bounded evaluation plan and runner](recognition-evaluation.md) validate the five-category 40-image manifest, bind approval to the manifest and every image hash, restrict candidates to GPT-5.6 Luna/Terra, reserve at most $0.80 under a hard $1 ceiling, checkpoint only sanitized results, and score complete manual reviews against AC-10/AC-11. All 23 function tests and a synthetic 40-JPEG approval-gate dry run pass; no representative evaluation image or provider request has been used.
  - Acceptance: evaluate the spec's representative photo set, record usefulness/unsupported claims/latency/cost, and pin the chosen model configuration. Do not silently weaken release criteria when evaluation fails.
  - Verify: reproducible evaluation report against AC-10/AC-11; manual review of failures; no personal images committed.
  - Files: `docs/recognition-evaluation.md`, `fixtures/recognition/manifest.example.json`, `scripts/evaluate-recognition.ts`, `supabase/tests/functions/recognition-evaluation.test.ts`, and the provider configuration selected after evaluation.

## E. Private deployment and acceptance

- [ ] **24 — Prepare the approved cloud target and account onboarding.** Depends on local backend/photo/auth checkpoints; requires explicit project and real-account targets.
  - Progress: the [deployment gate](deployment.md) and [two-account onboarding runbook](account-onboarding.md) define the exact target review, migration dry run, approved write sequence, email/deep-link handling, rollback stop conditions, and bidirectional smoke matrix. The approved cloud project has all 17 migrations, the private bucket, two verified users, their shared household, and active JWT-protected `media` and `cleanup` Edge Functions. Recognition remains undeployed with no provider key. Hosted photo/recovery/two-account smoke evidence, account-maintenance deployment, and backup proof remain open. Seven offline audit contract tests and the local audit snapshots pass without exposing credentials or personal records.
  - Acceptance: review migration changes for the identified project; verify private bucket and closed signup settings; provision only the two verified identities securely. Configure authorized email delivery and tested recovery redirects. No credentials in chat/source and no unapproved messages or paid plan.
  - Verify: remote read-only configuration audit before writes, then both users' authorized login/recovery and bidirectional inventory/photo smoke checks.
  - Files: `docs/deployment.md`, `docs/account-onboarding.md`, `supabase/config.toml`, ignored app/environment configuration examples as needed (maximum two files).

- [ ] **25 — Implement operator-assisted account removal and recovery operations.** Depends on 16, 24.
  - Progress: the [account removal and recovery runbook](recovery-runbook.md), service-role-only Edge Function, and migration implement membership-first revocation, checksum-verified attached-photo ownership transfer, retry cleanup for unfinished photos and closure, unknown-object blocking, Auth deletion ordering, and delayed record purge. Five offline transfer tests and all 254 database assertions pass, including old-JWT denial and spouse-visible purchase/photo retention. A three-test local HTTP suite also passes against actual Storage copy/move/delete and Auth Admin operations with generated identities and bytes. The database/object backup set and isolated exact-byte restore are specified separately. No real identity/object was changed; hosted removal/closure and restore evidence still depend on task 24.
  - Acceptance: verified removal request revokes access without deleting the spouse's purchases; explicit household closure cleans up photos with retries. Configure and document records-and-objects backups without conflating database backups with image backups.
  - Verify: isolated test removal/closure and restore of one item plus image; repeat-safe cleanup and failure visibility. Never run destructive tests against the actual household.
  - Files: `supabase/functions/account-maintenance/index.ts`, `supabase/tests/functions/account-maintenance.test.ts`, `supabase/tests/integration/account-maintenance.test.ts`, `docs/recovery-runbook.md`.

- [ ] **26 — Set up the chosen private iPhone distribution method.** Depends on 24; requires user choice and signing access.
  - Progress: the [private installation decision](private-installation.md) recommends Ad Hoc distribution for the two registered household phones and records the TestFlight fallback, Personal Team rejection, signing/privacy boundaries, archive inspection, install/update/revocation procedure, and renewal evidence. No Apple account, identifier, certificate, profile, device, archive, build, or invitation has been touched; the final bundle ID, signing team, and two authorized phones remain required inputs.
  - Acceptance: documented installation/update method for both phones without public listing; disclose any signing/renewal constraints after verifying the selected method. No public submission or unrelated signing changes.
  - Verify: install an authorized build on both phones; verify configuration is the intended environment, with no bundled administrator secrets.
  - Files: Xcode project, shared scheme, `docs/private-installation.md`.

- [ ] **27 — Complete two-phone release checks.** Depends on 19, 22–26.
  - Progress: the [release acceptance matrix](acceptance-results.md) maps every AC to existing evidence, the exact hosted/two-phone evidence still required, and the recognition-disabled gate. No open row is represented as a release pass.
  - Acceptance: record every relevant AC result, including shared photos, conflicting edits, recovery, accessibility, camera permission, cleanup, and backup restore. Unmet criteria remain explicitly open; do not call the app ready because only the preview tests pass.
  - Verify: DB, FUNCTIONS, HTTP, IOS, and authorized real-device acceptance matrix; visual inspection of approved styling/compact actions and manual VoiceOver checks.
  - Files: `docs/acceptance-results.md`, `docs/design-preview/README.md`, `README.md`.

## F. Incremental inventory improvements

- [x] **28 — Add per-item restock limits.** Depends on 13.
  - Evidence: the [stock-value specification](item-quantity.md) records the compatible
    domain, draft, UI, and database implementation. The complete iOS scheme, 306 pgTAP
    assertions, 18 inventory HTTP tests, schema lint, formatting, and configuration/safety
    checks pass locally. The seventeenth migration was deployed to the approved cloud project on
    2026-09-18 and its migration history was verified afterward.
  - Acceptance: both household members can create, view, reload, and edit nonnegative
    quantity and limit values; older rows and drafts default to 1; “Restock now” appears
    exactly at or below the limit; recognition and unrelated edits preserve both values.
  - Verify: domain compatibility and validation tests, two-account UI create/edit journey,
    database request/replay/conflict tests, direct constraint check, and HTTP reload checks.
  - Files: item/draft/store models, inventory/editor views and tests, restock-limit migration
    and pgTAP/HTTP tests, README, product/contract/user/deployment documentation.

## Approval boundary

Approve this task list as one local implementation program; routine task transitions then need no repeated product approval. Separate authority is still needed for the explicitly marked live-project, account/email, paid-provider, and device-distribution steps. If scope or privacy behavior materially changes, stop and review that change. Mark a task complete only with its recorded verification evidence.
