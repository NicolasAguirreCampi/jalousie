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
- Apply the tiling layout algorithm
- Handle window open/close events and auto-retile
- Implement swap-left, swap-right
- Implement focus-left, focus-right
- Expose `sendWindow(_:toSpace:)` used by SpaceManager

**Window enumeration:**
```swift
// Get all on-screen windows via CGWindowListCopyWindowInfo
// Filter: kCGWindowLayer == 0 (normal windows only)
// Filter: kCGWindowIsOnscreen == true
// Filter: not in Config.blacklist (by bundleID)
// Filter: has AXUIElement with AXRole == "AXWindow"
// Filter: window is not minimized (AXMinimized == false)
// Filter: window is not fullscreen (AXFullScreen == false) — manage these separately
```

**Tiling algorithm:**
```
screenFrame = NSScreen.main.visibleFrame  // excludes menu bar and Dock
windowCount = managedWindows.count
if windowCount == 0: return
tileWidth = screenFrame.width / windowCount
for i, window in managedWindows:
    frame = CGRect(
        x: screenFrame.origin.x + (tileWidth * i),
        y: screenFrame.origin.y,
        width: tileWidth,
        height: screenFrame.height
    )
    setFrame(window.axElement, frame)
```

**Performance requirement — no animation:**
Set window position and size via direct AXUIElement calls only. Never wrap these calls in `NSAnimationContext.runAnimationGroup` or any animation block. macOS may apply its own implicit window-move animation — disable it by setting the position and size attributes in a single synchronous block without yielding to the run loop between calls.

**Setting window frame via AXUIElement:**
```swift
func setFrame(_ element: AXUIElementRef, _ frame: CGRect) {
    var position = frame.origin
    var size = frame.size
    AXUIElementSetAttributeValue(element, kAXPositionAttribute,
        AXValueCreate(.cgPoint, &position)!)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute,
        AXValueCreate(.cgSize, &size)!)
}
```

**Auto-retile triggers (NSWorkspace notifications):**
- `NSWorkspace.didLaunchApplicationNotification` → wait 0.3s for window to appear, then retile
- `NSWorkspace.didTerminateApplicationNotification` → retile
- `NSWorkspace.activeSpaceDidChangeNotification` → retile current space

**Also observe via CGEventTap or polling (250ms timer):**
- Detect when a new window appears on screen (window count change)
- Detect when a window is closed mid-session (not just app quit)

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
Maintain order by `x` origin of each window's current frame. When a new window is added, append to the right end of the list before retiling.

---

### SpaceManager.swift

**Responsibilities:**
- Query the current space index
- Switch to a target space by index
- Move the focused window to a target space, then retile both the source and destination spaces

**Private CGS headers required** (`CGSPrivate.h`):
```c
typedef int CGSConnectionID;
typedef uint64_t CGSSpaceID;
typedef enum {
    kCGSSpaceUser  = 0,
    kCGSSpaceFullscreen = 1,
} CGSSpaceType;

extern CGSConnectionID CGSMainConnectionID(void);
extern CGSSpaceID CGSGetActiveSpace(CGSConnectionID cid);
extern NSArray *CGSCopySpaces(CGSConnectionID cid, int mask);
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID cid, NSArray *windows, CGSSpaceID space);
extern void CGSHideSpaces(CGSConnectionID cid, NSArray *spaces);
extern void CGSShowSpaces(CGSConnectionID cid, NSArray *spaces);
```

**Bridging header:** Add `CGSPrivate.h` to the Objective-C bridging header so Swift can call these directly.

**Switch space:**
```swift
func switchToSpace(_ index: Int) {
    // Use CGSCopySpaces to get list of user spaces
    // Get spaceID at index
    // Use CGSShowSpaces + CGSHideSpaces to switch
    // Fallback: CoreGraphics private SkyLight framework direct call
}
```

**Send window to space:**
```swift
func sendFocusedWindowToSpace(_ targetIndex: Int) {
    let conn = CGSMainConnectionID()
    let window = WindowManager.shared.getFocusedWindow()
    guard let windowID = window?.windowID else { return }
    let spaces = CGSCopySpaces(conn, 0x7) as! [CGSSpaceID]
    guard targetIndex < spaces.count else { return }
    CGSMoveWindowsToManagedSpace(conn, [windowID] as NSArray, spaces[targetIndex])
    WindowManager.shared.retile()          // retile source space
    // switch to target space and retile there too (optional, per user preference)
}
```

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
    "send-to-space-5":   { "key": "5", "modifiers": ["option", "shift"] }
  },
  "blacklist": [
    "com.apple.finder",
    "com.apple.systempreferences",
    "com.apple.ActivityMonitor",
    "com.apple.Terminal",
    "com.googlecode.iterm2"
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
| Focus left/right | ✅ |
| Swap left/right | ✅ |
| Send window to space N | ✅ |
| Switch to space N (without moving window) | ✅ |
| Window gap setting | ✅ (config only) |
| App blacklist | ✅ |
| Menu bar icon | ✅ |
| Manual retile shortcut | ✅ |
| Config hot-reload | ✅ |
| Custom layouts (BSP, main+stack) | ❌ v2 |
| Per-app rules | ❌ v2 |
| Multi-monitor support | ❌ v2 |
| Preferences window | ❌ v2 |
| Floating window toggle | ❌ v2 |

---

## Known macOS Tahoe (26.x) Constraints

- **Plain binaries cannot get Accessibility permissions.** Jalousie must be a proper `.app` bundle — this spec is designed for that from the start.
- **CGSPrivate functions are stable** across macOS 12–26 but are private API. Apple may change or remove them without notice. `CGSMoveWindowsToManagedSpace` is the most likely to break.
- **AXUIElement is the stable public path** for all window geometry operations. Prefer it over any private API wherever possible.
- **No scripting addition.** Do not attempt to replicate yabai's `--load-sa` injection approach. AXUIElement covers all v1 needs.

---

## Development Approach

This project is designed for **spec-driven development**. Each module above is self-contained and can be implemented and tested independently:

1. Start with `Config.swift` + `JalousieConfig.swift` — pure Swift, no system APIs
2. Implement `AppDelegate.swift` — get the menu bar app running, confirm Accessibility prompt works
3. Implement `WindowManager.swift` — test tiling on the current space with hardcoded values first
4. Implement `HotkeyManager.swift` — wire hotkeys to `print()` statements before connecting to WindowManager
5. Implement `SpaceManager.swift` — test space switching in isolation before integrating send-window

Each module exposes a `shared` singleton. All inter-module calls go through these singletons.
