# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FakeGPS is a macOS SwiftUI app that simulates GPS locations on iOS 17+ devices connected via USB. It uses a Python helper (`location_streamer.py`) compiled with PyInstaller and bundled into the app for device communication via `pymobiledevice3`.

## Build Commands

**Debug build:**
```bash
xcodebuild -project FakeGPS.xcodeproj -scheme FakeGPS -configuration Debug -derivedDataPath build
```

**Build PyInstaller helper (needed for release):**
```bash
pyinstaller --onefile --name location_streamer \
  --collect-all pymobiledevice3 --collect-all readchar \
  --copy-metadata readchar \
  FakeGPS/Resources/location_streamer.py
```

**No test suite exists.** CI only validates compilation (`.github/workflows/build.yml`, triggered on `v*` tag push).

## Architecture

### Swift (macOS app)
- **Entry point:** `FakeGPS/FakeGPSApp.swift`
- **DeviceManager** (`Services/DeviceManager.swift`): Central orchestrator — device detection, tunnel daemon startup (sudo), location streamer process management. Uses a fallback chain: bundled PyInstaller binary → system `pymobiledevice3` CLI → system Python.
- **RouteSimulator** (`Services/RouteSimulator.swift`): Waypoint interpolation with configurable speed, GPS drift simulation, haversine distance.
- **ShellExecutor** (`Utilities/ShellExecutor.swift`): Async process execution with `LockedValue<T>` for thread-safe stdout/stderr collection. `startSudoProcess()` uses AppleScript for password prompt.
- **Views** follow standard SwiftUI ObservableObject pattern with `@MainActor` isolation.

### Python helper (`FakeGPS/Resources/location_streamer.py`)
Three modes:
- `streamer --udid <UUID>`: Persistent stream server, reads `lat,lon\n` from stdin, sends `CLEAR` to reset
- `list`: JSON device enumeration
- `tunneld`: Wrapper for `pymobiledevice3 remote tunneld`

### Key constraints
- App runs **outside sandbox** (entitlements) for USB access and sudo elevation
- Tunnel daemon requires admin password (iOS 17+ requirement)
- All UI updates routed through `@MainActor`
- Saved locations persisted in `UserDefaults` with key `"SavedLocations"`
