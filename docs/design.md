# HouseKeeping design specification

Status (2026-09-14): the explicit demo keeps in-memory sample purchases and original product illustrations. The connected app implements authentication, durable inventory/photo saves, native camera capture, and editable recognition review/manual fallback. The provider remains disabled; cloud deployment and physical-device acceptance are open.

## Direction and template

Use Apple's [iOS design resources](https://developer.apple.com/design/resources/) and [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) as component and interaction references. Build the prototype in native SwiftUI using a standard iOS application target and self-contained previews. No Figma document or downloaded commercial template is required.

SwiftUI Expert guides view composition, observable state ownership, navigation, accessibility, and previews. Product illustrations are original SwiftUI shapes used as sample images; actual purchase photos will replace this presentation in the connected app.

The desired character is calm and domestic: warm paper backgrounds, forest green actions, generous spacing, clear type, and an inventory led by recognizable product images. Use standard system navigation, accessible buttons, and editable fields. Avoid decorative dashboards, spending totals, room filters, and other features outside the product spec.

## Visual tokens

| Token | Light appearance | Dark appearance |
| --- | --- | --- |
| Background | Warm ivory #F7F6F2 | Charcoal #171C19 |
| Surface | White #FFFFFF | Deep grey-green #242C26 |
| Primary text | Ink #24392D | Warm white #F3F5EF |
| Secondary text | Muted grey-green #667369 | Light grey-green #B4BEB5 |
| Action | Forest #285943 | Pale sage #B7D6BE, dark label |
| Soft accent | Sage #E9EFE6 | Dark green #303F34 |

Typography uses SF system text styles that scale with Dynamic Type. Screen titles use largeTitle, item names headline, descriptions subheadline/body, and supporting labels footnote/caption. Layout uses 24-point screen margins, a 4/8/12/16/24/32 spacing scale, 20-point image corners, and 16-point control corners. Primary actions have a minimum 52-point height; secondary tap targets have a minimum 44-point size.

## Inventory screen

- Small house mark and “HOUSEKEEPING” wordmark; an About button explains the demo's scope.
- Large “A little order. More home.” introduction followed by concise search guidance.
- Always-visible search field with a clear action. Search runs across sample names, descriptions, brand, and model, as specified in the product contract; no fake network progress.
- “Your purchases” section with the actual item count. Rows pair a product illustration with name and a short description; tapping opens details.
- Persistent bottom “Add a purchase” action opens the sample recognition review; an action chooser also supports a blank manual draft.
- No-results state keeps the search field and Add action available. An empty inventory has a welcoming explanation.

## Photo-review screen

- Native navigation with Cancel. Sheet owns its dismissal; cancel with edits asks to discard.
- “Make it yours.” heading and “Review your photo” supporting label.
- Large kettle illustration on a warm studio-like background, clearly marked as a sample photo in this prototype.
- Sage “Suggested from your photo” message, explaining that details are editable. No confidence percentage or unverifiable exact model.
- Labeled editable name and description, followed by optional brand and model. Prototype does not infer purchase date.
- Persistent “Save purchase” action is disabled for blank/overlong names or invalid field lengths. Saving inserts the reviewed record into the demo inventory and dismisses the sheet.
- The empty manual draft uses the same editor without sample suggestion fields or an attached illustration.

## Supporting screens and states

Purchase detail displays the same image treatment, full name/description, optional identity fields, and a sample-data note. About explains that the design prototype resets when relaunched. No control pretends to perform cloud operations.

Dark mode uses semantic tokens. At accessibility text sizes, row layouts stack and controls expand vertically. Scrollable content plus safe-area action placement keep Save reachable on small screens and above the keyboard. Text fields have visible labels and accessibility identifiers; decorative illustrations are hidden from VoiceOver when adjacent text already describes the item.

Pinned Add and Save buttons keep their full-width alignment and 56-point minimum height. Their label and icon scale only up to the system's XXX Large setting, keeping these actions compact even when the rest of the screen uses accessibility text sizes. No fixed maximum frame or text clipping is applied; the current English labels are tested to stay within 72 points tall. A large-content viewer provides an enlarged label on press-and-hold. Screen content continues to scale without this cap.

## Prototype verification

Completed simulator results and captured screens are in the [design preview gallery](design-preview/README.md).

- Build with the local Xcode toolchain for iOS Simulator.
- Exercise inventory → search → item detail and add → edit suggestion → save → find saved item.
- Check an empty name cannot save and cancel preserves inventory count.
- Capture the inventory and photo-review screens for review; inspect dark mode and a small-screen/large-text layout.
- No production readiness, real recognition accuracy, or cloud persistence is claimed by these checks.

The prototype's one-tap sample review is a design shortcut. The production capture/upload/recognition workflow and all authorization rules remain defined in [spec.md](spec.md) and [contracts.md](contracts.md).
