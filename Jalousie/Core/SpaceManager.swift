import AppKit
import CoreGraphics

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
}
