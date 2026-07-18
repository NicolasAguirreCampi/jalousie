import Foundation

// Every hotkey-triggered operation the app can perform. Parsed from the
// hyphenated action names in the JSON config ("focus-left", "send-to-space-3")
// via `init?(configKey:)` so the config file stays stringly-typed while the
// rest of the app is enum-typed.
enum WMAction: Equatable {
    case focusLeft
    case focusRight
    case swapLeft
    case swapRight
    case sendToSpace(Int)
    case switchToSpace(Int)
    case retile
    case reloadConfig
    case toggleZoomFullscreen

    init?(configKey: String) {
        switch configKey {
        case "focus-left":   self = .focusLeft
        case "focus-right":  self = .focusRight
        case "swap-left":    self = .swapLeft
        case "swap-right":   self = .swapRight
        case "retile":       self = .retile
        case "reload-config": self = .reloadConfig
        case "toggle-zoom-fullscreen": self = .toggleZoomFullscreen
        default:
            if let n = Self.trailingIndex(configKey, prefix: "send-to-space-") {
                self = .sendToSpace(n)
            } else if let n = Self.trailingIndex(configKey, prefix: "switch-to-space-") {
                self = .switchToSpace(n)
            } else {
                return nil
            }
        }
    }

    private static func trailingIndex(_ key: String, prefix: String) -> Int? {
        guard key.hasPrefix(prefix) else { return nil }
        return Int(key.dropFirst(prefix.count))
    }
}
