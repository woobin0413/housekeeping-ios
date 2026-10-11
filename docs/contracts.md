# Data and interface contracts

Status (2026-09-18): implementation contracts for the approved SwiftUI + Supabase [specification](spec.md). The approved project has all 17 migrations plus authenticated `media` and `cleanup` functions. Household/inventory APIs, private media, image drafts, photo display/removal, recognition authorization/review/manual fallback, and service-role-only account maintenance are implemented locally. The production app and cloud deployment omit recognition pending provider, key, evaluation, and spending approval; hosted photo/recovery and release acceptance remain open.

## Common rules

IDs are UUIDs. Timestamps are server-generated UTC instants encoded as ISO 8601; purchase dates are nullable `YYYY-MM-DD` calendar dates. Server code derives user identity from the verified session. Clients never select their own creator identity.

Public DTOs use camelCase. SQL rows use snake_case, mapped by the iOS data adapter. Input and output models are distinct. Treat optional PATCH fields as unchanged when absent; an explicit null clears a nullable field. Reject unknown input fields; clients tolerate additive output fields and render unknown optional recognition outcomes as manual-entry fallback.

All inventory operations require authentication and active membership. Single-record foreign or missing IDs produce `NOT_FOUND` to avoid revealing existence. Collection operations return only authorized rows. Search pagination is offset-based for the initial 10,000-record target, with stable ordering for an unchanged dataset; concurrent changes can shift pages and refresh resets them.

## Data model

| Table | Principal fields | Invariants |
| --- | --- | --- |
| households | id, name, created_at | Created only by a trusted provisioning operation; no app-client writes. |
| household_members | household_id, user_id, slot, joined_at | Unique user ID and unique household/slot; internal slot is 1 or 2, enforcing the two-member cap even under concurrency; equal app permissions; only trusted provisioning/revocation can mutate membership. |
| items | id, household_id, name, description, brand, model, purchased_on, quantity, restock_limit, created_by, created_at, updated_at, version, deleted_at, creation_requester_id, creation_request_id | Name nonblank; quantity and restock limit are nonnegative integers that default to 1; version starts at 1; household/original requester immutable; attribution may clear on account removal; unique household + original requester + creation request ID survives that removal. |
| photos | id, household_id, uploader_user_id, item_id, object_key, state, byte_size, mime_type, checksum, created_at, expires_at | One photo per item; immutable unique key; READY required to attach; household must match attached item; uploader UUID remains as retry attribution without an Auth FK after removal. |
| photo_analyses | id, household_id, photo_id, requested_by, request_id, state, suggestion, model_id, prompt_version, created_at, expires_at | Unique requester + request ID; no direct client writes; suggestion is separate from confirmed item fields. |
| cleanup_jobs | id, household_id, object_key, state, attempts, next_attempt_at, last_error_code | Internal only; retry deletion through Storage API before purging metadata. |
| account_operations | id, kind, household_id, subject_user_ids, state, timestamps | Internal operation tombstone; one active removal/closure per household; no email or request narrative. |
| account_photo_transfers | id, operation_id, photo/key/checksum/size, state, attempts, next_attempt_at, last_error_code | Internal retry ledger for moving attached departing-user images to service ownership without changing their purchase key. |

Member removal/account deletion may null historical attribution according to the specification, while retaining purchase content that belongs to a continuing household. Do not cascade-delete shared purchase history when deleting a member's auth identity.

Enforce matching household IDs with constraints and transactional checks, not client promises. A photo is immutable after validation; replacement uses a new ID if that feature is added. Never permit overwriting another photo through an upload upsert. Store server-computed checksum/size, not merely the client's declaration.

## Access matrix

| Resource/action | Unauthenticated/outsider | Either spouse with active membership |
| --- | --- | --- |
| Read/search saved purchases and attached photos | Denied | Allowed, regardless of creator/uploader |
| Create/update/delete purchases; remove attached photo | Denied | Allowed, regardless of creator/uploader |
| View/analyze/attach an unattached photo | Denied | Only own upload |
| Upload photo | Denied | Own reserved path |
| Read membership roster | Denied | Own household |
| Create household; add/remove members | Denied | Denied; trusted operator only |
| Set readiness, analysis outputs, cleanup jobs | Denied | Denied; server-managed |

Use RLS on all exposed tables and Storage objects. Membership-policy helpers must avoid recursive policy evaluation and explicitly check the authenticated user. Privileged SQL functions use a fixed search path, restricted execute grants, and internal authorization checks. Only narrowly scoped server operations may bypass RLS. Recheck current membership on each recognition request; an old session alone does not authorize a removed member.

## Domain types

```typescript
type UUID = string; // Runtime UUID validation at ingress.
type Instant = string; // ISO 8601 UTC.
type DateOnly = string; // Valid YYYY-MM-DD calendar date.

interface ItemFields {
  name: string;
  description: string | null;
  brand: string | null;
  model: string | null;
  purchasedOn: DateOnly | null;
  quantity: number; // Whole number 0..2147483647; defaults to 1 on create.
  restockLimit: number; // Whole number 0..2147483647; defaults to 1 on create.
}

interface CreateItemInput extends ItemFields {
  householdId: UUID;
  requestId: UUID;
  photoId: UUID | null;
}

interface UpdateItemInput {
  id: UUID;
  expectedVersion: number;
  fields: Partial<ItemFields>;
}

interface Item extends ItemFields {
  id: UUID;
  householdId: UUID;
  photoId: UUID | null;
  createdAt: Instant;
  updatedAt: Instant;
  version: number;
}

interface ItemQuery {
  householdId: UUID;
  query: string;
  limit: number; // Default 50; range 1..100.
  offset: number; // Default 0; range 0..10000.
}

interface ItemPage {
  data: Item[];
  nextOffset: number | null;
}

interface ProductSuggestion {
  name: string;
  description: string | null;
  brand: string | null;
  model: string | null;
}

interface AppError {
  code: string;
  message: string;
  requestId: UUID;
  retryable: boolean;
}
```

Limits are defined in the product spec and enforced both by request schemas and database constraints. An item needs restocking when `quantity <= restockLimit`; the comparison is display behavior and does not reject either valid value. `UpdateItemInput.fields` must contain at least one supported field. Purchase date validation checks calendar validity, not just a regular expression. UUID/string aliases above are illustrative; the Swift domain uses Foundation UUID and explicit date conversion.

## Inventory interfaces

The iOS repository exposes the following typed operations. Implement reads through the authenticated Supabase Data API or SQL RPC; use SQL RPC transactions for writes requiring version checks or photo attachment. Document actual wire schemas with the implementation. Raw Supabase errors are normalized at the adapter boundary, not presented directly in views.

| Operation | Input | Output and behavior |
| --- | --- | --- |
| search | ItemQuery | ItemPage; empty query orders updatedAt descending then id ascending; nonempty query ranks exact name, then name prefix, then other token matches, followed by updatedAt/id. |
| get | `{id: UUID}` | Item or NOT_FOUND. |
| create | CreateItemInput | Item; atomically attach own READY photo in same household; repeated identical request returns original item. Reusing requestId with different fields returns CONFLICT. |
| update | UpdateItemInput | Item with incremented version; outdated version returns CONFLICT. |
| delete | `{id: UUID, expectedVersion: number}` | No content; soft-delete and enqueue cleanup atomically; repeat for an already-deleted authorized item succeeds. |
| removePhoto | `{itemId: UUID, expectedVersion: number}` | Updated Item; clears reference and enqueues cleanup in one transaction. |

Reserve the original creation request and its normalized input fingerprint so an edit after creation does not make a retry look like a new create. Retain the request mapping with the tombstone until its defined retention window ends; never resurrect a deleted purchase by replaying its create request.

### Implemented SQL wire contract

Authenticated PostgREST RPC requests use a single JSON argument: `{"p_input": <input>}`. The input objects follow the domain types above; unknown keys are rejected. `create_item`, `update_item`, `get_item`, and `search_items` return the documented camelCase Item/ItemPage objects. `delete_item` returns SQL void (no domain payload); the Swift adapter discards the platform response body.

| SQL function | `p_input` |
| --- | --- |
| `create_item` | `CreateItemInput`; `name`, `householdId`, `requestId` required, nullable fields may be omitted. `quantity` and `restockLimit` default to 1; zero is valid and null is rejected. Optional `photoId` attaches the caller's own READY, unexpired photo in this household. |
| `update_item` | `{id, expectedVersion, fields}`; nonempty partial supported fields, absent leaves unchanged and null clears nullable fields. |
| `delete_item` | `{id, expectedVersion}`; an already-deleted item in the caller's household succeeds. |
| `remove_item_photo` | `{itemId, expectedVersion}`; returns the updated Item with no photo. A version conflict requires refreshing before another explicit attempt. Matching-version photo-free items return unchanged; removal increments once and enqueues cleanup atomically. |
| `get_item` | `{id}`; hidden, deleted, or missing items return NOT_FOUND. |
| `search_items` | `{householdId, query, limit?, offset?}`; defaults 50/0; limits 1–100 and 0–10000. |

Names trim leading/trailing PostgreSQL `[[:space:]]` characters, including tabs and newlines. Nullable create fields omitted and explicit null normalize identically. Description/brand/model content is otherwise preserved. The private `item_creation_requests` ledger keeps original normalized fields out of ordinary table reads. Identical create retries return the current item without overwriting subsequent edits; changed original input or a tombstoned item returns CONFLICT. Tombstones and their request ledger are currently retained indefinitely; no purge job exists yet.

Writes hold the caller's membership row through the transaction and lock affected items before version checks. This serializes them with competing edits and membership revocation. PostgreSQL's [row-level locking rules](https://www.postgresql.org/docs/17/explicit-locking.html) underpin this behavior. Identity always comes from `auth.uid()`, not caller fields.

RPC errors use `PT401`/`UNAUTHENTICATED`, `PT404`/`NOT_FOUND`, `PT409`/`CONFLICT`, and `PT422`/`VALIDATION_ERROR`. Denied execute grants use platform permission errors. The local HTTP suite verifies expected 401/403/404/409/422 responses and 204 for successful deletion; the Swift adapter normalizes these into token-free domain failures and preserves cancellation. Search uses a generated confirmed-text column and a [pg_trgm GIN index](https://www.postgresql.org/docs/17/pgtrgm.html), an escaped first-token LIKE condition, and literal checks for every token. No raw query text becomes executable SQL. At the offset ceiling, nextOffset is null rather than an invalid continuation.

`create_item` also returns `PT409`/`PHOTO_NOT_READY` when an authorized photo is no longer READY or has expired. This definite rejection leaves no request ledger entry; the client may renew its photo and retry the same purchase request UUID. The ledger is checked first, so a committed create with a lost response still replays its original input even after attachment or expiry. Generic conflicts and uncertain network failures must never renew the photo or change that frozen input.

The Swift repository is immutable per account/household/auth generation. It pins each request's token and rejects late results after account changes. `PurchaseDate` encodes calendar dates without time-zone conversion. `ItemPatch` distinguishes unchanged and explicit-null fields. Versions decode through 9,007,199,254,740,991; Swift updates require an expected version below that ceiling so incrementing cannot produce an unrepresentable result. Optional photo attachment is exposed only on create, not text edits. See [adapter details](inventory-development.md).

SQL search uses parameterized queries and literal escaping for `%`, `_`, and backslash. Do not build filter expressions or SQL by concatenating untrusted query text. Check every token against normalized confirmed text. Return at most limit + 1 internally to determine nextOffset; no mandatory expensive count query.

## Photo interfaces and state

```text
RESERVED → READY → ATTACHED → DELETE_PENDING → DELETED
     └──────────────→ DELETE_PENDING
               READY → DELETE_PENDING (discard or expiry)
```

These are logical API operations; the media Edge Function may host their routes under one deployment.

| Route | Typed input | Success output |
| --- | --- | --- |
| POST /media/photos | `{householdId: UUID, requestId: UUID}` | 201 `{photoId: UUID, objectKey: string, expiresAt: Instant}` |
| POST /media/photos/:photoId/completion | `{}` | 200 `{photoId: UUID, state: "READY"}` |
| DELETE /media/photos/:photoId | No body | 204; only an unattached upload owned by caller; attached photos use removePhoto/delete. |

Use the Supabase Storage SDK to upload to the reserved objectKey with the user session; no arbitrary path is accepted by the app service. Storage policies tie upload permission to a reservation owned by that user and deny overwrites. Reservations are idempotent per user/request ID.

The implemented `POST /media/photos` route accepts at most 4 KiB of JSON, authenticates the bearer session with Auth, and calls `reserve_photo({householdId, requestId})` under that user's RLS context. Reservations expire after 24 hours and return a server-generated key shaped as `<household UUID>/<uploader UUID>/<photo UUID>.jpg`. The `purchase-photos` bucket is private, JPEG-only, and capped at 5 MiB. Its policies grant INSERT only for the uploader's unexpired RESERVED key and authenticated GET only for the uploader's unfinished object or an active household member's ATTACHED object. No UPDATE or DELETE policy exists, and listing is intentionally excluded. Task 14 originally tested ATTACHED reads using privileged fixtures; task 16 now provides the transactional attachment transition. Local iOS preparation/recovery is task 17; connecting upload/download is task 18.

The implemented completion route accepts exactly `{}` and a server-reserved photo UUID. It resolves only the uploader's RLS-visible row, downloads the immutable object with that user's session, requires an exact JPEG end marker, parses dimensions before allocation, and strictly decodes the entropy stream. Limits are 5 MiB, 2,048 pixels per edge, 4,194,304 pixels, approximately 96 MiB decoder memory, and 1.5 seconds of validation wall time. The function computes lowercase SHA-256 and calls `finalize_photo` with the service credential; that RPC is denied to ordinary sessions and independently locks/rechecks uploader, current membership, object presence, expiry, state, and metadata consistency. Success is 200 `{photoId,state:"READY"}`. Identical/concurrent completion is idempotent. Invalid bytes or dimensions return 422; an absent upload can be retried, while an expired reservation requires a new reservation and never attaches. See [runtime evidence](photo-validation-development.md).

Attach checks READY plus unexpired reservation and locks the photo row. Cleanup locks the same row and first moves it to DELETE_PENDING so attachment cannot race deletion. Repeated completion is safe while the photo exists and caller remains authorized. Pending uploads never appear as successful attachments in the inventory.

Use authenticated Storage download for attached photos and the uploader's own drafts. Transient upload failures preserve local drafts; expired reservations get a fresh ID on explicit retry. Background cleanup and its internal authentication are operational interfaces, never public unauthenticated routes.

## Recognition contract

`POST /recognitions` is the recognition Edge Function route. It accepts a verified user session and JSON `{photoId: UUID, requestId: UUID}`. The server resolves the object path itself, checks membership, uploader ownership and READY status, reserves quota atomically, then invokes the provider.

```typescript
type RecognitionResponse =
  | {
      status: "SUGGESTED";
      analysisId: UUID;
      photoId: UUID;
      suggestion: ProductSuggestion;
    }
  | {
      status: "UNRECOGNIZED";
      analysisId: UUID;
      photoId: UUID;
      suggestion: null;
      reason: "UNCLEAR_IMAGE" | "MULTIPLE_PRODUCTS" | "NO_PRODUCT";
    };
```

Use 200 for both completed outcomes. Provider refusal or invalid/incomplete output becomes a structured error with manual-entry guidance, never a partially trusted suggestion. The provider response is schema-validated; null brand/model is valid. No provider-generated fields can select an object path, household, user, or database operation.

Initial limit proposal: 30 new recognition attempts per user per UTC day, a configurable household cap, and a project spending cutoff. Cached retries do not consume another quota unit. Store only the sanitized result, provider/model/prompt version, and minimal consumption metadata needed for evaluation and duplicate detection. Expire unattached analysis results with the photo; keep request metadata long enough to cover the documented retry window.

Bound provider work to 25 seconds, with a 30-second client timeout. In-flight duplicate request IDs return CONFLICT with retryable=true; completed duplicates return the stored result. Reuse with a different photo returns nonretryable CONFLICT. Expired in-flight attempts become an explicit retry state. Do not blindly repeat a timed-out provider call: its billing outcome may be unknown. A subsequent user-requested attempt receives a new request ID.

The app may ignore a completed result if the photo/draft has changed. Recognition never saves a purchase. The UI submits only the user's reviewed fields to the create operation.

## Household/account interfaces

Initial SQL wire contract: `public.get_household()` returns JSON `{householdId, name}` or raises `PT404` (`NOT_FOUND`). It is executable only by `authenticated`. `private.provision_household(p_household_id uuid, p_name text, p_user_a uuid, p_user_b uuid)` returns the household UUID and is executable only by the trusted `service_role`/database administrator, outside the exposed API schema. Input errors use `PT422`; conflicting assignments or changed retries use `PT409`. Household names are trimmed and limited to 1–100 characters. An identical retry after membership revocation conflicts rather than silently restoring access. Internal slots do not appear in app DTOs.

The only app household operation is `getHousehold() → {householdId: UUID, name: string}`. It returns the caller's household or NOT_FOUND. No arbitrary household switching, public signup, app-side `createHousehold`, invitation endpoints, member removal, or ownership transfer is exposed in this private two-person release.

Trusted operator provisioning is separate from the public API. Its input identifies an explicit household UUID/name and exactly two distinct, existing, verified auth user UUIDs. Validate both identities, lock the household, reject existing membership in another household, enforce the two-member cap transactionally, and insert membership atomically. An identical retry is safe; a different pair or name for the same requested household is a conflict, never an implicit reassignment. Do not trust mutable client-editable user metadata or matching email domains as membership evidence.

Provisioning/membership mutations are not granted to `anon` or `authenticated`. The installed deployment contains one shared household; separate households may exist in isolated test fixtures to prove tenant isolation. Any future third user or household-switching feature requires a scope review.

Operator-assisted account removal requires verification of the user's request. The service-role-only
`POST /account-maintenance` accepts either exact `removeMember` or `closeHousehold` input plus an
operation UUID and confirmation phrase. It revokes membership before asynchronous work. Removal
checksum-verifies and re-owns attached Storage objects, cleans unfinished uploads, blocks on unknown
owned objects, deletes the Auth identity, and preserves the spouse's shared purchases/photo keys.
Closure revokes every membership, cleans every household-prefix object through retry records, deletes
the Auth identities, and only then purges purchases and the household. Calls are bounded and
repeat-safe; `202 IN_PROGRESS` requires retrying the same operation, and only `200 COMPLETED` is final.
See [the operator and recovery runbook](recovery-runbook.md). None of these operations expose
administrator credentials to the iPhone app.

## Errors and compatibility

Custom HTTP operations return `{error: AppError}` consistently. Map validation to 422, missing/invalid session to 401, forbidden household administration to 403, foreign/missing object to 404, version/request conflicts to 409, invalid/oversized image to 415/413, quota exhaustion to 429, invalid provider response to 502, and provider unavailability/timeout to 503/504. Platform-level errors that occur before the handler are normalized by the client adapter as well.

Messages must not expose SQL, stack traces, credentials, object URLs, or provider response bodies. Use Retry-After for rate limits where a known retry time exists. Every server-generated response/request log uses a traceable request ID with no sensitive payload.

Add optional fields compatibly. Never rename/remove an existing required field or change its meaning in a released client contract without a migration strategy. Keep recorded JSON fixtures shared between Swift decoding tests and TypeScript schema tests. Unknown future enum values must produce a safe update/manual fallback rather than a crash.
