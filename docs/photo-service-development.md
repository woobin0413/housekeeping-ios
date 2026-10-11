# Private iOS photo adapter

Task 18 connects the `PhotoService` adapter, recoverable upload state, and save coordinator to new-purchase editors. List thumbnails and purchase details display genuine private photos; details offer confirmed removal while retaining the purchase. Local verification is described below; physical-device/cloud release checks remain separate.

## Contract and privacy boundary

Reservation, upload, completion, authenticated download, and discard are separate operations. The caller owns the reservation request UUID and must persist it before network work. No mutation is automatically retried. `CreateItemInput` now optionally encodes `photoId` using the existing transactional attachment contract; callers without photos retain their previous wire shape.

The adapter captures one account/household and authentication generation. Auth refreshes and verifies the account, persists its credential, then freezes that credential into the request. A response arriving after sign-out is rejected. Tokens never enter photo models or views. Only fixed same-project media, metadata, and Storage routes are used, and redirects are refused.

Uploads validate prepared bytes and reservation ownership/path/expiry, send JPEG with `x-upsert: false`, and leave the local draft untouched on failure. Downloads first read the photo metadata under RLS, require an attached photo in the active household, validate the server-generated path, then verify downloaded size and SHA-256. Metadata responses are bounded at 64 KiB and image responses at 5 MiB, including responses with no declared length. Stream assembly runs off the main actor. No public/signed image URLs or shared image cache are created; URLCache reads/writes are disabled for these requests.

The Storage behavior follows Supabase's [upload authorization](https://supabase.com/docs/reference/swift/storage-from-upload) and [private download](https://supabase.com/docs/guides/storage/serving/downloads) contracts. The adapter uses the existing verified Auth session with a bounded URLSession transport so it can refuse redirects and oversized responses before retaining a complete body.

## Verification

The final offline adapter/authentication/inventory regression run passes 30 test declarations (33 parameterized executions) on iPhone 17 Pro / iOS 26.5. Six new photo-adapter tests cover authenticated routes, other-spouse downloads, path and state validation, checksum corruption, byte limits, expiry, normalized failures, explicit retries, and stale/late responses after sign-out.

The real local photo HTTP suite passes all 11 tests, including uppercase/lowercase completion requests. Swift's uppercase UUID paths exposed a backend comparison bug: finalization could succeed but return HTTP 500 when compared to a lowercase database UUID. The media handler now canonicalizes path IDs before comparing them or replying. The local Edge runtime needs a restart to load changed handler code.

The opt-in iOS integration runner passed on iPhone SE (3rd generation) / iOS 18.3.1 after preparing synthetic images and exercising reservation replay, upload, completion replay, atomic attachment, exact-byte downloads in both directions, adapter reconstruction, denied unfinished/deleted reads, and discard. Its cleanup resolves only the generated household's object keys through guarded local SQL, removes bytes through the Storage API, and then purges fixture metadata/accounts. On Storage cleanup failure, metadata remains for retry. No cloud project, personal photo, physical device, or AI call is involved.

Pre-merge review checked the optional wire contract, ownership/path validation, frozen credentials, bounded off-main response handling, failure normalization, and Storage-first fixture cleanup. Handler type-check/lint/format checks and the runner's Node syntax check pass. The earlier Pro integration attempt failed before tests launched because the simulator was busy; it is not counted as app verification.

## Recoverable upload state

The image file can now include its reservation request UUID, returned reservation, and readiness. These optional fields preserve compatibility with earlier photo files. Every checkpoint is atomic with the same prepared bytes: the request UUID is saved before reservation, the reservation before upload, and readiness before purchase submission. This deliberately rewrites a bounded image file to avoid separate-file consistency rules.

On explicit retry, completion is checked before sending bytes. If an upload succeeded but its response was lost, completion recovers readiness without another upload. Expired known reservations receive a new persisted request identity; an explicit expiry response also clears an unknown reservation checkpoint when its original response was lost. Conversion, network, and checkpoint errors do not remove the prepared image.

Upload stages are separate from purchase saving. Session closure drains in-progress upload/checkpoint work before clearing local files. Work-generation checks prevent an older completed task from releasing a newer task's lifecycle guard. Purchase drafts persist `photoId` alongside their exact request and fields before submission; reconstruction and retries cannot replace that photo ID with a new selection.

Six controlled upload tests pass for lost reservation/upload responses, local and server-reported expiry, persistence failures, and close during upload. The broader draft/photo regression run passed 37 declarations with one expected physical-device-only skip; the final six-test upload suite passed separately after the explicit-expiry refinement. Draft-controller tests verify frozen photo/request replay; real protected-file round trips now include readiness and reservation state. Review covered checkpoint ordering, unchanged image bytes on failure, account validation, and close/write races. Screen integration still needs to use these APIs, distinguish upload from save progress, and avoid starting a new upload for an already-submitted purchase command. Remote abandoned reservations remain subject to the backend expiry/cleanup policy.

## Coordinated photo saves

`InventoryStore.saveDraft` now coordinates a matching account's photo service and text draft. Editable purchases validate their fields before upload; READY photo IDs are then persisted in the exact purchase command before submission. Already-submitted or acknowledged drafts bypass upload entirely, including after reconstruction or reservation expiry. Successful acknowledgment clears both protected files and the in-memory photo. Screens have not yet opted into the service.

The new migration distinguishes `PT409`/`PHOTO_NOT_READY` from generic conflicts. It is emitted only after the original-request ledger lookup, before creating a purchase or ledger entry. A definite rejection returns the text draft to editing with a durable rejected-photo marker. On explicit retry, the image checkpoint is reset before that marker is cleared, then a fresh upload can use the same purchase request UUID. Unknown failures keep the original command frozen. Failed reset writes preserve the marker across reconstruction. Sign-out drains reset writes as well as upload writes before clearing files.

Seven coordinator tests pass for successful cleanup, uncertain-response replay, definite rejection/reconstruction, failed checkpoint reset, sign-out during upload/reset, invalid fields, and account mismatch. The combined coordinator/store/connected-inventory/upload regression run passes, as does the focused repository error-mapping suite. All 192 database assertions, strict schema lint, and 11 photo HTTP tests pass. The real Swift SDK test on iPhone SE / iOS 18.3.1 now additionally imports a synthetic image through the coordinator, saves its purchase, checks both local files are cleared, and verifies an exact-byte download and deletion by the other spouse.

Pre-merge review checked request replay ordering, additive persisted fields, permission-preserving SQL replacement, account matching, bounded image writes, and sign-out races. Review found and fixed an untracked checkpoint-reset write; its new regression verifies no late write can recreate discarded data. Task 18 remains open for connected photo screens and their native UI verification.

## Connected editor and detail photos

The production factory now supplies the account-frozen photo service. The editor enables photo saves, shows reservation/upload/validation separately from purchase saving, and locks selection, fields, and dismissal during coordinated submission. Unknown save outcomes retain their exact retry action. An orphaned local photo resumes a new purchase instead of being silently attached to an existing item's text edit.

Detail downloads are decoded off the main actor, with source-byte/dimension limits and a 1,024-pixel display cap. A single session-owned image model holds the result; there is no disk or global cache. Detail changes, retirement, sign-out, and detected access loss clear the image immediately. Generation checks reject late download/decode results. Missing/corrupt/offline photos show a retry state rather than sample artwork. Upload authentication failures also send the user to account revalidation without discarding their draft.

The explicitly labeled, Debug-only inventory preview has a memory-only photo service for native UI journeys; live failures never construct it. Actual local-server SDK tests remain separate from those UI fixtures. Five new display/state tests cover bounded decode, late-response clearing, malformed/error/retry behavior, other-spouse display, retirement, orphan drafts, and access-loss handling. The combined focused regression run passes 35 tests. The real local Swift SDK upload/save/spouse-download smoke test passed again after production wiring.

### Synthetic system-picker fixture

The opt-in UI test selects only a generated image with the distinctive date January 2, 2030. It skips unless explicitly enabled. Create a fresh temporary directory, then run:

```sh
photo_fixture_directory=$(mktemp -d /tmp/housekeeping-photo-ui.XXXXXX)
swift scripts/make-ios-photo-fixture.swift "$photo_fixture_directory/housekeeping-fixture.jpg"
xcrun simctl addmedia <simulator-UUID> "$photo_fixture_directory/housekeeping-fixture.jpg"
TEST_RUNNER_HK_PHOTO_UI_FIXTURE=1 xcodebuild test \
  -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping \
  -destination 'platform=iOS Simulator,id=<simulator-UUID>' \
  -parallel-testing-enabled NO \
  -only-testing:HouseKeepingUITests/SharedInventoryTests
```

The helper refuses an existing output path and creates only geometric artwork. Do not substitute a personal photo or run fixture seeding against a physical device. The UI selector accepts the system's zero-padded day format. The seeded image remains in that simulator library for repeatable tests; neither import nor app discard modifies it.

The new native journey passes on iPhone 17 Pro / iOS 26.5 and iPhone SE / iOS 18.3.1: import the selected fixture, save, sign out, sign in as the other spouse, display the image, and delete the purchase. Its retained Pro screenshot was visually reviewed. The first attempts exposed test selectors rather than app failures: the picker uses a zero-padded day and exposes no normal accessibility hit point for its visible grid image, and the taller editor needs the name field scrolled above the bottom save bar. The final test uses the date-identified element's center only after checking its bounds. The real SE/server check also verifies the new detail decoder receives a 64 × 32 image and clears it on retirement.

The complete offline unit suite passes 115 test declarations with two expected environment-gated skips. A full UI rerun exposed an unrelated flaky Command-A selection in the existing text-edit journey; that test now uses native paragraph selection instead of depending on simulator hardware-keyboard routing. The final four-test shared-inventory UI suite passes after this correction. Read-only cleanup checks returned zero disposable users, households, photo records, and Storage objects.

Review covered production versus explicit-preview injection, source-byte/dimension bounds, off-main decode, token-free image state, late-response suppression, orphan-draft protection, and locked submission controls. No dependencies or public media URLs were added.

## Removing a shared photo

Purchase details now offer a separate confirmed “Remove photo” action. The confirmation captures the displayed purchase version; cancellation performs no mutation. Removal uses the existing transactional `remove_item_photo` RPC, keeps text fields, clears the image after acknowledgment, and refreshes inventory. No Storage administrator credential or direct object deletion is used by the app. The backend immediately revokes active photo access and schedules physical cleanup under its existing retry policy.

The Swift adapter verifies household/item identity, a null photo reference, and either the next version or the unchanged version for a photo-free no-op. It rejects the increment ceiling before sending a request. Network failures retain visible state for explicit retry; version conflicts reload the current purchase without overwriting it. Concurrent removal/edit/delete actions are blocked, and late responses after retirement cannot restore shared data. Local drafts or incomplete draft recovery block removal.

The focused 37-test unit run passes, covering wire names, response/version validation, confirmation, network failures, version conflicts, retained details, other-spouse refresh, and retirement during a pending removal. The real local Swift SDK run passes other-spouse removal, unchanged fields, denied downloads, matching-version no-op replay, and purchase deletion afterward. Review checked the captured confirmation version, authorization-preserving RPC reuse, delayed image clearing, concurrent-operation guards, and the separation of removal versus purchase-deletion progress.

The final full offline-unit plus photo UI run passes with two expected environment-gated skips. The native journey verifies “Keep photo,” confirmed removal, disappearance of the image, retained purchase name, and subsequent purchase deletion. Its confirmation selector is scoped to the alert's first matching button because the iOS 26 accessibility tree exposes nested duplicate button elements. No backend migration was needed.

## Session-scoped list thumbnails

Lazy list rows own a display model and register it with the current inventory store during loading. They use the existing authenticated, bounded private download endpoint, with off-main ImageIO decoding capped at a 192-pixel long edge for the 64-point thumbnail. Detail decoding keeps its existing 1,024-pixel cap. No thumbnail endpoint, public URL, disk cache, global cache, or dependency was added.

Row disappearance releases the model; refresh, search, retirement, sign-out, and detected access loss clear all registered images. A generation change restarts still-visible rows after a refresh. Per-request ownership and image generations suppress superseded or late downloads and errors. A cancelled task cannot clear a newer display. Missing-photo rows make no download; loading and unavailable states use accessible symbols, never sample artwork.

Focused coverage checks thumbnail dimensions, detail independence, no-photo rows, cancelled requests, late errors after release/refresh/retirement/deactivation, other-spouse display, and clearing every image on access denial. The native synthetic-photo journey checks thumbnails for both preview spouses, with a retained list screenshot visually reviewed. The real local Swift SDK test independently verifies the other spouse's thumbnail download and retirement clearing against disposable accounts. An initial unit-fixture failure was corrected by restoring the image draft before import, matching the app's required initialization order.

The full offline-unit and shared-inventory UI run passes 125 test declarations (121 unit plus four UI), with two expected environment-gated skips. The compact iOS 18.3.1 SE photo journey also passes. Independent review found no blocking correctness, privacy, lifecycle, or performance issue; its loading-state accessibility suggestion was applied. Source dimensions/bytes remain bounded, and no authorization or server contract changed.

Final expanded photo UI reruns pass on both Pro and SE: returning from detail reloads the thumbnail, and returning after confirmed photo removal shows the retained purchase without a thumbnail. Strict Swift formatting and `git diff --check` pass.
