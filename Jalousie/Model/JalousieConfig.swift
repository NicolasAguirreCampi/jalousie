import CoreGraphics
import Foundation

struct JalousieConfig: Codable, Equatable {
    var hotkeys: [String: HotKeyConfig]
    var blacklist: [String]
    var settings: Settings

    struct HotKeyConfig: Codable, Equatable {
        let key: String
        let modifiers: [String]
    }

    struct Settings: Codable, Equatable {
        var autoTile: Bool
        var tileOnSpaceSwitch: Bool
        var windowGap: CGFloat
        var ignoreSingleWindow: Bool
    }
}

extension JalousieConfig {
    static let `default` = JalousieConfig(
        hotkeys: [
            "focus-left":      HotKeyConfig(key: "j", modifiers: ["option"]),
            "focus-right":     HotKeyConfig(key: "l", modifiers: ["option"]),
            "swap-left":       HotKeyConfig(key: "j", modifiers: ["option", "shift"]),
            "swap-right":      HotKeyConfig(key: "l", modifiers: ["option", "shift"]),
            "send-to-space-1": HotKeyConfig(key: "1", modifiers: ["option", "shift"]),
            "send-to-space-2": HotKeyConfig(key: "2", modifiers: ["option", "shift"]),
            "send-to-space-3": HotKeyConfig(key: "3", modifiers: ["option", "shift"]),
            "send-to-space-4": HotKeyConfig(key: "4", modifiers: ["option", "shift"]),
            "send-to-space-5": HotKeyConfig(key: "5", modifiers: ["option", "shift"]),
            "retile":          HotKeyConfig(key: "e", modifiers: ["option", "shift"]),
        ],
        blacklist: [
            "com.apple.finder",
            "com.apple.systempreferences",
            "com.apple.ActivityMonitor",
            "com.apple.Terminal",
            "com.apple.calculator",
        ],
        settings: Settings(
            autoTile: true,
            tileOnSpaceSwitch: true,
            windowGap: 0,
            ignoreSingleWindow: false
        )
    )
}
