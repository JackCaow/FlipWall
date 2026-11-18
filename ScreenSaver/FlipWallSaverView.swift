import AppKit
import AVFoundation
import Darwin
import OSLog
import ScreenSaver

@objc(FlipWallSaverView)
final class FlipWallSaverView: ScreenSaverView {
    private static let logger = Logger(subsystem:"com.local.flipwall.saver",category:"gallery")
    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var wall: LiveSaverWall?
    private var loadedVersion: Date?
    private var lastCheck: TimeInterval = -.infinity
    private var generation = 0
    private var loading = false
    private var running = false
    private var reportedAnimation = false
    private var reportedReadFailure = false
    private let galleryQueue = DispatchQueue(label:"com.local.flipwall.saver.gallery",qos:.utility)

    override var isOpaque: Bool { true }

    private static let galleryURL: URL? = {
        let library = Bundle(for:FlipWallSaverView.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
        if library.lastPathComponent == "Library", library.path != "/Library" {
            return library.appendingPathComponent("Application Support/FlipWall",isDirectory:true)
                .appendingPathComponent(SaverGallery.filename)
        }
        // The system host redirects NSHomeDirectory to its sandbox container.
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath:String(cString:home),isDirectory:true)
            .appendingPathComponent("Library/Application Support/FlipWall",isDirectory:true)
            .appendingPathComponent(SaverGallery.filename)
    }()

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspectFill
        if let url = Bundle(for: Self.self).url(forResource: "Poster", withExtension: "jpg"),
           let poster = NSImage(contentsOf: url) {
            layer?.contents = poster
        }
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        animationTimeInterval = 1.0 / 30.0
        checkGallery(now:ProcessInfo.processInfo.systemUptime)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        wall?.layout(in:bounds)
    }

    override func startAnimation() {
        guard !running else { return }
        super.startAnimation()
        running = true
        lastCheck = -.infinity
        if wall == nil { startFallback() }
        checkGallery(now:ProcessInfo.processInfo.systemUptime)
    }

    private func startFallback() {
        guard player == nil,
              let video = Bundle(for: Self.self).url(forResource: "Loop", withExtension: "mp4") else { return }
        let queue = AVQueuePlayer()
        playerLayer.isHidden = false
        queue.isMuted = true
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: video))
        player = queue
        playerLayer.player = queue
        queue.play()
    }

    override func animateOneFrame() {
        guard running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        wall?.advance(now:now)
        if wall != nil, !reportedAnimation {
            reportedAnimation = true
            Self.logger.notice("Animating the live gallery, preview=\(self.isPreview,privacy:.public)")
        }
        checkGallery(now:now)
    }

    private func checkGallery(now: TimeInterval) {
        guard !loading, now - lastCheck >= 10, let url = Self.galleryURL else { return }
        lastCheck = now
        loading = true
        let token = generation
        let currentVersion = loadedVersion
        galleryQueue.async { [weak self] in
            let result = Result { () throws -> (Date, [LiveSaverWall.Cover])? in
                let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
                guard let version = attributes[.modificationDate] as? Date,
                      version != currentVersion else { return nil }
                let data = try Data(contentsOf:url)
                let gallery = try PropertyListDecoder().decode(SaverGallery.self,from:data)
                return (version,LiveSaverWall.decode(gallery))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.loading = false
                if case .failure(let error) = result, !self.reportedReadFailure {
                    Self.logger.error("Could not read shared gallery: \(error.localizedDescription,privacy:.public)")
                    self.reportedReadFailure = true
                }
                guard case .success(let loaded?) = result, loaded.1.count >= 6 else { return }
                let (version,covers) = loaded
                self.reportedReadFailure = false
                let next = LiveSaverWall(covers:covers)
                next.layout(in:self.bounds)
                self.layer?.addSublayer(next.layer)
                self.wall?.layer.removeFromSuperlayer()
                self.wall = next
                self.loadedVersion = version
                self.stopFallback()
                Self.logger.notice("Loaded \(covers.count,privacy:.public) shared covers from \(version.description,privacy:.public)")
            }
        }
    }

    private func stopFallback() {
        player?.pause()
        playerLayer.player = nil
        playerLayer.isHidden = true
        looper?.disableLooping()
        looper = nil
        player = nil
    }

    override func stopAnimation() {
        running = false
        reportedAnimation = false
        generation += 1
        loading = false
        loadedVersion = nil
        wall?.layer.removeFromSuperlayer()
        wall = nil
        stopFallback()
        super.stopAnimation()
    }
}
