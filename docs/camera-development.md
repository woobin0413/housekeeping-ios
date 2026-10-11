# Native camera development status

Status: task 19 is implemented and verified with injected camera fixtures and native simulator journeys. Physical-iPhone capture remains pending release evidence.

## Capture and permission flow

`CameraService` uses AVFoundation's back wide-angle camera and photo output. Authorization is checked only after the user chooses **Take a photo**. Denied or restricted access shows a stable fallback that returns to the existing library picker and manual fields. The app has a focused camera usage description and never writes captures to the Photos library.

Session configuration, start/stop, rotation updates, and capture requests are serialized. The live preview and photo output use `AVCaptureDevice.RotationCoordinator`; interruptions disable the shutter until the session resumes, and runtime or configuration failures lead to the same usable fallback. Dismissing the camera stops the session and resolves any pending capture.

## Preview, retake, and drafts

Captured bytes stay in memory while the user reviews or retakes the image. **Use photo** passes the bytes through the existing bounded `PhotoPreparation` actor, which normalizes orientation, removes source metadata, emits a JPEG within the existing 2,048-pixel/5 MiB limits, and writes the account/household-partitioned protected draft. Uploading begins only after the user explicitly saves the purchase. A preparation or protected-storage failure stays visible in the camera and preserves the previous photo draft.

Debug-only authorized, denied, and unavailable camera adapters make the native UI deterministic without claiming that a simulator has a real camera. They use generated synthetic pixels and are excluded from Release builds.

## Verification

On September 13, 2026, the focused four-test camera suite passed on iPhone 17 Pro / iOS 26.5. It covers request timing, denial, capture/retake, interruption/resume, orientation normalization, sensitive metadata removal, and protected draft persistence.

Two native UI journeys passed on iPhone 17 / iOS 26.5: authorized capture → preview → retake → use → leave/reopen draft, and denied permission → library/manual fallback → text-only save. The full shared scheme then passed with 143 tests, 3 expected environment-dependent skips, and no failures (174 parameterized test instances). A generic physical-iOS build also passed. Strict formatting passes for every changed Swift file, and the Info.plist validates.

No personal photo or real household data was used. A physical iPhone must still verify the actual permission prompt, live preview/capture, rotation in supported orientations, interruptions, background/foreground behavior, and recovery after relaunch. Those checks are required before treating AC-03/AC-05 or task 27 as release-accepted.
