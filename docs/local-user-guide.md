# Run HouseKeeping locally

This guide covers the offline simulator demo and the connected local Supabase build. Use synthetic
accounts and images only. Local services use development credentials and are not a private production
deployment.

## Prerequisites

- macOS with Xcode and an installed iPhone simulator; the project targets iOS 18 or newer.
- Node.js 22.
- Docker Desktop with a local Unix-socket Docker context.
- A complete Supabase CLI installation with the `supabase` and `supabase-go` binaries from the same
  release; version 2.109.1 is verified.
- Deno for Edge Function tests; version 2.9.5 is verified.

Clone the repository, enter it, and confirm the tree is clean:

```sh
git clone https://github.com/woobin0413/house-keeping.git
cd house-keeping
git status --short
```

## Fastest path: offline demo

The demo needs no Docker, Supabase configuration, Apple account, or network service.

```sh
open ios/HouseKeeping.xcodeproj
```

In Xcode, select the **HouseKeeping** scheme and an iPhone simulator, then Run. On the setup screen,
choose **Explore the demo**. Demo purchases and sample-photo suggestions are local sample data and
reset when the demo is exited or relaunched.

## Connected local build

Start Docker Desktop, then run the guarded launcher from the repository root:

```sh
node scripts/start-local.mjs
```

Do not use bare `supabase start` or bare `supabase db reset --local` on the verified CLI. The wrapper
forces all published ports to `127.0.0.1` and refuses unrelated Docker resources. A successful start
reports nine verified project containers.

Create the ignored app configuration:

```sh
cp ios/Configuration/Local.xcconfig.example ios/Configuration/Local.xcconfig
supabase status -o json
```

In `Local.xcconfig`, keep the existing loopback URL and replace only
`REPLACE_WITH_LOCAL_PUBLISHABLE_OR_ANON_KEY` with the reported `PUBLISHABLE_KEY` or legacy `ANON_KEY`.
Never paste `SERVICE_ROLE_KEY`, `SECRET_KEY`, a database password, or an AI key into the iOS project.
The file is ignored by Git.

The commands below assume `supabase` is on `PATH`. If it is not, replace each bare `supabase`
invocation with the absolute path to the trusted executable. `HK_SUPABASE_CLI` selects that
executable for `scripts/start-local.mjs`, but it does not rewrite commands entered in the shell.

The connected app requires two confirmed synthetic users and one household. Open local Studio at
`http://127.0.0.1:55323`, create two users under Authentication with `.invalid` email addresses, and
mark them confirmed. Copy their generated UUIDs. In Studio's SQL editor, generate a household UUID
and call the operator-only provisioning function:

```sql
select private.provision_household(
  '<new-household-uuid>',
  'Local test home',
  '<first-user-uuid>',
  '<second-user-uuid>'
);
```

Run the app from Xcode and sign in with either synthetic account. Changes are persisted in the local
Docker volume and shared between the two accounts. Recognition returns an unavailable/manual path
because no provider is configured. The offline sample remains available only in the explicit demo.

## Useful checks

Run the smallest documentation/configuration checks without starting the backend:

```sh
/usr/bin/ruby ios/Configuration/validate-public-key.test.rb
node --test scripts/local-safety.test.mjs
node --test scripts/audit-cloud-target.test.mjs
```

With the guarded local stack running, the main backend checks are:

```sh
supabase migration up --local
supabase test db
node supabase/tests/concurrency/households.mjs
node --test supabase/tests/integration/inventory.test.mjs
node --test supabase/tests/integration/recovery.test.mjs
node --test supabase/tests/integration/photos.test.ts
node --test supabase/tests/integration/account-maintenance.test.ts
supabase db lint --local --schema public,private --fail-on warning
```

Run Edge Function checks with Deno:

```sh
deno test --config supabase/functions/media/deno.json supabase/tests/functions/media.test.ts
deno test --config supabase/functions/cleanup/deno.json supabase/tests/functions/cleanup.test.ts
deno test --config supabase/functions/recognitions/deno.json supabase/tests/functions/recognition.test.ts
deno test --config supabase/functions/account-maintenance/deno.json supabase/tests/functions/account-maintenance.test.ts
```

For iOS tests, list destinations, set the simulator UUID, then run the shared scheme:

```sh
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping -showdestinations
export HK_SIMULATOR_ID='<simulator-uuid>'
xcodebuild -project ios/HouseKeeping.xcodeproj -scheme HouseKeeping \
  -destination "platform=iOS Simulator,id=${HK_SIMULATOR_ID}" \
  -derivedDataPath /tmp/housekeeping-derived-data CODE_SIGN_IDENTITY=- test
```

The optional connected Swift/Supabase check creates and removes synthetic users:

```sh
node scripts/test-ios-local-auth.mjs
```

## Stop and reset

Stop only this project's services when finished:

```sh
supabase stop
```

Normal stop preserves the local Docker volume. To get a clean database, stop the stack, remove only
the HouseKeeping-labelled local volume through an approved local maintenance step, and restart with
`node scripts/start-local.mjs`; do not use a broad Docker prune. See [local backend details](local-development.md)
for the binding limitation and complete evidence.

## Common problems

- **“Could not find `supabase-go`”**: install the complete Supabase CLI release and keep both binaries
  together. If the executable is outside `PATH`, set `HK_SUPABASE_CLI` for the startup wrapper and
  use its absolute path for direct CLI commands.
- **Setup screen instead of sign-in**: create `ios/Configuration/Local.xcconfig`, use only the local
  public key, clean/rebuild, and confirm the URL is exactly `http://127.0.0.1:55321`.
- **Sign-in succeeds but no inventory appears**: the confirmed synthetic identity has no household;
  provision both UUIDs with `private.provision_household`.
- **Recognition is unavailable**: expected for the core local build. Continue manually; do not add a
  provider key merely to run the app.
- **Local safety check reports wildcard ports**: stop the HouseKeeping stack and restart with the
  guarded launcher before sending any local request.
