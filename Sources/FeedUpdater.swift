import Foundation
import ImageIO
import CryptoKit

struct Video: Codable {
    var id: String
    var title: String
    var channel: String
    var published: String
    var views: Int
    var image: String
    var source: String
}

struct Channel: Codable {
    var name: String
    var id: String
}

private final class YouTubeFeed: NSObject, XMLParserDelegate {
    var videos: [Video] = []
    private var current: Video?
    private var text = ""
    private let source: String
    init(source: String) { self.source = source }
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        text = ""
        if elementName == "entry" {
            current = Video(id: "", title: "", channel: "", published: "", views: 0, image: "", source: source)
        }
        if elementName == "media:statistics" { current?.views = Int(attributes["views"] ?? "0") ?? 0 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "yt:videoId": current?.id = value
        case "title": current?.title = value
        case "name": current?.channel = value
        case "published": current?.published = value
        case "entry":
            if let video = current, video.id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil {
                videos.append(video)
            }
            current = nil
        default: break
        }
        text = ""
    }
}

enum FeedUpdater {
    static let defaultChannels = [
        Channel(name: "Marques Brownlee", id: "UCBJycsmduvYEL83R_U4JriQ"),
        Channel(name: "Fireship", id: "UCsBjURrPoezykLs9EqgamOA"),
        Channel(name: "Two Minute Papers", id: "UCbfYPyITQ-7l4upoX8nvctg"),
        Channel(name: "Linus Tech Tips", id: "UCXuqSBlHAE6Xw-yeJA0Tunw"),
        Channel(name: "Dave2D", id: "UCVYamHliCI9rw1tHR1xbkfw"),
        Channel(name: "Mrwhosetheboss", id: "UCMiJRAwDNSNzuYeN2uWa0pA"),
        Channel(name: "The Verge", id: "UCddiUEpeqJcYeBxX1IVBKvQ"),
        Channel(name: "CNET", id: "UCOmcA3f_RrH6b9NmcNa4tdg"),
        Channel(name: "Matthew Berman", id: "UCawZsQWqfGSbCI5yjkdVkTA"),
        Channel(name: "NVIDIA", id: "UCHuiy8bXnmK5nisYHUd1J5g"),
        Channel(name: "ShortCircuit", id: "UCdBK94H6oZT2Q7l0-b0xmMg"),
        Channel(name: "Google DeepMind", id: "UCP7jMXSY2xbc3KCAE0MHQ-A"),
        Channel(name: "OpenAI", id: "UCXZCJLdBC09xxGZ6gcdrc6A"),
        Channel(name: "Apple", id: "UCE_M8A5yxnLfW0KghEeajjw"),
        Channel(name: "Google", id: "UCK8sQmJBp8GCxrOtXWBpyEA"),
        Channel(name: "Google for Developers", id: "UC_x5XG1OV2P6uZZ5FSM9Ttw"),
        Channel(name: "Microsoft Developer", id: "UCsMica-v34Irf9KVTh6xx-g"),
        Channel(name: "ThePrimeagen", id: "UC8ENHE5xdFSwx71u3fDH5Xw"),
        Channel(name: "NetworkChuck", id: "UC9x0AN7BWHpCDHSm9NiJFJQ"),
        Channel(name: "Hardware Unboxed", id: "UCI8iQa1hv7oV_Z8D35vVuSg"),
        Channel(name: "Gamers Nexus", id: "UChIs72whgZI9w6d6FhwGGHA")
    ]

    static func refresh(directory: URL) async throws -> [Video] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let channelPath = directory.appendingPathComponent("channels.json")
        let channels = (try? JSONDecoder().decode([Channel].self, from: Data(contentsOf: channelPath))) ?? defaultChannels
        var candidates: [Video] = []
        for channel in channels.prefix(24) {
            try Task.checkCancellation()
            guard channel.id.range(of: "^UC[A-Za-z0-9_-]{22}$", options: .regularExpression) != nil else { continue }
            let source = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channel.id)"
            do {
                let (data, response) = try await session.data(from: URL(string: source)!)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else { continue }
                let feed = YouTubeFeed(source: source)
                let parser = XMLParser(data: data)
                parser.shouldResolveExternalEntities = false
                parser.delegate = feed
                guard parser.parse() else { continue }
                // Keep representation from every configured channel.
                candidates += feed.videos.prefix(15)
            } catch is CancellationError { throw CancellationError() }
            catch { NSLog("FlipWall: feed %@ unavailable: %@", channel.name, error.localizedDescription) }
        }
        let formatter = ISO8601DateFormatter()
        let now = Date()
        candidates = candidates.filter {
            guard let date = formatter.date(from: $0.published) else { return false }
            return now.timeIntervalSince(date) >= -3600 && now.timeIntervalSince(date) <= 45 * 86400
        }
        func score(_ video: Video) -> Double {
            let age = now.timeIntervalSince(formatter.date(from: video.published) ?? now) / 86400
            return Double(max(1, video.views)) / max(1, age)
        }
        candidates.sort { score($0) > score($1) }
        var seen: Set<String> = []
        candidates = candidates.filter { seen.insert($0.id).inserted }
        // Round-robin by channel so large channels cannot fill the pool.
        var order: [String] = []
        var groups: [String: [Video]] = [:]
        for video in candidates {
            if groups[video.channel] == nil { order.append(video.channel); groups[video.channel] = [] }
            if groups[video.channel]!.count < 8 { groups[video.channel]!.append(video) }
        }
        candidates = []
        for round in 0..<8 {
            for channel in order {
                if let group = groups[channel], round < group.count { candidates.append(group[round]) }
            }
        }
        var result: [Video] = []
        var fingerprints: Set<String> = []
        let images = directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        for var video in candidates.prefix(96) {
            try Task.checkCancellation()
            let destination = images.appendingPathComponent(video.id + ".jpg")
            if !FileManager.default.fileExists(atPath: destination.path) {
                for quality in ["maxresdefault", "hqdefault"] {
                    do {
                        let url = URL(string: "https://i.ytimg.com/vi/\(video.id)/\(quality).jpg")!
                        let (data, response) = try await session.data(from: url)
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                              response.mimeType?.hasPrefix("image/") == true,
                              data.count >= 4000, data.count <= 5_000_000,
                              data.starts(with: [0xff, 0xd8, 0xff]) else { continue }
                        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                              let width = properties[kCGImagePropertyPixelWidth] as? Int,
                              let height = properties[kCGImagePropertyPixelHeight] as? Int,
                              width >= 320, height >= 180 else { continue }
                        try data.write(to: destination, options: .atomic)
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch { continue }
                }
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                if let data = try? Data(contentsOf:destination) {
                    let fingerprint = SHA256.hash(data:data).description
                    guard fingerprints.insert(fingerprint).inserted else { continue }
                }
                video.image = "images/" + video.id + ".jpg"
                result.append(video)
            }
        }
        guard result.count >= 6 else {
            throw NSError(domain: "FlipWall", code: 1, userInfo: [NSLocalizedDescriptionKey: "可用新封面不足 6 张，保留原有素材。"])
        }
        let libraryPath = directory.appendingPathComponent("library.json")
        let previous = (try? JSONDecoder().decode([Video].self, from: Data(contentsOf: libraryPath))) ?? []
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: libraryPath, options: .atomic)
        try Data(ISO8601DateFormatter().string(from: Date()).utf8).write(to: directory.appendingPathComponent("last-refresh.txt"), options: .atomic)
        // Retain the previous generation while the running collage turns over.
        let keep = Set((result + previous).map { $0.id + ".jpg" })
        for url in (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "jpg" && !keep.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
        return result
    }
}
