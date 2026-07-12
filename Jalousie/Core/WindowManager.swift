import ApplicationServices
import AppKit
import CoreGraphics

// Private but stable Accessibility symbol used by every macOS window manager.
// Maps an AXUIElement (a window) to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

// AXObserver callback — C-callable, so it's a free function, not a method.
// The refcon carries an unowned pointer back to the WindowManager singleton
// (safe because the singleton lives for the whole app lifetime).
private let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    // Bounce onto the main queue — AX callbacks arrive on the main run loop
    // but nesting a retile inside the callback confuses AXObserver's own
    // internal state on some macOS versions.
    DispatchQueue.main.async { manager.handleAXNotification() }
}

final class WindowManager: NSObject {
    static let shared = WindowManager()
    private override init() { super.init() }

    // Set of window IDs seen on a prior enumeration. Used to keep tile order
    // stable across retiles: known windows keep their visual left-to-right
    // order (sorted by current x), brand-new windows are appended at the
    // right end regardless of where the app opened them.
    private var knownWindowIDs: Set<CGWindowID> = []

    // One AXObserver per non-blacklisted running app process. The observer is
    // used both for app-level notifications (window created) and for every
    // per-window notification attached to elements in that process.
    private var appObservers: [pid_t: AXObserver] = [:]

    // Window IDs whose destroyed/minimized/deminimized notifications have
    // already been registered on the owning app's observer.
    private var observedWindowIDs: Set<CGWindowID> = []

    // MARK: - Lifecycle

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
        nc.addObserver(self,
                       selector: #selector(handleAppActivate(_:)),
                       name: NSWorkspace.didActivateApplicationNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(handleAppUnhide(_:)),
                       name: NSWorkspace.didUnhideApplicationNotification,
                       object: nil)

        // Register AX observers for every already-running app so we catch
        // window creations that happen without a NSWorkspace launch event
        // (resident Electron apps, background helpers reopening a window, etc.).
        for app in NSWorkspace.shared.runningApplications {
            registerAppObserver(for: app)
        }
        Log.info("workspace + AX observers registered (\(appObservers.count) apps)")
    }

    // MARK: - Notification handlers

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            // Attach an AX observer immediately. The window-created callback
            // will fire once the app actually has a window — no timer needed.
            registerAppObserver(for: app)
        }
        retile()
    }

    @objc private func handleAppTerminate(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            unregisterAppObserver(pid: app.processIdentifier)
        }
        retile()
    }

    @objc private func handleSpaceChange(_ notification: Notification) {
        let settings = Config.shared.current.settings
        guard settings.autoTile, settings.tileOnSpaceSwitch else { return }
        retile()
    }

    @objc private func handleAppActivate(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        // Catches Cmd-Tab / dock-click into resident apps (WhatsApp, Slack,
        // etc.) that reveal a previously hidden window without triggering a
        // process-launch notification. The skip-if-already-tiled optimization
        // makes this cheap when nothing actually needs to move.
        retile()
    }

    @objc private func handleAppUnhide(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        retile()
    }

    // MARK: - Tiling

    func retile() {
        layout(enumerateManagedWindows())
    }

    // Apply the horizontal-split algorithm to an explicit ordered list. Swap
    // calls this directly with a mutated order to avoid re-reading AX
    // positions (which may lag the writes we just made).
    private func layout(_ windows: [ManagedWindow]) {
        let settings = Config.shared.current.settings

        // Newly-seen windows need destroy/minimize observers so we react to
        // Cmd-W / minimize without polling. Done here (not in enumerate) to
        // keep enumerate side-effect-free for callers like the debug menu.
        syncWindowObservers(for: windows)

        guard !windows.isEmpty else {
            Log.info("retile: no managed windows")
            return
        }
        if settings.ignoreSingleWindow && windows.count == 1 {
            Log.info("retile: single window ignored per config")
            return
        }
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first else {
            Log.warn("retile: no screen available")
            return
        }

        let usable = quartzUsableFrame(for: screen, primary: primary)
        let count = windows.count
        let gap = settings.windowGap
        let totalGap = gap * CGFloat(count - 1)
        let tileWidth = (usable.width - totalGap) / CGFloat(count)

        var moved = 0
        for (i, window) in windows.enumerated() {
            let x = usable.origin.x + (tileWidth + gap) * CGFloat(i)
            let targetFrame = CGRect(x: x, y: usable.origin.y,
                                     width: tileWidth, height: usable.height)
            // Skip windows already at their target frame. AX positions can
            // drift by fractional points from what we set, so we tolerate
            // a 1pt gap in either dimension.
            if framesApproximatelyEqual(window.frame, targetFrame) { continue }
            setFrame(of: window.axElement, to: targetFrame)
            moved += 1
        }
        Log.info("retile: laid out \(count) windows, moved=\(moved), gap=\(gap)")
    }

    private func framesApproximatelyEqual(_ a: CGRect, _ b: CGRect,
                                          tolerance: CGFloat = 1) -> Bool {
        abs(a.origin.x - b.origin.x) <= tolerance &&
        abs(a.origin.y - b.origin.y) <= tolerance &&
        abs(a.size.width - b.size.width) <= tolerance &&
        abs(a.size.height - b.size.height) <= tolerance
    }

    // NSScreen.visibleFrame is Cocoa (origin bottom-left of the screen),
    // AX APIs expect Quartz (origin top-left of the primary display).
    private func quartzUsableFrame(for screen: NSScreen, primary: NSScreen) -> CGRect {
        let cocoa = screen.visibleFrame
        let quartzY = primary.frame.height - cocoa.origin.y - cocoa.size.height
        return CGRect(x: cocoa.origin.x, y: quartzY,
                      width: cocoa.size.width, height: cocoa.size.height)
    }

    // Position + size in a single synchronous block — no NSAnimationContext,
    // no CATransaction, no delays. Snap-instant window moves per the spec.
    private func setFrame(of element: AXUIElement, to frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            Log.warn("setFrame: could not build AX values")
            return
        }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    // MARK: - Focus

    func focusLeft() { shiftFocus(by: -1) }
    func focusRight() { shiftFocus(by: +1) }

    private func shiftFocus(by delta: Int) {
        let windows = enumerateManagedWindows()
        guard !windows.isEmpty else { return }
        guard let currentIndex = focusedWindowIndex(in: windows) else {
            Log.info("focus: no focused managed window")
            return
        }
        let target = currentIndex + delta
        // Clamp at edges — a no-op at the boundary rather than a wrap-around
        // matches how yabai/Rectangle behave and avoids surprise jumps.
        guard target >= 0, target < windows.count, target != currentIndex else { return }
        raiseFocus(to: windows[target])
    }

    private func focusedWindowIndex(in windows: [ManagedWindow]) -> Int? {
        // Try system-wide focused window first. When the menu extra swallows
        // focus (clicking a debug menu item), system-wide can return nothing —
        // fall back to NSWorkspace's frontmost app and query its focused
        // window directly, which stays valid across the menu interaction.
        let sysID = systemWideFocusedWindowID()
        if let id = sysID, let idx = windows.firstIndex(where: { $0.windowID == id }) {
            return idx
        }
        let frontID = frontmostAppFocusedWindowID()
        if let id = frontID, let idx = windows.firstIndex(where: { $0.windowID == id }) {
            return idx
        }
        return nil
    }

    private func systemWideFocusedWindowID() -> CGWindowID? {
        let systemElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let cf = value,
              CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(cf as! AXUIElement, &id) == .success, id != 0 else {
            return nil
        }
        return id
    }

    private func frontmostAppFocusedWindowID() -> CGWindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let cf = value,
              CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(cf as! AXUIElement, &id) == .success, id != 0 else {
            return nil
        }
        return id
    }

    // MARK: - Swap

    func swapLeft() { performSwap(delta: -1) }
    func swapRight() { performSwap(delta: +1) }

    private func performSwap(delta: Int) {
        var windows = enumerateManagedWindows()
        guard !windows.isEmpty else { return }
        guard let currentIndex = focusedWindowIndex(in: windows) else {
            Log.info("swap: no focused managed window")
            return
        }
        let target = currentIndex + delta
        guard target >= 0, target < windows.count, target != currentIndex else { return }

        // Swap in-memory order, then lay out from that order. Reading back AX
        // positions after a setFrame can lag inside a single runloop tick, so
        // we deliberately drive layout from the mutated list rather than
        // calling retile() which re-enumerates.
        let moved = windows[currentIndex]
        windows.swapAt(currentIndex, target)
        layout(windows)
        // Keep focus on the window the user moved.
        raiseFocus(to: moved)
    }

    // MARK: - Focus (helpers)

    private func raiseFocus(to window: ManagedWindow) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window.axElement, &pid) == .success else { return }

        // NSRunningApplication.activate is a cooperative API on macOS 14+ —
        // when the previous frontmost app (notably Xcode) refuses to yield,
        // it returns false and the target never becomes frontmost. Try it
        // first because it's the "polite" path; fall back to the AX
        // frontmost attribute, which honors our Accessibility permission and
        // bypasses cooperative activation.
        var activated = false
        if let app = NSRunningApplication(processIdentifier: pid) {
            activated = app.activate(options: [.activateIgnoringOtherApps])
        }
        if !activated {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetAttributeValue(appElement,
                                         kAXFrontmostAttribute as CFString,
                                         kCFBooleanTrue)
        }
        // Bring the specific window to the top within the app and mark it main.
        AXUIElementSetAttributeValue(window.axElement,
                                     kAXMainAttribute as CFString,
                                     kCFBooleanTrue)
        AXUIElementPerformAction(window.axElement, kAXRaiseAction as CFString)
    }

    // MARK: - Enumeration

    func enumerateManagedWindows() -> [ManagedWindow] {
        let raw = collectRawManagedWindows()

        // Known windows: keep their visual order (sorted by current x). This
        // lets the user drag a window between tiles and have subsequent
        // retiles honor the new position.
        let known = raw.filter { knownWindowIDs.contains($0.windowID) }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }

        let brandNew = raw.filter { !knownWindowIDs.contains($0.windowID) }

        let ordered: [ManagedWindow]
        if known.isEmpty {
            // Fresh set (e.g. first enumeration, or a space switch left the
            // cache empty relative to the new space). Sort by current x so
            // the existing visual layout is preserved instead of being
            // shuffled into whatever PID order the enumeration returned.
            ordered = brandNew.sorted { $0.frame.origin.x < $1.frame.origin.x }
        } else {
            // Some tiles carry over. Preserve their order and append any new
            // window at the right end, per spec — a freshly-spawned window
            // should not displace known tiles.
            ordered = known + brandNew
        }

        var withIndex = ordered
        for i in withIndex.indices { withIndex[i].orderIndex = i }

        // Cache the union of what we just saw. Closed windows drop off
        // automatically; windows from other spaces stay cached so returning
        // to that space preserves the same-space order across visits.
        knownWindowIDs.formUnion(withIndex.map { $0.windowID })
        return withIndex
    }

    private func collectRawManagedWindows() -> [ManagedWindow] {
        let onScreenPIDs = collectOnScreenPIDs()
        let blacklist = Set(Config.shared.current.blacklist)
        var results: [ManagedWindow] = []

        for pid in onScreenPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  !blacklist.contains(bundleID) else { continue }

            let appElement = AXUIElementCreateApplication(pid)
            guard let axWindows: [AXUIElement] = copyAttribute(appElement, kAXWindowsAttribute) else { continue }

            let appName = app.localizedName ?? bundleID
            for window in axWindows {
                guard let managed = makeManagedWindow(from: window,
                                                      appName: appName,
                                                      bundleID: bundleID) else { continue }
                results.append(managed)
            }
        }
        return results
    }

    // MARK: - AX Observers

    private func registerAppObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0,
              let bundleID = app.bundleIdentifier,
              !Config.shared.current.blacklist.contains(bundleID),
              appObservers[pid] == nil else { return }

        var observer: AXObserver?
        let created = AXObserverCreate(pid, axObserverCallback, &observer)
        guard created == .success, let obs = observer else {
            Log.warn("AXObserverCreate failed for pid \(pid): \(created.rawValue)")
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        // App-level: fire whenever the app makes a new window (Cmd-N,
        // dialog panel, resident app re-opening after Cmd-W, etc.).
        AXObserverAddNotification(obs, appElement,
                                  kAXWindowCreatedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(obs),
                           .commonModes)
        appObservers[pid] = obs
    }

    private func unregisterAppObserver(pid: pid_t) {
        guard let obs = appObservers[pid] else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              AXObserverGetRunLoopSource(obs),
                              .commonModes)
        appObservers.removeValue(forKey: pid)
        // Drop stale window IDs so they get re-registered if their IDs
        // happen to be reused by a future app.
        observedWindowIDs = observedWindowIDs.filter { _ in true } // no-op; IDs prune naturally when windows disappear
    }

    // Attach destroyed/minimized/deminimized notifications to each managed
    // window, using the AXObserver already registered for the owning app.
    private func syncWindowObservers(for windows: [ManagedWindow]) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for window in windows where !observedWindowIDs.contains(window.windowID) {
            var pid: pid_t = 0
            guard AXUIElementGetPid(window.axElement, &pid) == .success,
                  let observer = appObservers[pid] else { continue }
            AXObserverAddNotification(observer, window.axElement,
                                      kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(observer, window.axElement,
                                      kAXWindowMiniaturizedNotification as CFString, refcon)
            AXObserverAddNotification(observer, window.axElement,
                                      kAXWindowDeminiaturizedNotification as CFString, refcon)
            observedWindowIDs.insert(window.windowID)
        }
    }

    // Called from the C callback below. Marked internal so the free
    // function can see it.
    fileprivate func handleAXNotification() {
        guard Config.shared.current.settings.autoTile else { return }
        retile()
    }

    // MARK: - Private

    private func collectOnScreenPIDs() -> Set<pid_t> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        var pids: Set<pid_t> = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID] as? pid_t else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private func makeManagedWindow(from element: AXUIElement,
                                   appName: String,
                                   bundleID: String) -> ManagedWindow? {
        guard let role: String = copyAttribute(element, kAXRoleAttribute), role == kAXWindowRole else {
            return nil
        }
        let isMinimized: Bool = copyAttribute(element, kAXMinimizedAttribute) ?? false
        if isMinimized { return nil }
        // "AXFullScreen" is not exposed as a Swift constant. Absent attribute → treat as false.
        let isFullscreen: Bool = copyAttribute(element, "AXFullScreen") ?? false
        if isFullscreen { return nil }

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else {
            return nil
        }

        let origin = copyAXPoint(element, kAXPositionAttribute) ?? .zero
        let size = copyAXSize(element, kAXSizeAttribute) ?? .zero

        return ManagedWindow(
            windowID: windowID,
            appName: appName,
            bundleID: bundleID,
            axElement: element,
            frame: CGRect(origin: origin, size: size),
            orderIndex: 0
        )
    }

    // MARK: - AX attribute helpers

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    private func copyAXPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let cf = value, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(cf as! AXValue, .cgPoint, &point)
        return point
    }

    private func copyAXSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let cf = value, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        AXValueGetValue(cf as! AXValue, .cgSize, &size)
        return size
    }
}
