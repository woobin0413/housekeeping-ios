# Two-account onboarding

Status: this is an operator runbook. No real identity, invitation, email, household, or recovery
message has been created. Start only after the target-specific deployment audit passes and the owner
authorizes the two exact recipients and outbound messages.

## Private worksheet

Keep the following values in a password manager or an encrypted local note, outside this repository:

- the two intended email addresses;
- each Auth user UUID after creation;
- one generated household UUID and the chosen household display name;
- invitation and recovery completion timestamps;
- the project ref and deployed repository commit.

Do not share passwords between users. Do not record passwords, access/refresh tokens, invitation
links, recovery links, service keys, database passwords, or SMTP credentials. Do not use screenshots
that expose those values as evidence.

## Preconditions

The latest `pre-deploy` audit must pass with the exact project ref, name, and region. Confirm the
hosted app has closed public signup, email confirmation, the exact recovery redirect, private
`purchase-photos`, and the three named Edge Functions with JWT verification. Confirm the read-only
database count is zero Auth users, zero households, and zero memberships before the first invitation.

Email delivery must already be configured. Supabase's default sender delivers only to
[pre-authorized organization-team addresses and is rate-limited](https://supabase.com/docs/guides/auth/auth-smtp).
When that mode is explicitly selected, verify both recipients are already authorized and allow for
the current rate limit. Otherwise finish custom SMTP setup and verify its sender/domain before using
real addresses.

Obtain approval for exactly these external effects as one reviewable batch: create two identities,
send one invitation to each approved local address, create one household with those two confirmed
members, then send one recovery message to each address during acceptance. If an invitation must be
resent, treat it as another message to the same already-approved recipient and record why.

## Create and verify exactly two identities

Use Supabase Dashboard **Authentication → Users → Invite user** for the first approved address, then
the second. The dashboard/Admin Auth path is privileged and bypasses the absent public registration
UI; never embed an Admin API or service key in the iOS app. Do not create placeholder, shared, test,
or operator identities in this project.

After each recipient accepts the invitation and chooses a unique password, inspect the user record:

- its UUID is distinct and belongs to the intended address;
- email confirmation has a timestamp;
- no phone identity, social identity, anonymous identity, or extra factor appeared;
- the total Auth user count is exactly two.

If one invitation fails, keep and retry that existing identity. Do not create a replacement or a
third user. Do not grant household membership until both intended records are confirmed.

## Provision the household once

Generate and retain one household UUID locally. In the target's SQL editor, review the ref again and
execute the following transaction with only the UUIDs and household name substituted. This is a
cloud database write and is part of the approved onboarding batch.

```sql
begin;
select private.provision_household(
  'HOUSEHOLD_UUID'::uuid,
  'HOUSEHOLD_NAME'::text,
  'FIRST_CONFIRMED_USER_UUID'::uuid,
  'SECOND_CONFIRMED_USER_UUID'::uuid
);
commit;
```

The function rejects unconfirmed/missing/duplicate users, a third slot, reuse of either identity in
another household, or conflicting retries. Repeating the exact call with the same UUID, name, and
users is safe. Never insert directly into `households` or `household_members`.

Set `HK_CLOUD_AUDIT_PHASE=post-deploy` locally and rerun `node scripts/audit-cloud-target.mjs`. Save
the sanitized report under `/tmp`. Every check must pass before installing a connected build.

## Initial login and recovery acceptance

Run these checks separately on each owner's authorized phone. Do not operate one person's mailbox or
choose a password for them.

1. Install the same reviewed build and confirm its displayed connection state points to the approved
   project.
2. Sign in, load the shared household, background/relaunch the app, and confirm the protected session
   restores.
3. Sign out and confirm cached session and household images are cleared.
4. Use **Forgot password** once. Open the received message on that phone, follow the exact
   `housekeeping://auth/recovery` deep link, choose a new unique password, and confirm the old
   password no longer works.
5. Sign in with the new password and repeat the session-restoration check.

Then perform the bidirectional inventory/photo smoke matrix from [deployment](deployment.md). Each
person must be able to view the other's attached photo, while unfinished uploads remain visible only
to the uploader. Confirm an unauthenticated request cannot list or download the bucket.

## Stop conditions

Stop onboarding if the project identity changes, any audit check fails, a third Auth user appears,
either email is unconfirmed, the recovery link does not open the intended app, the bucket is public,
or one user cannot read the other's attached photo. Preserve nonsecret request IDs and timestamps for
diagnosis. Do not fix the issue by opening signup, sharing credentials, weakening RLS/JWT checks,
adding wildcard redirects, or deleting an identity that may hold household data.

Account removal, household closure, durable object backup, and restore drills remain task 25. Until
that work passes in isolation, keep the two-user household intact and remove only the explicit smoke
items through the app's normal operations.
