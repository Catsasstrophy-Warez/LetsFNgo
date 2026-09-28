# Running Nexus on an iPhone 17 Pro Max

Nexus targets iOS 26 and later and is tuned for iPhone 17 Pro Max: the
on-device model, LiDAR room placement of the digital twin, live text
scanning and 120 Hz Metal rendering all use that hardware. CI builds the app
for the device (arm64) and runs the UI tests on an iPhone 17 Pro Max
simulator; nothing replaces a run on the phone itself.

## Build and install

1. On a Mac with Xcode 27 (iOS 27 SDK; the app still deploys to iOS 26):
   ```sh
   brew install xcodegen
   xcodegen generate
   open Nexus.xcodeproj
   ```
2. In the NexusApp and NexusWidgets targets, Signing & Capabilities: choose
   your team. The bundle ids are `com.catsasstrophy.nexus` and
   `com.catsasstrophy.nexus.widgets`; change the prefix in `project.yml` if
   your team can't use them, and regenerate.
3. Connect the iPhone, enable Developer Mode (Settings → Privacy & Security),
   pick it as the run destination and run the `NexusApp` scheme.
4. Launch with `-demo` (Edit Scheme → Arguments) for an in-memory demo world,
   or without it for the on-device store with the demo seeded once.

## What to try on the phone

| Feature | Where | Needs |
|---|---|---|
| Diagnose the LT-101 loop | More → Investigation | — |
| Ask / Conversation | Ask button, More → Conversation | Apple Intelligence on (Settings → Apple Intelligence & Siri); or a Claude key in Settings → Models |
| Twin in 3D, tap to select | More → Simulation | — |
| Twin in your room | Simulation → "In room" | Camera permission; LiDAR adds occlusion and shadows |
| Custom Metal shaders (signal flow, divergence pulse) | Simulation | A device (the Simulator falls back to standard materials) |
| Live nameplate scan | Search → Scan nameplate | Camera permission |
| Nameplate from a photo | Search → Nameplate photo | Photos |
| Meeting notes by voice | More → Meeting → Record | Microphone, speech recognition |
| Pencil / finger markup | Any object → Markup | — |
| Calendar and Reminders | More → Calendar | Calendar/Reminders access |
| Live Activity for agent runs | Ask something | Live Activities on |
| Siri / Shortcuts / Spotlight | "Open … in Nexus", Spotlight search | — |

## Capabilities you may need to add in Xcode

- **Private Cloud Compute** (iOS 27 only): the
  `com.apple.developer.private-cloud-compute` entitlement.
- **Push/CloudKit**: not used until the sync transport is chosen
  (docs/decisions/0001).

## Known limits on device

- The on-device model's context is about 4K tokens; long investigations
  are trimmed by the context budget.
- Room placement needs a textured, lit surface; the status line says when
  tracking isn't available.
- Nothing here has been profiled on the phone yet: check Instruments
  (Time Profiler, RealityKit Trace, Metal System Trace) on first runs.
