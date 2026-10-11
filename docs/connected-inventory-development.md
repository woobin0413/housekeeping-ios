# Connected inventory screens

Status: September 10, 2026. Task 13 is **implemented and locally verified**. Account-scoped browsing, search, pagination, fresh purchase details, add/edit/delete, foreground refresh, and durable editor recovery/conflict/discard are connected. Later tasks now connect private photos, camera capture, and recognition/manual fallback; this page records the task 13 milestone.

## What is connected

The configured app constructs a `SupabaseInventoryRepository` and `LocalDraftStore` for the verified account/household. Sign-in, restoration, and sign-out now pass through `AppConnection`, which owns the inventory instance. Production reads use the existing authenticated RPCs; views receive observable state, never SDK clients or credentials. The original explicit design demo is unchanged and still uses session-only sample data.

`ConnectedInventoryView` preserves the ivory/forest palette, native typography, search field, compact actions, and accessible layout. It shows server-backed list/search results, loading, empty and failure states, bounded pagination, fresh detail lookup, and pull-to-refresh. Detail requests are independent of list pages, so refreshing an item from a later page does not incorrectly make it disappear. Separate request generations suppress stale detail responses. Access denial moves to the account screen with a clear check-connection action.

The connected editor writes through `InventoryStore` and the existing account-pinned repository. Name, description, brand, model, and date edits are validated before mutation. New purchases reuse a stable request ID; edits send the original expected version. A successful add/edit refreshes the collection and an edit also updates the open detail. Deletes require confirmation, preserve optimistic-concurrency semantics, and reload the latest item after a stale-version conflict.

Draft phases are visible rather than collapsed into a generic spinner. Editing autosaves protected local text; uncertain submissions freeze the exact retry input; acknowledged requests survive local-cleanup failures without repeating the network write. Conflict review compares the local fields with the latest shared version and lets the user explicitly rebase either set. Discard always requires confirmation, warns when a mutation may already have committed, and refreshes afterward so an acknowledged remote save is not hidden. At this task-13 checkpoint there was no photo or recognition action in connected mode; later tasks added both. The existing explicit demo remains session-only and visually distinct.

## Account and draft lifecycle

Before revalidating authentication, retire the old inventory instance: hide its shared rows/details, invalidate pending operations, and finish persisting its private draft snapshot. Only successful preservation releases that instance. If local persistence fails, account transition is blocked with a retry message and the latest edits remain in memory.

Session expiration does not silently discard unfinished work. Its partitioned file remains available only when the same account/household returns. Another account receives a different store and draft partition. Leaving the active scene explicitly flushes queued draft text; foreground restoration reconstructs the account-scoped store, restores the draft, and refreshes purchases. This is not offline synchronization or Realtime.

Explicit sign-out warns about an existing or unreadable draft. Confirmed cleanup must succeed before credential removal begins. Failed draft cleanup retains text and allows retry; failed credential cleanup remains an authentication error, not a claimed successful logout. A pending server mutation may still commit after retirement/discard, so uncertain request input remains stable and late responses cannot resurrect the old state.

## Verification scope

Unit coverage includes account construction/foreground restoration, preview household stability, shared create/edit/delete across reconstructed stores, failed draft preservation, sign-out confirmation/cleanup ordering, session-expiry isolation, missing membership, uncertain-save retirement, acknowledged-save discard reconciliation, independent detail reads, stale delete recovery, late detail responses, and not-found versus denied-access behavior.

The offline iPhone 17 Pro / iOS 26.5 suite passes **80 tests**. The opt-in local-SDK check and physical-device file-protection check are skipped in that offline run. The real local-Supabase runner passes separately with disposable accounts: both spouses authenticate, resolve the same household, share CRUD/search/retry/conflict behavior, restore through Keychain, and sign out independently. All **18 inventory HTTP tests** pass against the guarded loopback stack.

UI tests use the explicitly launched `--preview-inventory` Debug fixture, marked offline/no-network. Its mutable in-memory household database supports deterministic shared writes and its account-partitioned draft storage survives store reconstruction. It is never selected after a live failure and is absent from Release. The focused journeys prove one account creates a purchase that a second account finds, edits, and deletes; a second journey proves a typed draft survives background/foreground reconstruction and cannot be discarded without explicit confirmation.

The UI run exposed a genuine largest-text overlap: the offline banner covered the navigation bar and intercepted Account taps. Moving it into a vertical layout fixed the overlap; an explicit 44-point button label fixes the target size. The test allows only a 0.0001-point floating-point tolerance for accessibility geometry reporting. [Saved Pro screenshots](design-preview/README.md) were visually inspected after the fixes. The lifecycle review reported no required finding; SwiftUI/API-design guidance kept observable ownership and SDK calls outside views.

The final Pro run passes all **15 UI journeys**, covering the explicit demo, authentication/recovery, read states, largest-text reachability, connected writes, and foreground draft recovery. Both new connected journeys also pass on the iPhone SE (3rd generation); XCTest automatically scrolls compact layouts to the draft and detail actions. The code-quality review found one required recovery issue: discarding an acknowledged retry copy could leave the accepted server item invisible until manual refresh. The fix routes discard through `InventoryStore`, refreshes immediately, and has a regression test. No required correctness, architecture, security, readability, or performance findings remain.

No cloud configuration, real accounts, or credentials were used. `Local.xcconfig` is still absent; the eventual client configuration contains only the authorized project URL and public key. Changes remain local and uncommitted.
