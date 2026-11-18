import Foundation

struct SaverGallery: Codable {
    struct Cover: Codable {
        let id: String
        let channel: String
        let jpeg: Data
    }

    static let filename = "screen-saver-gallery.plist"
    let covers: [Cover]
}

#if FLIPWALL_DESKTOP
extension SaverGallery {
    static func publish(_ videos: [Video], at directory: URL, force: Bool = false) throws {
        let target = directory.appendingPathComponent(filename)
        let library = directory.appendingPathComponent("library.json")
        if !force,
           let published = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           let source = try? library.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           published >= source { return }

        var ids = Set<String>()
        let covers = videos.compactMap { video -> Cover? in
            guard ids.insert(video.id).inserted,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(video.image)),
                  data.starts(with: [0xff, 0xd8, 0xff]) else { return nil }
            return Cover(id: video.id, channel: video.channel, jpeg: data)
        }
        guard covers.count >= 6 else {
            throw NSError(domain:"FlipWall.SaverGallery",code:1,
                          userInfo:[NSLocalizedDescriptionKey:"可用屏保封面不足 6 张"])
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(Self(covers:covers)).write(to:target,options:.atomic)
    }
}
#endif
