# Jalousie — Development Checklist

Step-by-step build plan. Each phase produces something you can run and verify before moving on. Do not skip verification steps — the whole point is catching errors at the boundary they were introduced.

**Performance is a hard requirement across every phase.** Every visible action must feel instant — no animations, no transitions, no smoothing delays. If a window ever appears to slide, fade, or lag during any verify step, treat it as a failing test and fix it before moving on. **No timers, no polling, no `asyncAfter` scheduling anywhere in the app.** Window-lifecycle changes are detected via AXObservers (event-driven); the only reason to reach for a delay would be to smooth visuals, which is banned.

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
- [ ] Add `setFrame(of:to:)` helper using `AXValueCreate` for position and size — position then size in a single synchronous block, no run-loop yield between them
- [ ] Do **not** wrap any AX call in `NSAnimationContext`, `animate(withDuration:)`, `CATransaction`, or any animation API
- [ ] Wire the "Retile current space" menu item to `WindowManager.shared.retile()`
- [ ] Respect `windowGap` from config
- [ ] **Verify:**
  - Two windows → each takes half the visible frame
  - Three windows → each takes a third
  - Zero/one window → no crash, no change (or single window full screen depending on `ignoreSingleWindow`)
  - Retiling twice in a row is idempotent
  - **Snap check:** windows jump to their new positions instantly — no slide, no fade, no perceivable delay. Record a screen capture at 60fps if unsure; there should be no in-between frames.

---

## Phase 8 — Window Order Stability

- [ ] Sort enumerated windows by current `x` origin before tiling
- [ ] Cache the current tiled order between retiles so a new window appends to the right end
- [ ] **Verify:** repeatedly retile after moving one window by hand — the order should track visual left-to-right position, and a newly opened window should slot in at the rightmost tile.

---

## Phase 9 — Auto-Retile on Workspace Events

- [ ] In `WindowManager.start()` register for `didLaunchApplicationNotification`, `didTerminateApplicationNotification`, `activeSpaceDidChangeNotification`
- [ ] Also register `didActivateApplicationNotification` and `didUnhideApplicationNotification` — resident apps (WhatsApp, Slack, VS Code) reveal windows on Cmd-Tab / dock click without firing a process-launch event
- [ ] Terminate handler retiles immediately
- [ ] Launch handler retiles immediately too — the AXObserver added in Phase 10 catches the actual window-created event, so no `asyncAfter` delay is needed
- [ ] Space change handler retiles only if `settings.tileOnSpaceSwitch` is true
- [ ] Gate all of it on `settings.autoTile`
- [ ] Before calling `setFrame`, skip windows already at their target frame (small tolerance) so repeat retiles and space switches to already-tiled spaces are essentially free
- [ ] **Verify:**
  - Opening a new app auto-tiles all windows
  - Closing an app auto-tiles the remainder
  - Cmd-Tab or dock-click to a resident app (WhatsApp) auto-tiles
  - Setting `autoTile = false` in config and reloading disables the behavior
  - Second retile with unchanged layout logs `moved=0`

---

## Phase 10 — Mid-session Window Add/Remove Detection (event-driven)

The spec's original polling-timer approach was replaced with event-driven `AXObserver` notifications. No timers, no polling.

- [ ] Add `appObservers: [pid_t: AXObserver]` and `observedWindowIDs: Set<CGWindowID>` state to `WindowManager`
- [ ] Free-standing C-callable `axObserverCallback` that bounces onto the main queue and calls `WindowManager.shared.retile()`
- [ ] `registerAppObserver(for:)`: create one AXObserver per non-blacklisted running app, subscribe to `kAXWindowCreatedNotification` on the app element, add source to the main run loop
- [ ] `unregisterAppObserver(pid:)`: remove run-loop source and drop from the map on app termination
- [ ] `syncWindowObservers(for:)` called from `retile()`: for each managed window not yet observed, add `kAXUIElementDestroyedNotification`, `kAXWindowMiniaturizedNotification`, `kAXWindowDeminiaturizedNotification` on the owning app's observer
- [ ] In `WindowManager.start()`, register app observers for every currently-running app so we cover the boot-time set, not just apps that launch after Jalousie starts
- [ ] Wire `didLaunchApplicationNotification` to `registerAppObserver(for:)` and `didTerminateApplicationNotification` to `unregisterAppObserver(pid:)`
- [ ] **Verify:**
  - `Cmd-N` in an already-running app (Firefox, Xcode) triggers a retile immediately
  - `Cmd-W` closing just a window while the app stays alive triggers a retile
  - Yellow-button minimize drops the window out of the layout; deminimize brings it back
  - No `Timer`, `scheduledTimer`, `DispatchSourceTimer`, or `asyncAfter` calls anywhere in the app

---

## Phase 11 — Focus Left/Right

- [ ] Add `focusLeft()` and `focusRight()` to `WindowManager`
- [ ] Find focused window via `AXUIElementCopyAttributeValue(system, kAXFocusedWindowAttribute)`
- [ ] Clamp at edges
- [ ] Add temporary menu items to trigger both
- [ ] **Verify:** with three windows tiled, clicking the menu items moves focus left/right visibly, with no perceivable delay.

---

## Phase 12 — Swap Left/Right

- [ ] Add `swapLeft()` and `swapRight()` that swap the focused window with its neighbor in the ordered list, then retile
- [ ] Clamp at edges
- [ ] Add temporary menu items
- [ ] **Verify:** swap moves the focused window to the neighbor's slot and vice versa; focus stays on the moved window; both windows snap instantly with no slide animation.

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
- [ ] Grep for `NSAnimationContext`, `animate(withDuration`, `CATransaction`, `.animator(` — **zero hits allowed**
- [ ] Grep for `Timer`, `scheduledTimer`, `DispatchSourceTimer`, `asyncAfter` — **zero hits allowed** (window-lifecycle detection is fully event-driven via AXObservers)
- [ ] Confirm every file matches the skill's naming and structure rules
- [ ] Confirm the code review checklist in `.claude/jalousie-swift-skill.md` passes

---

## Phase 21 — Release Build & Install

- [ ] `xcodebuild -scheme Jalousie -configuration Release -derivedDataPath build`
- [ ] `cp -r build/Build/Products/Release/Jalousie.app /Applications/`
- [ ] Launch from `/Applications`, re-grant Accessibility for the installed copy
- [ ] **Verify:** all v1 features work from the installed `.app` for at least 30 minutes of normal use with no crashes.

---

## Performance smoke test

- [ ] Retile 4 windows repeatedly for 30 s — no lag, no dropped frames, no visible animation on any window
- [ ] Hold down `focus-right` (key repeat) — focus jumps through windows as fast as macOS repeats keys, no queuing lag
- [ ] Hold down `swap-right` — window keeps snapping to the next slot every keydown with no in-between animation frames
- [ ] `send-to-space-N` happens in one snap — the window vanishes from the source without a slide

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
