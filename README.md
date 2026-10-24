# LightYears

A native iPhone memory browser for photos and videos captured on this day across the years. Built with SwiftUI, UIKit, Photos, AVFoundation, and MapKit. Screenshots are excluded.

## Open and run

Open `MemoryJourney.xcodeproj`, select the `MemoryJourney` scheme and a simulator or connected iPhone, then Run. For a physical device, select your own development team and bundle identifier in Signing & Capabilities. No credentials or signing profiles are included.

The current source builds with Xcode 27.1. The deployment target is iOS 17; newer glass and adaptive toolbar features are availability-gated. No third-party dependencies are required.

## Browsing

Photos and videos initially fill their pane. Pinching out reveals the original aspect ratio. Tap the left 40 percent to go back or the right 60 percent to go forward; swipe or use the native timeline slider to browse. Controls hide after three seconds and return on interaction.

The expanded layout shows media beside a map in landscape and above it in portrait, in equal halves. A glass card presents recorded metadata. A full-screen control hides the map. Active fold reservations take precedence over the default split.

Videos loop and preserve pause, seek, and mute intent while browsing. Sound is enabled by default, but the system Silent mode still applies. Manual mute lasts for the current browsing session. Leaving a video or backgrounding pauses it.

## Photos and privacy

Grant Photos access on first use. Media stays on the device; there are no photo uploads, telemetry, cloud AI, or people recognition. City-name lookup uses Apple's service and sends capture coordinates, not media. Missing metadata is not inferred.

Foreground preloading prioritizes the selected asset and nearby memories, with bounded download queues and a private 512 MiB disk cache. Rapid scrubbing defers expensive full-quality work until selection settles. iCloud-only media still depends on network availability; offline availability is not guaranteed. Debug builds produce bounded local navigation diagnostics without photo content or coordinates.

## Validation

Run `./scripts/check.sh` for model checks, Swift parsing, and project validation. Build a simulator app with:

```sh
xcodebuild -project MemoryJourney.xcodeproj -scheme MemoryJourney \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

`scripts/prepare-adaptive-check.py` creates a separate temporary fixture using generated illustrations and a synthetic video, without opening a photo library. The latest native fixture passed 50 checks covering paging, resizing, zoom, map focus, loading, video continuity, and audio state. Real device audio output and live Silent-mode changes still require physical verification.

This public snapshot intentionally excludes earlier local Git history, validation screenshots, device traces, and personal signing settings. The original development checkout is preserved separately.
