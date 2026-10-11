# HouseKeeping documentation

Updated September 18, 2026. The core app and backend are implemented and verified locally. The
approved cloud database, two-member household, private bucket, and photo `media`/`cleanup` Edge
Functions are provisioned; configured backups and hosted recovery proof, private device signing,
and two-phone acceptance remain open. Recognition is optional, undeployed, and disabled until its
separate evaluation passes.

## Start here

- [Run HouseKeeping locally](local-user-guide.md) — shortest path to the offline demo, connected local
  stack, synthetic accounts, and test commands.
- [HouseKeeping user guide](user-guide.md) — sign-in, shared inventory, photos, drafts, conflicts,
  deletion, recovery, and privacy behavior.
- [Product specification](spec.md) — approved product behavior and acceptance criteria.
- [Release acceptance matrix](acceptance-results.md) — evidence already collected and the exact
  hosted/two-phone checks still open.

## Product and design

- [Design specification](design.md)
- [Simulator screenshots](design-preview/README.md)
- [Architecture decision](architecture.md)
- [Two-person household model](shared-household.md)
- [Data and interface contracts](contracts.md)

## Delivery and operations

- [Implementation plan](implementation-plan.md)
- [Implementation task checklist](implementation-tasks.md)
- [Open-task criticality](release-criticality.md)
- [Local backend details and evidence](local-development.md)
- [Cloud deployment gate](deployment.md)
- [Two-account onboarding](account-onboarding.md)
- [Account removal, closure, backup, and recovery](recovery-runbook.md)
- [Private iPhone installation](private-installation.md)

## Feature evidence

- [Authentication and iOS configuration](ios-development.md)
- [Inventory adapter](inventory-development.md)
- [Durable drafts](draft-state-development.md)
- [Connected inventory screens](connected-inventory-development.md)
- [Quantity and restock limits](item-quantity.md)
- [Search performance](search-performance.md)
- [Photo reservations](photo-reservations-development.md)
- [Photo validation](photo-validation-development.md)
- [Photo attachment and cleanup](photo-lifecycle-development.md)
- [Photo preparation and drafts](photo-drafts-development.md)
- [Private photo service and screens](photo-service-development.md)
- [Native camera](camera-development.md)
- [Recognition authorization and quotas](recognition-boundary-development.md)
- [Recognition provider adapter](recognition-provider-development.md)
- [Editable recognition review](recognition-flow-development.md)
- [Deferred recognition evaluation](recognition-evaluation.md)

Feature evidence pages describe what passed at each checkpoint. Current release state comes from the
acceptance matrix and criticality page. “Locally complete” does not mean deployed or accepted on a
physical iPhone.
