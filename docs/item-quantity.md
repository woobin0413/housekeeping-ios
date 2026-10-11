# Item quantity and restock limit

## Objective

Show both the quantity on hand and a per-item restock limit so either household member
can see when supplies need replenishment. Quantity and restock limit are editable whole
numbers from 0 through 2,147,483,647. Both default to 1 for new items, migrated rows,
and older protected drafts. An item needs restocking whenever `quantity <= restockLimit`;
quantity zero is additionally labeled “Out of stock”. There is no automatic consumption,
notification, shopping list, or background ordering.

## Tech stack and project structure

The existing SwiftUI, Swift Observation, Supabase/PostgreSQL, Swift Testing, XCTest,
and pgTAP stack remains unchanged; no dependency is added.

- `ios/HouseKeeping/Domain` owns item validation, compatibility decoding, patches,
  and conflict rebasing.
- `ios/HouseKeeping/Features` renders and edits stock values with native SwiftUI controls.
- `ios/HouseKeeping/Data` carries the values through live and preview repositories.
- `ios/HouseKeepingTests` and `ios/HouseKeepingUITests` cover domain and user journeys.
- `supabase/migrations` owns additive schema/RPC changes; `supabase/tests` covers the wire contract.

Quantity and restock limit appear together in inventory rows, details, manual/photo
review, and conflict summaries. Changes use the existing explicit save, optimistic
version checks, shared refresh, and durable draft recovery. Recognition suggestions
leave both stock values unchanged.

## Implementation plan and tasks

1. Extend domain models and draft patches with `restockLimit`, preserving decoding of
   older items and drafts with a default of 1. Test defaulting, bounds, encoding, recovery,
   patch generation, recognition preservation, and conflict rebasing.
2. Add an additive `restock_limit` database migration. Extend item JSON and transactional
   create/update validation, and normalize old retry fingerprints to limit 1. Test defaults,
   boundary values, invalid input, replay, unrelated edits, search/detail output, and conflicts.
3. Update the connected and explicit-demo interfaces to display the limit and a visible
   “Restock now” state at or below it. Edit quantity and limit with separate accessible
   steppers and verify the saved values in the existing two-account UI journey.
4. Update the README, product specification, contracts, user guide, implementation plan,
   task checklist, deployment migration count, and verification evidence.

## Code style

Follow existing camelCase Swift/JSON and snake_case SQL naming. Treat omission as
unchanged for updates and use defaults only for creates or compatibility decoding:

```swift
ItemPatch(quantity: 0, restockLimit: 2)
```

The patch changes exactly those two fields. An omitted `restockLimit` does not overwrite
the saved threshold.

## Commands

Commands (from the repository root):

```sh
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/housekeeping-quantity-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -showdestinations
# Use an installed simulator ID for HK_SIMULATOR_ID.
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -destination "platform=iOS Simulator,id=${HK_SIMULATOR_ID}" -derivedDataPath /tmp/housekeeping-quantity-build CODE_SIGN_IDENTITY=- test
supabase migration up --local
supabase test db
```

Always validate at both boundaries and preserve authorization, retries, and photo
lifecycle. Ask before deployment to a cloud target or changing unrelated features.
Never reset existing data or commit credentials. Acceptance requires quantity and
restock limit to survive saving/reloading and draft recovery, including zero;
unrelated edits, recognition, and photo removal must preserve both. Cloud rollout must
apply the migration before an updated app writes the new field.

## Success criteria

- Every inventory row and detail displays quantity on hand and restock limit.
- “Restock now” appears exactly when quantity is less than or equal to the limit;
  quantity zero also displays “Out of stock”.
- Either household member can create or edit both values, with optimistic conflicts
  handled by the existing review flow.
- Database and Swift validation reject null, fractional, negative, nonnumeric, or
  greater-than-32-bit values.
- Older rows, requests, app responses, and protected drafts retain a compatible default of 1.
- The iOS build, focused tests, database tests, lint/format checks, and diff review pass.

## Boundaries

- Always: validate both values in Swift and PostgreSQL; preserve authorization,
  idempotency, version checks, draft durability, photo lifecycle, and accessibility.
- Ask first: deploy the migration or app to a hosted target; change notification,
  shopping-list, recognition, or account behavior.
- Never: reset shared data, rewrite migration history, commit credentials, or let a
  recognition suggestion overwrite user-entered stock values.

## Open questions

None. The accepted defaults are limit 1 and restock at `quantity <= restockLimit`.

## Verification record

Verified locally on 2026-09-18:

- The generic simulator build and complete iPhone 17 Pro / iOS 26.5 scheme passed:
  136 unit tests and 21 UI tests, with only two unit and one UI environment-dependent
  skips. The two-account journey creates and reloads both stock values, then saves
  quantity zero and confirms both “Out of stock” and “Restock now”.
- All 306 pgTAP assertions and all 18 inventory HTTP integration tests passed. The
  migration was applied only to the isolated local HouseKeeping database.
- Supabase schema lint, strict Swift formatting, 92 public-key configuration assertions,
  12 local safety/cloud-audit contract tests, and `git diff --check` passed.

The reviewed seventeenth migration was applied to the approved hosted project on 2026-09-18;
post-deploy migration history matches all 17 local versions.
