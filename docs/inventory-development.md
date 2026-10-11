# Swift inventory adapter

Status: task 11 implements typed purchase models and a Supabase-backed repository for search, get, create, update, and delete. Real local SDK tests prove shared access in both directions. Task 12 adds [durable text drafts and observable inventory state](draft-state-development.md). [Task 13](connected-inventory-development.md) now connects the full manual inventory UI, including editor/write, recovery, conflict, and account lifecycle. The demo still uses session-only sample data.

## Contract and account boundary

`Item`, `ItemFields`, `ItemPatch`, and the repository protocol contain no SDK types or credentials. `PurchaseDate` is a validated Gregorian `YYYY-MM-DD` string, not a midnight timestamp. Server creation/update timestamps decode with or without fractional seconds and remain instants. Text limits count Unicode scalars to match PostgreSQL character counts; zero bytes are rejected.

The task-11 adapter calls the transactional RPCs with `{"p_input": ...}` and camelCase fields. It never writes tables directly or supplies creator identity. A create request carries the caller-owned stable request UUID and flattened fields. Nullable PATCH values distinguish omission (`.unchanged`) from clearing (`.set(nil)`). Photo attachment was added later by the task-18 service flow.

Each repository instance is bound to one account, household, and authentication generation. The authentication service refreshes/verifies protected session storage, pins each request to that account's token, and checks the generation again before returning results. A new sign-in/sign-out invalidates old repositories. Tokens stay within the authentication data service. The scoped request uses the pinned SDK's PostgREST client, avoiding its general Supabase client's asynchronous current-token substitution during account changes.

The SDK's [session access](https://supabase.com/docs/reference/swift/auth-getsession) can refresh expired credentials; database calls use its [RPC support](https://supabase.com/docs/reference/swift/rpc). The implementation was also checked against the locally resolved 2.55.1 source. No new dependency or cloud configuration is introduced.

## Failure and retry behavior

- Requests do not automatically retry. After an uncertain create result, retry with the same request UUID and original fields. A replay may return a purchase edited since creation; it must not overwrite that edit.
- Version/request conflicts remain distinct from not-found, validation, unavailable service, protected-storage, and authorization failures. Cancellation stays `CancellationError`, not a user-facing server failure. Server messages and payloads are never forwarded as error copy.
- Updates reject the maximum contract version before sending because incrementing it would exceed the supported range. That maximum remains valid for decoding and deletion.
- Responses validate purchase identity/household, field/date/version shape, unique page IDs, page size, and bounded forward pagination. Foreign or malformed data never becomes a valid purchase.
- Cancelling a request cannot undo a server mutation already committed. The draft controller preserves uncertain input and request/version metadata, offers explicit conflict review, and never treats cancellation as a confirmed rollback. [Task 13](connected-inventory-development.md) connects these states to the screens.

## Verification

At the task 11 checkpoint, the iPhone 17 Pro / iOS 26.5 offline suite passed **51 unit tests**: the existing 36 plus four model/contract tests and 11 inventory transport tests. Xcode reported 52 including the skipped opt-in local test; the latter passed separately through the guarded runner. New Swift formatting lint, Ruby configuration checks (3 tests / 92 assertions), project/Info.plist validation, and Markdown link/fence checks passed. See [connected-screen verification](connected-inventory-development.md) for the current suite totals.

The full **11/11 UI regression suite** also passes after the adapter changes. Authentication and approved demo flows remain intact. No screen layout changed in this slice, so the existing screenshots remain the design reference; there is no new connected-inventory preview yet.

The first model test run failed for missing implementation, then passed after the models were added. Offline transport tests cover exact RPC bodies, literal search text, pagination, date decoding, explicit-null updates, empty successful deletes, timeout/retry behavior, malformed/foreign results, authorization errors, protected-storage failures, and cancellation. A controlled delayed-response test proves account switching rejects the old response and repository while a new request uses the new account's token.

A separate gateway regression first failed because non-JSON 401/403 responses became generic unavailable errors. The adapter now preserves their authorization meaning without exposing response bodies. The version-ceiling review finding was fixed with a pre-request update guard and a no-network regression test.

The guarded real SDK runner passed against disposable local spouses: create/read/search/edit/delete in both directions, service reconstruction with protected session restoration, shared search pagination, exact create retries, changed-request conflicts, stale-edit rejection, explicit-null clearing, idempotent deletion, and denied tombstone replay. This is adapter/server verification, not a connected iPhone inventory journey.

The final rerun passed after the RPC encoding/error-handling adjustments. Cleanup verification found zero local users, households, purchases, recovery-flow records, and captured emails. Only this project's services were stopped, preserving volumes and leaving other projects alone. Changes remain local and uncommitted.

```sh
# Offline tests: select an installed simulator UUID.
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -destination "platform=iOS Simulator,id=${HK_SIMULATOR_ID}" -derivedDataPath /tmp/housekeeping-design-build -parallel-testing-enabled NO -only-testing:HouseKeepingTests CODE_SIGN_IDENTITY=- test

# Optional real local check, after guarded startup; no cloud URL override exists.
node scripts/start-local.mjs
node scripts/test-ios-local-auth.mjs
supabase stop
```

See [fixture protections](../supabase/tests/integration/README.md) before running local services. No `Local.xcconfig` is required or generated for these tests. Cloud setup still waits until the authorized connection milestone; only the project URL and public key will belong in that ignored client configuration.
