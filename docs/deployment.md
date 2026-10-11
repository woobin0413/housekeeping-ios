# Private cloud deployment

Status (2026-09-18): the approved private project has all 17 migrations, the private photo bucket,
two verified household members, and active JWT-protected `media` and `cleanup` Edge Functions.
Recognition remains undeployed and has no provider secret. Account-maintenance deployment, hosted
recovery/backup proof, private installation, and two-phone acceptance remain open.

## Target and authority

Use a dedicated existing Supabase project whose exact project ref, name, and region the owner has
identified. Project creation, a plan change, cloud writes, real-account creation, outbound email, and
device distribution remain separate actions. Do not paste an access token, database password, SMTP
credential, service key, API key, user email address, or recovery link into chat, source, an issue, or
a command-line argument.

The audit uses four documented Management API capabilities: [get a project](https://supabase.com/docs/reference/api/v1-get-project),
[get Auth configuration](https://supabase.com/docs/reference/api/v1-get-auth-service-config),
[list Storage buckets](https://supabase.com/docs/reference/api/v1-list-all-buckets), and the beta
[read-only database query](https://supabase.com/docs/reference/api/v1-read-only-query). Create a
short-lived fine-grained access token with only `project_admin_read`, `auth_config_read`,
`storage_read`, and `database_read`. The database endpoint executes only `SELECT` as the platform's
read-only role. Revoke the token when deployment work ends.

Copy `.env.cloud.example` to the ignored `.env.cloud`, set mode `0600`, and fill it locally. Choose
`custom-smtp` for dependable delivery. `supabase-team-only` is acceptable only when both intended
addresses are already authorized organization-team addresses and the owner accepts the default
mailer's restrictions.

```sh
cp .env.cloud.example .env.cloud
chmod 600 .env.cloud
set -a
. ./.env.cloud
set +a
node scripts/audit-cloud-target.mjs > /tmp/housekeeping-cloud-audit.json
```

The command never returns Auth templates, SMTP fields, account addresses, database rows, or the
access token. It prints boolean/configuration checks, row counts, schema names, migration versions,
and a SHA-256 review digest. It makes three `GET` calls and one read-only-query `POST`. If migration
history exists, it makes a second read-only query for the versions; a target that already has the
exact migration set gets one additional read-only row-count `POST`. Every database request uses the
fixed Management API read-only endpoint. A nonzero exit is expected when a new
project still has open signup or other settings that must change.

Before any write, the `project-ref`, `project-name`, `project-region`, and `project-status` checks must
match the intended target. `database-baseline` must be `empty` or `current-unused`; an unexpected,
partial, or populated schema blocks deployment. A pre-existing public `purchase-photos` bucket also
blocks deployment.
Review every remaining failed check as the exact proposed configuration change, and bind cloud-write
approval to the project ref, region, repository commit, audit digest, migration list, and function
names.

## Migration and function review

Linking changes only ignored local CLI state, but still verify the ref before entering the database
password at the interactive prompt. Never put the password in `--password`, shell history, or the
environment file above.

```sh
supabase link --project-ref "$HK_SUPABASE_PROJECT_REF"
supabase migration list --linked
supabase db push --dry-run
git status --short
git rev-parse HEAD
git log --oneline --reverse -- supabase/migrations supabase/functions supabase/config.toml
```

The dry run must list exactly the 17 timestamped files in `supabase/migrations`, in order, when the
target is empty. If it shows remote-only migrations, a partial history, or fewer local migrations,
stop. Do not use `db reset`, `migration repair`, `--include-all`, or a remote SQL editor to force the
histories to match. Supabase's [environment workflow](https://supabase.com/docs/guides/deployment/managing-environments)
and [CLI reference](https://supabase.com/docs/reference/cli/supabase-db-push) distinguish the dry run
from the mutating push. Review the complete contents of every listed migration and named function at
that clean commit; an uncommitted checkout or an unreviewed commit is not a deployment input.

Review the Auth changes separately in the dashboard before applying them. The intended hosted values
are:

- global public signup off while email/password remains enabled for existing users;
- anonymous, phone, Web3, OAuth, passkey, and manual identity linking off;
- email confirmation required, unverified email sign-in off, secure password changes on, and a
  minimum password length of 12;
- the exact recovery allow-list entry `housekeeping://auth/recovery`, with no wildcard redirect;
- the approved custom SMTP sender, or the explicitly accepted two-address team-only default.

Do not run `supabase config push` directly from this checkout. The tracked `site_url` is intentionally
localhost for guarded development, and a broad config push would apply local-only values to the
hosted project. Enter the reviewed hosted Auth values in the dashboard. Supabase documents that a
disabled signup setting still permits [existing users to sign in](https://supabase.com/docs/guides/auth/general-configuration),
that mobile applications can use [deep-link redirect URIs](https://supabase.com/docs/guides/auth/redirect-urls),
and that its default SMTP service is restricted and has no delivery SLA; [custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp)
is required for dependable user email.

After explicit approval of the concrete target and change set, the database/function write sequence
is:

```sh
supabase db push
supabase functions deploy media --project-ref "$HK_SUPABASE_PROJECT_REF"
supabase functions deploy cleanup --project-ref "$HK_SUPABASE_PROJECT_REF"
supabase functions deploy account-maintenance --project-ref "$HK_SUPABASE_PROJECT_REF"
supabase functions list --project-ref "$HK_SUPABASE_PROJECT_REF" --output json
```

Keep JWT verification enabled and deploy functions one at a time. Do not add `--no-verify-jwt` or
`--prune`. Do not deploy `recognitions` or set `OPENAI_API_KEY`, `OPENAI_MODEL`,
`RECOGNITION_PROVIDER`, or recognition cost limits until task 23 selects a model and the owner
separately approves that configuration and spend. The production app keeps the AI action disabled
until then.

Run the `pre-deploy` audit again after Auth, migrations, bucket, and functions are configured. It must
now pass before account invitations. The bucket originates from migration `20260910000100` and must
remain private, limited to 5 MiB, and restricted to `image/jpeg`; Supabase applies access control to
[private buckets through RLS](https://supabase.com/docs/guides/storage/buckets/fundamentals).

## App configuration and verification

Create the already-ignored `ios/Configuration/Local.xcconfig` with only the hosted HTTPS URL and a
public `sb_publishable_...` key. Never use a secret key or legacy service-role JWT. The build phase
validates both fields without printing them.

```text
HK_SUPABASE_URL = https:/$()/PROJECT_REF.supabase.co
HK_SUPABASE_PUBLISHABLE_KEY = sb_publishable_REPLACE_LOCALLY
```

Follow [account onboarding](account-onboarding.md), then change `HK_CLOUD_AUDIT_PHASE` to
`post-deploy` and rerun the audit. Post-deployment success requires exactly two confirmed Auth users,
one household, two memberships, the exact migration/relation/policy sets, RLS on every public app
table, no anonymous app-table privileges, no direct authenticated writes, and the exact private
bucket contract.

Use each account on its owner's authorized iPhone for the final smoke checks:

1. User A signs in, creates an item with a prepared JPEG, and signs out.
2. User B signs in, sees and downloads the same item/photo, edits it, then creates a second item/photo.
3. User A sees User B's changes and second item/photo.
4. Each user completes one recovery flow through the exact app deep link.
5. Remove the two smoke items through the app and invoke one bounded cleanup run; confirm no pending
   smoke objects or jobs remain.

Record only pass/fail, timestamps, app build, project ref, and nonsecret request IDs. Do not save real
addresses, recovery links, tokens, photos, or inventory content in the repository.

## Failure and rollback boundary

Record the repository commit and the pre-write audit report before deployment. If migration or
function deployment fails, stop further writes, rerun `migration list` and the read-only audit, and
inspect the failed operation. Do not reset the hosted database or rewrite migration history. These
migrations do not have automatic down migrations.

Before onboarding, the accepted target contains no user data, so leaving a failed deployment idle is
safer than destructive cleanup. Function code can be restored by checking out the recorded commit
and redeploying only the affected named function after approval. Project deletion, database restore,
migration repair, user deletion, bucket deletion, and plan changes are destructive or externally
visible operations and require a new concrete review. Cleanup scheduling, backup/restore, and
household closure are completed under task 25 rather than improvised during deployment.
