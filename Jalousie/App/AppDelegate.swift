import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Jalousie starting")
        Config.shared.load()
        setupStatusItem()
        checkAccessibilityPermission()
        WindowManager.shared.start()
    }

    // MARK: - Accessibility permission

    private func checkAccessibilityPermission() {
        if AXIsProcessTrusted() {
            Log.info("accessibility: trusted")
            return
        }

        Log.warn("accessibility: not trusted — prompting user")
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Jalousie needs Accessibility access"
        alert.informativeText = """
        Open System Settings → Privacy & Security → Accessibility and enable Jalousie.

        Click Continue to open the system prompt.
        """
        alert.addButton(withTitle: "Continue")
        alert.alertStyle = .informational
        alert.runModal()

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
            accessibilityDescription: "Jalousie"
        )
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Jalousie", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Retile current space",
            action: #selector(retileClicked),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Reload config",
            action: #selector(reloadConfigClicked),
            keyEquivalent: ""
        ))
        // Phase 6 verification helper. Removed in Phase 20 cleanup.
        menu.addItem(NSMenuItem(
            title: "List windows (debug)",
            action: #selector(listWindowsClicked),
            keyEquivalent: ""
        ))
        // Phase 11 verification helpers. Removed in Phase 20 cleanup.
        menu.addItem(NSMenuItem(
            title: "Focus left (debug)",
            action: #selector(focusLeftClicked),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Focus right (debug)",
            action: #selector(focusRightClicked),
            keyEquivalent: ""
        ))

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        ))

        for entry in menu.items where entry.action != nil {
            entry.target = self
        }
        return menu
    }

    @objc private func retileClicked() {
        Log.info("menu: Retile current space")
        WindowManager.shared.retile()
    }

    @objc private func reloadConfigClicked() {
        Log.info("menu: Reload config")
        Config.shared.reload()
    }

    @objc private func quitClicked() {
        Log.info("menu: Quit")
        NSApp.terminate(nil)
    }

    @objc private func focusLeftClicked() {
        Log.info("menu: Focus left")
        WindowManager.shared.focusLeft()
    }

    @objc private func focusRightClicked() {
        Log.info("menu: Focus right")
        WindowManager.shared.focusRight()
    }

    @objc private func listWindowsClicked() {
        let windows = WindowManager.shared.enumerateManagedWindows()
        Log.info("managed windows: \(windows.count)")
        for window in windows {
            let f = window.frame
            Log.info("  [\(window.orderIndex)] \(window.appName) — id=\(window.windowID) bundle=\(window.bundleID) frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.size.width))x\(Int(f.size.height)))")
        }
    }
}
