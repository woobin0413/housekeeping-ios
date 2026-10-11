# Account removal, closure, and recovery

Status: critical task 25 is implemented and verified with generated local identities and image bytes.
No real member, Auth identity, Storage object, household, backup, or hosted project has been changed.
Hosted configuration and an isolated records-plus-object restore exercise remain required before
release.

## Safety boundary

These are operator operations. The iPhone app cannot call them. The Edge Function accepts only the
service-role bearer credential, exact identifiers, a caller-generated operation UUID, and the exact
confirmation phrase. Keep the service-role key, database URL/password, S3 credentials, member UUIDs,
and operation payloads out of source, shell history, chat, screenshots, and reports.

Before any operation, verify the request with the affected person through the household's established
contact method. Confirm whether the request is **member removal** or **full household closure**, read
back the consequence, capture a fresh database export plus Storage-object export, and record only a
nonsecret ticket/reference and the backup manifest digest. Never test either operation against the
actual household.

The migration and function enforce this order:

1. Lock the household against concurrent membership-authorized writes.
2. Remove membership first, immediately denying all RLS and privileged inventory/photo RPCs even to
   an unexpired access token.
3. For member removal, discard unfinished uploads through the existing retry ledger. Stage each
   attached photo, verify its recorded SHA-256 and byte size, move it back to the same object key as a
   service-owned object, and retain its purchase association for the spouse.
4. Refuse identity deletion while a transfer, tracked photo cleanup, or any object owned by the
   departing identity remains. An unknown owned object is an investigation stop, not an object to
   delete speculatively.
5. Delete Auth identities with the Admin API. Purchase attribution becomes the existing “former
   member” state while immutable request/uploader UUIDs retain retry identity without an Auth foreign
   key.
6. For household closure, detach every photo and delete Storage bytes through retryable cleanup before
   deleting photo metadata, purchases, or the household. Preserve the operation tombstone.

Supabase documents that an Auth user cannot be deleted while they own Storage objects and that a
previously issued JWT remains valid until expiry unless each sensitive operation also checks the
session. This app's membership checks close that JWT window at the data boundary. See
[Supabase user deletion](https://supabase.com/docs/guides/auth/managing-user-data). Supabase also
documents that a copy/move assigns the new object to its initiating user and that service-key-created
objects have no user owner; that is the basis for retaining attached photos without retaining the
departing Auth identity. See [copy/move behavior](https://supabase.com/docs/guides/storage/management/copy-move-objects)
and [Storage ownership](https://supabase.com/docs/guides/storage/security/ownership).

## Deploy and invoke

Deploy only after task 24's exact-target pre-deployment audit passes. Deploy `cleanup` and
`account-maintenance` from the reviewed commit, configure cleanup scheduling, and rerun the audit.
The operation endpoint processes at most 10 ownership transfers and 25 cleanup jobs per invocation;
HTTP `202 IN_PROGRESS` means invoke the identical operation again after the retry time. HTTP `200
COMPLETED` is the only completion result. A new UUID with the same household conflicts while an
operation is active.

Use an operator-only local terminal that supplies secrets from its protected environment. Do not put
real values in this document:

```sh
# Member removal body
curl --fail-with-body --request POST \
  --header "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  --header 'Content-Type: application/json' \
  --data "{\"action\":\"removeMember\",\"confirmation\":\"REMOVE MEMBER\",\"operationId\":\"${HK_OPERATION_ID}\",\"householdId\":\"${HK_HOUSEHOLD_ID}\",\"userId\":\"${HK_USER_ID}\"}" \
  "${HK_SUPABASE_URL}/functions/v1/account-maintenance"

# Full household closure body
curl --fail-with-body --request POST \
  --header "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}" \
  --header 'Content-Type: application/json' \
  --data "{\"action\":\"closeHousehold\",\"confirmation\":\"CLOSE HOUSEHOLD\",\"operationId\":\"${HK_OPERATION_ID}\",\"householdId\":\"${HK_HOUSEHOLD_ID}\"}" \
  "${HK_SUPABASE_URL}/functions/v1/account-maintenance"
```

On `202`, inspect only aggregate `pending` counts. If transfers and tracked photos are both zero while
owned objects remain nonzero, use a read-only object inventory and explicitly classify the unknown
objects. On a retryable `500`, reuse the same
operation UUID and payload. Never repair the private ledger manually. After member completion, prove
that the old access token gets neutral/denied inventory, photo, and recognition results and that the
remaining member can still download the exact retained image. After closure, prove the household
prefix has zero Storage objects, app tables have zero rows for the household, and the completion
tombstone remains.

## Records and object backups

Database backups and Storage-object backups are separate artifacts. Supabase's database backup
contains Storage metadata but excludes the image bytes, so restoring it cannot recover an object that
was deleted from Storage: [database backup scope](https://supabase.com/docs/guides/platform/backups).
The release backup set must therefore contain all of the following from one recorded cutoff:

- a platform database backup/clone or the official three-part CLI logical export (roles, schema, and
  data), plus migration-history export when using the CLI procedure;
- a private `purchase-photos` S3/Storage export containing the actual bytes;
- a manifest of object key, byte size, SHA-256, database-export digest, source project ref, cutoff
  time, tool versions, and repository commit, without inventory text, email, or image contents;
- an encrypted, access-controlled destination outside the Supabase project, so project deletion or
  project-wide failure does not remove both the source and backup.

Use Supabase's current [CLI backup/restore procedure](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
for records. Use an S3-compatible client against the server-only Storage S3 endpoint to copy actual
objects; generated S3 credentials bypass RLS and must be short-lived and protected. Supabase describes
the compatible endpoint and server credential boundary in [S3 authentication](https://supabase.com/docs/guides/storage/s3/authentication).

Until the target plan and storage destination are approved, the release baseline is a pre-operation
backup plus a daily backup on days when household data changes, retaining seven daily sets and four
weekly sets. Expired sets are deleted from the backup destination under its own audit log. This
retention is a pending deployment choice; do not purchase a plan, enable PITR, create S3 credentials,
or copy real images without the concrete task 24 target and authorization.

## Isolated restore exercise

Run the exercise in a newly created, disposable project or approved isolated branch, never over the
household project. Record the target ref and prove it contains no unrelated data before restoring.

1. Select one backup set whose database and object-manifest digests match. Record the recovery point
   and expected sample item/photo IDs privately.
2. Restore the database by the exact procedure appropriate to the configured backup. A Supabase
   project clone is database-only and still needs manual Storage, function, and Auth configuration:
   [clone scope](https://supabase.com/docs/guides/platform/clone-project).
3. Restore `purchase-photos` through the Storage API/S3 interface, not by writing `storage.objects` or
   a filesystem volume. Recreate the private 5 MiB JPEG bucket configuration and confirm every
   restored object's byte size and SHA-256 against the manifest.
4. Deploy the exact functions and configure closed signup, recovery redirect, email delivery, cleanup
   scheduling, and public app configuration for the isolated target. Run the post-deployment audit.
5. Sign in only with isolated test identities. Fetch the selected purchase through the app API,
   download its attached image through authenticated Storage, and compare its SHA-256 to both the
   database checksum and backup manifest. Then check foreign and anonymous denial.
6. Destroy the isolated restore target only under its separate authorization and retain the nonsecret
   pass/fail evidence. A database-only row restore, a Storage listing without byte comparison, or a
   restore into the live household is not AC-14 evidence.

Task 25 closes only after the hosted removal/closure rehearsal and this isolated exact-byte restore
pass. Local tests prove state ordering, grants, retry behavior, spouse preservation, the actual local
Storage copy/move/delete calls, and local Auth Admin deletion; they do not prove the selected platform
backup, S3 destination, email/session behavior, or hosted Storage behavior.
