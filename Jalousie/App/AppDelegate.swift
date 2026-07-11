import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Jalousie starting")
        setupStatusItem()
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
