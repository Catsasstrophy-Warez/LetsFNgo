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
   bundle ID `com.catsasstrophy.nexus.<TEAM_ID>` (bundle IDs end in your team ID, so they're always yours), or your own prefix (see step 3). If
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

Bundle IDs end in your team ID (`com.catsasstrophy.nexus.<TEAM_ID>`), so
they don't clash with anyone else's. To use a different prefix anyway:
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
- **iCloud (CloudKit)**: only for iCloud sync; see below.

## iCloud sync

Settings → Sync syncs your data through your own iCloud private database
(decision 0001, option B). It is off by default. Everything is encrypted on
the device before it's uploaded, with a key kept in iCloud Keychain, so only
your devices can read it.

A **free Apple ID can't sign apps that use iCloud**, so the default build
leaves CloudKit out; its Sync section explains this. To build with sync you
need the Apple Developer Program, and:

1. At developer.apple.com → Certificates, Identifiers & Profiles:
   - Identifiers → **iCloud Containers** → +. Use the identifier
     `iCloud.com.catsasstrophy.nexus.<TEAM_ID>`, which is `iCloud.` plus the
     app's bundle ID. With `BUNDLE_ID_PREFIX`, use `iCloud.<prefix>.<TEAM_ID>`.
   - Identifiers → the app's ID (`com.catsasstrophy.nexus.<TEAM_ID>`) →
     tick **iCloud**, choose **CloudKit**, click **Configure** and select
     that container. Save. Profiles made before this are outdated;
     automatic signing makes new ones.
2. Build with `NEXUS_CLOUDKIT_ENABLED=YES`. That setting signs the app with
   `App/NexusCloud.entitlements` and compiles it with `NEXUS_CLOUDKIT`:
   - Mac: `NEXUS_CLOUDKIT=1 scripts/install-on-iphone.sh`. In Xcode, you can
     instead set `NEXUS_CLOUDKIT_ENABLED` to `YES` in `project.yml` and run
     `xcodegen generate`.
   - TestFlight: add the repository variable `NEXUS_CLOUDKIT` = `1`
     (Settings → Secrets and variables → Actions → Variables). The unsigned
     `.ipa` never includes sync.
3. TestFlight and App Store builds use CloudKit's **production**
   environment. After a development build has synced once, open the
   CloudKit Console (icloud.developer.apple.com), select the container,
   and use **Deploy Schema Changes** to copy the `NexusChangeSet` and
   `NexusBlob` record types to production. Until you do, TestFlight builds
   report an error in Settings → Sync.
4. On the phone, sign in to iCloud with iCloud Drive and iCloud Keychain on
   (Settings → your name → iCloud). Turn on Settings → Sync in Nexus on
   **one** device first, and wait a minute before turning it on anywhere
   else. The first device creates the encryption key; the others need it
   from iCloud Keychain. If a device made its own key, Sync says "Another
   device synced with a different key".

Sync runs at launch, when the app comes to the foreground, every five
minutes, and a few seconds after you change something. The section shows
the last sync, errors (no iCloud account, iCloud storage full, offline), and
how many conflicts were kept for review. A conflict is a newer modeled or
agent value that lost to a recorded or observed one.

## Known limits on device

- The on-device model's context is about 4K tokens; long investigations
  are trimmed by the context budget.
- Room placement needs a textured, lit surface; the status line says when
  tracking isn't available.
- Nothing here has been profiled on the phone yet: check Instruments
  (Time Profiler, RealityKit Trace, Metal System Trace) on first runs.
