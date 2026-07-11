---
name: jalousie-swift
description: Swift and macOS system API best practices for developing Jalousie — a native macOS window manager. Use this skill whenever writing, reviewing, or refactoring any Swift code in the Jalousie project. Covers code style, AXUIElement patterns, CGEventTap safety, CGSPrivate usage, memory management, error handling, and project structure conventions.
---

# Jalousie Swift Development Skill

You are acting as a senior Swift/macOS engineer pairing with a developer who does not know Swift. Your job is to write clean, idiomatic, production-quality Swift — and to explain every non-obvious decision briefly in a comment or inline. Never produce code that works but smells wrong. Prefer clarity over cleverness.

---

## Project Context

Jalousie is a macOS menu bar window manager. It has no UI beyond a status bar item. It uses:
- `AXUIElement` (Accessibility API) for all window geometry
- `CGEventTap` for global hotkey interception
- `CGSPrivate` (private framework) for space switching
- `NSWorkspace` notifications for auto-retile triggers
- A JSON config file at `~/.config/jalousie/config.json`

Full spec is in `jalousie-spec.md`. Always read it before implementing a new module.

---

## Swift Code Style

### Naming
- Types: `UpperCamelCase` — `WindowManager`, `ManagedWindow`, `HotkeyManager`
- Functions and variables: `lowerCamelCase` — `retileCurrentSpace()`, `focusedWindow`
- Constants: `lowerCamelCase` — never `ALL_CAPS` in Swift
- Booleans: name as assertions — `isMinimized`, `canReceiveFocus`, `autoTileEnabled`
- Avoid abbreviations — `win` → `window`, `mgr` → `manager`, `cfg` → `config`

### Structure
- One type per file. File name matches type name exactly.
- Group related methods with `// MARK: - Section Name`
- Order within a type: properties → init → public methods → private methods
- Keep functions under 30 lines. If it's longer, it needs to be split.

### Swift idioms — always use these
```swift
// Guard for early exit instead of nested if
guard let window = getFocusedWindow() else { return }

// Prefer if let over force unwrap
if let value = optionalValue {
    // use value
}

// Never use ! unless you can guarantee non-nil with a comment explaining why
let screen = NSScreen.main! // guaranteed: app only runs when a display is connected

// Use defer for cleanup
func withCGEventTap(_ block: () -> Void) {
    CGEvent.tapEnable(tap: tap, enable: true)
    defer { CGEvent.tapEnable(tap: tap, enable: false) }
    block()
}

// Prefer computed properties over parameterless functions for state reads
var focusedWindow: ManagedWindow? {
    // returns current focused window
}

// Use result builders or map/filter/reduce instead of for loops where readable
let visibleWindows = allWindows.filter { !$0.isMinimized && !$0.isFullscreen }
```

### What to avoid
- `Any` and `AnyObject` — use generics or protocols instead
- `NSObject` subclasses unless required by AppKit/Cocoa
- Singletons everywhere — only `WindowManager`, `SpaceManager`, `HotkeyManager`, and `Config` use `shared`
- `DispatchQueue.main.async` inside tight loops
- Stringly typed values — use enums for actions, not raw strings like `"focus-left"`

---

## Singletons Pattern

All four core managers use the same singleton pattern:

```swift
final class WindowManager {
    static let shared = WindowManager()
    private init() {}
}
```

`final` prevents subclassing. `private init()` prevents external instantiation. Always use this exact pattern for the four core managers — nowhere else.

---

## AXUIElement Patterns

AXUIElement is the only supported API for moving and resizing windows. It requires Accessibility permission.

### Getting all windows
```swift
func enumerateManagedWindows() -> [ManagedWindow] {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[CFString: Any]] else { return [] }

    return windowList.compactMap { info -> ManagedWindow? in
        guard
            let windowID = info[kCGWindowNumber] as? CGWindowID,
            let layer = info[kCGWindowLayer] as? Int, layer == 0,
            let ownerPID = info[kCGWindowOwnerPID] as? pid_t,
            let name = info[kCGWindowOwnerName] as? String
        else { return nil }

        let appElement = AXUIElementCreateApplication(ownerPID)
        // ... get window element, check blacklist, return ManagedWindow
    }
}
```

### Setting window frame
```swift
func setFrame(of element: AXUIElement, to frame: CGRect) {
    var origin = frame.origin
    var size = frame.size

    guard
        let positionValue = AXValueCreate(.cgPoint, &origin),
        let sizeValue = AXValueCreate(.cgSize, &size)
    else { return }

    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
}
```

### Reading an AX attribute safely
```swift
func axValue<T>(of element: AXUIElement, attribute: String) -> T? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard result == .success else { return nil }
    return value as? T
}

// Usage
let isMinimized: Bool = axValue(of: windowElement, attribute: kAXMinimizedAttribute) ?? false
```

### Never force-cast AX results
```swift
// BAD
let title = AXUIElementCopyAttributeValue(...) as! String

// GOOD
guard let title = axValue(of: element, attribute: kAXTitleAttribute) as String? else { return }
```

---

## CGEventTap Patterns

CGEventTap runs on the main run loop. Keep the callback fast — no I/O, no heavy computation.

### Setup
```swift
private func createEventTap() -> CFMachPort? {
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    return CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(proxy: proxy, type: type, event: event)
        },
        userInfo: Unmanaged.passRetained(self).toOpaque()
    )
}
```

### Handle method — keep it under 20 lines
```swift
func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    guard type == .keyDown else { return Unmanaged.passRetained(event) }
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.intersection([.maskAlternate, .maskShift, .maskCommand, .maskControl])

    if let action = matchedAction(keyCode: keyCode, flags: flags) {
        DispatchQueue.main.async { self.dispatch(action) }
        return nil  // suppress the event
    }
    return Unmanaged.passRetained(event)  // pass through
}
```

### Use an enum for actions — not strings
```swift
enum WMAction {
    case focusLeft
    case focusRight
    case swapLeft
    case swapRight
    case sendToSpace(Int)
    case switchToSpace(Int)
    case retile
    case reloadConfig
}
```

---

## CGSPrivate Patterns

CGSPrivate functions are C functions imported via a bridging header. They have no Swift error handling — they silently fail or crash if called incorrectly.

### Always validate before calling
```swift
func switchToSpace(at index: Int) {
    let conn = CGSMainConnectionID()
    guard conn != 0 else {
        print("[Jalousie] CGSMainConnectionID returned 0 — cannot switch space")
        return
    }
    guard let spaces = CGSCopySpaces(conn, 0x7) as? [CGSSpaceID],
          index < spaces.count else {
        print("[Jalousie] Space index \(index) out of bounds")
        return
    }
    // proceed
}
```

### Never call CGS functions on a background thread
All CGSPrivate calls must happen on the main thread. If you're dispatching from a hotkey callback, wrap in `DispatchQueue.main.async`.

---

## Memory Management

Swift uses ARC (Automatic Reference Counting). The main manual memory concern in Jalousie is `Unmanaged` references used with CGEventTap callbacks.

### The Unmanaged pattern — always use takeUnretainedValue in callbacks
```swift
// Passing self into C callback
userInfo: Unmanaged.passRetained(self).toOpaque()

// Inside the C callback — do NOT use takeRetainedValue (causes double-release)
let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
```

### Avoid retain cycles in closures
```swift
// BAD — self retains the closure, closure retains self
NotificationCenter.default.addObserver(forName: ...) { notification in
    self.retile()
}

// GOOD
NotificationCenter.default.addObserver(forName: ...) { [weak self] notification in
    self?.retile()
}
```

### AXUIElement is a CFTypeRef — no manual retain/release needed in Swift
Swift bridges CFTypeRef to ARC automatically. Just hold the reference normally.

---

## Error Handling

Jalousie is a background system utility. Errors should never crash the app or show alerts to the user (except the one-time Accessibility permission alert on first launch).

### Logging pattern — use a simple wrapper, not print()
```swift
// In a file called Log.swift
enum Log {
    static func info(_ message: String) {
        NSLog("[Jalousie] ℹ️ \(message)")
    }
    static func warn(_ message: String) {
        NSLog("[Jalousie] ⚠️ \(message)")
    }
    static func error(_ message: String) {
        NSLog("[Jalousie] ❌ \(message)")
    }
}

// Usage
Log.warn("Could not get focused window — skipping retile")
```

Logs appear in Console.app and `log stream --predicate 'process = "Jalousie"'` — useful for debugging without Xcode attached.

### Result type for operations that can fail
```swift
enum TileError: Error {
    case noManagedWindows
    case axPermissionDenied
    case windowNotFound
}

func retile() -> Result<Void, TileError> {
    let windows = enumerateManagedWindows()
    guard !windows.isEmpty else { return .failure(.noManagedWindows) }
    // ...
    return .success(())
}
```

### Call sites — handle or log, never ignore
```swift
switch WindowManager.shared.retile() {
case .success:
    break
case .failure(let error):
    Log.warn("Retile failed: \(error)")
}
```

---

## Concurrency

Jalousie is single-threaded for simplicity in v1. All logic runs on the main thread.

```swift
// If you ever need to delay (e.g. waiting for a window to appear after app launch)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    WindowManager.shared.retile()
}

// Do NOT use async/await in v1 — it adds complexity without benefit here
// Do NOT use background queues for AX or CGS calls — they are not thread-safe
```

---

## NSWorkspace Notifications

Register in `WindowManager.start()`, not in `init()`:

```swift
func start() {
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(self,
        selector: #selector(handleAppLaunch(_:)),
        name: NSWorkspace.didLaunchApplicationNotification,
        object: nil)
    nc.addObserver(self,
        selector: #selector(handleAppTerminate(_:)),
        name: NSWorkspace.didTerminateApplicationNotification,
        object: nil)
    nc.addObserver(self,
        selector: #selector(handleSpaceChange(_:)),
        name: NSWorkspace.activeSpaceDidChangeNotification,
        object: nil)
}

@objc private func handleAppLaunch(_ notification: Notification) {
    // Wait for window to appear
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        self?.retile()
    }
}
```

---

## Config File Handling

```swift
// Always use FileManager for path construction — never hardcode strings
func configURL() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home
        .appendingPathComponent(".config")
        .appendingPathComponent("jalousie")
        .appendingPathComponent("config.json")
}

// Create directory if missing
func ensureConfigDirectory() throws {
    let dir = configURL().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir,
        withIntermediateDirectories: true)
}

// Decode with a clear error
func load() -> JalousieConfig {
    let url = configURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
        return copyAndLoadDefault()
    }
    do {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(JalousieConfig.self, from: data)
    } catch {
        Log.error("Failed to load config: \(error). Using defaults.")
        return JalousieConfig.default
    }
}
```

---

## Project Structure Conventions

```
Jalousie/
├── App/
│   └── AppDelegate.swift       # Entry point only — no business logic here
├── Core/
│   ├── WindowManager.swift     # All tiling, swap, focus logic
│   ├── SpaceManager.swift      # All space switching logic
│   ├── HotkeyManager.swift     # All CGEventTap logic
│   └── Config.swift            # File I/O only — no parsing logic here
├── Model/
│   ├── ManagedWindow.swift     # Pure data struct — no methods that call managers
│   ├── JalousieConfig.swift    # Codable structs + static default
│   └── WMAction.swift          # The WMAction enum
├── Util/
│   └── Log.swift               # Logging wrapper
├── Headers/
│   ├── CGSPrivate.h
│   └── Jalousie-Bridging-Header.h
└── Resources/
    └── jalousie-default.json
```

**Rules:**
- `AppDelegate` only wires things together — no window or hotkey logic lives there
- `Model` types are pure data — they never reference managers or singletons
- `Core` managers never import each other's internals — they call through `shared`
- `Util` has no dependencies on `Core` or `Model`

---

## Code Review Checklist

Before considering any module done, verify:

- [ ] No force unwraps (`!`) without an explaining comment
- [ ] No `print()` — use `Log.*` instead
- [ ] No stringly-typed actions — use `WMAction` enum
- [ ] All AX calls check return value or use the safe `axValue()` helper
- [ ] All CGS calls validate connection and index before calling
- [ ] No retain cycles in closures — `[weak self]` used where needed
- [ ] Notifications registered in `start()`, not `init()`
- [ ] Every function has a single clear responsibility
- [ ] File name matches the type name exactly
- [ ] All `DispatchQueue` calls are on `.main` — no background threads

---

## Asking Claude for Help

When asking Claude to implement a module, always include:

1. The contents of `jalousie-spec.md` (the project spec)
2. This skill file
3. Any already-implemented files the new module depends on
4. A one-sentence description of what you want: *"Implement `WindowManager.swift` per the spec"*

Claude will follow the patterns in this skill automatically. If it produces code that violates any rule above, point to the specific rule and ask it to fix that section.
