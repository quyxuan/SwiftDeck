# SwiftDeck

SwiftDeck is an open-source macOS dashboard for building and running real iOS and iPadOS Simulator apps.

It provides:

- Xcode project and workspace import.
- Scheme, configuration, and Simulator destination selection.
- Build, Run, Stop, and Clean actions backed by real `xcodebuild` commands.
- A live Simulator in the main workspace, with framebuffer rendering and HID input.
- Multiple project windows with shared operation ownership.
- Target-aware project icons.
- Persistent project selection, destinations, appearance, and keyboard shortcuts.

SwiftDeck is a local developer tool. It is not an Xcode replacement and it does not attach a debugger.

## Important: Simulator.app vs. the Simulator runtime

An iOS Simulator has two separate parts:

1. **CoreSimulator runtime** — the virtual iPhone/iPad that boots, installs, and runs apps.
2. **Simulator.app** — Apple's optional macOS window for displaying that runtime.

SwiftDeck can boot and control the runtime without opening `Simulator.app`. The live display is rendered inside the SwiftDeck window.

- **Run** boots the selected runtime when needed, installs the built app, launches it, and opens the embedded display.
- Double-clicking a device or choosing **Open in SwiftDeck** uses the embedded display.
- Actions explicitly labeled **External** open Apple's `Simulator.app`.
- SwiftDeck does not close or reconfigure a `Simulator.app` that is already running. If that app is open, it may display a runtime independently.

## Requirements

- macOS 15 or later on Apple silicon.
- Full Xcode 26 or newer.
- An installed iOS/iPadOS Simulator runtime.
- Xcode Command Line Tools selected in **Xcode → Settings → Locations**, or a valid `DEVELOPER_DIR`.

Xcode 26.4 is the verified toolchain. Embedded display and input use private Xcode interfaces through a pinned FBSimulatorControl backend; a future Xcode release may require backend updates.

## Unsigned DMG

Download [SwiftDeck-1.0-unsigned.dmg](https://github.com/quyxuan/SwiftDeck-Releases/releases/download/v1.0-unsigned/SwiftDeck-1.0-unsigned.dmg). This unnotarized disk image is a manual download, not a Sparkle update. On another Apple-silicon Mac meeting the requirements above, open the DMG, drag **SwiftDeck.app** onto **Applications**, then open the copy in Applications. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway** for that app (or Control-click the app and choose **Open**). Only override Gatekeeper for a copy you trust. Subsequent updates require installing a new copy manually.

## Quick start

1. Open SwiftDeck.
2. Choose **File → Open Project…** (`⌘O`) and select a trusted `.xcodeproj`, `.xcworkspace`, or containing folder.
3. Select a scheme and configuration.
4. Select a Simulator destination.
5. Press **Build** (`⌘B`) or **Run** (`⌘R`).

While a project is building or running, **⌘B** rebuilds and **⌘R** reruns it: SwiftDeck first cancels the current operation and waits for its process and device cleanup before starting the new one. **Stop** (`⌘.`) cancels a pending rebuild or rerun. Clean remains unavailable until the active operation ends.

On launch, SwiftDeck displays the selected project's booted Simulator in the main workspace. For a shut-down device, choose **Open in SwiftDeck** in the workspace or double-click the device to boot and display it.

To intentionally use Apple's external window, choose **Open Simulator (External)** in Tools or **Show in Simulator (External)** in the device menu.

## Simulator controls

The sidebar shows booted devices. Destination pickers and the embedded-device picker show the full installed inventory, including shut-down devices.

The Simulator toolbar has volume down/up, a Silent Mode toggle, Home, and a power button that locks or wakes the screen. The **…** menu separately offers **Disconnect** and **Shut Down…**; the power button does not shut down the Simulator.

Device actions:

- **Open in SwiftDeck** — boot if needed and attach the interactive embedded display.
- **Boot & Open in Simulator (External)** — boot if needed and open Apple's application.
- **Show in Simulator (External)** — show an already booted device in Apple's application.
- **Restart…** — shut down and boot the device; it does not open `Simulator.app`.
- **Shut Down…** — stop every app on the device after confirmation.
- **Stop This Window's App** — stop only the app launched by the current SwiftDeck session.
- **Save Screenshot…**, **Open URL…**, **Device Details…**, and device metadata actions.

Press **⌘S** in the SwiftDeck window to capture the currently embedded Simulator immediately, or the selected project's booted Simulator when no display is embedded. The PNG is written to `~/Desktop/Simulator Screenshot … .png` without a save dialog. Press **⇧⌘I** to copy the screenshot image to the clipboard instead, without saving a file. Both shortcuts are customizable in Settings. Use the device's **Save Screenshot…** action if you want to choose a different location.
Successful captures briefly show an animated confirmation in the SwiftDeck window; failures show an error alert instead.

SwiftDeck tracks the actual launched app PID. It never uses `killall`, erases devices, or shuts down unrelated devices. If a device shuts down while cleanup is running, SwiftDeck confirms that state and finishes cleanup without booting the device again.

## Build and test

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you need to regenerate the project:

```sh
brew install xcodegen
```

Open `SwiftDeck.xcodeproj`, select the shared **SwiftDeck** scheme and **My Mac**, then run it from Xcode.

Command-line build:

```sh
xcodebuild -quiet \
  -project SwiftDeck.xcodeproj \
  -scheme SwiftDeck \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SwiftDeckDerived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Command-line tests:

```sh
xcodebuild -quiet \
  -project SwiftDeck.xcodeproj \
  -scheme SwiftDeck \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SwiftDeckDerived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The first build of the **Simulator Backend** downloads the pinned [facebook/idb](https://github.com/facebook/idb) source into ignored `.build/idb`, applies the tracked backend overlay, and builds static FBSimulatorControl libraries. Network access and Git are required for that first build.

## Security and trust

SwiftDeck runs outside the App Sandbox with Hardened Runtime enabled. Import only projects you trust:

- Project discovery and builds can execute project-defined build scripts.
- Swift Package Manager may resolve packages during Xcode builds.
- SwiftDeck does not modify project source files or provisioning settings.
- DerivedData is isolated under `~/Library/Application Support/SwiftDeck/DerivedData/`.
- No `sudo` or shell interpolation is used.

## Scope and limitations

Supported:

- iOS/iPadOS Simulator applications.
- One application target per Run scheme.
- Local `.xcodeproj`, `.xcworkspace`, and supported folder imports.
- Multiple SwiftDeck windows with coordinated project/device ownership.

Not supported:

- Physical iPhones or iPads.
- Provisioning or App Store distribution.
- macOS target execution.
- Multi-application Run schemes.
- Debugger attachment.
- Automatic Simulator runtime installation, device creation, erase, or deletion.

## Architecture

- `SwiftDeck/App/` — application lifecycle and native commands.
- `SwiftDeck/Models/` — project, workspace, log, issue, preference, shortcut, and icon state.
- `SwiftDeck/ViewModels/DashboardViewModel.swift` — per-window state and operation orchestration.
- `SwiftDeck/Services/XcodeBuildService.swift` — metadata, build, clean, and artifact validation.
- `SwiftDeck/Services/CoreSimulatorService.swift` — device inventory, lifecycle, launch, output, and PID cleanup.
- `SwiftDeck/Services/EmbeddedSimulatorSession.swift` — framebuffer, HID, display leases, and input cleanup.
- `SwiftDeck/Services/ProjectIconResolver.swift` — target-aware icon discovery and rendering.
- `SwiftDeck/Services/ProcessRunner.swift` — bounded subprocess execution and cancellation.
- `SwiftDeck/Views/` — native SwiftUI dashboard, sidebar, controls, logs, settings, and embedded display.
- `SwiftDeckTests/` — deterministic service and state-transition tests.

## Contributing

Before opening a pull request:

1. Read the security and scope sections above.
2. Keep changes focused and preserve existing ownership/cancellation rules.
3. Run the build and test commands.
4. Include the macOS/Xcode versions used and any Simulator runtime involved.
5. For UI changes, include a screenshot or a clear reproduction/verification path.

## License

No license file is currently included. Do not assume that the repository is licensed for redistribution until a project license is added.
