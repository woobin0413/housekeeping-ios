# Durable text drafts and inventory state

Status: task 12 implemented the tested state/persistence foundation on September 9, 2026. [Task 13](connected-inventory-development.md) now connects inventory reads, writes, editor recovery/conflict/discard, and the authentication lifecycle. The existing demo still resets its sample data on relaunch. No cloud configuration or real accounts were used.

## Ownership and storage

`InventoryStore` and `InventoryDraftController` are main-actor observable objects with read-only exposed state and injected interfaces. The future account composition owns one instance per session. Views do not own SDK clients, credentials, or filesystem operations. `LocalDraftStore` is an actor; file operations run outside the main-actor state boundary.

Each project/account/household combination has one versioned Codable text file under protected Application Support storage. Filenames use a project URL hash and account/household UUIDs. Decoding verifies ownership, envelope version, item shape, and the 64 KiB bound. Invalid/incomplete editing fields are deliberately preserved; submitted fields must be valid. Corrupt files surface an error and are not silently replaced by a new empty draft.

Writes request atomic replacement and complete file protection; directories/files request 0700/0600 permissions. Apple documents [atomic and protected writes](https://developer.apple.com/documentation/foundation/nsdata/writingoptions) and [file encryption/protection](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files). The simulator tests verify actual private file permissions and requested write options, not physical-device encryption. The tested simulator did not return file-protection metadata; a separate device-only metadata test is present. Lock/unlock behavior still needs a physical iPhone.

This task-12 slice did not add photos or change text-draft backup behavior. Task 17 later added protected photo drafts with backup exclusion; hosted backup/retention and exact-byte restore proof remain in critical task 25. No passwords, tokens, administrator keys, or image bytes are stored in these text files. Partitioning prevents accidental cross-account loading within the app; it is not a replacement for the iOS sandbox or server authorization.

## Save and recovery contract

| Phase | Behavior |
| --- | --- |
| Editing | Ordered autosave keeps the latest snapshot. Invalid form text remains recoverable. |
| Submitting | Persist the stable request UUID, exact fields, and original edit version before sending a mutation. Freeze edits while the outcome is uncertain. An explicit retry sends the same input. |
| Acknowledged | Persist the returned item before clearing the draft. If cleanup fails, retry local cleanup without submitting the purchase again. |

An initial disk-write failure prevents the network request and keeps the form editable. Timeout/cancellation is not proof of rollback, so uncertain input remains frozen for exact retry or explicit discard. A crash before acknowledgment persistence can leave a submitting draft: creation remains server-idempotent; an edit retry may require conflict review. Acknowledged-create replays can legitimately return a purchase subsequently changed by the spouse.

Version conflicts retain edits. Explicit review fetches the latest item; the user may reload it or reapply only fields changed relative to the original base. Untouched spouse changes are preserved. Resolving a conflict does not automatically submit an update.

Confirmation is required before discarding a draft or deactivating its account state. Deactivation blocks new edits, invalidates pending network generations, and waits for all queued snapshots. Only successful file removal clears the in-memory draft and marks the store inactive. Failed cleanup retains the latest text and an active, usable controller for retry. Late RPC results cannot repopulate old state, but cancellation/discard cannot undo a server mutation already accepted.

## Inventory state

Search uses a 250 ms debounce and generation guards in addition to cancellation, so a server response that ignores cancellation cannot replace a newer query. Refresh resets pagination; additional pages deduplicate by stable item ID. Loading, empty success, errors, and last successful update are explicit state. Acknowledged saves/deletes refresh inventory. Collection access loss clears results and blocks further requests while retaining the private draft for account recovery.

Task 13 integrates foreground/pull-to-refresh, read/write errors, account replacement, sign-out warnings/cleanup ordering, and editor conflict/discard/recovery presentation. Its connected foreground and two-account journeys are recorded separately; the task 12 unit evidence below remains specific to the state foundation.

## Verification

The iPhone 17 Pro / iOS 26.5 offline suite passes **66 unit tests**, including **15 new file/state tests**. Swift Testing reports 68 including two skipped checks: the opt-in local SDK integration test and physical-device file-protection metadata test. This run requires neither running Supabase services nor client configuration.

The full **11/11 UI regression suite** also passes. No screens or layouts changed, so the existing design screenshots remain current for the demo/authentication flows. Swift formatting lint, Ruby client-configuration checks (3 tests / 92 assertions), and whitespace checks pass.

New checks cover real-file reconstruction and isolation; corrupt/oversized input; private permissions; query races; pagination/refresh; ordered autosave; timeout/reconstruction with identical retry input; local-write failure before network; acknowledged cleanup retry; conflict rebasing; access loss; failed deactivation with multiple queued edits; and late search/save responses after deactivation. Controlled repository/storage doubles deliberately hold operations to reproduce races; separate filesystem tests exercise actual Codable files. UI-level draft relaunch remains a task 13 check.

The initial test run failed for missing implementation. Independent review identified that failed sign-out cleanup could lose queued edits; the lifecycle fix and regressions now pass review with no remaining required finding. Physical file-protection, real-device suspension, and cloud behavior remain unverified. Changes remain local and uncommitted; no `Local.xcconfig` has been created.

Run the offline scheme using the simulator command in [implementation tasks](implementation-tasks.md). See [adapter verification](inventory-development.md) for the separately completed real local SDK tests and [iOS configuration](ios-development.md) for the eventual URL/public-key boundary.
