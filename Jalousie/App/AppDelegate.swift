import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    // WindowManager/HotkeyManager start() attaches CGEventTaps and AX
    // observers that only succeed when the process is trusted. Guard against
    // double-start when the accessibility grant fires the notification.
    private var managersStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Jalousie starting")
        Config.shared.load()
        setupStatusItem()
        // macOS captures a process's TCC/accessibility decision at launch
        // and does not re-evaluate it in-process, so if we're not trusted
        // now we can't become trusted without spawning a fresh process.
        // promptForAccessibilityIfNeeded handles that flow (grant + relaunch).
        promptForAccessibilityIfNeeded()
        startManagersIfTrusted()
    }

    // MARK: - Accessibility permission

    private func promptForAccessibilityIfNeeded() {
        if AXIsProcessTrusted() {
            Log.info("accessibility: trusted")
            return
        }

        Log.warn("accessibility: not trusted — prompting user")
        NSApp.activate(ignoringOtherApps: true)

        // Trigger the system prompt up-front so the user sees the OS's own
        // "add Jalousie" dialog alongside our instructions.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)

        let alert = NSAlert()
        alert.messageText = "Jalousie needs Accessibility access"
        alert.informativeText = """
        Open System Settings → Privacy & Security → Accessibility and enable Jalousie.

        macOS caches this permission at process launch, so once you toggle Jalousie on, click Relaunch below and everything will start working.
        """
        alert.addButton(withTitle: "Relaunch Jalousie")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .informational
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            relaunch()
        } else {
            NSApp.terminate(nil)
        }
    }

    // Spawn a fresh copy of ourselves via `open`, then exit. The new
    // process reads TCC fresh and sees the just-granted trust.
    private func relaunch() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else {
            Log.error("relaunch: no bundle URL — quitting")
            NSApp.terminate(nil)
            return
        }
        let process = Process()
        process.launchPath = "/usr/bin/open"
        process.arguments = ["-n", bundleURL.path]
        do {
            try process.run()
        } catch {
            Log.error("relaunch: failed to spawn new instance: \(error)")
        }
        NSApp.terminate(nil)
    }

    private func startManagersIfTrusted() {
        guard !managersStarted, AXIsProcessTrusted() else { return }
        managersStarted = true
        WindowManager.shared.start()
        HotkeyManager.shared.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Prefer the bundled template SVG. Falls back to the SF Symbol if
        // the asset can't be loaded, so a broken/missing MenuBarIcon.imageset
        // never leaves the menu bar empty.
        let icon = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "rectangle.split.3x1",
                       accessibilityDescription: "Jalousie")
        icon?.isTemplate = true
        item.button?.image = icon
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
}
