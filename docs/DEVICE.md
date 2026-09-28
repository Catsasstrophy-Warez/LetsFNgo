# Running Nexus on an iPhone 17 Pro Max

Nexus targets iOS 27 and later and is tuned for iPhone 17 Pro Max: the
on-device model, LiDAR room placement of the digital twin, live text
scanning and 120 Hz Metal rendering all use that hardware. CI builds the app
for the device (arm64) and runs the UI tests on an iPhone 17 Pro Max
simulator; nothing replaces a run on the phone itself.

## Getting it on the phone

There are three ways. Each needs your Apple ID, because only you can sign
an app for your phone.

### A. TestFlight (no Mac needed; Apple Developer Program)

1. Join the Apple Developer Program (developer.apple.com, 99 USD a year).
2. In App Store Connect, go to Apps → + → New App, platform iOS. Use the
   bundle ID `com.catsasstrophy.nexus`, or your own prefix (see step 3). If
   the ID isn't in the list, register it first at developer.apple.com →
   Identifiers.
3. In App Store Connect, go to Users and Access → Integrations → App Store
   Connect API, and create a key with the Admin role. Admin lets CI create
   the signing certificate and profiles. Then add these repository secrets
   on GitHub (Settings → Secrets and variables → Actions):
   - `APPLE_TEAM_ID`: your team ID (developer.apple.com → Membership).
   - `ASC_KEY_ID`: the key's ID.
   - `ASC_ISSUER_ID`: the issuer ID shown above the list of keys.
   - `ASC_KEY_P8`: the whole contents of the downloaded `.p8` file.
   - `BUNDLE_ID_PREFIX` (optional): for example `com.yourname.nexus`. Set it
     if you registered a different ID in step 2.
4. Run the **iPhone build** workflow in one of three ways: from the Actions
   tab, by pushing a tag named `iphone-<something>`, or by pushing a commit
   whose message contains `[iphone]`. It archives for iOS 27, signs, and
   uploads the build.
5. After 5–15 minutes of processing, the build appears in App Store
   Connect → TestFlight. Answer the export-compliance question once, then
   add yourself as an internal tester. Install the TestFlight app on the
   phone and install Nexus from it. Later runs update the app in place.

### B. Unsigned build and a sideloading tool (no Mac; free Apple ID)

Without the secrets, the same workflow produces `Nexus-unsigned.ipa` as an
artifact of the run. A sideloading tool such as Sideloadly or AltStore signs
it with your free Apple ID and installs it over USB or Wi-Fi. With a free
Apple ID, the app expires after 7 days and must be re-signed.

### C. Xcode on a Mac

One-time setup:
- Install Xcode 27 or later.
- Sign in to your Apple ID in Xcode → Settings → Accounts. A free Apple ID
  works; the app then needs reinstalling every 7 days.
- Connect the iPhone with a cable, unlock it and tap Trust.
- Turn on Developer Mode on the phone (Settings → Privacy & Security →
  Developer Mode). It restarts the phone.

Then, from the repository:

```sh
scripts/install-on-iphone.sh
```

The script:
- finds your team from your Apple Development certificate (or pass the
  team ID as an argument);
- installs XcodeGen and generates the project;
- downloads the Metal toolchain the first time;
- builds for iOS 27 and registers the phone with automatic signing;
- installs the app and launches it.

If `com.catsasstrophy.nexus` isn't registered to your team, choose your
own prefix:
`BUNDLE_ID_PREFIX=com.yourname.nexus scripts/install-on-iphone.sh`.

The first time the app opens, the phone may say "Untrusted Developer". Go to
Settings → General → VPN & Device Management, tap your Apple ID, then Trust.

To use Xcode directly instead, run `xcodegen generate` and open
`Nexus.xcodeproj`. Choose your team in Signing & Capabilities for the
NexusApp and NexusWidgets targets, pick the phone as the destination, and
run.

With any of these, launching with `-demo` (in Xcode: Edit Scheme →
Arguments) gives an in-memory demo world. Without it, the app uses the
on-device store, seeded with the demo once.

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

- **Private Cloud Compute**: the
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
