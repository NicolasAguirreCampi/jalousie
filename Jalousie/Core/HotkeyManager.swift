import AppKit
import CoreGraphics

// CGEventTap callback — free function so it's C-callable. Forwards to the
// singleton via an unretained refcon (safe because HotkeyManager.shared lives
// for the whole app lifetime).
private let hotkeyEventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    return manager.handle(proxy: proxy, type: type, event: event)
}

final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    // A single loaded hotkey: modifier flags (canonicalized to just the mask
    // bits we care about) plus the keycode. Stored in a plain array — the
    // set is small (< 20) and array iteration beats dictionary hashing at
    // this size, especially inside a CGEventTap callback on every keydown.
    private struct Binding {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
        let action: WMAction
    }

    private var bindings: [Binding] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Lifecycle

    func start() {
        rebuildHotkeys()
        installEventTap()
    }

    // Reparse bindings from the current config. Called on launch and every
    // "Reload config" — cheap enough to rerun in full each time.
    func rebuildHotkeys() {
        var loaded: [Binding] = []
        for (configKey, hotkey) in Config.shared.current.hotkeys {
            guard let action = WMAction(configKey: configKey) else {
                Log.warn("hotkey: unknown action '\(configKey)' — skipping")
                continue
            }
            guard let keyCode = keyCode(for: hotkey.key) else {
                Log.warn("hotkey: unknown key '\(hotkey.key)' for \(configKey) — skipping")
                continue
            }
            let flags = eventFlags(for: hotkey.modifiers)
            loaded.append(Binding(keyCode: keyCode, flags: flags, action: action))
        }
        bindings = loaded
        Log.info("hotkeys: loaded \(bindings.count) bindings")
    }

    // MARK: - Event tap

    private func installEventTap() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventTapCallback,
            userInfo: refcon
        ) else {
            Log.error("hotkeys: could not create CGEventTap — is Accessibility granted?")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        Log.info("hotkeys: event tap installed")
    }

    // Runs on every keydown — must stay fast. Compare against the small
    // bindings array and either suppress on match or pass through untouched.
    fileprivate func handle(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent) -> Unmanaged<CGEvent>? {
        // CGEventTap can disable itself under load (kCGEventTapDisabledByTimeout);
        // re-enable and drop the event so the tap keeps working.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.intersection(Self.trackedModifierMask)

        for binding in bindings where binding.keyCode == keyCode && binding.flags == flags {
            // Log-only in Phase 13. Phase 14 will wire this into real dispatch.
            DispatchQueue.main.async { Log.info("dispatch \(binding.action)") }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    // Only compare on the modifiers we care about; strip caps-lock, function,
    // etc. so a stuck FN key doesn't break bindings.
    private static let trackedModifierMask: CGEventFlags = [
        .maskAlternate, .maskShift, .maskCommand, .maskControl,
    ]

    // MARK: - Parsing helpers

    private func eventFlags(for modifiers: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "option", "alt":       flags.insert(.maskAlternate)
            case "shift":               flags.insert(.maskShift)
            case "command", "cmd":      flags.insert(.maskCommand)
            case "control", "ctrl":     flags.insert(.maskControl)
            default:
                Log.warn("hotkey: unknown modifier '\(modifier)' — ignoring")
            }
        }
        return flags
    }

    // Config keys are single characters ("j", "l", "1"..). Map them via a
    // static ANSI keyboard table — good enough for v1; non-ANSI layouts can
    // fall back to name-based lookup below.
    private func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        if let code = Self.keyCodeTable[normalized] { return code }
        return nil
    }

    private static let keyCodeTable: [String: CGKeyCode] = [
        "a": 0,  "s": 1,  "d": 2,  "f": 3,  "h": 4,  "g": 5,  "z": 6,  "x": 7,
        "c": 8,  "v": 9,  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16,
        "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30,
        "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45,
        "m": 46, ".": 47, "`": 50,
        "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    ]
}
