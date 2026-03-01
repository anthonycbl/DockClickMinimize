# DockClick Minimize

DockClick Minimize is a macOS menu bar app that intercepts Dock icon clicks and applies minimize/restore behavior based on user settings.

## Platform

- Intended platform: **macOS Tahoe (version 26)**.
- Current bundle minimum (`LSMinimumSystemVersion`): **macOS 13.0**.

## Current behavior

- App runs as a menu bar app (`LSUIElement` style behavior).
- Override can be toggled on/off without quitting (`Enabled`).
- Settings are persisted locally in `UserDefaults`.
- On first run, onboarding prompts for required permissions.

### Dock click handling

- Frontmost app click:
  - Toggle minimize/restore according to settings.
  - Supports:
    - Minimize all windows / frontmost window
    - Restore all minimized windows / last active window
    - Modal blocking behavior options
    - Fullscreen exit-then-minimize option
- Non-frontmost app click:
  - `Bring to front`: passes through to native macOS Dock behavior.
  - `Minimize immediately`: custom minimize path with fallbacks.
- Excluded bundle IDs always pass through to native macOS behavior.
- If Dock click resolution confidence is too low, action is skipped.

### Safety behavior

- No network calls.
- No polling loop for click detection (event-tap driven).
- Dock interception is suppressed while this app's Settings/Onboarding windows are key, so controls remain interactive.

## Permissions

Required for full functionality:

- Accessibility
- Input Monitoring

Without both permissions, override behavior remains disabled.

## Build and run

```bash
cd /path/to/dockToggle
swift build
swift run DockClickMinimize
```

Notes:

- `swift run` keeps the process attached to your terminal.
- Interact through the menu bar item (`DockClick`).
- Stop with `Ctrl+C` in the terminal running the app.

## Install as a normal app (no terminal needed)

Build release, wrap in `.app`, sign ad-hoc, and copy to `/Applications`:

```bash
cd /path/to/dockToggle
swift build -c release

rm -rf /tmp/DockClickMinimize.app
mkdir -p /tmp/DockClickMinimize.app/Contents/MacOS
mkdir -p /tmp/DockClickMinimize.app/Contents/Resources
cp .build/release/DockClickMinimize /tmp/DockClickMinimize.app/Contents/MacOS/DockClickMinimize

cat > /tmp/DockClickMinimize.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>DockClick Minimize</string>
  <key>CFBundleExecutable</key><string>DockClickMinimize</string>
  <key>CFBundleIdentifier</key><string>com.example.dockclickminimize</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>DockClickMinimize</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - /tmp/DockClickMinimize.app
rm -rf /Applications/DockClickMinimize.app
cp -R /tmp/DockClickMinimize.app /Applications/DockClickMinimize.app
open /Applications/DockClickMinimize.app
```

## Test

```bash
swift test
```

Important:

- In environments that do not provide `XCTest` (for example CLT-only setups), `swift test` may build successfully but not execute XCTest cases.
- For full test execution, use full Xcode toolchain (`xcode-select` set to Xcode).

## Debug logging

Run with debug logs enabled:

```bash
DOCKCLICK_DEBUG=1 swift run DockClickMinimize
```

This enables resolver/coordinator/window logs to help troubleshoot click resolution and action paths.

