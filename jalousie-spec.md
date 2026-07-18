# Jalousie — macOS Window Manager
## Project Spec v1.0

---

## Overview

Jalousie is a lightweight native macOS window manager built as a proper `.app` bundle in Swift. It requires no third-party dependencies (no yabai, no skhd, no Karabiner), works on macOS Tahoe (26.x), and obtains Accessibility permissions correctly through standard TCC without SIP modifications.

It lives in the menu bar, has no Dock icon, and is driven entirely by keyboard shortcuts.

**Performance is a first-class requirement.** Every action — tiling, focus, swap, space switch — must feel instantaneous. There are zero animations, zero transitions, and zero delays of any kind. Windows snap to their new positions immediately. This is non-negotiable and applies to every module.

---

## Target Environment

- **Language:** Swift 5.9+
- **Minimum macOS:** 14.0 (Sonoma), primary target macOS 26 (Tahoe)
- **Xcode:** 15+
- **Architecture:** Universal (arm64 + x86_64)
- **Distribution:** Local build only, no App Store, no notarization required
- **Bundle ID:** `com.local.jalousie`

---

## Core Design Principles

1. **No scripting addition.** All window manipulation uses `AXUIElement` (Accessibility API) only.
2. **No SIP modifications required.** Being a proper `.app` bundle means TCC prompts work correctly on Tahoe.
3. **No third-party dependencies.** Pure Swift, zero Swift Package Manager packages.
4. **Single binary.** One `.app`, drag to `/Applications`, done.
5. **Config-driven.** Hotkeys and app blacklist live in `~/.config/jalousie/config.json`, editable without recompiling.
6. **Minimal UI.** Menu bar icon + dropdown only. No preferences window needed for v1.
7. **No animations. No transitions. Ever.** Windows must snap to position instantly on every action. Do not use `NSAnimationContext`, `animate(withDuration:)`, `CATransaction`, or any animation API anywhere in the codebase. Do not add `DispatchQueue` delays to smooth visual changes. Snappiness is a core feature, not a preference.
8. **No timers, no polling.** Every reaction to window / app / space state is event-driven. Use `AXObserver` for window lifecycle (created / destroyed / minimized / deminimized) and `NSWorkspace.NotificationCenter` for app lifecycle. `Timer`, `scheduledTimer`, `DispatchSourceTimer`, and `DispatchQueue.main.asyncAfter` must not appear in the app.

---

## App Structure

```
Jalousie.xcodeproj
└── Jalousie/
    ├── App/
    │   ├── AppDelegate.swift          # NSApplication entry, menu bar setup, permission check
    │   └── Info.plist                 # LSUIElement=YES (no Dock icon), NSAccessibilityUsageDescription
    ├── Core/
    │   ├── WindowManager.swift        # AXUIElement queries, tiling algorithm, swap, focus
    │   ├── SpaceManager.swift         # CGSPrivate space switching, send-window-to-space
    │   ├── HotkeyManager.swift        # CGEventTap, key combo registration and dispatch
    │   └── Config.swift               # Load/save ~/.config/jalousie/config.json
    ├── Model/
    │   ├── ManagedWindow.swift        # Struct: windowID, appName, bundleID, axElement, frame
    │   └── JalousieConfig.swift         # Codable config model: hotkeys, blacklist, settings
    ├── Headers/
    │   └── CGSPrivate.h               # Private CGS headers for space operations
    └── Resources/
        └── jalousie-default.json        # Bundled default config, copied on first launch
```

---

## Module Specifications

### AppDelegate.swift

**Responsibilities:**
- Set `LSUIElement = YES` in Info.plist (no Dock icon, menu bar only)
- On launch: call `Config.load()`, then `HotkeyManager.start()`, then `WindowManager.start()`
- Check Accessibility permission on launch via `AXIsProcessTrusted()`
- If not trusted: show a one-time `NSAlert` directing user to System Settings → Privacy & Security → Accessibility, then call `AXIsProcessTrustedWithOptions` with prompt
- Set up menu bar `NSStatusItem` with icon and dropdown menu containing: "Jalousie", separator, "Retile current space", "Reload config", separator, "Quit"

**Key APIs:**
```swift
AXIsProcessTrusted() -> Bool
AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true]) -> Bool
NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
```

---

### WindowManager.swift

**Responsibilities:**
- Enumerate all visible, manageable windows on the current space
- Apply the tiling layout algorithm (per-screen for multi-monitor setups)
- Handle window open/close events and auto-retile
- Implement swap-left, swap-right
- Implement focus-left, focus-right
- Implement zoom-fullscreen toggle (window fills its display; tile slot preserved for focus/swap ordering)
- Expose `focusedManagedWindow()` used by SpaceManager for send-to-space

**Window enumeration:**
```swift
// Iterate NSWorkspace.runningApplications where activationPolicy == .regular
// (CGWindowList's PID column drops Electron windows owned by helper renderers)
// For each app: read kAXWindowsAttribute, then filter each window:
//   - AXRole == "AXWindow"
//   - AXSubrole == "AXStandardWindow" (rejects dialogs, floating panels,
//     iTerm's Cmd+F find bar, etc.)
//   - AXMinimized == false
//   - AXFullScreen (private attr) == false
//   - CGWindowID present in CGWindowList's on-screen set (per-window on-screen check)
//   - bundleID not in Config.blacklist
```

**Tiling algorithm (per-screen, adaptive):**
```
1. Group managed windows by the screen their frame overlaps most.
2. For each screen group:
   a. Compute equal tile widths across usable (screen.visibleFrame → Quartz).
   b. Promote any window with a learned "stubborn floor" (see below) to its
      floor; equal-share the remainder among flexible windows. Iterate until
      no more promotions.
   c. For each window: setFrame to (x, y, allocated width, usable height).
      If the window is in zoomedWindowIDs, target the full usable frame
      instead. Its tile x-cursor still advances so unzoom is a plain retile.
   d. Read back sizes. If any non-zoomed window's actual > allocated + 1pt,
      record it as that window's minimum and re-apply the row.
```

**Zoom-fullscreen:**
Windows in the `zoomedWindowIDs` set are overridden to fill their display's
full usable frame at layout time. The tile slot is still tracked, so focus-
left/right traverses the ordered list normally and revealing a neighbor
brings it to the front over the zoomed windows. Multiple windows can be
zoomed simultaneously — the raised one is visible on top.

**Adaptive widths:**
Some apps (Xcode, Discord, Slack, etc.) refuse to shrink below a per-app
minimum. `learnStubbornWidths` observes actual widths post-setFrame and
records the floor keyed by CGWindowID. Zoomed windows are skipped from
this learning so the intentionally-forced full-usable width isn't
recorded as their minimum.

**Performance requirement — no animation:**
Set window position and size via direct AXUIElement calls only. Never wrap
these calls in `NSAnimationContext.runAnimationGroup`, `CATransaction`, or
any animation block. Additionally, temporarily disable
`AXEnhancedUserInterface` on each affected app for the duration of each
retile — apps with it enabled (Firefox, Discord, Slack, VoiceOver, Zoom)
animate every position write and silently drop overlapping writes, which
otherwise causes drops and visible flicker.

**Setting window frame via AXUIElement:**
```swift
func setFrame(_ element: AXUIElementRef, _ frame: CGRect) {
    var position = frame.origin
    var size = frame.size
    // Size → position → size sandwich: an intervening AXPosition write can
    // otherwise clamp size to the target app's visible-area constraint.
    AXUIElementSetAttributeValue(element, kAXSizeAttribute,     AXValueCreate(.cgSize, &size)!)
    AXUIElementSetAttributeValue(element, kAXPositionAttribute, AXValueCreate(.cgPoint, &position)!)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute,     AXValueCreate(.cgSize, &size)!)
}
```

**Auto-retile triggers (NSWorkspace notifications):**
- `NSWorkspace.didLaunchApplicationNotification` → register an AXObserver on the new app and retile immediately (the app's window-created event will fire once its window actually exists)
- `NSWorkspace.didTerminateApplicationNotification` → unregister the app's AXObserver and retile
- `NSWorkspace.activeSpaceDidChangeNotification` → retile the newly-active space (gated on `settings.tileOnSpaceSwitch`)
- `NSWorkspace.didActivateApplicationNotification` → retile (catches Cmd-Tab / dock-click into resident Electron-style apps like WhatsApp, Slack, VS Code, which reveal a hidden window without firing a launch event)
- `NSWorkspace.didUnhideApplicationNotification` → retile (Cmd-H toggle reveal)

**Mid-session window changes — event-driven, no polling:**
Register a per-process `AXObserver` for every non-blacklisted running app and subscribe to:

App-level (some Chromium/Electron apps skip kAXWindowCreated; the extras cover them):
- `kAXWindowCreatedNotification`
- `kAXFocusedWindowChangedNotification`
- `kAXMainWindowChangedNotification`
- `kAXApplicationShownNotification` / `kAXApplicationHiddenNotification`

Per managed-window:
- `kAXUIElementDestroyedNotification` — Cmd-W
- `kAXWindowMiniaturizedNotification` / `kAXWindowDeminiaturizedNotification`
- `kAXWindowMovedNotification` — sets a `pendingRetileAfterDrag` flag; the actual retile is flushed by a global `.leftMouseUp` `NSEvent` monitor so we don't fight the user's cursor during a drag

All non-move callbacks funnel into `retile()`. **No timers, no polling anywhere in the app** — window lifecycle is entirely event-driven.

**Swap algorithm:**
```
focused = getFocusedWindow()
index = managedWindows.firstIndex(of: focused)
swapLeft:  swap(managedWindows[index], managedWindows[index - 1])  // clamp at 0
swapRight: swap(managedWindows[index], managedWindows[index + 1])  // clamp at count-1
retile()
```

**Focus algorithm:**
```
focused = getFocusedWindow()
index = managedWindows.firstIndex(of: focused)
focusLeft:  AXUIElementSetAttributeValue(managedWindows[index-1], kAXFocusedAttribute, true)
focusRight: AXUIElementSetAttributeValue(managedWindows[index+1], kAXFocusedAttribute, true)
```

**Window ordering:**
A persistent cache (`orderedKnownWindowIDs`) records each window's slot. Dragging does **not** reorder — the window snaps back to its assigned slot on the next retile. Only `swapLeft/Right` mutates the order. Brand-new windows are appended to the right end (sorted by their initial x among themselves) and closed windows drop out automatically.

---

### SpaceManager.swift

**Responsibilities:**
- Query the current space index
- Switch to a target space by index
- Move the focused window to a target space, then retile both the source and destination spaces

**Private CGS/SLS headers required** (`CGSPrivate.h`):
```c
typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;

extern CGSConnectionID CGSMainConnectionID(void);
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);
extern NSArray *CGSCopySpaces(CGSConnectionID cid, int mask);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, NSArray *windows, CGSSpaceID space);
extern void CGSHideSpaces(CGSConnectionID cid, NSArray *spaces);
extern void CGSShowSpaces(CGSConnectionID cid, NSArray *spaces);
// SLSSpaceSetCompatID / SLSSetWindowListWorkspace / SLSSpaceAddWindowsAndRemoveFromSpaces
// are resolved via dlsym at runtime — not declared here because the SkyLight
// framework isn't in the public link path.
```

**Bridging header:** Add `CGSPrivate.h` and `SpaceBridge.h` (see below) to the Objective-C bridging header so Swift can call these directly.

**Display-aware space list:**
Space IDs are per-display. `spacesForCurrentDisplay(of:)` calls
`CGSCopyManagedDisplaySpaces`, resolves the focused window's display via
`CGGetDisplaysWithPoint` → `CGDisplayCreateUUIDFromDisplayID`, and returns
only the space list for that display. `Option+Shift+2` therefore always
means "second space on the monitor the focused window is on".

**Send window to space (macOS 26+ / Tahoe):**
The exported wrapper `SLSSpaceAddWindowsAndRemoveFromSpaces` is gated behind
`SLSWindowManagementClientOperationsEnabled` and returns `-1342177280`
(unentitled) for non-Apple processes. The working path is yabai's v7.1.25
trick: walk the SkyLight image's LC_SYMTAB with a small Mach-O parser to
find the private symbol
`__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation`,
allocate a `SLSBridgedMoveWindowsToManagedSpaceOperation` via `objc_msgSend`
(selector `initWithSpaceID:windows:options:` on macOS 26+, or
`initWithWindows:spaceID:` on older), and call the perform function
directly — bypassing the entitlement gate. Implemented in
`Jalousie/Core/SpaceBridge.m`.

**Switch space:**
Still uses `CGSShowSpaces` + `CGSHideSpaces`. This API is heavily clamped on
Tahoe (visibly no-ops in most configurations) — kept as-is because there is
no known SIP-enabled bypass. Not a blocker for send-to-space, which uses
the bridged operation above.

---

### HotkeyManager.swift

**Responsibilities:**
- Create a `CGEventTap` at `kCGSessionEventTap` to intercept keydown events globally
- Parse key combos from `Config.hotkeys`
- Dispatch to the appropriate `WindowManager` or `SpaceManager` action
- Suppress the event (return nil) so it doesn't reach other apps

**CGEventTap setup:**
```swift
let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
    callback: eventTapCallback,
    userInfo: Unmanaged.passRetained(self).toOpaque()
)
// Add to run loop
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
```

**Key matching:**
```swift
struct HotKey {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags   // e.g. [.maskAlternate, .maskShift]
    let action: String            // "focus-left", "focus-right", "swap-left", etc.
}

func matches(_ event: CGEvent, _ hotkey: HotKey) -> Bool {
    let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl])
    return code == hotkey.keyCode && flags == hotkey.modifiers
}
```

**Default key codes:**
```
J = 38
L = 37
1 = 18, 2 = 19, 3 = 20, 4 = 21, 5 = 23, 6 = 22, 7 = 26, 8 = 28, 9 = 25
```

---

### Config.swift + JalousieConfig.swift

**Config file location:** `~/.config/jalousie/config.json`

**Default config (jalousie-default.json):**
```json
{
  "hotkeys": {
    "focus-left":        { "key": "j", "modifiers": ["option"] },
    "focus-right":       { "key": "l", "modifiers": ["option"] },
    "swap-left":         { "key": "j", "modifiers": ["option", "shift"] },
    "swap-right":        { "key": "l", "modifiers": ["option", "shift"] },
    "send-to-space-1":   { "key": "1", "modifiers": ["option", "shift"] },
    "send-to-space-2":   { "key": "2", "modifiers": ["option", "shift"] },
    "send-to-space-3":   { "key": "3", "modifiers": ["option", "shift"] },
    "send-to-space-4":   { "key": "4", "modifiers": ["option", "shift"] },
    "send-to-space-5":   { "key": "5", "modifiers": ["option", "shift"] },
    "retile":            { "key": "e", "modifiers": ["option", "shift"] },
    "toggle-zoom-fullscreen": { "key": "m", "modifiers": ["option", "shift"] }
  },
  "blacklist": [
    "com.apple.finder",
    "com.apple.systempreferences",
    "com.apple.ActivityMonitor",
    "com.apple.Terminal",
    "com.apple.calculator"
  ],
  "settings": {
    "autoTile": true,
    "tileOnSpaceSwitch": true,
    "windowGap": 0,
    "ignoreSingleWindow": false
  }
}
```

**JalousieConfig Codable model:**
```swift
struct JalousieConfig: Codable {
    var hotkeys: [String: HotKeyConfig]
    var blacklist: [String]
    var settings: Settings

    struct HotKeyConfig: Codable {
        let key: String
        let modifiers: [String]
    }

    struct Settings: Codable {
        var autoTile: Bool
        var tileOnSpaceSwitch: Bool
        var windowGap: CGFloat
        var ignoreSingleWindow: Bool
    }
}
```

**Config.load():** Read from `~/.config/jalousie/config.json`. If missing, copy `jalousie-default.json` from bundle to that path, then load it.

**Config.reload():** Re-read the file and call `HotkeyManager.shared.rebuildHotkeys()`.

---

### ManagedWindow.swift

```swift
struct ManagedWindow: Equatable {
    let windowID: CGWindowID        // from CGWindowListCopyWindowInfo
    let appName: String
    let bundleID: String
    let axElement: AXUIElement      // for move/resize/focus
    var frame: CGRect               // current frame, updated after each tile
    var orderIndex: Int             // position in the tiled layout (0 = leftmost)
}
```

---

## Info.plist Requirements

```xml
<key>LSUIElement</key>
<true/>
<key>NSAccessibilityUsageDescription</key>
<string>Jalousie needs Accessibility access to move and resize windows.</string>
<key>NSPrincipalClass</key>
<string>NSApplication</string>
```

---

## CGSPrivate Bridging Setup

1. Create `Jalousie-Bridging-Header.h` in the project root
2. Add to Build Settings → Objective-C Bridging Header: `Jalousie/Headers/Jalousie-Bridging-Header.h`
3. Contents of bridging header:
```objc
#import "CGSPrivate.h"
```
4. `CGSPrivate.h` declares only the functions actually used (see SpaceManager spec above)
5. Link `ApplicationServices.framework` and `CoreGraphics.framework` (both already present in macOS SDK)

---

## Permissions Required

| Permission | Why | How obtained |
|---|---|---|
| Accessibility | Move and resize windows via AXUIElement | Standard TCC prompt on first launch |
| None else | CGSPrivate needs no special entitlement | — |

**No entitlements file needed.** No App Sandbox. No Hardened Runtime required for local builds.

---

## Build & Run

```bash
# Clone / create project
open Jalousie.xcodeproj

# Build
xcodebuild -scheme Jalousie -configuration Release -derivedDataPath build

# Install
cp -r build/Build/Products/Release/Jalousie.app /Applications/

# Run (first launch will prompt for Accessibility)
open /Applications/Jalousie.app
```

---

## Feature Flags (v1 scope)

| Feature | In v1 |
|---|---|
| Auto-tile on window open | ✅ |
| Auto-retile on window close | ✅ |
| Equal horizontal splits, 100% height | ✅ |
| Adaptive widths for apps with hard-coded minimums | ✅ |
| Focus left/right | ✅ |
| Swap left/right | ✅ |
| Zoom-fullscreen toggle (multi-window, tile-slot preserved) | ✅ |
| Send window to space N | ✅ |
| Switch to space N (without moving window) | ⚠️ dispatches, but the CGS show/hide APIs are clamped on macOS 26 |
| Multi-monitor support (per-screen tiling, drag between screens) | ✅ |
| Window gap setting | ✅ (config only) |
| App blacklist | ✅ |
| Menu bar icon | ✅ |
| Manual retile shortcut | ✅ |
| Config hot-reload | ✅ |
| Custom layouts (BSP, main+stack) | ❌ v2 |
| Per-app rules | ❌ v2 |
| Preferences window | ❌ v2 |
| Floating window toggle | ❌ v2 |
| Persisted stubborn-width cache across launches | ❌ v2 |

---

## Known macOS Tahoe (26.x) Constraints

- **Plain binaries cannot get Accessibility permissions.** Jalousie must be a proper `.app` bundle. Trust is cached at process launch and cannot be re-evaluated in-process, so the first-launch flow shows an alert with a "Relaunch Jalousie" button that spawns a fresh instance via `open -n` after the user grants access.
- **AXUIElement is the stable public path** for all window geometry operations. Prefer it over any private API wherever possible.
- **Apps may drop AX writes silently** when `AXEnhancedUserInterface` is enabled on the target app (Firefox, Discord, Slack, VoiceOver, Zoom). The window manager temporarily disables and restores that attribute across each retile — this is the same mitigation yabai uses.
- **`CGSMoveWindowsToManagedSpace` is silently no-op'd** on macOS 26. Send-to-space uses the private `SLSBridgedMoveWindowsToManagedSpaceOperation` class + a Mach-O local-symbol resolver to reach the underlying perform function (yabai's v7.1.25 fix). Works with SIP enabled.
- **`CGSShowSpaces` / `CGSHideSpaces` (switch-to-space)** dispatches but doesn't visibly move on Tahoe. No known SIP-enabled bypass; kept in place so hotkeys wire up cleanly.
- **No scripting addition.** Do not attempt to replicate yabai's `--load-sa` injection approach. The Mach-O symbol trick above avoids the need.

---

## Development Approach

This project is designed for **spec-driven development**. Each module above is self-contained and can be implemented and tested independently:

1. Start with `Config.swift` + `JalousieConfig.swift` — pure Swift, no system APIs
2. Implement `AppDelegate.swift` — get the menu bar app running, confirm Accessibility prompt works
3. Implement `WindowManager.swift` — test tiling on the current space with hardcoded values first
4. Implement `HotkeyManager.swift` — wire hotkeys to `print()` statements before connecting to WindowManager
5. Implement `SpaceManager.swift` — test space switching in isolation before integrating send-window

Each module exposes a `shared` singleton. All inter-module calls go through these singletons.
