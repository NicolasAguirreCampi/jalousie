import Foundation

final class Config {
    static let shared = Config()
    private init() {}

    private(set) var current: JalousieConfig = .default

    // MARK: - Public API

    func load() {
        ensureConfigDirectoryExists()
        if !FileManager.default.fileExists(atPath: configURL.path) {
            copyBundledDefault()
        }
        current = decodeFromDisk()
        Log.info("config loaded: hotkeys=\(current.hotkeys.count), blacklist=\(current.blacklist.count), autoTile=\(current.settings.autoTile)")
    }

    func reload() {
        current = decodeFromDisk()
        Log.info("config reloaded: hotkeys=\(current.hotkeys.count), blacklist=\(current.blacklist.count), autoTile=\(current.settings.autoTile)")
    }

    // MARK: - Paths

    private var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("jalousie")
            .appendingPathComponent("config.json")
    }

    // MARK: - Disk I/O

    private func ensureConfigDirectoryExists() {
        let dir = configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error("could not create config directory at \(dir.path): \(error)")
        }
    }

    private func copyBundledDefault() {
        guard let bundledURL = Bundle.main.url(forResource: "jalousie-default", withExtension: "json") else {
            Log.error("jalousie-default.json missing from bundle — skipping copy")
            return
        }
        do {
            try FileManager.default.copyItem(at: bundledURL, to: configURL)
            Log.info("wrote default config to \(configURL.path)")
        } catch {
            Log.error("failed to copy default config to \(configURL.path): \(error)")
        }
    }

    private func decodeFromDisk() -> JalousieConfig {
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(JalousieConfig.self, from: data)
        } catch {
            Log.error("failed to load config from \(configURL.path): \(error). Falling back to defaults.")
            return .default
        }
    }
}
