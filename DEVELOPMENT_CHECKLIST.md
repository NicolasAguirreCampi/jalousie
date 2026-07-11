# Jalousie — Development Checklist

Step-by-step build plan. Each phase produces something you can run and verify before moving on. Do not skip verification steps — the whole point is catching errors at the boundary they were introduced.

---

## Phase 0 — Project Scaffold

- [ ] Create `Jalousie.xcodeproj` in Xcode: macOS App, Swift, no Storyboard, no Core Data, no tests initially
- [ ] Set Bundle ID to `com.local.jalousie`
- [ ] Set Deployment Target to macOS 14.0
- [ ] Set Architectures to Universal (arm64 + x86_64)
- [ ] Create folder structure: `App/`, `Core/`, `Model/`, `Util/`, `Headers/`, `Resources/`
- [ ] In `Info.plist` set `LSUIElement = YES` and add `NSAccessibilityUsageDescription`
- [ ] Build empty app. **Verify:** builds with no errors, launches without a Dock icon, no window shown.

---

## Phase 1 — Logging Utility

- [ ] Create `Util/Log.swift` with `info`, `warn`, `error` static methods using `NSLog`
- [ ] Call `Log.info("Jalousie starting")` from `AppDelegate.applicationDidFinishLaunching`
- [ ] **Verify:** launch app, run `log stream --predicate 'process == "Jalousie"'`, see the startup line.

---

## Phase 2 — Menu Bar Item

- [ ] In `AppDelegate.swift` create an `NSStatusItem` with `squareLength`
- [ ] Set a system symbol icon (e.g. `rectangle.split.3x1`)
- [ ] Build the dropdown menu: title row, separator, "Retile current space", "Reload config", separator, "Quit"
- [ ] Wire "Quit" to `NSApp.terminate(_:)`; the others print/log a placeholder
- [ ] **Verify:** icon appears in menu bar, dropdown opens, Quit works, log lines appear when clicking the placeholder items.

---

## Phase 3 — Config Model + Defaults

- [ ] Create `Model/JalousieConfig.swift` with `Codable` structs (`hotkeys`, `blacklist`, `settings`) matching the spec
- [ ] Add a `static let `default`: JalousieConfig` fallback in code
- [ ] Create `Resources/jalousie-default.json` matching the spec's default JSON, add to app bundle
- [ ] **Verify:** unit-check by decoding the bundled JSON at launch and logging the parsed struct's field count.

---

## Phase 4 — Config Loader

- [ ] Create `Core/Config.swift` singleton with `load()`, `reload()`, `current`
- [ ] `load()` ensures `~/.config/jalousie/` exists, copies bundled default if `config.json` missing, then decodes
- [ ] Handle decode failure by logging and falling back to `JalousieConfig.default`
- [ ] Call `Config.shared.load()` from `AppDelegate`
- [ ] Wire "Reload config" menu item to `Config.shared.reload()`
- [ ] **Verify:**
  - First launch creates `~/.config/jalousie/config.json`
  - Deleting the file and relaunching recreates it
  - Editing the file to invalid JSON logs an error but doesn't crash
  - "Reload config" picks up an edit without a relaunch (log the new value)

---

## Phase 5 — Accessibility Permission

- [ ] In `AppDelegate` check `AXIsProcessTrusted()` on launch
- [ ] If not trusted: show a single `NSAlert` explaining the permission, then call `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])`
- [ ] Do not retry or loop — trust is checked once per launch
- [ ] **Verify:**
  - First launch shows the alert and the system prompt
  - After granting in System Settings and relaunching, no prompt appears
  - Log clearly indicates trusted / not trusted at startup

---

## Phase 6 — Window Enumeration (read-only)

- [ ] Create `Model/ManagedWindow.swift` per spec
- [ ] Create `Core/WindowManager.swift` singleton with `start()` and `enumerateManagedWindows() -> [ManagedWindow]`
- [ ] Implement enumeration via `CGWindowListCopyWindowInfo` + `AXUIElementCreateApplication`
- [ ] Apply filters: layer 0, on-screen, blacklist, `AXRole == AXWindow`, not minimized, not fullscreen
- [ ] Add a temporary "List windows" menu item that logs the current managed windows
- [ ] **Verify:**
  - Menu item logs the expected apps and skips blacklisted ones (Finder, Terminal, etc.)
  - Minimizing a window removes it from the list
  - Fullscreen window is excluded

---

## Phase 7 — Tiling (manual trigger)

- [ ] Add `retile()` to `WindowManager` implementing the equal-horizontal-split algorithm
- [ ] Add `setFrame(of:to:)` helper using `AXValueCreate` for position and size
- [ ] Wire the "Retile current space" menu item to `WindowManager.shared.retile()`
- [ ] Respect `windowGap` from config
- [ ] **Verify:**
  - Two windows → each takes half the visible frame
  - Three windows → each takes a third
  - Zero/one window → no crash, no change (or single window full screen depending on `ignoreSingleWindow`)
  - Retiling twice in a row is idempotent

---

## Phase 8 — Window Order Stability

- [ ] Sort enumerated windows by current `x` origin before tiling
- [ ] Cache the current tiled order between retiles so a new window appends to the right end
- [ ] **Verify:** repeatedly retile after moving one window by hand — the order should track visual left-to-right position, and a newly opened window should slot in at the rightmost tile.

---

## Phase 9 — Auto-Retile on Workspace Events

- [ ] In `WindowManager.start()` register for `didLaunchApplicationNotification`, `didTerminateApplicationNotification`, `activeSpaceDidChangeNotification`
- [ ] Launch handler waits 0.3s then retiles
- [ ] Terminate handler retiles immediately
- [ ] Space change handler retiles only if `settings.tileOnSpaceSwitch` is true
- [ ] Gate all of it on `settings.autoTile`
- [ ] **Verify:**
  - Opening a new app auto-tiles all windows
  - Closing an app auto-tiles the remainder
  - Setting `autoTile = false` in config and reloading disables the behavior

---

## Phase 10 — Mid-session Window Add/Remove Detection

- [ ] Add a 250ms `Timer` that polls the window count and triggers retile when the set changes
- [ ] Debounce so a burst of changes results in one retile
- [ ] **Verify:** opening a second window of an already-running app (Cmd-N in a text editor) triggers a retile.

---

## Phase 11 — Focus Left/Right

- [ ] Add `focusLeft()` and `focusRight()` to `WindowManager`
- [ ] Find focused window via `AXUIElementCopyAttributeValue(system, kAXFocusedWindowAttribute)`
- [ ] Clamp at edges
- [ ] Add temporary menu items to trigger both
- [ ] **Verify:** with three windows tiled, clicking the menu items moves focus left/right visibly.

---

## Phase 12 — Swap Left/Right

- [ ] Add `swapLeft()` and `swapRight()` that swap the focused window with its neighbor in the ordered list, then retile
- [ ] Clamp at edges
- [ ] Add temporary menu items
- [ ] **Verify:** swap moves the focused window to the neighbor's slot and vice versa; focus stays on the moved window.

---

## Phase 13 — Hotkey Manager (dispatch to logs first)

- [ ] Create `Model/WMAction.swift` enum: `focusLeft`, `focusRight`, `swapLeft`, `swapRight`, `sendToSpace(Int)`, `switchToSpace(Int)`, `retile`, `reloadConfig`
- [ ] Create `Core/HotkeyManager.swift` singleton with `start()`, `rebuildHotkeys()`
- [ ] Parse hotkeys from `Config.shared.current.hotkeys`: string key → `CGKeyCode`, modifier strings → `CGEventFlags`
- [ ] Set up `CGEventTap` on `.cgSessionEventTap` for keydown events
- [ ] In the callback, match against the loaded hotkeys; on match, `Log.info("dispatch \(action)")` and return `nil` to suppress
- [ ] Call `HotkeyManager.shared.start()` from `AppDelegate`
- [ ] **Verify:**
  - Log line appears when pressing each configured shortcut
  - Non-matching keys pass through normally (typing still works)
  - "Reload config" rebuilds hotkeys with new bindings

---

## Phase 14 — Hotkey → WindowManager Wiring

- [ ] In `HotkeyManager.dispatch(_:)` route `focusLeft/Right` and `swapLeft/Right` to `WindowManager.shared`
- [ ] Route `retile` and `reloadConfig` similarly
- [ ] Dispatch on `DispatchQueue.main.async` from the event tap callback
- [ ] **Verify:** the four window shortcuts work end-to-end from keyboard, no menu clicks needed. `retile` hotkey also works.

---

## Phase 15 — CGSPrivate Bridging

- [ ] Create `Headers/CGSPrivate.h` declaring only the functions listed in the spec
- [ ] Create `Headers/Jalousie-Bridging-Header.h` importing `CGSPrivate.h`
- [ ] Set the bridging header path in Build Settings
- [ ] Link `ApplicationServices.framework` and `CoreGraphics.framework` (they are usually auto-linked; verify)
- [ ] **Verify:** call `CGSMainConnectionID()` from `AppDelegate` at startup and log the result — it should be non-zero.

---

## Phase 16 — Space Query + Switch

- [ ] Create `Core/SpaceManager.swift` singleton
- [ ] Add `currentSpaceID()` using `CGSGetActiveSpace(CGSMainConnectionID())`
- [ ] Add `switchToSpace(at index: Int)` using `CGSCopySpaces` + `CGSShowSpaces`/`CGSHideSpaces`
- [ ] Validate connection and index before every CGS call
- [ ] Add temporary menu items "Switch to space 1..N"
- [ ] **Verify:** menu item switches spaces on a Mac configured with multiple spaces. Log the space list before/after.

---

## Phase 17 — Send Focused Window to Space

- [ ] Add `sendFocusedWindowToSpace(_ index: Int)` using `CGSMoveWindowsToManagedSpace`
- [ ] After the move, retile the source space; optionally follow to the destination
- [ ] **Verify:** focused window disappears from the source space and reappears on the target space. Focus behavior matches expectation.

---

## Phase 18 — Space Hotkeys

- [ ] Wire `sendToSpace(N)` and `switchToSpace(N)` in `HotkeyManager.dispatch`
- [ ] Parse the digit keys `1..9` correctly
- [ ] **Verify:** all `send-to-space-N` bindings from the default config work from the keyboard.

---

## Phase 19 — Config Hot-Reload End-to-End

- [ ] Ensure `Config.reload()` calls `HotkeyManager.shared.rebuildHotkeys()`
- [ ] Ensure changing `blacklist` in the file and reloading affects the next enumeration
- [ ] Ensure changing `windowGap` and reloading affects the next retile
- [ ] **Verify:** edit config, click "Reload config", changes take effect without a relaunch.

---

## Phase 20 — Cleanup Pass

- [ ] Remove temporary debug menu items ("List windows", per-action test items, "Switch to space N" if not needed)
- [ ] Grep for `print(` — none should remain; all logging goes through `Log`
- [ ] Grep for force unwraps `!` — each remaining one needs a comment explaining why it is safe
- [ ] Confirm every file matches the skill's naming and structure rules
- [ ] Confirm the code review checklist in `.claude/jalousie-swift-skill.md` passes

---

## Phase 21 — Release Build & Install

- [ ] `xcodebuild -scheme Jalousie -configuration Release -derivedDataPath build`
- [ ] `cp -r build/Build/Products/Release/Jalousie.app /Applications/`
- [ ] Launch from `/Applications`, re-grant Accessibility for the installed copy
- [ ] **Verify:** all v1 features work from the installed `.app` for at least 30 minutes of normal use with no crashes.

---

## v1 Feature Coverage — final smoke test

- [ ] Auto-tile on window open
- [ ] Auto-retile on window close
- [ ] Equal horizontal splits, 100% height, gap respected
- [ ] Focus left / right
- [ ] Swap left / right
- [ ] Send window to space N (1..5 by default)
- [ ] Switch to space N without moving window (if you added the bindings)
- [ ] App blacklist respected
- [ ] Menu bar icon present, dropdown functional
- [ ] Manual retile shortcut
- [ ] Config hot-reload
