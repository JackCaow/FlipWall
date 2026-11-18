import AppKit
import Darwin

/// WallpaperAgent reads this per-user store when loginwindow presents the
/// locked session. Only the desktop content of a matching FlipWall saver
/// selection is substituted, and only while the session is locked.
struct LockScreenWallpaper {
    private typealias Plist = [String: Any]
    static let preferenceKey = "DynamicLockWallpaperEnabled"
    private static let provider = "com.apple.wallpaper.choice.screen-saver"
    private let store: URL
    private let backup: URL
    private let saver: URL
    private let reload: () -> Void

    enum Failure: LocalizedError {
        case missingSelection, changedDuringWrite, unrecognizedStore, restoreConflict

        var errorDescription: String? {
            switch self {
            case .missingSelection: return "FlipWall 屏保未安装或未在系统中选中"
            case .changedDuringWrite: return "系统墙纸设置正在变化"
            case .unrecognizedStore: return "无法读取系统墙纸设置"
            case .restoreConflict: return "系统墙纸设置出现冲突，原设置备份已保留"
            }
        }
    }

    init(directory: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         reload: @escaping () -> Void = Self.reloadSystemWallpaper) {
        store = home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        saver = home.appendingPathComponent("Library/Screen Savers/FlipWall.saver", isDirectory: true)
        backup = directory.appendingPathComponent("lock-wallpaper-backup.plist")
        self.reload = reload
    }

    @discardableResult
    func activate() throws -> Int {
        let fm = FileManager.default
        if fm.fileExists(atPath: backup.path) {
            // An earlier activation already owns the backup.
            return 0
        }
        guard fm.fileExists(atPath: saver.path) else { throw Failure.missingSelection }
        let original = try Data(contentsOf: store)
        let current = try decode(original)
        var changed = 0
        let locked = visit(current, originals: nil) { desktop, idle, _ in
            guard let idle, isFlipWall(idle), !isFlipWall(desktop) else { return desktop }
            var result = desktop
            result["Content"] = idle["Content"]
            changed += 1
            return result
        }
        guard changed > 0 else { throw Failure.missingSelection }

        try original.write(to: backup, options: .atomic)
        do {
            try replaceStore(with: locked, expecting: original)
        } catch {
            try? fm.removeItem(at: backup)
            throw error
        }
        reload()
        return changed
    }

    @discardableResult
    func restore() throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { return 0 }
        let original = try decode(Data(contentsOf: backup))
        let storeData = try Data(contentsOf: store)
        let current = try decode(storeData)
        var changed = 0
        var conflict = false
        let unlocked = visit(current, originals: original) { desktop, _, oldDesktop in
            guard isFlipWall(desktop) else { return desktop }
            guard let oldDesktop, let content = oldDesktop["Content"] else {
                conflict = true
                return desktop
            }
            guard !isFlipWall(oldDesktop) else { return desktop }
            var result = desktop
            result["Content"] = content
            changed += 1
            return result
        }
        if changed > 0 {
            try replaceStore(with: unlocked, expecting: storeData)
            reload()
        }
        guard !conflict else { throw Failure.restoreConflict }
        try fm.removeItem(at: backup)
        return changed
    }

    private func decode(_ data: Data) throws -> Plist {
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? Plist else {
            throw Failure.unrecognizedStore
        }
        return result
    }

    private func replaceStore(with value: Plist, expecting data: Data) throws {
        let next = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        guard try Data(contentsOf: store) == data else { throw Failure.changedDuringWrite }
        try next.write(to: store, options: .atomic)
    }

    private func isFlipWall(_ entry: Plist) -> Bool {
        guard let content = entry["Content"] as? Plist,
              let choices = content["Choices"] as? [Plist], choices.count == 1,
              let choice = choices.first, choice["Provider"] as? String == Self.provider,
              let config = choice["Configuration"] as? Data,
              let module = (try? decode(config))?["module"] as? Plist,
              let relative = module["relative"] as? String,
              let url = URL(string: relative), url.isFileURL else { return false }
        return url.standardizedFileURL.path == saver.standardizedFileURL.path
    }

    private func visit(_ dictionary: Plist, originals: Plist?,
                       change: (Plist, Plist?, Plist?) -> Plist) -> Plist {
        var result = dictionary
        if let desktop = dictionary["Desktop"] as? Plist {
            result["Desktop"] = change(desktop, dictionary["Idle"] as? Plist, originals?["Desktop"] as? Plist)
        }
        // The keyed containers cover the system default plus display and
        // Space overrides. Traversing them also preserves historical entries.
        for (key, item) in dictionary where key != "Desktop" && key != "Idle" {
            if let nested = item as? Plist {
                result[key] = visit(nested, originals: originals?[key] as? Plist, change: change)
            }
        }
        return result
    }

    private static func reloadSystemWallpaper() {
        let bundleIDs = ["com.apple.ScreenSaver.Engine", "com.apple.ScreenSaver.Engine.legacyScreenSaver",
                         "com.apple.wallpaper.agent"]
        for bundleID in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                if !app.terminate() { Darwin.kill(app.processIdentifier, SIGTERM) }
            }
        }
    }
}
