# Specification: HouseKeeping for iPhone

Status (2026-09-18): SwiftUI + Supabase, a private two-person household, and email/password authentication are confirmed. The approved project has all 17 migrations, its private photo bucket, both household members, and authenticated `media` and `cleanup` Edge Functions. Connected inventory and photo behavior are verified locally; hosted photo/device acceptance, recovery proof, private installation, and two-phone acceptance remain open. Recognition is disabled in the production app and undeployed until a provider, server-side key, evaluation, and spending limit are separately approved.

## Objective

Help a household answer “what did we buy?” by recording purchases and finding them by name or description. A photo can be saved normally without AI. Optional recognition may reduce typing later by turning a photo into editable suggested details.

Core workflow: take or choose photo → enter/edit details → confirm → save → search later. Optional future workflow: explicitly request suggestions → review/edit every suggested field → confirm → save.

Success means a user can record and retrieve an item without knowing its exact product model, and a recognition error cannot silently create a misleading purchase record.

## Scope and assumptions

Core release: native iPhone app, authenticated private inventory, manual entry, photo capture/library selection, optional recognition, editable details, list/search/detail screens, edits, deletion, and durable local drafts.

Confirmed household scope: the user and his wife have separate accounts in one shared household. Both can view every saved item and its attached photo, add purchases, edit details, remove photos, and delete purchases regardless of who originally created them. The app will not have a public App Store listing. Private distribution and backend authorization are separate concerns.

Proposed defaults: one photo per purchase, English interface, iOS 18 or later, online cloud operations, and durable local drafts without full offline synchronization. Confirmed login method: email/password with two administrator-provisioned accounts. No shared password, public signup, anonymous login, additional login providers, in-app invitations, or household switching is included.

Out of scope: Android/web clients, retailer integrations, receipts with multiple line items, guaranteed SKU identification, price lookup, budgeting, automatic stock depletion, restock notifications, shopping lists, barcode catalog services, visual similarity search, semantic search, and full offline synchronization.

## User flows

### Open and find a purchase

After authentication, open the inventory with a search field and Add action. An empty inventory explains how to add the first item. Results show name, quantity on hand, restock limit, thumbnail when present, and description preview. Items at or below their limit are labeled “Restock now”; zero quantity is additionally labeled “Out of stock”. Selecting a result opens the saved details.

Search uses trimmed case-insensitive query tokens against confirmed name, description, brand, and model. All tokens must match; order does not matter. Examples: `KETTLE` matches “Black electric kettle”; `black kettle` may match “Electric kettle” with description “Black, stainless steel”; `dish` matches “dishwasher.” Synonym and typo correction are not promised.

Empty query lists recent purchases. Use a 250 ms typing debounce and cancel or ignore stale responses. Display loading, no matches, offline, and retry states distinctly. Query limit: 200 characters and 8 tokens. Treat SQL wildcard characters literally. Fetch 50 results at a time, up to 100 per page. Reset pagination on query changes and refresh.

### Add manually

Require a nonblank name (1–200 characters after trimming). Description is optional (up to 2,000 characters). Brand/model are optional (100 characters each). Purchase date is optional; do not substitute record creation time for an unknown purchase date. Save accepts an optional photo. Quantity on hand and restock limit each default to 1 and accept whole numbers including zero; either household member can edit them. Restocking is needed when quantity is less than or equal to the saved limit. See [item quantity and restock limit](item-quantity.md) for validation and compatibility. Price, retailer, and room remain deferred.

Each record represents a purchase entry, not a canonical product. Buying the same named product twice can create two entries. The system must not merge records just because their names or images resemble one another.

### Add with a photo

1. Choose camera or system photo picker. Request camera permission when used; denial leaves library selection and manual entry available.
2. Preview the selected image and allow a retake. Persist the draft before network work. Normal photo saving must not depend on recognition. Show a recognition action only when the feature is configured and enabled; that action must explain that the photo is sent to an AI service to suggest details.
3. Normalize orientation and re-encode a JPEG with metadata removed, a maximum long edge of 2,048 pixels, and a 5 MiB upload cap. Show an actionable error if conversion fails. These are app limits, not claims about provider limits.
4. Upload privately and validate the actual image bytes server-side. Do not trust filename, MIME header, client-supplied dimensions, or storage path alone.
5. Show upload and recognition progress separately when recognition is enabled. Manual entry and saving with the photo remain available without recognition. Once upload completes, recognition failure must not prevent a manual save with the photo.
6. Show suggested fields as editable. Missing identity returns a neutral result and suggests retaking the photo or typing a name. Do not show uncalibrated numeric confidence as a probability.
7. Save only on the user's explicit confirmation. A late recognition response cannot overwrite fields the user has edited or a draft they have left.

Recognition operates on one product per photo. If multiple products are visible, ask the user to retake with one item; do not create several purchases implicitly. Never derive price, purchase date, or retailer from product appearance. Visible branding/model text may support a suggestion, but still requires user review.

### Edit and delete

Save edits with the version originally loaded. If it has changed, retain the local draft and offer reload/review of the newer record. No silent overwrite. Initial photo handling supports adding a photo at creation and removing it later; replacing a saved photo is deferred.

Confirm deletion in the app. Hide deleted records immediately after acknowledgment. Schedule related object deletion with retries; target removal from active storage within 24 hours. Recovery from operator backups, if configured, follows the documented retention schedule and does not mean an in-app Undo feature exists.

### Shared household for two

A trusted administrator provisions the two confirmed identities and assigns them to one household. Household membership cannot be created or edited from an ordinary app session. Server-side provisioning must reject a third member and assigning either user to another household. Keep public signup disabled; an authenticated identity without membership still has no inventory or photo access.

Saved purchases and attached photos belong to the household, not to a private per-user collection. Unsubmitted local drafts and unattached uploads remain visible only to their author until saved. Sharing does not require copying the item or photo into a second account.

Refresh on app foreground, pull-to-refresh, and after an acknowledged local write. Automatic live updates while both apps remain open are deferred; show loading, last-updated, and retry states honestly. Version checks protect against simultaneous conflicting edits.

An operator can revoke membership. Every new request must recheck access; app-owned caches are cleared when revocation is discovered. Already downloaded files cannot be remotely recalled. This setup does not expose invitations, member administration, or ownership transfer in the app.

### Account lifecycle

Sign-out clears app-owned drafts, caches, and credentials after warning about unsaved drafts. Account removal is an authenticated operator-assisted process for this private deployment: revoke membership and sessions, then remove the identity while retaining the other person's shared inventory. Purchase attribution may become “Former member”; deleting an auth identity must not cascade-delete purchases. Closing the household and deleting all its data requires an explicit request and verified cleanup. Complete photo cleanup before purging the metadata needed to retry it.

## Data handling and security

- Persist photos in a private Supabase Storage bucket; persist object references and purchase details in PostgreSQL.
- Require active household membership for every record read/write, photo download, and recognition request. Deny access by default.
- Keep local drafts and credentials in appropriate protected app storage; credentials use Keychain. Exclude temporary photo drafts from cloud device backups where appropriate to the chosen retention policy.
- Keep service-role and AI keys on the server. The iOS app contains only public project configuration and its user's session.
- Restrict SQL function execution grants, fix search paths for privileged functions, and validate authorization inside every elevated operation.
- Do not let clients mutate household membership, photo readiness, creator identity, analysis results, or server timestamps directly.
- Store no raw AI output in logs. Validate third-party output before presenting it. Photo contents are input data and cannot grant the model tools or permission to change records.
- Authenticated downloads are the default. Do not store expiring URLs in purchase rows.
- Document provider data handling and backup retention before release. Deleting an app photo must not be described as deleting every provider log or existing backup instantly.

## Tech stack

SwiftUI and Supabase are selected. Supabase Swift 2.55.1 and the function dependencies are pinned in the repository. The recognition provider/model remains disabled, unselected, and undeployed pending an authorized evaluation.

| Area | Technology |
| --- | --- |
| iPhone UI | SwiftUI, Swift concurrency, native navigation/forms |
| Capture/import | AVFoundation camera integration and PhotosPicker |
| Local drafts | Codable files in protected Application Support storage; no sync engine |
| Backend | Supabase Auth, hosted PostgreSQL, private Storage |
| Server logic | Supabase SQL functions and TypeScript Edge Functions on Deno |
| Recognition | OpenAI Responses API candidate, image input plus structured output; model configurable server-side |
| Search | PostgreSQL token/substring search and pg_trgm indexing |
| Tests | Swift Testing for app logic, XCTest/XCUITest for UI, Deno tests, SQL/pgTAP policy tests |

Use iOS 18 as the minimum. Local inspection found Xcode 26.6 (build 17F113). `Package.resolved` and function lockfiles pin the locally verified dependencies. The provider model remains deliberately unpinned until recognition evaluation is authorized and performed.

## Project structure

The SwiftUI app, design components, explicit demo, authentication/recovery services and screens, and tests exist. All 17 migrations plus the photo `media` and `cleanup` functions are deployed to the approved project. Authentication is connected; the [inventory adapter](inventory-development.md) is tested against both local spouses, and [durable text drafts/inventory state](draft-state-development.md) have offline coverage. [Connected manual inventory and account lifecycle](connected-inventory-development.md) are implemented through editor/write recovery and verified two-account journeys. [Image drafts](photo-drafts-development.md), backend media/cleanup, [app photo upload/save/thumbnail/detail display](photo-service-development.md), photo removal, and the [native camera flow](camera-development.md) are implemented. The [recognition authorization/quota boundary](recognition-boundary-development.md), offline-tested [provider adapter](recognition-provider-development.md), and [editable review/fallback flow](recognition-flow-development.md) remain in source and tests, but the production composition and cloud deployment omit recognition. Service-role-only [member removal and household closure](recovery-runbook.md) are locally verified. Authorized provider evaluation and remaining hosted release proof remain open. See [design.md](design.md) for the interface scope and [local-development.md](local-development.md) for backend evidence.

```text
ios/HouseKeeping.xcodeproj       Xcode project and shared schemes
ios/HouseKeeping/App/            Composition root and navigation
ios/HouseKeeping/Features/       Inventory, item editor/detail, capture, settings
ios/HouseKeeping/Domain/         Models, repository protocols, app errors
ios/HouseKeeping/Data/           Supabase adapters and local draft storage
ios/HouseKeeping/Services/       Camera, photo preparation, recognition client
ios/HouseKeepingTests/           Swift logic tests
ios/HouseKeepingUITests/         UI journey tests
supabase/config.toml            Local service configuration
supabase/migrations/            Schema, constraints, policies, SQL functions
supabase/functions/             Media, recognition, cleanup, and account-maintenance handlers
supabase/tests/database/        SQL access and transaction tests
supabase/tests/concurrency/     Competing database-session tests
supabase/tests/functions/       Function tests with fake provider responses
fixtures/recognition/           Synthetic/licensed test cases; no personal photos
docs/                           Architecture, specification, and contracts
```

## Code style

Use feature folders, `UpperCamelCase` Swift types and `lowerCamelCase` members. Keep views free of networking and SQL. Use `async/await`, cancellation, and explicit error states. Avoid a large framework of generic repositories. Wire concrete adapters at the composition root and fake adapters in tests.

Illustrative contract style; the referenced domain types are specified in [contracts.md](contracts.md):

```swift
protocol InventoryRepository: Sendable {
    func search(_ query: ItemQuery) async throws -> ItemPage
    func create(_ input: CreateItemInput) async throws -> Item
    func update(_ input: UpdateItemInput) async throws -> Item
    func delete(id: UUID, expectedVersion: Int) async throws
}
```

Use four-space Swift indentation, two-space TypeScript indentation, explicit TypeScript types at boundaries, and `strict` checking. Use snake_case for SQL storage and camelCase for app/service DTOs, with explicit mappings. Backend input and provider output require schema validation; normal internal values should not be repeatedly revalidated.

## Commands

These are the current command contracts. Follow the [local run guide](local-user-guide.md) for prerequisites, safe startup, connected configuration, and the complete test sequence. Run commands from the repository root unless noted.

```sh
# Start the localhost-only backend and its configured functions.
node scripts/start-local.mjs

# Open the app and discover installed simulator destinations.
open ios/HouseKeeping.xcodeproj
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -showdestinations

# Resolve packages and build without device signing.
xcodebuild -resolvePackageDependencies -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/housekeeping-derived-data CODE_SIGNING_ALLOWED=NO build

# Set HK_SIMULATOR_ID to an installed destination UUID from -showdestinations.
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -destination "platform=iOS Simulator,id=${HK_SIMULATOR_ID}" -enableCodeCoverage YES -derivedDataPath /tmp/housekeeping-derived-data test

# Formatting, analysis, and backend tests.
xcrun swift-format lint --recursive --strict ios/HouseKeeping ios/HouseKeepingTests ios/HouseKeepingUITests
deno fmt --check supabase/functions supabase/tests/functions
deno lint supabase/functions supabase/tests/functions
deno test --config supabase/functions/media/deno.json supabase/tests/functions/media.test.ts
deno test --config supabase/functions/cleanup/deno.json supabase/tests/functions/cleanup.test.ts
deno test --config supabase/functions/recognitions/deno.json supabase/tests/functions/recognition.test.ts
deno test --config supabase/functions/account-maintenance/deno.json supabase/tests/functions/account-maintenance.test.ts
supabase test db
```

Unit tests must use injected adapters so they need no AI keys or external network. Local integration tests may use explicit localhost-only permissions when needed. Keep `.env.local` ignored. Use local migrations and test fixtures without resetting a shared or production database. Deployment and live AI evaluation are separate future operations, not actions performed by these documentation changes.

## Testing strategy

Test app validation, draft persistence, stale-response suppression, search normalization, and edit conflicts with Swift Testing. Use XCUITest for add/search/edit/delete and manual fallback. Use fixtures for photo flows in simulators; verify real capture and permissions on a physical iPhone.

Use two authenticated test users in the same household to prove bidirectional access to saved purchases and actual stored image bytes. Use a third unrelated authenticated identity, a foreign-household fixture, and an anonymous caller to test denials, including forged household IDs and photo references. Test revocation, simultaneous edits, and rejecting third-member provisioning. SQL tests must check actual RLS behavior and transaction races, not only helper functions; Storage HTTP tests must prove both members can download each other's attached photos.

Function tests cover expired auth, foreign photo IDs, invalid image bytes, limits, incomplete uploads, duplicate requests, provider timeout/refusal/malformed JSON, and late responses. Integration tests exercise upload → ready photo → suggestion → confirmed save, including failures between storage and database operations. All automated provider tests use recorded synthetic/fake responses.

Evaluate the actual recognition model separately on at least 40 representative, authorized photos: labeled packaging, unbranded objects, poor lighting, small labels, and multiple products. Record editable name usefulness, unsupported brand/model claims, latency, and cost. Choose the model based on this evidence, then pin its version/configuration. Targets below are proposed release criteria, not achieved results.

Coverage expectations: every access-control rule and recovery path has a behavioral test. No blanket line-coverage percentage substitutes for those tests. Run the appropriate app/backend suites after changes; documentation edits need structural/link checks only.

## Success criteria

| ID | Testable condition |
| --- | --- |
| AC-01 | A signed-in user creates a named purchase manually and finds it after restarting the app. |
| AC-02 | Search returns records matching name/description fragments and all query tokens, regardless of case; foreign household records never appear. |
| AC-03 | A real iPhone captures a photo; its validated upload remains accessible after app/backend restart. |
| AC-04 | Recognition creates an editable suggestion; no purchase row exists until confirmation. |
| AC-05 | Denied camera permission, offline access, failed upload, or failed recognition leaves the typed draft recoverable and shows a usable next action. |
| AC-06 | Repeating a save with the same request ID produces one purchase; stale edits cannot overwrite a newer version. |
| AC-07 | An unauthenticated or unrelated user cannot read/mutate purchases, access photos, or spend AI quota through forged references. |
| AC-08 | Discarded uploaded photos expire after 24 hours; deleting a purchase removes active photo objects within 24 hours under healthy service conditions, with retry visibility on failures. |
| AC-09 | Server search p95 is at most 500 ms for 10,000 seeded records over 100 representative queries; measure cold and warm results separately. End-to-end results target 1.5 seconds on a measured stable connection. |
| AC-10 | Recognition returns a suggestion within 15 seconds p95 in the evaluation environment; after 30 seconds the app offers retry/manual entry. Report actual network/device/model conditions. |
| AC-11 | At least 90% of the single-product evaluation images receive a useful editable name/description; unsupported exact brand/model claims are release failures to investigate, not accepted identities. |
| AC-12 | Dynamic Type, VoiceOver labels, keyboard dismissal, loading/retry states, and touch targets work on the smallest supported iPhone layout. |
| AC-13 | Operator-assisted account removal revokes access without deleting the remaining member's shared inventory; explicit household closure leaves an auditable cleanup result. |
| AC-14 | A restore exercise recovers both a sample purchase and its image from the configured backups/exports. |
| AC-S1 | Each spouse can find, view the photo of, edit, and delete a purchase saved by the other after refresh, without copying records or sharing credentials. |
| AC-S2 | Public signup and anonymous login are disabled; an unrelated authenticated account or revoked member cannot make new authorized inventory or photo requests. |
| AC-S3 | Ordinary app sessions cannot create households or alter membership; privileged provisioning rejects a third member or a second household membership. |
| AC-S4 | If both spouses edit the same version, exactly one update succeeds and the other receives a conflict with its local draft preserved. |

## Boundaries

- Always: enforce authorization at backend boundaries; preserve drafts on failure; keep AI suggestions separate from saved items; validate external data; run relevant tests; update contracts when behavior changes.
- Resolve with the user when necessary: adding new platforms, changing agreed privacy/retention behavior, provisioning paid services without existing authorization, or expanding into receipt parsing/full offline sync.
- Never: embed server secrets in iOS, make household images public, auto-save AI output as confirmed purchases, log personal images/tokens, or use destructive production resets.

## Open decisions

The user has selected SwiftUI + Supabase and confirmed shared access for himself and his wife, with no public App Store listing. Sharing is mandatory, not an extension. Full offline synchronization remains outside the proposed initial scope.

Email/password is confirmed; there is no remaining login-method decision. Ad Hoc distribution is the documented recommendation, pending the final bundle ID, signing team, and two registered phones. Before deployment, identify the Supabase project and region and approve the backup/retention configuration. Recognition stays disabled unless a later authorized evaluation selects a model and spending limit. No project creation, account provisioning, paid plan, or external invitation is authorized merely by this document.
