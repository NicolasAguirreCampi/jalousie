import Foundation
import os.log

enum Log {
    private static let logger = OSLog(subsystem: "com.local.jalousie", category: "app")

    static func info(_ message: String) {
        os_log("%{public}@", log: logger, type: .info, "ℹ️ \(message)")
    }

    static func warn(_ message: String) {
        os_log("%{public}@", log: logger, type: .default, "⚠️ \(message)")
    }

    static func error(_ message: String) {
        os_log("%{public}@", log: logger, type: .error, "❌ \(message)")
    }
}
