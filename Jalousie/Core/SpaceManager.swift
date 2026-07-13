import AppKit
import CoreGraphics
import Darwin

// SkyLight private-framework symbols used by yabai for the space-move
// workaround. We dlopen the framework and dlsym the two functions we need —
// linking directly would break on macOS versions that don't export them,
// and the runtime lookup lets us fall back cleanly if a future macOS
// renames or drops them.
// Look symbols up in the current process first (GUI apps already have
// SkyLight loaded via ApplicationServices), then fall back to explicit
// dlopen. The `Versions/A/SkyLight` path stopped existing as a file on disk
// years ago — the binary lives in the dyld shared cache.
private func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) { return sym }
    if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let sym = dlsym(handle, name) {
        return sym
    }
    return nil
}

private typealias SLSSpaceSetCompatIDFn =
    @convention(c) (CGSConnectionID, CGSSpaceID, UInt64) -> Int32
private typealias SLSSetWindowListWorkspaceFn =
    @convention(c) (CGSConnectionID, UnsafePointer<UInt32>, Int32, UInt64) -> Int32
// New on macOS Tahoe (26+): supersedes SLSMoveWindowsToManagedSpace and the
// SLSPerformAsynchronousBridgedWindowManagementOperation path. Signature
// taken from actively-maintained projects that target current macOS
// (SketchyBar, Lakr233/SkyLightWindow). The trailing `mask` is the CGS
// space mask used when computing which spaces to remove from — 7 means
// "all spaces on this connection".
private typealias SLSSpaceAddWindowsAndRemoveFromSpacesFn =
    @convention(c) (CGSConnectionID, UInt64, CFArray, Int32) -> Int32

private let slsSpaceSetCompatID: SLSSpaceSetCompatIDFn? = {
    guard let sym = skyLightSymbol("SLSSpaceSetCompatID") else { return nil }
    return unsafeBitCast(sym, to: SLSSpaceSetCompatIDFn.self)
}()

private let slsSetWindowListWorkspace: SLSSetWindowListWorkspaceFn? = {
    guard let sym = skyLightSymbol("SLSSetWindowListWorkspace") else { return nil }
    return unsafeBitCast(sym, to: SLSSetWindowListWorkspaceFn.self)
}()

private let slsSpaceAddWindowsAndRemove: SLSSpaceAddWindowsAndRemoveFromSpacesFn? = {
    guard let sym = skyLightSymbol("SLSSpaceAddWindowsAndRemoveFromSpaces") else { return nil }
    return unsafeBitCast(sym, to: SLSSpaceAddWindowsAndRemoveFromSpacesFn.self)
}()

// Thin Swift wrapper around the private CGS space APIs. Every call validates
// the connection ID and space index before touching CGS — the private
// functions have no error channel and crash the app when handed bad input.
final class SpaceManager {
    static let shared = SpaceManager()
    private init() {}

    // MARK: - Query

    // The active space on the current display, or nil if CGS refuses to
    // hand us a connection (should never happen after launch, but the
    // private API deserves defensive handling).
    func currentSpaceID() -> CGSSpaceID? {
        let conn = CGSMainConnectionID()
        guard conn != 0 else {
            Log.warn("space: CGSMainConnectionID returned 0")
            return nil
        }
        return CGSGetActiveSpace(conn)
    }

    // All user-manageable spaces on all displays, in the order CGS reports
    // them. Fullscreen "spaces" show up too; callers filter as needed.
    func userSpaces() -> [CGSSpaceID] {
        let conn = CGSMainConnectionID()
        guard conn != 0 else { return [] }
        // Mask 0x7 = include current, other, and all spaces on this connection.
        // The result is a heterogeneous NSArray of NSNumber-wrapped IDs.
        guard let raw = CGSCopySpaces(conn, 0x7) as? [NSNumber] else { return [] }
        return raw.map { CGSSpaceID($0.uint64Value) }
    }

    // Space IDs for the display the given window currently occupies, in the
    // order macOS presents them (which matches the Mission Control ordering
    // the user sees). CGSCopyManagedDisplaySpaces returns one entry per
    // physical display, each with a "Display Identifier" CFUUID string and
    // an ordered "Spaces" array.
    func spacesForCurrentDisplay(of window: ManagedWindow) -> [CGSSpaceID] {
        let conn = CGSMainConnectionID()
        guard conn != 0 else { return [] }
        guard let raw = CGSCopyManagedDisplaySpaces(conn)?.takeRetainedValue() as? [[String: Any]] else {
            return []
        }
        // Match the window to its display via its center point → NSScreen.
        // Fall back to the main display's spaces if we can't identify one.
        let uuid = displayUUIDContaining(window: window)
        for entry in raw {
            let identifier = entry["Display Identifier"] as? String
            guard identifier == uuid || (uuid == nil && raw.count == 1) else { continue }
            guard let spaces = entry["Spaces"] as? [[String: Any]] else { return [] }
            return spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
        // No match on the window's display — return the first display's list
        // as a last-resort so hotkeys still do something sensible instead of
        // being a silent no-op.
        if let first = raw.first, let spaces = first["Spaces"] as? [[String: Any]] {
            return spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
        }
        return []
    }

    // Resolve which display's CGDirectDisplayID matches the given window,
    // then convert to the CFUUID string CGS uses to key its display topology.
    private func displayUUIDContaining(window: ManagedWindow) -> String? {
        let frame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetDisplaysWithPoint(center, 16, &displays, &displayCount) == .success,
              displayCount > 0 else { return nil }
        guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displays[0])?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuidRef) as String?
    }

    // MARK: - Switch

    // Show the space at the given (1-based, matching config hotkey names)
    // index and hide the currently active one. macOS animates the transition
    // itself; we can't shorten it, but no code path here adds a delay of
    // our own.
    func switchToSpace(at index: Int) {
        let conn = CGSMainConnectionID()
        guard conn != 0 else {
            Log.warn("space: switch aborted, no CGS connection")
            return
        }
        let spaces = userSpaces()
        // Config uses 1-based indices to match the hotkey labels ("send-to-
        // space-1"). Translate to a 0-based array index once, right here.
        let arrayIndex = index - 1
        guard arrayIndex >= 0, arrayIndex < spaces.count else {
            Log.warn("space: index \(index) out of bounds (have \(spaces.count) spaces)")
            return
        }
        let target = spaces[arrayIndex]
        guard let currentID = currentSpaceID(), currentID != target else { return }

        // Order matters: show the target first so there's no flash of an
        // empty desktop while we transition.
        CGSShowSpaces(conn, [NSNumber(value: target)])
        CGSHideSpaces(conn, [NSNumber(value: currentID)])
        Log.info("space: switched to index \(index) (id=\(target))")
    }

    // MARK: - Move window

    // Move the currently focused managed window to the space at the given
    // 1-based index, then retile the source space so the remaining windows
    // fill the gap. CGSMoveWindowsToManagedSpace is the CGS call that has
    // stayed effective across recent macOS versions, unlike Show/HideSpaces.
    func sendFocusedWindowToSpace(_ index: Int) {
        let conn = CGSMainConnectionID()
        guard conn != 0 else {
            Log.warn("space: send aborted, no CGS connection")
            return
        }
        guard let window = WindowManager.shared.focusedManagedWindow() else {
            Log.info("space: no focused managed window to send")
            return
        }
        // Spaces are per-display. Pick the Nth space on the display the
        // focused window is currently on — otherwise Option+Shift+2 could
        // send the window to another monitor's second space.
        let spacesOnDisplay = spacesForCurrentDisplay(of: window)
        let arrayIndex = index - 1
        guard arrayIndex >= 0, arrayIndex < spacesOnDisplay.count else {
            Log.warn("space: send index \(index) out of bounds on current display (have \(spacesOnDisplay.count) spaces)")
            return
        }
        let target = spacesOnDisplay[arrayIndex]

        // yabai's compat-ID workaround for macOS Sonoma+: tag the destination
        // space with a magic compat ID, associate the window's workspace
        // with that same ID, then clear the compat ID. The private
        // WindowServer honors the association even when the newer
        // CGS/SLS move APIs are clamped. The literal magic value 0x79616265
        // is "yabe" in ASCII — kept identical to yabai's so any macOS
        // internals that special-case it work for us too.
        // Preferred path: invoke the private perform function directly via
        // the Obj-C class SLSBridgedMoveWindowsToManagedSpaceOperation.
        // The exported wrapper SLSSpaceAddWindowsAndRemoveFromSpaces gates
        // callers on SLSWindowManagementClientOperationsEnabled — the
        // internal perform function does not. This is yabai's fix from
        // v7.1.25 and works with SIP enabled.
        if JalousieBridgedSendWindowToSpace(window.windowID, target) {
            Log.info("space: sent \(window.appName)#\(window.windowID) to index \(index) (id=\(target)) via bridged op")
            WindowManager.shared.retile()
            return
        }

        // Fallback for future macOS versions where the mangled symbol name
        // changes — the exported wrapper still succeeds on entitled hosts.
        if let addAndRemove = slsSpaceAddWindowsAndRemove {
            let idNumber = NSNumber(value: Int32(bitPattern: window.windowID))
            let ids: CFArray = [idNumber] as CFArray
            let err = addAndRemove(conn, target, ids, 7)
            Log.info("space: sent \(window.appName)#\(window.windowID) to index \(index) (id=\(target)) via SLSSpaceAddWindowsAndRemoveFromSpaces err=\(err)")
            WindowManager.shared.retile()
            return
        }

        // Tier 3: compat-ID workaround for older macOS where neither of the
        // above symbols exist.
        let compatID: UInt64 = 0x79616265
        var windowID = window.windowID
        if let setCompat = slsSpaceSetCompatID,
           let setList = slsSetWindowListWorkspace {
            _ = setCompat(conn, target, compatID)
            _ = setList(conn, &windowID, 1, compatID)
            _ = setCompat(conn, target, 0)
            Log.info("space: sent \(window.appName)#\(window.windowID) to index \(index) (id=\(target)) via SLS compat-id")
        } else {
            CGSMoveWindowsToManagedSpace(conn,
                                         [NSNumber(value: window.windowID)],
                                         target)
            Log.warn("space: SLS symbols unavailable — used CGSMoveWindowsToManagedSpace fallback")
        }
        WindowManager.shared.retile()
    }
}
