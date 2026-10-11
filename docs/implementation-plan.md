# Implementation plan: private shared inventory

Status (2026-09-14): shared inventory, private photo preparation/storage/display/removal, native camera fallback, recognition authorization/review/manual fallback, and operator account-maintenance controls pass locally. The [critical release chain](release-criticality.md) is tasks 24–27: cloud onboarding, hosted recovery proof, private installation, and two-phone acceptance. Provider evaluation is deferred with recognition disabled.

## Outcome and boundaries

Deliver one persistent inventory and photo collection for the user and his wife, each using separate credentials. Keep the approved SwiftUI design, including compact Add/Save actions. Follow [spec.md](spec.md), [contracts.md](contracts.md), and [shared-household.md](shared-household.md).

Start locally with synthetic identities and sample images. Do not provision real accounts, send email, choose a paid plan, deploy to an unidentified project, or publish the app as part of local implementation. The local core milestone includes shared manual inventory and private photos; release completion still requires the critical hosted/device evidence.

## Components and build order

### 1. Local backend and authorization foundation

Verify the local Supabase/Docker prerequisites without changing unrelated services. Add local configuration, repeatable schema migrations, and isolated test fixtures. Implement households, two-member provisioning, item constraints, grants, and membership-based row access. Public signup and anonymous sign-in remain disabled; privileged provisioning stays outside the app.

Verification checkpoint: both synthetic spouses read the same records; anonymous, unrelated, and revoked users are denied. Client membership mutation, third-member provisioning, and second-household membership fail. Test actual access policies, not just helper functions.

### 2. Email/password login and secure sessions

Add the compatible Supabase Swift dependency and pin its resolved version after a build check. Introduce a small authentication adapter, protected session storage, and sign-in/sign-out screens. Handle invalid credentials, expired sessions, no household membership, and connectivity failures. Support initial password setup and password recovery with validated redirects and neutral responses; test using local email capture before authorizing real email delivery.

Verification checkpoint: both test users can sign in independently, resume a valid session, recover access, and sign out. Signing out clears session-specific state without leaking one account's draft or cached photos into another. No password or administrator key appears in source, logs, or fixtures for real users.

### 3. Persistent shared inventory

Implement the existing typed inventory contract with server-side search, transactional writes, retry-safe creation, and optimistic version checks. Replace the composition root's demo-only store with an injected live adapter while keeping explicit offline preview/test adapters. Preserve current screen styling; add loading, retry, edit/delete, conflict, and refresh behavior. Track quantity on hand and a per-item restock limit, showing a restock state when quantity is at or below the limit.

Verification checkpoint: spouse A creates an item with stock values, restarts the app, and still finds it; spouse B refreshes, finds it, and can edit the quantity, limit, or other details. Repeat in reverse. At-or-below-limit items show the restock state. Duplicate saves create one item. Concurrent stale edits cannot silently overwrite each other. Run the existing design smoke tests plus connected-flow tests. This is the first usable milestone, without photos yet.

### 4. Private shared photos and durable drafts

Add protected local draft storage, photo-library selection, normalization, private upload reservation/finalization, authenticated downloads, and cleanup retries. Validate real image bytes before marking a photo ready. Prove the selected function runtime can perform bounded image validation; revisit processing placement if it cannot, rather than dropping validation. Attach photos atomically and use household access for saved photos, uploader-only access for unfinished uploads.

Verification checkpoint: each spouse downloads the other's attached image bytes through the Storage API. Forged paths and foreign references fail. Abandoned uploads expire; item/photo deletion retries cleanup without broken references. Offline or failed uploads preserve recoverable local drafts. Include upload/attachment/cleanup race tests.

### 5. Camera and recognition

Native camera permissions, capture, retake, simulator fallback, authenticated recognition authorization, schema validation, request deduplication, quota limits, and manual fallback are implemented. Physical-device camera checks remain. The provider stays unconfigured unless an authorized representative-photo evaluation and spending limit later justify enabling it. Suggestions never create purchases without confirmation.

Verification checkpoint: manual entry still works when camera permission or recognition fails. Late suggestions cannot overwrite edits. Provider fixtures cover malformed output and timeouts; real-device and authorized model-evaluation results are recorded separately.

### 6. Private deployment and two-phone acceptance

The deployment gate, account-onboarding procedure, local member-removal/closure implementation, recovery plan, Ad Hoc distribution recommendation, and acceptance matrix are prepared. Completion requires the identified Supabase target, approved backup configuration, signing assets, and the two authorized phones. Review migrations before applying them; no public listing is part of this plan.

Verification checkpoint: the two actual accounts pass bidirectional inventory/photo tests on the two phones, including refresh and edit conflicts. Verify revocation, account-removal preservation, household-closure cleanup, and a restore of both an item and its photo. No production-ready claim before these checks.

## Dependencies and parallel work

Authorization and contract tests precede connecting real data. Authentication and inventory adapters can be prepared independently once the contracts are stable, but shared integration requires both. Photo preparation and media finalization can be developed independently; attachment must wait for the transaction and policy checks. Recognition depends on validated private uploads. This describes separable work, not authorization to spawn agents or deploy services concurrently.

## Main risks and mitigation

| Risk | Mitigation |
| --- | --- |
| Photo access accidentally restricted to uploader | Test both spouses fetching the same saved object via authenticated Storage requests. |
| UI-only privacy restrictions | Test direct database/Storage requests, grants, membership controls, and disabled signup. |
| Conflicting edits or repeated saves | Version checks and idempotent creation, with race and retry tests. |
| Database row and photo lifecycle diverge | Transactional attachment plus durable Storage cleanup jobs and retry visibility. |
| Recovery links or local caches expose credentials/data | Validate auth redirects, protect sessions, isolate caches, and test account switching. |
| Local prerequisites or image decoding fail | Resolve the local tool/runtime issue explicitly; retain manual-entry progress and do not substitute a live project for tests. |
| Preview appears connected when it is not | Keep demo mode explicit; never silently fall back to sample data on live errors. |

## Review checkpoint

Work only the critical tasks 24–27 in the [implementation checklist](implementation-tasks.md). Their remaining actions depend on the approved cloud project, verified account targets, backup destination, signing team, and two phones. Keep passwords and administrator secrets out of source, documentation, and chat.
