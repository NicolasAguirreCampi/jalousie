import ApplicationServices
import CoreGraphics
import Foundation

struct ManagedWindow: Equatable {
    let windowID: CGWindowID
    let appName: String
    let bundleID: String
    let axElement: AXUIElement
    var frame: CGRect
    var orderIndex: Int

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.windowID == rhs.windowID
    }
}
