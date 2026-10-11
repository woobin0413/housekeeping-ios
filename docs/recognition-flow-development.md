# Editable recognition flow

Task 22 connects the authenticated iPhone editor to the task 20–21 recognition boundary. The
production client is ready for an explicitly configured provider, but no model, credential, paid
request, or real image evaluation was used in this task.

The production composition currently leaves the recognition client disabled, so connected users
do not see the AI suggestion action. Offline preview/test fixtures still exercise the complete
review flow. Re-enable the production client only after task 23 approves a model, server-side key,
evaluation evidence, and spending limit.

## Review and fallback behavior

- Recognition starts only after the user taps the action below a clear disclosure that the prepared
  photo will be sent to the configured AI provider. The offline UI fixture says “sample” and states
  that it does not contact a provider.
- Upload and recognition progress are shown separately. “Continue manually” cancels the active
  client request while keeping the protected text and photo draft available.
- A suggestion fills only name, description, brand, and model. Purchase date remains user-owned,
  every field stays editable, and the existing Save purchase action is still the only operation that
  creates a shared purchase.
- Unrecognized, refusal, invalid response, quota, timeout, and unavailable states keep manual entry
  usable. A provider failure never substitutes demo content in the connected app.

## Identity and late-result safety

The app sends only `photoId` and a persisted `requestId` to the fixed same-project Edge Function
route. The provider image upload remains server-side. The recognition request ID is stored with the
protected image draft before the call: an uncertain transport result replays that ID, while a
definite server retry state records that the next explicit attempt needs a new ID.

A result can populate fields only while the same account-scoped store, text draft, and image draft
remain active and the fields still equal their pre-request values. Editing during recognition keeps
the user's fields. Manual continuation, sheet dismissal, save, discard, sign-out, account
replacement, and photo replacement all invalidate pending results.

## Verification

- Seven focused Swift tests cover editable suggestion review, no purchase before confirmation,
  timeout/manual save, durable request renewal and uncertain replay after reconstruction, stale
  fields, cancellation/discard, authenticated HTTP decoding, error normalization, and oversized or
  malformed responses.
- The complete iOS unit target passes with 132 named tests (163 device-reported passes after
  parameterized cases expand) and two expected environment skips on an iPhone 17 Pro simulator.
- The complete native UI target passes 20 tests with one opt-in photo-library fixture skip. Two new
  journeys edit an explicitly labeled offline sample before saving and save manually with the same
  photo after a simulated recognition timeout.
- The real local Swift/Supabase journey passes with disposable accounts. It uploads and finalizes a
  synthetic photo, receives the expected unavailable result from the deliberately unconfigured
  provider path, and then saves the manual text and photo together. The guarded stack verifies all
  published ports bind to `127.0.0.1`.
- A generic simulator build and strict recursive Swift formatting pass.

Task 23 remains the approval boundary for choosing and configuring a model, spending money, sending
authorized evaluation images, and measuring usefulness, unsupported claims, latency, and cost.
