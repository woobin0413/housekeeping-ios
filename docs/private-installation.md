# Private iPhone installation

Status: critical task 26 is prepared through the signing/account boundary. No Apple account was
accessed, no device identifier was collected, no certificate/profile was created, no archive was
exported, and no build or invitation was distributed.

## Decision

**Recommended for this two-person household: Ad Hoc distribution to exactly two registered
iPhones.** It matches the no-public-listing requirement, limits installation to named devices, and
does not require TestFlight beta review. Apple documents that an Ad Hoc profile requires an App ID,
a distribution certificate, and registered devices, and that Xcode can manage the profile
automatically: [create an Ad Hoc profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile).

This route requires an active Apple Developer Program membership. Apple currently lists membership
at USD 99 per year where that price applies; a free Personal Team uses seven-day App IDs, devices,
and profiles and therefore is not a durable release route: [membership comparison](https://developer.apple.com/support/compare-memberships/).
Registered-device distribution also requires Developer Mode on each iPhone and installation through
Xcode/Device Hub or Apple Configurator: [registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

TestFlight remains the fallback when wireless installation and updates matter more than the
registered-device workflow. Internal testers must be App Store Connect users and builds last 90
days; an external tester requires the TestFlight external-testing path and its first-build review.
See Apple's [internal tester rules](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers)
and [TestFlight overview](https://developer.apple.com/testflight/). Do not add the second household
member as an App Store Connect user merely to avoid external review without first reviewing the
account access that role grants.

| Property | Recommended Ad Hoc | TestFlight fallback | Free Personal Team |
| --- | --- | --- | --- |
| Public App Store listing | None | None | None |
| Device/user scope | Exact registered UDIDs | Invited internal/external testers | Devices connected to developer workflow |
| Review | No beta review | External first build requires beta review | None |
| Install/update | Xcode/Device Hub or Apple Configurator; repeat for updates | TestFlight app, remote updates | Rebuild/reinstall frequently |
| Time constraint | Membership, certificate, and profile renewal | Each build available for 90 days | Profiles expire after 7 days |
| Release suitability | Best fit for two known phones | Acceptable fallback | Rejected for ongoing household use |

Apple permits up to 100 registered iPhones per membership year, but disabling a device during that
year does not restore its slot: [device limits](https://developer.apple.com/help/account/devices/devices-overview).
This project needs only two. Device names and UDIDs are private operational data and must remain out
of source, chat, issue trackers, screenshots, and acceptance reports.

## Required local inputs

Before changing the Xcode project, the account holder must provide through the local Xcode/account
session:

- an active Apple Developer Program team with authority to create the App ID/profile;
- the final reverse-DNS bundle identifier, replacing the current preview identifier
  `com.housekeeping.designpreview`;
- the two connected authorized iPhones, registered by Xcode without copying their UDIDs into this
  repository;
- approval to let Xcode create or select the distribution certificate and Ad Hoc profile.

Do not export or transmit the signing certificate private key. Do not commit a Team ID,
`.mobileprovision`, `.p12`, archive, `.ipa`, or device list. Existing ignore rules cover common
signing/build artifacts, but the operator must still choose an export directory outside the
repository.

## Build gate

Task 24 must pass its post-deployment audit first. The ignored
`ios/Configuration/Local.xcconfig` must contain only the approved hosted HTTPS project URL and public
publishable key. Before archiving:

1. Confirm a clean repository at the approved commit and increment `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` deliberately.
2. Set the approved final bundle identifier and signing team for the app target; keep test targets
   local and avoid unrelated capability changes.
3. Run the complete unit/UI suite and a Release device build. The existing build phase must reject
   any service-role/secret credential.
4. Inspect the archive's generated `Info.plist`, entitlements, signing identity, provisioning profile,
   bundle identifier, version, minimum iOS version, and embedded public Supabase origin.
5. Export Ad Hoc for only the two registered iPhones. Do not select App Store, Enterprise, or a
   public over-the-air manifest.

The concrete archive/export action is externally effective because it uses the owner's signing
account and device list. Prepare the clean diff and test evidence first, then obtain approval for the
exact bundle identifier, Team, two devices, version/build, and export destination.

## Install, update, and revoke

Install the exported `.ipa` on each connected authorized iPhone using Xcode/Device Hub or Apple
Configurator. Enable Developer Mode only on those phones. Verify that an unregistered test iPhone
cannot install the same archive. Keep the `.ipa` in a private operator-controlled location and do not
send it through an unapproved message or public link.

For an update, increment the build number, rerun the release gates, export with the same App ID and a
profile containing the same two active devices, and install over the existing app. Verify Keychain
session behavior and protected drafts before removing the prior build artifact.

If a phone is lost or leaves the household, first use task 25 to revoke the corresponding backend
membership and sessions. Then disable the registered device and regenerate the profile before the
next build. Disabling a UDID does not remove an already installed app or remotely erase downloaded
data, so backend revocation is the effective access control.

Record only the release commit, bundle identifier, semantic/build version, signing certificate
expiry date, profile expiry date, installation date, device model/iOS version, and pass/fail. Review
membership/certificate/profile expiry at least 30 days before the earliest date and prepare a signed
replacement build while the current credentials still work.
