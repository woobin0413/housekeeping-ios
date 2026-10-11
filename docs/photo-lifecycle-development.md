# Atomic photo lifecycle and cleanup: implementation status

Status: task 16 is implemented and verified locally. Item creation can atomically attach the caller's own READY, unexpired photo; either active spouse can remove the shared photo or delete its purchase. Every removal moves metadata to `DELETE_PENDING` and writes a private cleanup job in the same transaction.

## Cleanup boundary

- Direct item/photo mutation and cleanup-table access remain denied. Authenticated discard accepts only the uploader's unattached RESERVED/READY photo. Cleanup RPCs and `POST /cleanup` require the service role.
- Attachment, discard, expiry, photo removal, and purchase deletion lock the relevant membership/item/photo rows. A simultaneous attach and discard has exactly one winner.
- Workers enqueue expired uploads, claim 1–25 due jobs with `SKIP LOCKED`, and reclaim a `RUNNING` lease after five minutes. Failures use bounded exponential retry; raw Storage errors are not persisted or returned.
- Storage deletion happens before `finish_photo_cleanup(...succeeded:true)` may purge photo metadata. Deleting an already-missing object succeeds, and repeated completion is safe.

## Verification

- All 191 database assertions pass, including 23 lifecycle checks for attachment ownership/expiry, spouse removal, private grants, bounded claims, transient retry, success ordering/invariants, and abandoned-lease recovery.
- Five cleanup-function tests pass for boundary validation, normal/missing objects, transient Storage failure, malformed claimed data, and checkpoint failure.
- All 35 HTTP tests pass. Eleven photo tests exercise real Auth, PostgREST, Edge Functions, and Storage, including service denial, spouse photo/purchase removal, missing-object cleanup, and concurrent attach/discard.
- SQL lint, Deno type-check/lint/format, frozen dependency resolution, and dependency audit pass. Tests use only generated `.invalid` accounts and synthetic JPEGs.

Cloud scheduling remains an operations/deployment task: invoke the service-authenticated cleanup function periodically with a bounded batch. [Task 17](photo-drafts-development.md) adds app photo selection and preparation; upload/download follows in task 18.
