# JPEG validation and readiness: implementation status

Status: task 15 is implemented and verified locally. An uploaded object becomes `READY` only after the authenticated media function strictly decodes real JPEG bytes and a service-only database transaction rechecks the lifecycle boundary.

## Validation boundary

- Function-local `deno.json` and `deno.lock` pin Supabase JS 2.55.0 and `jpeg-js` 0.4.4. The decoder is pure JavaScript with no transitive dependencies; the frozen lock records the complete graph.
- Validation rejects inputs above 5 MiB before decoding, reads JPEG dimensions before allocation, and caps each edge at 2,048 pixels and total pixels at 4,194,304.
- `jpeg-js` runs with tolerant decoding disabled, RGB output, a 96 MiB internal memory ceiling, and a 1.5-second validation budget. Missing end markers, malformed marker streams, truncated entropy, trailing payloads, and inconsistent decoder output fail.
- The function computes byte size and lowercase SHA-256 itself. Client headers, filenames, dimensions, and checksums are never trusted.
- `finalize_photo` is executable only by `service_role`; it locks the row and rechecks uploader, active membership, object existence, expiry, state, byte bounds, MIME, and checksum shape. An ordinary session's direct RPC attempt is denied. Identical and concurrent completion returns the existing `READY` result without changing metadata.

## Verification

- Five Deno tests pass: real decode/checksum, malformed and truncated inputs, byte/edge limits, decoder consistency/timeout, and maximum 2,048×2,048 dimensions. The maximum case decoded in approximately 244 ms on the local machine.
- All 168 database assertions pass, including 12 finalization tests for privileges, metadata, idempotency, conflict, missing object, expiry, uploader mismatch, and revocation.
- All 31 HTTP tests pass. The media route accepts a genuine JPEG and stores an independently verified SHA-256, handles simultaneous completion safely, and rejects plausible-MIME malformed/truncated bytes, missing or oversized uploads, expired reservations, nonempty input, spouse/outsider completion, and direct finalizer bypass.
- Deno type-check, lint, formatting, frozen dependency resolution, and vulnerability audit pass. The dependency graph is 6.64 MiB, so deployment must use the Supabase CLI's local bundling path rather than the 5 MiB server-side bundler.

This document validates readiness. Atomic attachment, discard/expiry cleanup, deletion retries, and lifecycle races are implemented separately in [task 16](photo-lifecycle-development.md). No cloud project, personal image, or paid service was used.
