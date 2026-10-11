# Private shared-household setup

Status (2026-09-14): household scope and email/password authentication are confirmed. Local database APIs, native authentication/recovery, persistent inventory/photos, and account-maintenance controls are implemented and tested; see [local development](local-development.md), [iOS status](ios-development.md), and the [recovery runbook](recovery-runbook.md). This is not a deployed backend. The explicit inventory demo remains available.

## Confirmed outcome

The user and his wife each sign in independently to one household. Both can access all saved purchases and attached photos, including purchases created by the other person. Neither a shared password nor duplicate per-person collections are needed. There is no public App Store listing and no public signup flow.

The household is the authorization boundary. The uploader/creator fields describe attribution, not exclusive ownership of saved content. Local drafts and unfinished uploads are not shared until the user saves the purchase.

## Authentication decision

Confirmed: email/password with exactly two administrator-provisioned accounts. Disable public signup, anonymous sign-in, and unused providers. The iPhone presents sign-in/sign-out and session recovery, not registration. Verify each account owner's email before membership is granted; never invent real account addresses, store passwords in fixtures, or transmit credentials through chat. Password recovery and secure initial credential setup must be tested before either real user is onboarded.

Supabase documents that disabling new-user signup restricts sign-in to existing accounts in its [Auth configuration](https://supabase.com/docs/guides/auth/general-configuration). Its [admin user-creation API](https://supabase.com/docs/reference/javascript/auth-admin-createuser) belongs in trusted server/operator tooling, not the iOS binary.

Sign in with Apple is not included in the initial implementation. Do not enable additional providers or temporarily open general signup to discover the two identities.

Signing in does not grant data access by itself. An authenticated identity must also have an administrator-controlled household membership. The UI may show a neutral “Household access has not been set up” state when membership is absent.

## Storage and database contract

- PostgreSQL holds one household, its two memberships, purchases, and photo references.
- The private `purchase-photos` bucket holds photo bytes once uploaded.
- Either member can read attached photos by authenticated download. Policies must resolve membership through the saved item's household, not require the downloader to equal the uploader.
- An uploader can access their own reserved/ready photo before attachment. The other member gains access when it becomes attached to a saved item.
- No public object URLs, user-editable membership metadata, or app-bundled server secrets.
- Client-side photo deletion goes through the inventory operation, which queues Storage API cleanup; do not grant arbitrary direct object deletion that leaves broken item references.

These boundaries use the [Supabase Storage RLS model](https://supabase.com/docs/guides/storage/security/access-control). Detailed inputs, outputs, state transitions, conflicts, and provisioning rules are in [contracts.md](contracts.md).

## Acceptance checks

1. User A saves a purchase and photo; user B refreshes and reads the same record and image bytes. Repeat in the other direction.
2. Either user can edit or delete the other's purchase. Simultaneous edits based on one version produce one success and one recoverable conflict.
3. Anonymous callers, unrelated authenticated identities, forged paths, and revoked memberships cannot access either records or attached images.
4. A normal app session cannot change membership or provision households. A privileged attempt to add a third member or second household membership is rejected.
5. Public and anonymous signup are denied by the backend, not just hidden in the UI.
6. Sign-out clears app-owned credentials/cache after warning about unsaved drafts. Account removal preserves the other person's shared history.

## Release scope and remaining critical work

The [live inventory adapter](inventory-development.md), [durable drafts](draft-state-development.md), [connected inventory](connected-inventory-development.md), private image flow, native camera, and recognition/manual fallback all pass their local checks. The account-maintenance backend locally proves revocation, continuing-spouse preservation, image ownership transfer, closure cleanup, and repeat-safe retries with synthetic identities and bytes.

The [critical release chain](release-criticality.md) is cloud target/onboarding, hosted recovery and restore proof, private installation, and two-phone acceptance. Guarded startup verifies explicit localhost-only publishing; use `node scripts/start-local.mjs`, not bare CLI startup. Details and the remaining cold-cache/device performance limits are in [local-development.md](local-development.md).

Before cloud connection, identify the target Supabase project/region and obtain approved configuration through a local ignored file or service connection. Administrator secrets stay out of chat and source. Cloud writes, real-account creation, external messages, and iPhone signing require their explicit targets.

## Review checkpoint

Email/password, the build order, and the task list are approved. Private installation on the two iPhones and backup configuration remain release inputs. Recognition stays disabled, so provider/model spending is outside the current critical path.
