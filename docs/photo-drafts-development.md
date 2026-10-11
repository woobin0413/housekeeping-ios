# Local photo preparation and drafts

Task 17 adds library selection to new-purchase editors. A prepared photo can be kept with the local draft, reopened after session restoration or relaunch, replaced by another selection, or explicitly discarded. Import never writes to the source Photos library. [Task 18](photo-service-development.md) now connects recoverable upload/save and private detail images; a purchase with a local photo is never saved as text by silently dropping the photo.

## Preparation and storage

The system Photos picker transfers a file with a bounded read (25 MiB source cap). An ImageIO actor checks source dimensions before decoding, rejects more than 200 million source pixels and multiple-image sources, applies all eight EXIF orientations, and downsamples to a maximum 2,048-pixel edge. A new JPEG is encoded from pixels without copying source metadata. Up to five fixed quality attempts enforce the 5 MiB output cap. Conversion errors preserve the previous prepared draft.

Apple documents the [orientation transform](https://developer.apple.com/documentation/imageio/kcgimagesourcecreatethumbnailwithtransform) and [Photos picker transfer support](https://developer.apple.com/documentation/photosui/photospickeritem). Output may include encoder-generated structural image properties, but source GPS, author, camera, timestamp, and comment metadata are not carried forward.

Photo bytes and their owner, identifier, and dimensions occupy one bounded binary property-list file. Project/account/household partitions are separate. Writes are atomic, request complete file protection, use private permissions, and exclude the draft directory and photo file from device backups. Recovery revalidates the owner and decoded JPEG dimensions. Corrupt files remain available for explicit discard.

The inventory session owns the photo model. Retirement finishes any pending prepared-image write before clearing memory; reconstruction restores its partition. Confirmed sign-out drains pending imports and clears both text and photo files before reporting success. An inactive model cannot recreate a discarded photo. Library transfer also blocks purchase saving while selection is being read.

## Verification

Fixtures cover all eight orientations with pixel-position checks, source metadata removal, dimensions and byte caps, conversion failures, previous-draft preservation, reconstruction, account/project partitioning, file permissions and backup exclusion, explicit discard, and sign-out while preparation is pending. Simulator UI journeys cover reaching/cancelling the system picker, keeping/reopening a draft, and existing shared text entry/edit/delete flows.

On iPhone 17 Pro / iOS 26.5 with Xcode 26.6, the signed offline unit suite passed 88 test declarations (parameterized cases run separately), with two expected environment-gated skips. Both existing shared-inventory UI journeys passed. The subsequent focused run passed all eight photo-preparation declarations (including PNG/HEIC and eight orientations) and the corrected picker/keep-draft UI journey. That UI test now scopes Cancel to the system Photos navigation bar and waits for each sheet to disappear; the previous unscoped selector had targeted the covered editor instead. The successful result retains the photo-editor screenshot as an attachment.

Physical-device file encryption, locked-device behavior, and personal/iCloud library delivery remain device checks. No personal photos, cloud resources, or AI requests are used by these fixtures.
