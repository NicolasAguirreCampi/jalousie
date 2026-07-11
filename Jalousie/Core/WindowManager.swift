import ApplicationServices
import AppKit
import CoreGraphics

// Private but stable Accessibility symbol used by every macOS window manager.
// Maps an AXUIElement (a window) to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

final class WindowManager: NSObject {
    static let shared = WindowManager()
    private override init() { super.init() }

    // Set of window IDs seen on a prior enumeration. Used to keep tile order
    // stable across retiles: known windows keep their visual left-to-right
    // order (sorted by current x), brand-new windows are appended at the
    // right end regardless of where the app opened them.
    private var knownWindowIDs: Set<CGWindowID> = []

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
        Log.info("workspace observers registered")
    }

    // MARK: - Notification handlers

    @objc private func handleAppLaunch(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        // Wait for the new app's first window to actually exist. Not a
        // smoothing delay — the retile itself is still snap-instant.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.retile()
        }
    }

    @objc private func handleAppTerminate(_ notification: Notification) {
        guard Config.shared.current.settings.autoTile else { return }
        retile()
    }

    @objc private func handleSpaceChange(_ notification: Notification) {
        let settings = Config.shared.current.settings
        guard settings.autoTile, settings.tileOnSpaceSwitch else { return }
        retile()
    }

    // MARK: - Tiling

    func retile() {
        let windows = enumerateManagedWindows()
        let settings = Config.shared.current.settings

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

        for (i, window) in windows.enumerated() {
            let x = usable.origin.x + (tileWidth + gap) * CGFloat(i)
            let frame = CGRect(x: x, y: usable.origin.y,
                               width: tileWidth, height: usable.height)
            setFrame(of: window.axElement, to: frame)
        }
        Log.info("retile: laid out \(count) windows, gap=\(gap)")
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
