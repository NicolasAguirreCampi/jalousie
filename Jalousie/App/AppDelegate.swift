import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Jalousie starting")
        logBundledDefaultConfig()
        setupStatusItem()
    }

    // Phase 3 verify: decode the bundled default JSON and log field counts.
    // Removed once Config.load() is in place in Phase 4.
    private func logBundledDefaultConfig() {
        guard let url = Bundle.main.url(forResource: "jalousie-default", withExtension: "json") else {
            Log.error("jalousie-default.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let config = try JSONDecoder().decode(JalousieConfig.self, from: data)
            Log.info("default config decoded: hotkeys=\(config.hotkeys.count), blacklist=\(config.blacklist.count), autoTile=\(config.settings.autoTile)")
        } catch {
            Log.error("default config decode failed: \(error)")
        }
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
        Log.info("menu: Retile current space (placeholder)")
    }

    @objc private func reloadConfigClicked() {
        Log.info("menu: Reload config (placeholder)")
    }

    @objc private func quitClicked() {
        Log.info("menu: Quit")
        NSApp.terminate(nil)
    }
}
