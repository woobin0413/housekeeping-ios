# Release acceptance results

Status (2026-09-18): all 17 migrations and the authenticated photo `media` and `cleanup` functions
are deployed to the approved project. Critical task 27 is prepared but not complete. This matrix
distinguishes existing local or simulator evidence from required hosted/two-phone evidence. No
unchecked row is a release pass. Recognition is absent from the production composition and cloud
deployment, so its rows remain behind the explicit disabled-feature gate.

| Criterion | Current evidence | Required critical evidence | Status |
| --- | --- | --- | --- |
| AC-01 manual create/relaunch/find | Real local SDK and two-account inventory journeys pass | Repeat on each authorized phone against the approved project | Open |
| AC-02 search semantics/isolation | 31 SQL assertions and authenticated local HTTP checks pass | Repeat isolation plus task 05 cloud/device timing during this matrix | Open |
| AC-03 physical capture/restart | Simulator capture/preparation and local upload persistence pass | Permission, capture, orientation, upload, backend restart, and download on a real iPhone | Open |
| AC-04 editable recognition/no autosave | Offline provider fixtures and editable UI flow pass | Disabled for core release; requires task 23 before provider enablement | Gated off |
| AC-05 recoverable failure paths | Offline draft, denied-camera, failed-upload, and failed-recognition tests pass | Network loss and camera denial/interruption on a real phone | Open |
| AC-06 idempotency/conflict | Database, HTTP, Swift, and competing-session checks pass | Two-phone conflicting save against hosted project | Open |
| AC-07 unauthorized access/quota | Local RLS, HTTP, and recognition-boundary denial checks pass | Post-deploy audit plus anonymous/foreign/revoked hosted probes | Open |
| AC-08 photo expiry/cleanup | Storage-first retry ledger and cleanup worker pass locally | Hosted schedule, failure visibility, and removal within 24 hours | Open |
| AC-09 search performance | 10,000 rows: warm DB 5.616 ms, local HTTP 8.600 ms | 100 cold/warm hosted queries and stable-connection device timing | Open |
| AC-10 recognition latency | Evaluation runner prepared | Disabled for core release; task 23 required before enablement | Gated off |
| AC-11 recognition usefulness/safety | Strict fake-response validation passes | Disabled for core release; authorized 40-image evaluation required before enablement | Gated off |
| AC-12 accessibility/layout | Largest-text Pro/SE simulator journeys and touch targets pass | Manual VoiceOver, contrast, keyboard, retry, and smallest-phone checks | Open |
| AC-13 member removal/closure | All 254 database assertions and five ownership-transfer tests pass; a three-test local HTTP suite proves actual local Storage/Auth removal and closure while preserving spouse bytes | Hosted isolated removal/full closure with hosted Storage and Auth Admin APIs | Open |
| AC-14 records plus image restore | Separate database/object backup set and exact-byte restore procedure are specified; no configured backup exists | Approved backup destination plus isolated restore of one purchase and exact image bytes | Open |
| AC-S1 bidirectional household | Local two-account item/photo flows pass | Both directions on the two authorized phones | Open |
| AC-S2 closed signup/revocation | Local Auth/RLS checks pass | Hosted Auth audit and revoked-session probe | Open |
| AC-S3 operator-only provisioning | 36 SQL provisioning/grant assertions pass | Post-onboarding hosted audit: exactly two confirmed members | Open |
| AC-S4 simultaneous edit conflict | Local concurrent version checks pass | Coordinated edit from both phones; one success and one preserved draft | Open |

## Evidence recording rules

For each hosted/device run, record date/time, repository commit, app build identifier, project ref,
device model/iOS version, connection type, pass/fail, and nonsecret request IDs. Record aggregate
latency and cleanup counts rather than inventory text or image contents. Never commit email addresses,
tokens, recovery/invitation links, device identifiers, signing material, personal photos, or raw
provider output.

Any failed authorization, data-retention, restore, or cross-household test blocks release. A failure
in a recognition-gated row keeps recognition disabled. Performance results remain factual even when
they miss a target; do not relabel a failed threshold as passed.
