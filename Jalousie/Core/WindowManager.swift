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
private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Bounce onto the main queue — AX callbacks arrive on the main run loop
    // but nesting a retile inside the callback confuses AXObserver's own
    // internal state on some macOS versions.
    DispatchQueue.main.async { manager.handleAXNotification(named: name) }
}

final class WindowManager: NSObject {
    static let shared = WindowManager()
    private override init() { super.init() }

    // Ordered list of window IDs seen on prior enumerations. Once a window
    // is assigned a slot, it keeps that slot until closed — dragging does
    // not reorder tiles, it just snaps the window back on the next retile.
    // Brand-new windows are appended to the right end.
    private var orderedKnownWindowIDs: [CGWindowID] = []

    // One AXObserver per non-blacklisted running app process. The observer is
    // used both for app-level notifications (window created) and for every
    // per-window notification attached to elements in that process.
    private var appObservers: [pid_t: AXObserver] = [:]

    // Window IDs whose destroyed/minimized/deminimized notifications have
    // already been registered on the owning app's observer.
    private var observedWindowIDs: Set<CGWindowID> = []

    // Set by kAXWindowMovedNotification, cleared once we retile on the
    // following leftMouseUp. Lets us react to the end of a manual drag
    // without retiling on every mouse-move during it, and without polling.
    private var pendingRetileAfterDrag = false
    private var mouseUpMonitor: Any?

    // Undocumented AX attribute set on app elements (`true` for Firefox,
    // Discord, Slack, VoiceOver, Zoom, etc.). When enabled, macOS animates
    // every AXPosition/AXSize write and silently drops writes that arrive
    // during an in-flight animation — that's the "Firefox rejects position"
    // bug. yabai temporarily flips it off around every set-frame call and
    // restores it after.
    private static let kAXEnhancedUserInterface = "AXEnhancedUserInterface" as CFString

    // Some apps (Xcode, Discord, Slack) refuse to resize below a per-app
    // minimum. Once we observe a window ignoring our target width, we
    // remember its floor and route allocation around it — otherwise
    // subsequent retiles loop trying to shrink it and neighbors overlap.
    private var minObservedWidths: [CGWindowID: CGFloat] = [:]

    // Windows currently in fullscreen-zoom mode. Any number can be zoomed
    // simultaneously — each is independently toggled. Zoomed windows
    // occupy the full usable frame of their screen; their tile position
    // is still remembered so un-zooming instantly reveals correct
    // neighbors, and non-zoomed windows keep their normal tile layout
    // (they end up behind whichever zoomed window is currently raised).
    private var zoomedWindowIDs: Set<CGWindowID> = []

    // Collapses bursts of AX / workspace notifications into a single retile
    // on the next runloop tick. Direct callers (menu bar "Retile" click,
    // hotkey, swap) still call retile() synchronously — coalescing only
    // applies to system-driven event storms.
    private lazy var coalescer = RetileCoalescer(
        schedule: { DispatchQueue.main.async(execute: $0) },
        execute: { [weak self] in self?.retile() }
    )

    // PIDs we've observed producing at least one managed window this
    // process lifetime. Combined with CGWindowList's on-screen owner PIDs,
    // this lets enumerate skip the ~30-40 running apps that never had a
    // window and stop asking each one for kAXWindowsAttribute every retile.
    private var appsWithWindows: Set<pid_t> = []

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

        // Global left-mouse-up monitor — the only trigger we get for the end
        // of a manual window drag. addGlobalMonitor is event-driven (no
        // polling); it doesn't fire on clicks inside Jalousie itself, which
        // is fine — we have no clickable UI besides the menu bar item.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.handleMouseUp()
        }
        Log.info("workspace + AX observers registered (\(appObservers.count) apps)")
    }

    private func handleMouseUp() {
        guard pendingRetileAfterDrag else { return }
        pendingRetileAfterDrag = false
        guard Config.shared.current.settings.autoTile else { return }
        // Yield to the next runloop tick so any trailing kAXWindowMoved
        // notifications with the drag's final frame land before we sample
        // AX positions. Without this we occasionally read stale frames and
        // regroup the dragged window on its old screen.
        DispatchQueue.main.async { [weak self] in
            self?.retile()
        }
    }

    // MARK: - Notification handlers

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            // Attach an AX observer immediately. The window-created callback
            // will fire once the app actually has a window — no timer needed.
            registerAppObserver(for: app)
        }
        requestRetile()
    }

    @objc private func handleAppTerminate(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            unregisterAppObserver(pid: app.processIdentifier)
        }
        requestRetile()
    }

    @objc private func handleSpaceChange(_ notification: Notification) {
        let settings = Config.shared.current.settings
        guard settings.autoTile, settings.tileOnSpaceSwitch else { return }
        requestRetile()
    }

    @objc private func handleAppActivate(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        requestRetile()
    }

    @objc private func handleAppUnhide(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        requestRetile()
    }

    // MARK: - Tiling

    // Coalesced retile — the entry point every AX / workspace notification
    // should use. Bursts of N requests in one runloop tick fan into a single
    // retile() call, cutting redundant work on Cmd-Tab and window-creation
    // storms. Direct callers (menu bar, hotkey) should still call retile().
    func requestRetile() {
        PerfCounters.retileRequested += 1
        coalescer.request()
    }

    func retile() {
        let start = DispatchTime.now().uptimeNanoseconds
        PerfCounters.retileExecuted += 1
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            PerfCounters.retileTotalNanos &+= elapsed
            if elapsed > PerfCounters.retileMaxNanos {
                PerfCounters.retileMaxNanos = elapsed
            }
        }
        layoutSuspendingEnhancedUI(enumerateManagedWindows())
    }

    // Wraps a layout call with the AXEnhancedUserInterface disable/restore
    // dance so AX writes to apps like Firefox/Discord aren't dropped or
    // animated. Both retile() and performSwap() route through this — swap
    // used to call layout() directly, which is why Firefox visibly animated
    // on Option+Shift+J/L.
    private func layoutSuspendingEnhancedUI(_ windows: [ManagedWindow]) {
        var pids = Set<pid_t>()
        for w in windows {
            var pid: pid_t = 0
            if AXUIElementGetPid(w.axElement, &pid) == .success { pids.insert(pid) }
        }
        let restore = suspendEnhancedUserInterface(for: pids)
        defer { restore() }
        layout(windows)
    }

    // Turn AXEnhancedUserInterface off on every app that has it on right
    // now, remembering which apps we touched. The returned closure restores
    // the attribute on exactly those apps — apps that already had it off
    // are left untouched. This is the cornerstone yabai trick that makes
    // AXPosition writes stick on Firefox/Discord/Slack.
    private func suspendEnhancedUserInterface(for pids: Set<pid_t>) -> () -> Void {
        var toRestore: [pid_t] = []
        for pid in pids {
            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            PerfCounters.axReads += 1
            let err = AXUIElementCopyAttributeValue(appElement,
                                                   Self.kAXEnhancedUserInterface,
                                                   &value)
            guard err == .success, let cf = value,
                  CFGetTypeID(cf) == CFBooleanGetTypeID(),
                  // Safe: guarded by CFGetTypeID(cf) == CFBooleanGetTypeID() above.
                  CFBooleanGetValue((cf as! CFBoolean)) else { continue }
            PerfCounters.axWrites += 1
            AXUIElementSetAttributeValue(appElement,
                                         Self.kAXEnhancedUserInterface,
                                         kCFBooleanFalse)
            toRestore.append(pid)
        }
        return {
            for pid in toRestore {
                let appElement = AXUIElementCreateApplication(pid)
                PerfCounters.axWrites += 1
                AXUIElementSetAttributeValue(appElement,
                                             Self.kAXEnhancedUserInterface,
                                             kCFBooleanTrue)
            }
        }
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
        // The Quartz-Y flip needs the screen at Cocoa origin (0,0) — that's
        // the coordinate-origin screen (the one with the menu bar), and it
        // isn't necessarily NSScreen.screens.first when the user has
        // reassigned displays.
        guard let primary = primaryScreen() else {
            Log.warn("retile: no primary screen available")
            return
        }

        // Group windows by the screen their frame currently overlaps most.
        // Dragging a window to another monitor moves it into that screen's
        // group on the next retile — we do not force it back to a "main"
        // display like the single-screen version did.
        var groups: [ObjectIdentifier: (screen: NSScreen, windows: [ManagedWindow])] = [:]
        for window in windows {
            guard let screen = screen(for: window, in: NSScreen.screens, primary: primary) else { continue }
            let key = ObjectIdentifier(screen)
            groups[key, default: (screen, [])].windows.append(window)
        }

        var totalMoved = 0
        var totalLaid = 0
        for (_, group) in groups {
            let (laid, moved) = layoutOnScreen(group.windows,
                                               screen: group.screen,
                                               primary: primary,
                                               settings: settings)
            totalLaid += laid
            totalMoved += moved
        }
        Log.info("retile: laid out \(totalLaid) windows across \(groups.count) screen(s), moved=\(totalMoved), gap=\(settings.windowGap)")
    }

    private func layoutOnScreen(_ windows: [ManagedWindow],
                                screen: NSScreen,
                                primary: NSScreen,
                                settings: JalousieConfig.Settings) -> (laid: Int, moved: Int) {
        if settings.ignoreSingleWindow && windows.count == 1 { return (0, 0) }
        let usable = quartzUsableFrame(for: screen, primary: primary)
        let count = windows.count
        let gap = settings.windowGap
        var widths = allocateWidths(count: count, usable: usable.width,
                                    gap: gap, windows: windows)

        var moved = applyRow(windows: windows, widths: widths,
                             origin: usable.origin, height: usable.height,
                             gap: gap, zoomedIDs: zoomedWindowIDs, zoomFrame: usable)
        if learnStubbornWidths(windows: windows, widths: widths, skip: zoomedWindowIDs) {
            widths = allocateWidths(count: count, usable: usable.width,
                                    gap: gap, windows: windows)
            moved += applyRow(windows: windows, widths: widths,
                              origin: usable.origin, height: usable.height,
                              gap: gap, zoomedIDs: zoomedWindowIDs, zoomFrame: usable)
        }
        return (count, moved)
    }

    // Divide usable width across windows. Windows we've observed to have a
    // floor (Xcode, Discord, …) get their floor; the rest share the leftover
    // equally. Iterates because fixing one window may leave a share smaller
    // than another window's known floor.
    private func allocateWidths(count: Int, usable: CGFloat, gap: CGFloat,
                                windows: [ManagedWindow]) -> [CGFloat] {
        let totalGap = gap * CGFloat(max(count - 1, 0))
        var fixed = Array(repeating: false, count: count)
        var widths = Array(repeating: CGFloat(0), count: count)

        while true {
            let fixedSum = zip(widths, fixed).reduce(CGFloat(0)) { acc, pair in
                acc + (pair.1 ? pair.0 : 0)
            }
            let flexibleIndexes = (0..<count).filter { !fixed[$0] }
            if flexibleIndexes.isEmpty { break }
            let share = max(0, (usable - totalGap - fixedSum) / CGFloat(flexibleIndexes.count))

            var promoted = false
            for i in flexibleIndexes {
                let floor = minObservedWidths[windows[i].windowID] ?? 0
                if floor > share + 1 {
                    widths[i] = floor
                    fixed[i] = true
                    promoted = true
                } else {
                    widths[i] = share
                }
            }
            if !promoted { break }
        }
        return widths
    }

    private func applyRow(windows: [ManagedWindow], widths: [CGFloat],
                          origin: CGPoint, height: CGFloat, gap: CGFloat,
                          zoomedIDs: Set<CGWindowID>, zoomFrame: CGRect) -> Int {
        var moved = 0
        var x = origin.x
        for (i, window) in windows.enumerated() {
            // Zoomed windows take the full zoomFrame instead of their tile.
            // Their tile position (x cursor) still advances so unzoom is a
            // no-op re-layout without needing to recompute.
            let targetFrame: CGRect
            if zoomedIDs.contains(window.windowID) {
                targetFrame = zoomFrame
            } else {
                targetFrame = CGRect(x: x, y: origin.y,
                                     width: widths[i], height: height)
            }
            x += widths[i] + gap
            if framesApproximatelyEqual(window.frame, targetFrame) { continue }
            setFrame(of: window.axElement, to: targetFrame)
            moved += 1
        }
        return moved
    }

    // Returns true if we discovered new floor information (i.e. any window
    // stayed wider than what we asked for). Caller uses that as the signal
    // to re-allocate and re-apply.
    private func learnStubbornWidths(windows: [ManagedWindow],
                                     widths: [CGFloat],
                                     skip: Set<CGWindowID>) -> Bool {
        var learned = false
        for (i, window) in windows.enumerated() {
            // Zoomed windows were intentionally set to full-usable width;
            // reading them back would falsely record that as their minimum,
            // then allocateWidths would forever give them the whole screen.
            if skip.contains(window.windowID) { continue }
            guard let actual = readSize(window.axElement) else { continue }
            if actual.width > widths[i] + 1 {
                let known = minObservedWidths[window.windowID] ?? 0
                if actual.width > known {
                    minObservedWidths[window.windowID] = actual.width
                    learned = true
                }
            }
        }
        return learned
    }

    private func readSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        PerfCounters.axReads += 1
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let cf = value, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Safe: guarded by CFGetTypeID(cf) == AXValueGetTypeID() above.
        AXValueGetValue(cf as! AXValue, .cgSize, &size)
        return size
    }

    // The primary display in Cocoa terms is the one whose frame.origin is
    // (0, 0) — that's the coordinate origin used for Quartz-Y conversion.
    // NSScreen.main tracks the active screen, NSScreen.screens.first isn't
    // guaranteed to be the origin display, so search explicitly.
    private func primaryScreen() -> NSScreen? {
        for screen in NSScreen.screens where screen.frame.origin == .zero {
            return screen
        }
        return NSScreen.screens.first
    }

    // Pick the screen a window "belongs to" by choosing the one its frame
    // overlaps most. Window frames are in Quartz coords (y grows down from
    // the primary display's top-left); NSScreen.frame is Cocoa (y grows up
    // from the primary display's bottom-left), so convert first.
    private func screen(for window: ManagedWindow,
                        in screens: [NSScreen],
                        primary: NSScreen) -> NSScreen? {
        let cocoaY = primary.frame.height - window.frame.origin.y - window.frame.size.height
        let cocoaFrame = CGRect(x: window.frame.origin.x, y: cocoaY,
                                width: window.frame.size.width, height: window.frame.size.height)
        var best: (NSScreen, CGFloat)?
        for screen in screens {
            let intersection = screen.frame.intersection(cocoaFrame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > (best?.1 ?? 0) { best = (screen, area) }
        }
        // Fall back to the screen the center point sits on — covers the
        // pathological case where a window's frame is fully offscreen
        // (e.g. mid-drag) so no intersection is positive.
        if best == nil {
            let center = CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)
            for screen in screens where screen.frame.contains(center) {
                return screen
            }
        }
        return best?.0
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

    // Position + size in a single synchronous block — no animations, no
    // delays. yabai's size-position-size sandwich: an intervening AXPosition
    // write can otherwise clamp size to the target app's visible-area
    // constraint, so we set size, then position, then size again.
    private func setFrame(of element: AXUIElement, to frame: CGRect) {
        var origin = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            Log.warn("setFrame: could not build AX values")
            return
        }
        PerfCounters.setFrameCalls += 1
        PerfCounters.axWrites &+= 3
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }

    // MARK: - Focus

    func focusLeft() { shiftFocus(by: -1) }
    func focusRight() { shiftFocus(by: +1) }

    // Exposed so SpaceManager can move the focused window without
    // duplicating the system-wide / frontmost-app focus resolution.
    func focusedManagedWindow() -> ManagedWindow? {
        let windows = enumerateManagedWindows()
        guard let idx = focusedWindowIndex(in: windows) else { return nil }
        return windows[idx]
    }

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
        PerfCounters.axReads += 1
        guard AXUIElementCopyAttributeValue(systemElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let cf = value,
              CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        // Safe: guarded by CFGetTypeID(cf) == AXUIElementGetTypeID() above.
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
        PerfCounters.axReads += 1
        guard AXUIElementCopyAttributeValue(appElement,
                                            kAXFocusedWindowAttribute as CFString,
                                            &value) == .success,
              let cf = value,
              CFGetTypeID(cf) == AXUIElementGetTypeID() else { return nil }
        var id: CGWindowID = 0
        // Safe: guarded by CFGetTypeID(cf) == AXUIElementGetTypeID() above.
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
        // Persist the new order so the next retile keeps it. Enumeration now
        // reads strictly from the cached order, so without this the swap
        // would be undone as soon as any other event fires a retile.
        orderedKnownWindowIDs = windows.map { $0.windowID }
        layoutSuspendingEnhancedUI(windows)
        // Keep focus on the window the user moved.
        raiseFocus(to: moved)
    }

    // MARK: - Zoom

    // Toggle the focused window's fullscreen-zoom on its own display.
    // Matches yabai's `--toggle zoom-fullscreen`: layout order is preserved,
    // only one window per display can be zoomed at a time, and focus-left/
    // right still traverses the ordered list so opt+L from a zoomed window
    // reveals the neighbor behind it.
    func toggleZoomFullscreen() {
        let windows = enumerateManagedWindows()
        guard let index = focusedWindowIndex(in: windows) else {
            Log.info("zoom: no focused managed window")
            return
        }
        let window = windows[index]
        if zoomedWindowIDs.contains(window.windowID) {
            zoomedWindowIDs.remove(window.windowID)
            Log.info("zoom: off \(window.appName)#\(window.windowID)")
        } else {
            zoomedWindowIDs.insert(window.windowID)
            Log.info("zoom: on \(window.appName)#\(window.windowID)")
        }
        retile()
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
        PerfCounters.enumerateCalls += 1
        let raw = collectRawManagedWindows()
        let rawByID = Dictionary(uniqueKeysWithValues: raw.map { ($0.windowID, $0) })

        // Preserve the cached slot order for every window still present.
        // A dragged window keeps its slot; only newly-created windows shift
        // the layout, and they land at the right end.
        var ordered = orderedKnownWindowIDs.compactMap { rawByID[$0] }
        let knownIDs = Set(ordered.map { $0.windowID })
        let brandNew = raw.filter { !knownIDs.contains($0.windowID) }
        // Sort new windows by x so their initial layout mirrors whatever
        // order their apps opened them in.
        ordered += brandNew.sorted { $0.frame.origin.x < $1.frame.origin.x }

        for i in ordered.indices { ordered[i].orderIndex = i }
        orderedKnownWindowIDs = ordered.map { $0.windowID }
        // Drop zoom entries for windows that no longer exist so the set
        // doesn't grow unbounded across the process lifetime.
        let alive = Set(orderedKnownWindowIDs)
        zoomedWindowIDs.formIntersection(alive)
        return ordered
    }

    private func collectRawManagedWindows() -> [ManagedWindow] {
        // Iterate regular running apps and use CGWindowList only as a
        // per-window on-screen filter (Electron apps report their windows
        // under helper-renderer PIDs that don't resolve to a regular
        // NSRunningApplication, so a PID-first enumeration would drop them).
        let onScreenIDs = collectOnScreenWindowIDs()
        let onScreenPIDs = collectOnScreenPIDs()
        let blacklist = Set(Config.shared.current.blacklist)
        var results: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  !blacklist.contains(bundleID) else { continue }
            let pid = app.processIdentifier
            // Fast-path skip: don't pay for kAXWindowsAttribute on apps
            // that have neither a currently on-screen window nor any
            // history of producing a managed window this session. Cuts
            // ~30-40 AX round-trips per retile in a typical workstation
            // where you have Xcode + a browser + Slack + Terminal open
            // among 70 running apps.
            if !onScreenPIDs.contains(pid) && !appsWithWindows.contains(pid) {
                continue
            }
            let appElement = AXUIElementCreateApplication(pid)
            guard let axWindows: [AXUIElement] = copyAttribute(appElement, kAXWindowsAttribute) else { continue }

            let appName = app.localizedName ?? bundleID
            var foundOne = false
            for window in axWindows {
                guard let managed = makeManagedWindow(from: window,
                                                      appName: appName,
                                                      bundleID: bundleID),
                      onScreenIDs.contains(managed.windowID) else { continue }
                results.append(managed)
                foundOne = true
            }
            // Cache the pid so we keep querying it on subsequent retiles
            // even if all its windows go off-screen briefly.
            if foundOne { appsWithWindows.insert(pid) }
        }
        return results
    }

    // Owner PIDs of every layer-0 on-screen window. Used as the primary
    // signal for "which apps should we ask for windows?" before falling
    // back to appsWithWindows.
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
        // App-level notifications. kAXWindowCreatedNotification handles the
        // normal case (Cmd-N, dialog panel, resident app re-opening after
        // Cmd-W). Chromium-based apps (VS Code, Slack, Discord) sometimes
        // skip that event when a new window arrives via IPC — subscribing to
        // focused/main window changes catches those, and to shown/hidden
        // covers the window revealing without activating the app.
        for name in [
            kAXWindowCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationShownNotification,
            kAXApplicationHiddenNotification,
        ] {
            AXObserverAddNotification(obs, appElement, name as CFString, refcon)
        }

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
        appsWithWindows.remove(pid)
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
            // Manual drags fire this continuously; we defer the retile to
            // the following leftMouseUp so we don't tile mid-drag.
            AXObserverAddNotification(observer, window.axElement,
                                      kAXWindowMovedNotification as CFString, refcon)
            observedWindowIDs.insert(window.windowID)
        }
    }

    // Called from the C callback below. Marked internal so the free
    // function can see it.
    fileprivate func handleAXNotification(named name: String) {
        if name == (kAXWindowMovedNotification as String) {
            pendingRetileAfterDrag = true
            return
        }
        guard Config.shared.current.settings.autoTile else { return }
        requestRetile()
    }

    // MARK: - Private

    // The set of CGWindowIDs currently visible on any display in this space,
    // restricted to layer 0 (normal app windows). Used as a per-window filter
    // rather than a per-PID one so Electron helper-owned windows still pass.
    private func collectOnScreenWindowIDs() -> Set<CGWindowID> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return []
        }
        var ids: Set<CGWindowID> = []
        for entry in list {
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0,
                  let id = entry[kCGWindowNumber] as? CGWindowID else { continue }
            ids.insert(id)
        }
        return ids
    }

    // The 6 window attributes we read on every enumerate. Kept in this
    // exact order because indexes below assume it.
    private static let windowAttributeNames: [String] = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXMinimizedAttribute as String,
        "AXFullScreen",              // no Swift constant
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
    ]
    private static let windowAttributeNamesCFArray: CFArray =
        windowAttributeNames.map { $0 as CFString } as CFArray

    private func makeManagedWindow(from element: AXUIElement,
                                   appName: String,
                                   bundleID: String) -> ManagedWindow? {
        // Single batched IPC for all 6 attributes instead of one round-trip
        // per attribute. AXUIElementCopyMultipleAttributeValues returns
        // parallel values; missing attributes come back as AXValueRef
        // wrapping an .axError so we can distinguish from real values.
        var out: CFArray?
        PerfCounters.axReads += 1
        let err = AXUIElementCopyMultipleAttributeValues(
            element,
            Self.windowAttributeNamesCFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &out
        )
        guard err == .success, let values = out as? [AnyObject],
              values.count == Self.windowAttributeNames.count else { return nil }

        // Only tile top-level user windows. Dialogs, floating panels, and
        // in-window auxiliaries like iTerm's Cmd+F find bar all present as
        // AXWindow but with a non-standard subrole — tiling them churns
        // the layout every time the user opens/dismisses one.
        guard let role = attrString(values[0]), role == kAXWindowRole else { return nil }
        if let subrole = attrString(values[1]), subrole != kAXStandardWindowSubrole { return nil }
        if attrBool(values[2]) == true { return nil }  // minimized
        if attrBool(values[3]) == true { return nil }  // AXFullScreen

        var windowID: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &windowID) == .success, windowID != 0 else {
            return nil
        }

        let origin = attrPoint(values[4]) ?? .zero
        let size   = attrSize(values[5])  ?? .zero

        return ManagedWindow(
            windowID: windowID,
            appName: appName,
            bundleID: bundleID,
            axElement: element,
            frame: CGRect(origin: origin, size: size),
            orderIndex: 0
        )
    }

    // Batched-read result unpackers. Values that came back as an error
    // (AXValueRef with type .axError) are treated as absent.
    private func isErrorValue(_ v: AnyObject) -> Bool {
        let cf = v as CFTypeRef
        guard CFGetTypeID(cf) == AXValueGetTypeID() else { return false }
        // Safe: guarded by CFGetTypeID(cf) == AXValueGetTypeID() above.
        return AXValueGetType(cf as! AXValue) == .axError
    }
    private func attrString(_ v: AnyObject) -> String? {
        isErrorValue(v) ? nil : (v as? String)
    }
    private func attrBool(_ v: AnyObject) -> Bool? {
        isErrorValue(v) ? nil : (v as? Bool)
    }
    private func attrPoint(_ v: AnyObject) -> CGPoint? {
        guard !isErrorValue(v),
              CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // Safe: guarded by CFGetTypeID above.
        AXValueGetValue(v as! AXValue, .cgPoint, &point)
        return point
    }
    private func attrSize(_ v: AnyObject) -> CGSize? {
        guard !isErrorValue(v),
              CFGetTypeID(v as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Safe: guarded by CFGetTypeID above.
        AXValueGetValue(v as! AXValue, .cgSize, &size)
        return size
    }

    // MARK: - AX attribute helpers

    private func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        PerfCounters.axReads += 1
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }

    private func copyAXPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        PerfCounters.axReads += 1
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let cf = value, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        // Safe: guarded by CFGetTypeID(cf) == AXValueGetTypeID() above.
        AXValueGetValue(cf as! AXValue, .cgPoint, &point)
        return point
    }

    private func copyAXSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        PerfCounters.axReads += 1
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let cf = value, CFGetTypeID(cf) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        // Safe: guarded by CFGetTypeID(cf) == AXValueGetTypeID() above.
        AXValueGetValue(cf as! AXValue, .cgSize, &size)
        return size
    }
}
