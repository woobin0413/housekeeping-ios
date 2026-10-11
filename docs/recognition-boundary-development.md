# Recognition authorization and quota boundary

Task 20 installs the server-owned boundary that must pass before any image reaches a vision
provider. Task 21 adds the inactive-by-default adapter, and task 22 connects the editable app review
flow. The provider remains inactive without the task 23 configuration and evaluation approval.

## Authorization and request state

- `POST /recognitions` accepts only `{photoId, requestId}` after session verification. Its live
  handler returns `RECOGNITION_UNAVAILABLE` before reserving work while no provider adapter is
  configured, so the incomplete local route cannot consume quota.
- The service-only `reserve_recognition` transaction receives the already verified caller ID,
  locks current membership, and then locks the referenced photo. Only that caller's unexpired
  `READY` upload qualifies; spouse and foreign references return the same `NOT_FOUND` boundary.
- `(requested_by, request_id)` is unique and serialized. A different photo under the same request
  ID conflicts, active work returns `RECOGNITION_IN_PROGRESS`, a stored completion replays without
  new quota, and an expired 90-second lease requires a new request ID rather than repeating work
  with an uncertain provider billing outcome.
- Analysis and quota tables grant no direct client access. Analysis rows use a composite foreign
  key to enforce the photo's household and cascade when photo cleanup removes its metadata.

## Quotas

New work reserves user, household, and project usage in the same transaction that creates the
analysis row. Defaults are 30 attempts per user and 60 per two-person household per UTC day.
The private configuration also has a nullable project spend ceiling in micro-US dollars. It stays
disabled until a provider/model and spending limit are explicitly approved; provider work will
supply its bounded estimate in task 21. Cached and in-flight replays do not increment counters.

## Verification

- A clean local database rebuild applied all 13 migrations, followed by all 215 pgTAP assertions.
  The 23 recognition checks cover grants, exact inputs, ownership, foreign references, readiness,
  replay/conflict states, revocation, user/household quotas, and the disabled project ceiling.
- Nine real competing-session scenarios pass. The added quota race holds one reservation open
  while a second distinct request crosses a one-attempt limit; exactly one analysis and one quota
  unit commit.
- Six isolated Deno tests pass for authentication/input validation, provider-disabled behavior,
  server-resolved reservation data, replay mapping, sanitized errors, limits, and malformed
  internal results. Type-check, strict formatting, lint, and strict database schema lint pass.

No AI key, provider request, personal image, cloud project, or direct client analysis write was
used. The [task 21 provider adapter](recognition-provider-development.md) adds schema-validated
execution and completion accounting with fake responses before any authorized evaluation.
