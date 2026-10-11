# HouseKeeping user guide

HouseKeeping gives two household members separate sign-ins to one shared purchase list and private
photo collection. The current repository is locally verified but not released; this guide describes
the connected build once an operator has installed it and provided an account.

## Sign in and recover access

Open the app and enter the email address and password provided by the household operator. There is no
public registration screen. If the account has not been assigned to the household, the app shows a
no-membership state and does not expose purchases.

Choose **Set up or reset password** if you need a first password or cannot sign in. Enter the account
email, open the recovery link on the same iPhone, and choose a new password of at least 12 characters.
An expired or already-used link must be requested again.

## Browse and search

The inventory opens with recent purchases. Pull down to refresh after the other household member
makes a change. Search checks the name, description, brand, and model without regard to letter case;
all typed words must match somewhere in the purchase. Clear the search field to return to recent
items.

Each purchase shows its quantity on hand and restock limit in the list and details. At or below the
limit, the app shows **Restock now**; zero is additionally labeled **Out of stock**. Existing
purchases start with quantity 1 and limit 1; adjust both to match how you stock the item.

Tap a purchase to see its current details and attached photo. A temporary connection problem shows a
retry action and never substitutes sample data for the household's records.

## Add a purchase

Choose **Add a purchase**. A name is required. Description, brand, model, and purchase date are
optional.

Set **Quantity on hand** and **Restock limit** using their minus and plus controls. Both start at 1
and can be zero. Photo suggestions leave both values unchanged.

You can:

- enter the details manually;
- choose a photo from the system photo picker; or
- choose **Take a photo**, review it, retake if needed, and select **Use photo**.

Camera permission is requested only after choosing the camera. If access is denied or the camera is
unavailable, return to the picker or continue manually. Captures are not automatically saved to the
Photos library.

The app prepares an upright JPEG and removes source metadata before upload. Upload progress and save
progress are separate. If preparation, upload, or saving fails, keep the draft and use the displayed
retry action.

## Recognition and confirmation

Recognition is optional. The core release keeps the live provider disabled until evaluation passes,
so manual entry and photo saving remain the normal path. In the explicit offline demo, **Try sample
photo** shows a clearly labelled sample suggestion.

When live recognition is eventually enabled, invoking it sends the selected product image to the
configured provider. Treat every returned name, description, brand, and model as an editable
suggestion. Review the fields and choose Save yourself; a suggestion never creates a purchase
automatically. If recognition times out or fails, choose **Continue manually**.

## Edit, remove a photo, or delete

Open a purchase and choose Edit to change its details, quantity, or restock limit. Update the count
when you use or replenish an item and change the limit when your preferred minimum changes, then
save. If both people edit the same version, the
first save succeeds and the second person sees a conflict. Review the newer record without discarding
the local draft, then apply the desired changes again.

Choose **Remove photo** to delete only the attached image while keeping the purchase details. Choose
**Delete purchase** to remove the purchase and schedule its image for protected cleanup. Both actions
require confirmation. Either active household member can edit or delete a shared purchase regardless
of who created it.

## Drafts, offline use, and refresh

An unfinished form and prepared photo are stored in the app's protected local area for the current
account and household. Relaunch the app and choose **Continue purchase draft** to resume. Confirm
before discarding a draft or signing out with unfinished work.

Complete inventory search, cloud saves, photo downloads, and account recovery require connectivity.
Previously loaded content can become stale while offline. Pull to refresh or reopen the app after the
connection returns.

## Account and privacy

Open Account to see the signed-in address and household, then choose **Sign out**. Signing out clears
the app-owned session, caches, and drafts after any required confirmation. The other member's account
and shared saved purchases remain intact.

Account removal and full household closure are operator-assisted. Member removal revokes access and
retains the remaining member's shared purchases and attached images. Household closure is a separate
verified request that deletes all household records and images through retryable cleanup.

Photos are stored in a private bucket and require an active household session. Already downloaded
content cannot be remotely erased from another device. Do not share passwords, recovery links, or
screenshots containing private purchase information.

## Offline demo

When no backend is configured, choose **Explore the demo** on the setup screen. The demo is labelled,
uploads nothing, and contains only sample items and original app artwork. Its edits reset when you
exit or relaunch, and it never appears as a fallback after a connected request fails.
