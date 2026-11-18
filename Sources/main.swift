import AppKit
import ColorSync
import WebKit
import Darwin

struct Settings: Codable, Equatable {
    static let standardInterval = 3.0
    var columns = 5
    var interval = standardInterval
    var duration = 1.25
    var brightness = 0.78
    var paused = false
    var epoch: Double?
}

struct DisplaySettings: Codable, Equatable {
    var enabled = true
    var paused = false
    var brightness: Double?
    var columns: Int?
}

enum DisplayChange {
    case toggleEnabled, togglePaused, brightness(Double?), columns(Int?)
}

final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Wallpaper: NSObject, WKNavigationDelegate {
    let displayID: CGDirectDisplayID
    let displayKey: String
    let window: DesktopWindow
    let webView: WKWebView
    let directory: URL
    var videos: [Video]
    var config: Settings
    var ready = false
    private(set) var rendererRestarts = 0
    private var clock: DispatchWorkItem?
    private var clockGeneration = 0
    private var reload: DispatchWorkItem?
    private var loadFailures = 0

    static func id(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func key(for screen: NSScreen) -> String {
        let id = Self.id(for:screen)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil,uuid) as String
        }
        return "display-\(id)"
    }

    init(screen: NSScreen, directory: URL, videos: [Video], config: Settings) {
        displayID = Self.id(for:screen)
        displayKey = Self.key(for:screen)
        self.directory = directory; self.videos = videos; self.config = config
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: webConfig)
        window = DesktopWindow(contentRect:NSRect(origin:.zero,size:screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        super.init()
        // The initializer's rectangle is relative to its screen. Apply the
        // global frame exactly once, including negative/above-main origins.
        window.setFrame(screen.frame, display:true)
        window.title = "FlipWall · " + screen.localizedName
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.canHide = false
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        loadPage()
    }

    private func loadPage() {
        let entry = directory.appendingPathComponent("index.html")
        webView.loadFileURL(entry, allowingReadAccessTo: directory)
    }

    func updateFrame(for screen: NSScreen) {
        if window.frame != screen.frame { window.setFrame(screen.frame, display:true) }
        window.title = "FlipWall · " + screen.localizedName
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        apply()
        supply(videos)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL,
              url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        rendererRestarts += 1
        recover(from: "WebKit renderer stopped")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { recover(from:error.localizedDescription) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { recover(from:error.localizedDescription) }
    }

    private func recover(from reason: String) {
        ready = false
        // Fall back to the macOS wallpaper instead of covering it with an
        // empty WebKit window while the renderer restarts.
        window.orderOut(nil)
        restartClock()
        reload?.cancel()
        loadFailures += 1
        let delay = min(8.0, 0.5 * pow(2.0, Double(min(4,loadFailures - 1))))
        NSLog("FlipWall: %@ (%@), reloading in %.1fs",window.title,reason,delay)
        let attempt = DispatchWorkItem { [weak self] in self?.loadPage() }
        reload = attempt
        DispatchQueue.main.asyncAfter(deadline:.now() + delay, execute:attempt)
    }

    func apply() {
        guard ready, let data = try? JSONEncoder().encode(config), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.flipWall.configure(\(json))") { _, error in
            if let error = error { NSLog("FlipWall: configuration error: %@", error.localizedDescription) }
        }
        restartClock()
    }

    func supply(_ videos: [Video]) {
        self.videos = videos
        guard ready, let data = try? JSONEncoder().encode(videos),
              let entries = try? JSONSerialization.jsonObject(with:data) else { return }
        webView.callAsyncJavaScript("return await window.flipWall.setLibrary(entries);",arguments:["entries":entries],in:nil,in:.page) { [weak self] result in
            guard let self, self.ready else { return }
            switch result {
            case .success(let value):
                guard value as? Bool == true else { return }
                self.loadFailures = 0
                if !self.window.isVisible { self.window.orderFrontRegardless() }
            case .failure(let error):
                NSLog("FlipWall: library error: %@",error.localizedDescription)
            }
        }
    }

    func videoURL(at point: CGPoint, completion: @escaping (URL?) -> Void) {
        let frame = window.frame
        guard ready, window.isVisible, frame.contains(point) else { completion(nil); return }
        let position = ["x":point.x - frame.minX, "y":frame.maxY - point.y]
        webView.callAsyncJavaScript("return window.flipWall.videoAt(x, y);",arguments:position,in:nil,in:.page) { result in
            guard case .success(let value) = result, let id = value as? String,
                  id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {
                completion(nil)
                return
            }
            var url = URLComponents()
            url.scheme = "https"
            url.host = "www.youtube.com"
            url.path = "/watch"
            url.queryItems = [URLQueryItem(name:"v",value:id)]
            completion(url.url)
        }
    }

    private func restartClock() {
        clockGeneration += 1
        clock?.cancel(); clock = nil
        guard ready && !config.paused else { return }
        advanceClock(generation: clockGeneration)
    }

    private func advanceClock(generation: Int) {
        guard ready && !config.paused && generation == clockGeneration else { return }
        // Constant script plus a structured argument avoids reparsing a new
        // timestamp-bearing JS program on every animation frame.
        webView.callAsyncJavaScript("return window.flipWall.advance(stamp);",
                                   arguments:["stamp":ProcessInfo.processInfo.systemUptime * 1000],
                                   in:nil, in:.page) { [weak self] result in
            guard let self = self, self.ready, !self.config.paused,
                  generation == self.clockGeneration else { return }
            let milliseconds: Double
            switch result {
            case .success(let value): milliseconds = (value as? NSNumber)?.doubleValue ?? 500
            case .failure(let error):
                NSLog("FlipWall: animation clock error: %@",error.localizedDescription)
                milliseconds = 1000
            }
            let work = DispatchWorkItem { [weak self] in self?.advanceClock(generation:generation) }
            self.clock = work
            DispatchQueue.main.asyncAfter(deadline:.now() + max(0.033, min(5,milliseconds / 1000)), execute:work)
        }
    }

    func close() {
        ready = false
        reload?.cancel(); reload = nil
        clockGeneration += 1; clock?.cancel(); clock = nil
        webView.navigationDelegate = nil; webView.stopLoading(); window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let refreshInterval: TimeInterval = 3600
    var wallpapers: [Wallpaper] = []
    var statusItem: NSStatusItem?
    var settings = Settings()
    private var displaySettings: [String:DisplaySettings] = [:]
    private var displaySettingsURL: URL { directory.appendingPathComponent("display-settings.json") }
    var videos: [Video] = []
    var directory: URL!
    var lockDescriptor: Int32 = -1
    var refreshTask: Task<Void, Never>?
    var refreshTimer: Timer?
    var observers: [NSObjectProtocol] = []
    var sleeping = false
    var refreshing = false
    var lastError: String?
    var activity: NSObjectProtocol?
    var selfTestSampler: Timer?
    var observedIntermediateFrame = false
    var animationEpoch = ProcessInfo.processInfo.systemUptime * 1000
    var pauseStarted: Double?
    var diagnosticObserver: NSObjectProtocol?
    private var lockScreenObservers: [NSObjectProtocol] = []
    private var lockScreenWallpaper: LockScreenWallpaper?
    private var lockWallpaperTask: DispatchWorkItem?
    private var lockWallpaperEnabled: Bool {
        UserDefaults.standard.bool(forKey: LockScreenWallpaper.preferenceKey)
    }
    private var mouseMonitor: Any?
    private var optionClickStart: CGPoint?
    let args = CommandLine.arguments
    var selfTest: Bool { args.contains("--self-test") }
    var refreshOnly: Bool { args.contains("--refresh-only") }

    func argument(_ name: String) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            directory = argument("--state-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlipWall", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            lockDescriptor = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                NSLog("FlipWall: another instance already owns this library"); NSApp.terminate(nil); return
            }
            try prepareResources()
            let cachedLibrary = directory.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: cachedLibrary.path) {
                videos = try JSONDecoder().decode([Video].self, from: Data(contentsOf: cachedLibrary))
                if !videos.isEmpty {
                    do { try SaverGallery.publish(videos,at:directory) }
                    catch { NSLog("FlipWall: screen saver gallery: %@",error.localizedDescription) }
                }
            }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
               let saved = try? JSONDecoder().decode(Settings.self, from: data) { settings = saved }
            settings.columns = min(8, max(3, settings.columns))
            settings.interval = min(15, max(1.5, settings.interval))
            settings.duration = min(3, max(0.3, settings.duration))
            settings.brightness = min(1, max(0.25, settings.brightness))
            if let data = try? Data(contentsOf:displaySettingsURL),
               let saved = try? JSONDecoder().decode([String:DisplaySettings].self,from:data) { displaySettings = saved }
            if refreshOnly { refresh(); return }
            if selfTest { settings = Settings(); displaySettings = [:] }
            if !selfTest { makeStatusItem() }
            rebuildScreens()
            if selfTest {
                if args.contains("--test-renderer-recovery") {
                    DispatchQueue.main.asyncAfter(deadline:.now() + 2) { [weak self] in self?.testRendererRecovery() }
                } else if args.contains("--test-video-links") {
                    DispatchQueue.main.asyncAfter(deadline:.now() + 2) { [weak self] in self?.testVideoLinks() }
                } else if args.contains("--test-display-settings") {
                    DispatchQueue.main.asyncAfter(deadline:.now() + 2) { [weak self] in self?.testDisplaySettings() }
                } else {
                    runSelfTest()
                }
                return
            }
            if #available(macOS 14.2, *), argument("--state-dir") == nil {
                observeLockScreen()
            }
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handleDesktopClick(event)
            }
            diagnosticObserver = DistributedNotificationCenter.default().addObserver(forName:Notification.Name("com.local.flipwall.diagnostics"), object:nil, queue:.main) { [weak self] _ in self?.writeDiagnostics() }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.rebuildScreens() })
            observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.applySettings(save: false) })
            let workspace = NSWorkspace.shared.notificationCenter
            observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.applySettings(save: false) })
            observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = false
                self?.applySettings(save: false)
                self?.scheduleRefresh()
            })
            if videos.isEmpty { refresh() }
            else { scheduleRefresh() }
        } catch {
            NSLog("FlipWall: startup failed: %@", error.localizedDescription)
            if !selfTest && !refreshOnly { let alert = NSAlert(); alert.messageText = "FlipWall 无法启动"; alert.informativeText = error.localizedDescription; alert.runModal() }
            Darwin.exit(1)
        }
    }

    private func observeLockScreen() {
        lockScreenWallpaper = LockScreenWallpaper(directory: directory)
        restoreLockWallpaper()
        let center = DistributedNotificationCenter.default()
        lockScreenObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                       object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLockWallpaper()
        })
        lockScreenObservers.append(center.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                       object: nil, queue: .main) { [weak self] _ in
            self?.restoreLockWallpaper()
        })
        if (CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool == true {
            scheduleLockWallpaper()
        }
        updateMenu()
    }

    private func scheduleLockWallpaper(attempts: Int = 8) {
        guard lockWallpaperEnabled, let lockScreenWallpaper else { return }
        lockWallpaperTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            do {
                let count = try lockScreenWallpaper.activate()
                if count > 0 { NSLog("FlipWall: lock wallpaper activated for %d entries", count) }
            } catch LockScreenWallpaper.Failure.changedDuringWrite where attempts > 1 {
                self?.scheduleLockWallpaper(attempts: attempts - 1)
            } catch {
                NSLog("FlipWall: could not activate lock wallpaper: %@", error.localizedDescription)
            }
        }
        lockWallpaperTask = task
        // WallpaperAgent saves its own state during the lock transition.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
    }

    private func restoreLockWallpaper(retry: Bool = true) {
        lockWallpaperTask?.cancel()
        lockWallpaperTask = nil
        guard let lockScreenWallpaper else { return }
        do {
            let count = try lockScreenWallpaper.restore()
            if count > 0 { NSLog("FlipWall: restored %d desktop wallpaper entries", count) }
        } catch {
            NSLog("FlipWall: could not restore desktop wallpaper: %@", error.localizedDescription)
            if retry, case LockScreenWallpaper.Failure.changedDuringWrite = error {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    if (CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool != true {
                        self?.restoreLockWallpaper(retry: false)
                    }
                }
            }
        }
    }

    func prepareResources() throws {
        guard let resource = Bundle.main.resourceURL else { throw NSError(domain:"FlipWall",code:2) }
        let fm = FileManager.default
        for name in ["index.html", "wallpaper.js"] {
            try Data(contentsOf: resource.appendingPathComponent(name)).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        if !fm.fileExists(atPath: directory.appendingPathComponent("channels.json").path) {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]
            try encoder.encode(FeedUpdater.defaultChannels).write(to: directory.appendingPathComponent("channels.json"), options: .atomic)
        }
    }

    private var globallyPaused: Bool {
        settings.paused || sleeping || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func preference(for key: String) -> DisplaySettings {
        displaySettings[key] ?? DisplaySettings()
    }

    func effectiveSettings(for key: String) -> Settings {
        let display = preference(for:key)
        var config = settings
        config.paused = globallyPaused || display.paused
        if let brightness = display.brightness { config.brightness = min(1,max(0.25,brightness)) }
        if let columns = display.columns { config.columns = min(8,max(3,columns)) }
        config.epoch = animationEpoch
        return config
    }

    func rebuildScreens(refreshLibrary: Bool = false) {
        let screens = NSScreen.screens
        guard !screens.isEmpty, !videos.isEmpty else { return }
        var previous = wallpapers
        wallpapers = screens.enumerated().compactMap { index, screen in
            let key = Wallpaper.key(for:screen)
            guard preference(for:key).enabled else { return nil }
            let config = effectiveSettings(for:key)
            let pool = partition(index, screens:screens)
            if let existing = previous.firstIndex(where: { $0.displayID == Wallpaper.id(for:screen) }) {
                let wallpaper = previous.remove(at:existing)
                wallpaper.updateFrame(for:screen)
                if wallpaper.config != config { wallpaper.config = config; wallpaper.apply() }
                if refreshLibrary || wallpaper.videos.map(\.id) != pool.map(\.id) { wallpaper.supply(pool) }
                return wallpaper
            }
            return Wallpaper(screen:screen,directory:directory,videos:pool,config:config)
        }
        previous.forEach { $0.close() }
        updateActivity()
        updateMenu()
    }

    func partition(_ screen: Int, screens: [NSScreen] = NSScreen.screens) -> [Video] {
        let count = max(1,screens.count)
        let required = screens.map { display -> Int in
            // A lower density still uses its original pool, so adjusting this
            // display does not replace the images on another display.
            let columns = max(settings.columns,effectiveSettings(for:Wallpaper.key(for:display)).columns)
            let rows = min(10,max(1,Int((Double(columns) * display.frame.height / display.frame.width * 16 / 9).rounded())))
            return columns * rows + (rows > 1 ? 2 : 1)
        }
        let total = required.reduce(0,+)
        if screen < required.count && total > 0 && videos.count >= total {
            let extra = videos.count - total
            let sizes = required.enumerated().map { index, value in value + extra / count + (index < extra % count ? 1 : 0) }
            let offset = sizes.prefix(screen).reduce(0,+)
            return Array(videos[offset..<(offset + sizes[screen])])
        }
        return videos.enumerated().filter { $0.offset % count == screen }.map { $0.element }
    }

    func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "FlipWall 动态壁纸")
        updateMenu()
    }

    private func handleDesktopClick(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.option, .command, .control, .shift])
        let point = NSEvent.mouseLocation
        if event.type == .leftMouseDown {
            optionClickStart = flags == .option ? point : nil
            return
        }
        defer { optionClickStart = nil }
        guard flags == .option, event.clickCount == 1, let start = optionClickStart,
              hypot(point.x - start.x, point.y - start.y) < 5,
              let wallpaper = wallpapers.first(where: { $0.window.isVisible && $0.window.frame.contains(point) }),
              isWallpaperExposed(wallpaper, at:point) else { return }
        wallpaper.videoURL(at:point) { [weak self, weak wallpaper] url in
            guard let self, let wallpaper, let url, self.isWallpaperExposed(wallpaper, at:point) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private func isWallpaperExposed(_ wallpaper: Wallpaper, at point: CGPoint) -> Bool {
        guard wallpaper.window.isVisible, let mainScreen = NSScreen.screens.first,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] else { return false }
        let location = CGPoint(x:point.x,y:mainScreen.frame.maxY - point.y)
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first?.processIdentifier
        let displayBounds = CGDisplayBounds(wallpaper.displayID)

        for entry in windows {
            if (entry[kCGWindowNumber as String] as? Int) == wallpaper.window.windowNumber { return true }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer >= 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let encoded = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation:encoded), bounds.contains(location) else { continue }
            // Dock owns a display-sized window that doesn't intercept clicks.
            if let dockPID, entry[kCGWindowOwnerPID as String] as? Int32 == dockPID, bounds == displayBounds { continue }
            return false
        }
        return false
    }

    func item(_ title: String, _ action: Selector, _ value: Any? = nil, checked: Bool = false) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; entry.representedObject = value; entry.state = checked ? .on : .off
        return entry
    }

    func updateMenu() {
        guard statusItem != nil else { return }
        let menu = NSMenu()
        let title = NSMenuItem(title: "FlipWall · \(videos.count) 张科技封面", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        let shortcut = NSMenuItem(title:"⌥ + 点击桌面封面打开视频",action:nil,keyEquivalent:"")
        shortcut.isEnabled = false
        menu.addItem(shortcut)
        menu.addItem(.separator())
        menu.addItem(item(settings.paused ? "继续全局播放" : "暂停全部壁纸", #selector(togglePaused)))
        let displays = NSMenuItem(title:"显示器",action:nil,keyEquivalent:"")
        displays.submenu = NSMenu()
        for screen in NSScreen.screens { displays.submenu?.addItem(displayMenu(for:screen)) }
        menu.addItem(displays)
        for (label, entries, action) in [
            ("翻牌节奏", [("舒缓", 6.0), ("标准", Settings.standardInterval), ("轻快", 1.8)], #selector(setInterval(_:))),
            ("默认亮度", [("柔和", 0.55), ("标准", 0.78), ("明亮", 1.0)], #selector(setBrightness(_:)))
        ] {
            let parent = NSMenuItem(title:label, action:nil, keyEquivalent:""); let submenu = NSMenu()
            for (name, value) in entries {
                let current = label == "翻牌节奏" ? settings.interval : settings.brightness
                submenu.addItem(item(name, action, value, checked: abs(current - value) < 0.01))
            }
            parent.submenu = submenu; menu.addItem(parent)
        }
        let density = NSMenuItem(title:"默认卡片密度", action:nil, keyEquivalent:""); let densities = NSMenu()
        for value in [4, 5, 6, 8] { densities.addItem(item("\(value) 列", #selector(setColumns(_:)), value, checked:settings.columns == value)) }
        density.submenu = densities; menu.addItem(density)
        if lockScreenWallpaper != nil {
            menu.addItem(item("动态锁屏（实验性）", #selector(toggleDynamicLockWallpaper), checked: lockWallpaperEnabled))
        }
        menu.addItem(.separator())
        let update = item(refreshing ? "正在更新封面…" : "立即更新封面", #selector(refreshClicked)); update.isEnabled = !refreshing; menu.addItem(update)
        if let lastError = lastError {
            let title = videos.isEmpty ? "暂未获取到封面，稍后重试" : "更新未完成，继续使用缓存"
            let error = NSMenuItem(title: title, action:nil,keyEquivalent:""); error.toolTip = lastError; error.isEnabled = false; menu.addItem(error)
        }
        menu.addItem(item("打开素材与频道配置", #selector(openLibrary)))
        menu.addItem(item("关于与来源", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = item("退出 FlipWall", #selector(quitApp)); quit.keyEquivalent = "q"; menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func displayMenu(for screen: NSScreen) -> NSMenuItem {
        let key = Wallpaper.key(for:screen)
        let config = preference(for:key)
        let title = config.enabled ? screen.localizedName : "\(screen.localizedName)（已关闭）"
        let display = NSMenuItem(title:title,action:nil,keyEquivalent:"")
        let menu = NSMenu()
        display.submenu = menu

        func setting(_ label: String, _ change: DisplayChange, checked: Bool = false) -> NSMenuItem {
            item(label,#selector(changeDisplay(_:)),(key,change),checked:checked)
        }

        menu.addItem(setting("启用动态壁纸",.toggleEnabled,checked:config.enabled))
        menu.addItem(setting("暂停本屏",.togglePaused,checked:config.paused))
        let brightness = NSMenuItem(title:"本屏亮度",action:nil,keyEquivalent:"")
        let brightnessMenu = NSMenu()
        brightness.submenu = brightnessMenu
        brightnessMenu.addItem(setting("使用默认",.brightness(nil),checked:config.brightness == nil))
        for (name, value) in [("柔和",0.55),("标准",0.78),("明亮",1.0)] {
            brightnessMenu.addItem(setting(name,.brightness(value),checked:config.brightness == value))
        }
        menu.addItem(brightness)
        let density = NSMenuItem(title:"本屏卡片密度",action:nil,keyEquivalent:"")
        let densityMenu = NSMenu()
        density.submenu = densityMenu
        densityMenu.addItem(setting("使用默认",.columns(nil),checked:config.columns == nil))
        for columns in [4,5,6,8] {
            densityMenu.addItem(setting("\(columns) 列",.columns(columns),checked:config.columns == columns))
        }
        menu.addItem(density)
        return display
    }

    @objc private func changeDisplay(_ item: NSMenuItem) {
        guard let (key,change) = item.representedObject as? (String,DisplayChange) else { return }
        var config = preference(for:key)
        switch change {
        case .toggleEnabled: config.enabled.toggle()
        case .togglePaused: config.paused.toggle()
        case .brightness(let value): config.brightness = value
        case .columns(let value): config.columns = value
        }
        var saved = displaySettings
        saved[key] = config
        do {
            try JSONEncoder().encode(saved).write(to:displaySettingsURL,options:.atomic)
            displaySettings = saved
            rebuildScreens()
        } catch {
            NSLog("FlipWall: could not save display settings: %@",error.localizedDescription)
        }
    }

    func applySettings(save: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime * 1000
        if globallyPaused {
            if pauseStarted == nil { pauseStarted = now }
        } else if let start = pauseStarted {
            animationEpoch += now - start; pauseStarted = nil
        }
        if save, let data = try? JSONEncoder().encode(settings) { try? data.write(to: directory.appendingPathComponent("settings.json"), options:.atomic) }
        rebuildScreens()
    }

    func updateActivity() {
        if !wallpapers.contains(where:{ !$0.config.paused }) {
            if let activity = activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        } else if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep, reason:"Render desktop wallpaper")
        }
    }
    @objc func togglePaused() { settings.paused.toggle(); applySettings() }
    @objc func setInterval(_ item: NSMenuItem) { if let v = item.representedObject as? Double { settings.interval = v; applySettings() } }
    @objc func setBrightness(_ item: NSMenuItem) { if let v = item.representedObject as? Double { settings.brightness = v; applySettings() } }
    @objc func setColumns(_ item: NSMenuItem) { if let v = item.representedObject as? Int { settings.columns = v; applySettings() } }
    @objc func refreshClicked() { refresh() }
    @objc private func toggleDynamicLockWallpaper() {
        let enable = !lockWallpaperEnabled
        UserDefaults.standard.set(enable, forKey: LockScreenWallpaper.preferenceKey)
        if !enable { restoreLockWallpaper() }
        updateMenu()
    }
    @objc func openLibrary() { NSWorkspace.shared.open(directory) }
    @objc func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let alert = NSAlert(); alert.messageText = "FlipWall \(version)"
        alert.informativeText = "桌面和 FlipWall 屏保使用同一批 YouTube 科技封面，每小时更新一次。断网时使用本地缓存。\n\n封面、视频标题归原视频作者。来源见素材目录 library.json。\n登录启动请运行随附的 Install.command。"
        NSApp.activate(ignoringOtherApps:true); alert.runModal()
    }
    @objc func quitApp() { NSApp.terminate(nil) }

    func writeDiagnostics() {
        let group = DispatchGroup()
        var displays: [[String:Any]] = []
        for wallpaper in wallpapers {
            group.enter()
            wallpaper.webView.evaluateJavaScript("window.flipWall.status()") { value, error in
                var state = (value as? [String:Any]) ?? [:]
                state["windowFrame"] = NSStringFromRect(wallpaper.window.frame)
                state["windowTitle"] = wallpaper.window.title
                state["windowVisible"] = wallpaper.window.isVisible
                state["rendererRestarts"] = wallpaper.rendererRestarts
                state["brightness"] = wallpaper.config.brightness
                state["requestedColumns"] = wallpaper.config.columns
                if let error = error { state["error"] = error.localizedDescription }
                displays.append(state)
                group.leave()
            }
        }
        group.notify(queue:.main) { [weak self] in
            guard let self = self else { return }
            let connected = NSScreen.screens.map { screen in
                let config = self.preference(for:Wallpaper.key(for:screen))
                return ["name":screen.localizedName,"enabled":config.enabled,"paused":config.paused] as [String:Any]
            }
            let report: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"capturedAt":Date().timeIntervalSince1970,
                "displays":displays,"connectedDisplays":connected,"refreshInterval":Self.refreshInterval,
                "nextRefreshAt":self.refreshTimer?.fireDate.timeIntervalSince1970 ?? 0,
                "dynamicLockWallpaper":self.lockScreenWallpaper != nil && self.lockWallpaperEnabled]
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
                try? data.write(to:self.directory.appendingPathComponent("diagnostics.json"),options:.atomic)
            }
        }
    }

    private func scheduleRefresh(retryAfter: TimeInterval? = nil) {
        guard !selfTest, !refreshOnly, !refreshing else { return }
        let last = (try? String(contentsOf:directory.appendingPathComponent("last-refresh.txt"),encoding:.utf8))
            .flatMap { ISO8601DateFormatter().date(from:$0) }
        let elapsed = last.map { max(0,Date().timeIntervalSince($0)) } ?? Self.refreshInterval
        let delay = retryAfter ?? max(15,Self.refreshInterval - elapsed)
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval:delay,repeats:false) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshing = true; lastError = nil; updateMenu()
        let root = directory!
        refreshTask = Task { @MainActor [weak self] in
            do {
                let result = try await FeedUpdater.refresh(directory: root)
                guard let self = self else { return }
                do {
                    try await Task.detached(priority:.utility) { try SaverGallery.publish(result,at:root,force:true) }.value
                } catch {
                    NSLog("FlipWall: retaining previous screen saver gallery: %@",error.localizedDescription)
                }
                self.videos = result
                self.refreshing = false
                self.rebuildScreens(refreshLibrary:true)
                NSLog("FlipWall: refreshed %d images", result.count)
                if self.refreshOnly { print("REFRESH_OK \(result.count)"); NSApp.terminate(nil) }
                self.scheduleRefresh()
            } catch {
                guard let self = self else { return }
                self.refreshing = false; self.lastError = error.localizedDescription; self.updateMenu()
                NSLog("FlipWall: refresh failed, keeping cache: %@", error.localizedDescription)
                if self.refreshOnly { Darwin.exit(2) }
                self.scheduleRefresh(retryAfter:900)
            }
        }
    }

    func runSelfTest() {
        // A real WKWebView test, run against an isolated state directory.
        selfTestSampler = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in
            guard let self = self, let wallpaper = self.wallpapers.first else { return }
            wallpaper.webView.evaluateJavaScript("window.flipWall.status()") { [weak self] value, _ in
                guard let self = self, let status = value as? [String:Any],
                      let transforms = status["transforms"] as? [String] else { return }
                let angles = transforms.compactMap { value -> Double? in
                    guard value.hasPrefix("rotateX("), value.hasSuffix("deg)") else { return nil }
                    return Double(value.dropFirst(8).dropLast(4))
                }
                if angles.contains(where:{ angle in
                    let phase = abs(angle.truncatingRemainder(dividingBy:180))
                    return phase > 15 && phase < 85
                }) { self.observedIntermediateFrame = true }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 5) { [weak self] in self?.checkSelfTest() }
        DispatchQueue.main.asyncAfter(deadline:.now() + 25) { NSLog("SELF_TEST_TIMEOUT"); Darwin.exit(3) }
    }

    func testRendererRecovery() {
        let original = wallpapers.map { $0.window.windowNumber }
        rebuildScreens()
        guard let affected = wallpapers.first, original == wallpapers.map({ $0.window.windowNumber }),
              wallpapers.allSatisfy({ $0.window.isVisible }) else { Darwin.exit(3) }
        affected.webViewWebContentProcessDidTerminate(affected.webView)
        guard !affected.window.isVisible, wallpapers.dropFirst().allSatisfy({ $0.window.isVisible }) else { Darwin.exit(3) }
        DispatchQueue.main.asyncAfter(deadline:.now() + 4) {
            affected.webView.evaluateJavaScript("window.flipWall.status()") { value, _ in
                guard let status = value as? [String:Any], status["loaded"] as? Bool == true,
                      (status["wave"] as? Int ?? 0) > 0, affected.window.isVisible,
                      affected.rendererRestarts == 1, original == self.wallpapers.map({ $0.window.windowNumber }) else {
                    NSLog("SELF_TEST_RECOVERY_FAILED %@",String(describing:value)); Darwin.exit(3)
                }
                print("SELF_TEST_RECOVERY_OK")
                NSApp.terminate(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 11) { Darwin.exit(3) }
    }

    func testVideoLinks() {
        let group = DispatchGroup()
        var matches = 0
        for wallpaper in wallpapers {
            let frame = wallpaper.window.frame
            group.enter()
            wallpaper.videoURL(at:CGPoint(x:frame.minX + 40,y:frame.maxY - 40)) { url in
                if let url, url.host == "www.youtube.com", url.path == "/watch",
                   let id = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first?.value,
                   wallpaper.videos.contains(where:{ $0.id == id }) { matches += 1 }
                group.leave()
            }
        }
        group.notify(queue:.main) {
            guard matches > 0, matches == self.wallpapers.count else { Darwin.exit(3) }
            print("SELF_TEST_VIDEO_LINKS_OK \(matches)")
            NSApp.terminate(nil)
        }
        DispatchQueue.main.asyncAfter(deadline:.now() + 10) { Darwin.exit(3) }
    }

    func testDisplaySettings() {
        let screens = NSScreen.screens
        guard screens.count >= 2, let first = wallpapers.first, let second = wallpapers.dropFirst().first,
              wallpapers.allSatisfy({ $0.window.isVisible }) else { Darwin.exit(3) }
        let secondWindow = second.window.windowNumber
        let secondPool = second.videos.map(\.id)
        let epoch = animationEpoch

        func select(_ title: String, in submenu: String? = nil) {
            let menu = displayMenu(for:screens[0]).submenu
            let target = submenu.flatMap { menu?.item(withTitle:$0)?.submenu } ?? menu
            guard let entry = target?.item(withTitle:title),
                  NSApp.sendAction(#selector(changeDisplay(_:)),to:self,from:entry) else { Darwin.exit(3) }
        }

        select("启用动态壁纸")
        guard !first.window.isVisible, !wallpapers.contains(where:{ $0 === first }),
              second.window.isVisible, second.window.windowNumber == secondWindow,
              second.videos.map(\.id) == secondPool else { Darwin.exit(3) }
        let savedOff = try? JSONDecoder().decode([String:DisplaySettings].self,from:Data(contentsOf:displaySettingsURL))
        guard savedOff?[first.displayKey]?.enabled == false else { Darwin.exit(3) }

        select("启用动态壁纸")
        select("暂停本屏")
        select("柔和",in:"本屏亮度")
        select("4 列",in:"本屏卡片密度")
        DispatchQueue.main.asyncAfter(deadline:.now() + 2) {
            guard let restored = self.wallpapers.first, restored !== first, restored.window.isVisible,
                  restored.config.paused, restored.config.brightness == 0.55, restored.config.columns == 4,
                  !second.config.paused, second.config.brightness == self.settings.brightness,
                  second.config.columns == self.settings.columns, self.animationEpoch == epoch else { Darwin.exit(3) }
            select("暂停本屏")
            let saved = try? JSONDecoder().decode([String:DisplaySettings].self,from:Data(contentsOf:self.displaySettingsURL))
            guard !restored.config.paused, saved?[first.displayKey]?.enabled == true,
                  saved?[first.displayKey]?.paused == false, saved?[first.displayKey]?.columns == 4,
                  second.window.windowNumber == secondWindow, second.videos.map(\.id) == secondPool else { Darwin.exit(3) }
            let allIDs = self.wallpapers.flatMap { $0.videos.map(\.id) }
            guard allIDs.count == Set(allIDs).count else { Darwin.exit(3) }
            print("SELF_TEST_DISPLAY_SETTINGS_OK")
            NSApp.terminate(nil)
        }
    }

    func checkSelfTest() {
        guard let wallpaper = wallpapers.first else { NSLog("NO_DISPLAY"); Darwin.exit(3) }
        for (wallpaper,screen) in zip(wallpapers,NSScreen.screens) {
            guard NSEqualRects(wallpaper.window.frame,screen.frame) else {
                NSLog("DISPLAY_FRAME_MISMATCH %@ %@",NSStringFromRect(wallpaper.window.frame),NSStringFromRect(screen.frame)); Darwin.exit(3)
            }
        }
        let pooledIDs = wallpapers.flatMap { $0.videos.map { $0.id } }
        guard Set(pooledIDs).count == pooledIDs.count else { NSLog("DISPLAY_POOL_OVERLAP"); Darwin.exit(3) }
        wallpaper.webView.evaluateJavaScript("window.flipWall.status()") { [weak self] value, error in
            guard let self = self, let status = value as? [String:Any], status["ready"] as? Bool == true,
                  status["loaded"] as? Bool == true, (status["tiles"] as? Int ?? 0) >= 4,
                  (status["wave"] as? Int ?? 0) > 0, (status["elapsed"] as? Double ?? 0) > 500,
                  self.observedIntermediateFrame else {
                NSLog("SELF_TEST_NOT_READY %@ %@", String(describing:value),String(describing:error)); Darwin.exit(3)
            }
            self.settings.paused = true; self.applySettings(save:false)
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.3) {
                wallpaper.webView.evaluateJavaScript("window.flipWall.status()") { value, _ in
                    guard let paused = value as? [String:Any], paused["paused"] as? Bool == true,
                          let before = paused["elapsed"] as? Double else { Darwin.exit(3) }
                    DispatchQueue.main.asyncAfter(deadline:.now() + 0.5) {
                        wallpaper.webView.evaluateJavaScript("window.flipWall.status()") { value, _ in
                            guard let after = value as? [String:Any], let clock = after["elapsed"] as? Double,
                                  abs(clock - before) < 0.1 else { NSLog("PAUSE_FAILED"); Darwin.exit(3) }
                            self.settings.paused = false; self.applySettings(save:false)
                            let snapshot = WKSnapshotConfiguration(); snapshot.afterScreenUpdates = true
                            wallpaper.webView.takeSnapshot(with:snapshot) { image, error in
                                guard let image = image, let tiff = image.tiffRepresentation,
                                      let bitmap = NSBitmapImageRep(data:tiff),
                                      let png = bitmap.representation(using:.png, properties:[:]) else { NSLog("SNAPSHOT_FAILED"); Darwin.exit(3) }
                                let output = self.argument("--snapshot").map { URL(fileURLWithPath:$0) } ?? self.directory.appendingPathComponent("preview.png")
                                do { try png.write(to:output,options:.atomic) } catch { Darwin.exit(3) }
                                var report = status
                                report["pauseVerified"] = true
                                report["intermediateFlipVerified"] = self.observedIntermediateFrame
                                report["displayFramesVerified"] = true
                                report["disjointDisplayPoolsVerified"] = true
                                report["windows"] = self.wallpapers.map { ["number":$0.window.windowNumber,"level":$0.window.level.rawValue,"visible":$0.window.isVisible,"mouseTransparent":$0.window.ignoresMouseEvents,"frame":NSStringFromRect($0.window.frame)] as [String:Any] }
                                if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),let json = String(data:data,encoding:.utf8) { print("SELF_TEST_OK\n" + json) }
                                NSApp.terminate(nil)
                            }
                        }
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreLockWallpaper(retry: false)
        lockScreenObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        refreshTask?.cancel(); refreshTimer?.invalidate()
        selfTestSampler?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let diagnosticObserver = diagnosticObserver { DistributedNotificationCenter.default().removeObserver(diagnosticObserver) }
        if let activity = activity { ProcessInfo.processInfo.endActivity(activity) }
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        wallpapers.forEach { $0.close() }
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); Darwin.close(lockDescriptor) }
    }
}

if CommandLine.arguments.contains("--restore-desktop-wallpaper") {
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FlipWall", isDirectory: true)
    do {
        try LockScreenWallpaper(directory: directory).restore()
        Darwin.exit(0)
    } catch {
        fputs("FlipWall: \(error.localizedDescription)\n", stderr)
        Darwin.exit(1)
    }
}

if CommandLine.arguments.contains("--diagnose") {
    let start = Date()
    DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.local.flipwall.diagnostics"),object:nil,userInfo:nil,deliverImmediately:true)
    let url = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("FlipWall/diagnostics.json")
    for _ in 0..<50 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath:url.path),
           let modified = attrs[.modificationDate] as? Date, modified >= start,
           let text = try? String(contentsOf:url,encoding:.utf8) { print(text); Darwin.exit(0) }
        Thread.sleep(forTimeInterval:0.1)
    }
    fputs("No diagnostic response from running FlipWall.\n",stderr); Darwin.exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
