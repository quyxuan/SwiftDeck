# SwiftDeck

SwiftDeck is an open-source macOS dashboard for building and running real iOS and iPadOS Simulator apps.

It provides:

- Xcode project and workspace import.
- Scheme, configuration, and Simulator destination selection.
- Build, Run, Stop, and Clean actions backed by real `xcodebuild` commands.
- Live build logs and parsed compiler diagnostics.
- An embedded Simulator view with framebuffer rendering and HID input.
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

## Quick start

1. Open SwiftDeck.
2. Choose **File → Open Project…** (`⌘O`) and select a trusted `.xcodeproj`, `.xcworkspace`, or containing folder.
3. Select a scheme and configuration.
4. Select a Simulator destination.
5. Press **Build** (`⌘B`) or **Run** (`⌘R`).

For an embedded display without running an app, double-click a booted device or choose **Open in SwiftDeck** from its device menu. A shut-down device is booted automatically.

To intentionally use Apple's external window, choose **Open Simulator (External)** in Tools or **Show in Simulator (External)** in the device menu.

## Simulator controls

The sidebar shows booted devices. Destination pickers and the embedded-device picker show the full installed inventory, including shut-down devices.

Device actions:

- **Open in SwiftDeck** — boot if needed and attach the interactive embedded display.
- **Boot & Open in Simulator (External)** — boot if needed and open Apple's application.
- **Show in Simulator (External)** — show an already booted device in Apple's application.
- **Restart…** — shut down and boot the device; it does not open `Simulator.app`.
- **Shut Down…** — stop every app on the device after confirmation.
- **Stop This Window's App** — stop only the app launched by the current SwiftDeck session.
- **Save Screenshot…**, **Open URL…**, **Device Details…**, and device metadata actions.

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
