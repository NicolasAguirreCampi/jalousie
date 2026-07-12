import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Jalousie starting")
        // Phase 15 sanity check: confirms the CGSPrivate bridging header is
        // wired up. A non-zero connection ID means the private symbol
        // resolved at load time; zero would indicate a broken bridge.
        Log.info("CGS main connection id: \(CGSMainConnectionID())")
        Config.shared.load()
        setupStatusItem()
        checkAccessibilityPermission()
        WindowManager.shared.start()
        HotkeyManager.shared.start()
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
        // Phase 12 verification helpers. Removed in Phase 20 cleanup.
        menu.addItem(NSMenuItem(
            title: "Swap left (debug)",
            action: #selector(swapLeftClicked),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Swap right (debug)",
            action: #selector(swapRightClicked),
            keyEquivalent: ""
        ))
        // Phase 16 verification helpers. Removed in Phase 20 cleanup.
        for spaceIndex in 1...5 {
            let item = NSMenuItem(
                title: "Switch to space \(spaceIndex) (debug)",
                action: #selector(switchToSpaceClicked(_:)),
                keyEquivalent: ""
            )
            item.tag = spaceIndex
            menu.addItem(item)
        }
        // Phase 17 verification helpers. Removed in Phase 20 cleanup.
        for spaceIndex in 1...5 {
            let item = NSMenuItem(
                title: "Send window to space \(spaceIndex) (debug)",
                action: #selector(sendToSpaceClicked(_:)),
                keyEquivalent: ""
            )
            item.tag = spaceIndex
            menu.addItem(item)
        }

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

    @objc private func swapLeftClicked() {
        Log.info("menu: Swap left")
        WindowManager.shared.swapLeft()
    }

    @objc private func swapRightClicked() {
        Log.info("menu: Swap right")
        WindowManager.shared.swapRight()
    }

    @objc private func switchToSpaceClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        Log.info("menu: Switch to space \(index)")
        let before = SpaceManager.shared.currentSpaceID().map(String.init) ?? "nil"
        SpaceManager.shared.switchToSpace(at: index)
        let after = SpaceManager.shared.currentSpaceID().map(String.init) ?? "nil"
        Log.info("space: before=\(before) after=\(after)")
    }

    @objc private func sendToSpaceClicked(_ sender: NSMenuItem) {
        let index = sender.tag
        Log.info("menu: Send window to space \(index)")
        SpaceManager.shared.sendFocusedWindowToSpace(index)
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
