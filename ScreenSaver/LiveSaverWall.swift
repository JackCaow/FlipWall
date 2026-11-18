import AppKit
import ImageIO
import QuartzCore

final class LiveSaverWall {
    struct Cover {
        let id: String
        let channel: String
        let image: CGImage
    }

    private struct Tile {
        var cover: Cover
        let layer: CALayer
    }

    private struct Flip {
        let upper: Int
        let lower: Int?
        let newUpper: Cover
        let newLower: Cover?
        let started: TimeInterval
        let region: CGRect
        let buffer: CGContext
    }

    private static let interval: TimeInterval = 3
    private static let duration: TimeInterval = 1.25
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let background = CGColor(srgbRed: 0.047, green: 0.047, blue: 0.047, alpha: 1)
    private let tilesLayer = CALayer()
    private let flap = CALayer()
    private let gap: CGFloat = 10
    private var covers: [Cover]
    private var tiles: [Tile] = []
    private var columns = 5
    private var lastSlot: Int?
    private var flip: Flip?
    let layer = CALayer()

    init(covers: [Cover]) {
        self.covers = covers
        layer.isOpaque = true
        layer.masksToBounds = true
        layer.backgroundColor = Self.background
        layer.addSublayer(tilesLayer)
        flap.isOpaque = true
        flap.isHidden = true
        layer.addSublayer(flap)
    }

    static func decode(_ gallery: SaverGallery) -> [Cover] {
        gallery.covers.compactMap { cover in
            guard let source = CGImageSourceCreateWithData(cover.jpeg as CFData,nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                    kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,
                    kCGImageSourceShouldCacheImmediately:true,
                    kCGImageSourceThumbnailMaxPixelSize:640
                  ] as CFDictionary),
                  let context = bitmap(width: image.width, height: image.height) else { return nil }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.draw(image, in: bounds)
            context.setFillColor(gray: 0, alpha: 0.22)
            context.fill(bounds)
            guard let sdr = context.makeImage() else { return nil }
            return Cover(id:cover.id,channel:cover.channel,image:sdr)
        }
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    func layout(in bounds: CGRect) {
        guard bounds.width > 0, bounds.height > 0, layer.frame != bounds || tiles.isEmpty else { return }
        withoutAnimations {
            layer.frame = bounds
            tilesLayer.frame = layer.bounds
            buildTiles()
        }
    }

    private func buildTiles() {
        flip = nil
        flap.isHidden = true
        flap.contents = nil
        tilesLayer.sublayers = nil
        let width = tilesLayer.bounds.width
        let height = tilesLayer.bounds.height
        func rowCount(_ columns: Int) -> Int {
            max(1,min(10,Int((Double(columns) * height / width * 16 / 9).rounded())))
        }
        columns = 5
        while columns > 1 && columns * rowCount(columns) + 2 > covers.count { columns -= 1 }
        let rows = min(rowCount(columns),max(1,(covers.count - 2) / columns))
        let inset = min(CGFloat(10),width * 0.03,height * 0.03)
        let spacing = min(gap,width / CGFloat(columns * 3),height / CGFloat(rows * 3))
        let tileWidth = (width - 2 * inset - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let tileHeight = (height - 2 * inset - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        var available = covers
        var usedChannels: [String:Int] = [:]
        tiles = (0..<(columns * rows)).map { index in
            let best = available.indices.min {
                (usedChannels[available[$0].channel] ?? 0) < (usedChannels[available[$1].channel] ?? 0)
            }!
            let cover = available.remove(at:best)
            usedChannels[cover.channel,default:0] += 1
            let tile = CALayer()
            tile.contentsGravity = .resizeAspectFill
            tile.masksToBounds = true
            tile.frame = CGRect(x:inset + CGFloat(index % columns) * (tileWidth + spacing),
                                y:height - inset - tileHeight - CGFloat(index / columns) * (tileHeight + spacing),
                                width:tileWidth,height:tileHeight)
            tile.contents = cover.image
            tilesLayer.addSublayer(tile)
            return Tile(cover:cover,layer:tile)
        }
    }

    private func beginFlip(slot: Int, start: TimeInterval) {
        let upper = slot % tiles.count
        let lower = upper + columns < tiles.count ? upper + columns : nil
        let visible = Set(tiles.map { $0.cover.id })
        let choices = covers.filter { !visible.contains($0.id) }.shuffled()
        guard choices.count >= (lower == nil ? 1 : 2) else { return }

        let upperFrame = tiles[upper].layer.frame
        let region = lower.map { upperFrame.union(tiles[$0].layer.frame) } ?? upperFrame
        let scale = min(2, 960 / region.width)
        guard let buffer = Self.bitmap(width: max(1, Int((region.width * scale).rounded())),
                                       height: max(1, Int((region.height * scale).rounded()))) else { return }
        buffer.scaleBy(x: CGFloat(buffer.width) / region.width, y: CGFloat(buffer.height) / region.height)
        buffer.interpolationQuality = .medium
        flap.frame = region
        flip = Flip(upper:upper,lower:lower,newUpper:choices[0],
                    newLower:lower == nil ? nil : choices[1],started:start,region:region,buffer:buffer)
    }

    func advance(now: TimeInterval) {
        guard !tiles.isEmpty else { return }
        let slot = Int(now / Self.interval)
        let start = Double(slot) * Self.interval
        if flip == nil && slot == lastSlot { return }
        withoutAnimations {
            if let current = flip {
                let progress = min(1,max(0,(now - current.started) / Self.duration))
                let rotation = 180 * progress * progress * (3 - 2 * progress)
                if progress == 1 || (current.lower == nil && rotation >= 90) {
                    finish(current)
                } else {
                    render(current, rotation: rotation)
                }
            }
            if flip == nil && lastSlot != slot {
                lastSlot = slot
                if now - start < 0.2 {
                    beginFlip(slot:slot,start:start)
                    if let flip { render(flip, rotation: 0) }
                }
            }
        }
    }

    private func finish(_ current: Flip) {
        tiles[current.upper].cover = current.newUpper
        tiles[current.upper].layer.contents = current.newUpper.image
        if let lower = current.lower, let next = current.newLower {
            tiles[lower].cover = next
            tiles[lower].layer.contents = next.image
        }
        flap.isHidden = true
        flap.contents = nil
        flip = nil
    }

    private func render(_ current: Flip, rotation: Double) {
        let context = current.buffer
        let region = current.region
        let upper = tiles[current.upper].layer.frame.offsetBy(dx: -region.minX, dy: -region.minY)
        let lower = current.lower.map { tiles[$0].layer.frame.offsetBy(dx: -region.minX, dy: -region.minY) }
        context.setFillColor(Self.background)
        context.fill(CGRect(origin: .zero, size: region.size))
        draw(current.newUpper.image, in: upper, context: context)
        if let index = current.lower, let lower {
            draw(tiles[index].cover.image, in: lower, context: context)
        }
        let hinge = lower.map { (upper.minY + $0.maxY) / 2 } ?? upper.minY
        if rotation < 90 {
            drawSheet(tiles[current.upper].cover.image, in: upper, hinge: hinge,
                      angle: rotation, aboveHinge: true, context: context)
        } else if let cover = current.newLower, let lower {
            drawSheet(cover.image, in: lower, hinge: hinge,
                      angle: 180 - rotation, aboveHinge: false, context: context)
        }
        flap.contents = context.makeImage()
        flap.isHidden = false
    }

    private func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let destination = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                 width: size.width, height: size.height)
        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: destination)
        context.restoreGState()
    }

    private func drawSheet(_ image: CGImage, in rect: CGRect, hinge: CGFloat, angle: Double,
                           aboveHinge: Bool, context: CGContext) {
        if angle == 0 {
            draw(image, in: rect, context: context)
            return
        }
        let radians = angle * .pi / 180
        let direction: CGFloat = aboveHinge ? 1 : -1
        let restingEdge = aboveHinge ? rect.minY : rect.maxY
        let edge = restingEdge + (hinge - restingEdge) * sin(radians)
        let foreshortening = cos(radians)
        let perspective = sin(radians) * rect.height / max(480, layer.bounds.height * 1.5)
        // Draw the perspective in horizontal strips, all inside the two-card
        // SDR buffer. The system host never composites a moving window layer.
        let stripCount = 16
        for band in 0..<stripCount {
            let start = CGFloat(band) / CGFloat(stripCount)
            let end = CGFloat(band + 1) / CGFloat(stripCount)
            let widthScale = 1 / (1 - perspective * (start + end) / 2)
            let near = edge + direction * rect.height * start * foreshortening / (1 - perspective * start)
            let far = edge + direction * rect.height * end * foreshortening / (1 - perspective * end)
            let height = abs(far - near)
            guard height > 0.02 else { continue }
            let projectedHeight = height * CGFloat(stripCount)
            let stripBottom = min(near, far)
            let sourceBand = aboveHinge ? band : stripCount - 1 - band
            context.saveGState()
            context.clip(to: CGRect(x: rect.minX, y: stripBottom - 0.5,
                                    width: rect.width, height: height + 1))
            context.translateBy(x: rect.midX, y: stripBottom - height * CGFloat(sourceBand))
            context.scaleBy(x: widthScale, y: projectedHeight / rect.height)
            draw(image, in: CGRect(x: -rect.width / 2, y: 0, width: rect.width, height: rect.height),
                 context: context)
            context.restoreGState()
        }
    }

    private func withoutAnimations(_ update: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        update()
        CATransaction.commit()
    }
}
