import CoreGraphics
import CoreText
import Foundation

/// Turns characters into ribbon-ink impressions: thickened, rough-edged and unevenly dark,
/// the way a cloth ribbon leaves them. Each character gets a few variants so that no two
/// neighbouring letters look stamped from the same die.
final class GlyphCache {
    struct Glyph {
        let image: CGImage
        let wide: Bool
        /// Pixel size of the image.
        let width: Int
        let height: Int
    }

    private struct Key: Hashable {
        let s: String
        let ink: UInt8
        let variant: UInt8
    }

    static let variants: UInt8 = 3
    static let inkColors: [SIMD3<Float>] = [
        SIMD3(0.082, 0.072, 0.094),   // black ribbon
        SIMD3(0.640, 0.105, 0.085),   // red ribbon
    ]

    let layout: Layout
    /// Blank border around each glyph image, in points, so ink can spread past its cell.
    let pad: CGFloat
    private let latin: CTFont
    private let cjk: CTFont
    private var cache: [Key: Glyph] = [:]

    init(layout: Layout, latinFont: String, cjkFont: String) {
        self.layout = layout
        pad = (7 * layout.zoom * layout.ps).rounded() / layout.ps
        latin = CTFontCreateWithName(latinFont as CFString, layout.fontSize, nil)
        cjk = CTFontCreateWithName(cjkFont as CFString, layout.fontSize * 1.07, nil)
    }

    func glyph(_ s: String, ink: UInt8, variant: UInt8) -> Glyph {
        let key = Key(s: s, ink: min(ink, 1), variant: variant % GlyphCache.variants)
        if let g = cache[key] { return g }
        let g = rasterize(key)
        cache[key] = g
        return g
    }

    private func rasterize(_ key: Key) -> Glyph {
        let ps = layout.ps
        let wide = Grid.width(of: key.s) == 2
        let wPts = (wide ? 2 : 1) * layout.cellW + 2 * pad
        let hPts = layout.lineH + 2 * pad
        let w = max(2, Int((wPts * ps).rounded()))
        let h = max(2, Int((hPts * ps).rounded()))

        // 1. Coverage: the clean letterform, thickened with a round-jointed stroke.
        var cov = [UInt8](repeating: 0, count: w * h)
        cov.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.scaleBy(x: ps, y: ps)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            let white = CGColor(gray: 1, alpha: 1)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): wide ? cjk : latin,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): white,
                // Negative = fill and stroke, as a percentage of the point size.
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): wide ? -4.2 : -5.2,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: key.s, attributes: attrs))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: (wPts - advance) / 2, y: pad + layout.lineH - layout.baselineDrop)
            CTLineDraw(line, ctx)
        }

        // 2. A slight blur, as ink wicks into the paper.
        var soft = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                var wsum: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w { continue }
                        let k: Float = (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1)
                        sum += Float(cov[yy * w + xx]) * k
                        wsum += k
                    }
                }
                soft[y * w + x] = sum / (wsum * 255)
            }
        }

        // 3. Rough edges and uneven density from the weave of the ribbon.
        var seedHash: UInt64 = UInt64(key.variant) &* 7919 &+ UInt64(key.ink) &* 104729
        for u in key.s.unicodeScalars { seedHash = seedHash &* 31 &+ UInt64(u.value) }
        var rng = SplitMix(seedHash)
        let ox = Float(rng.unit() * 500), oy = Float(rng.unit() * 500)
        // A strike is rarely square to the paper: one side prints a little fainter.
        let tiltX = Float(rng.signed()) * 0.10, tiltY = Float(rng.signed()) * 0.12
        let fine = Float(1.0 / (1.25 * ps))      // grain about 1.25 pt across
        let blotch = Float(1.0 / (5.5 * ps))
        let ink = GlyphCache.inkColors[Int(key.ink)]
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let fy = Float(y)
            let ny = (fy / Float(h) - 0.5) * 2
            for x in 0..<w {
                let v = soft[y * w + x]
                if v < 0.02 { continue }
                let fx = Float(x)
                let nx = (fx / Float(w) - 0.5) * 2
                let n1 = GlyphCache.valueNoise(fx * fine + ox, fy * fine + oy)
                let n2 = GlyphCache.valueNoise(fx * blotch + ox * 0.3, fy * blotch + oy * 0.3)
                let n3 = GlyphCache.hash(UInt32(x), UInt32(y), UInt32(truncatingIfNeeded: seedHash))
                var a = GlyphCache.smooth(0.34, 0.62, v + (n1 - 0.5) * 0.30 + (n3 - 0.5) * 0.10)
                a *= 0.78 + 0.22 * n2
                a *= 0.94 + 0.06 * n3
                a *= 1 - max(0, nx * tiltX + ny * tiltY)
                a = max(0, min(1, a))
                let i = (y * w + x) * 4
                out[i] = UInt8(ink.x * a * 255 + 0.5)
                out[i + 1] = UInt8(ink.y * a * 255 + 0.5)
                out[i + 2] = UInt8(ink.z * a * 255 + 0.5)
                out[i + 3] = UInt8(a * 255 + 0.5)
            }
        }

        let provider = CGDataProvider(data: Data(out) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return Glyph(image: image, wide: wide, width: w, height: h)
    }

    // MARK: - Noise

    static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    static func hash(_ x: UInt32, _ y: UInt32, _ seed: UInt32) -> Float {
        var h = x &* 374761393 &+ y &* 668265263 &+ seed &* 2246822519
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0x1000000)
    }

    static func valueNoise(_ x: Float, _ y: Float) -> Float {
        let xi = floor(x), yi = floor(y)
        var fx = x - xi, fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let ix = UInt32(truncatingIfNeeded: Int(xi)), iy = UInt32(truncatingIfNeeded: Int(yi))
        let a = hash(ix, iy, 1), b = hash(ix &+ 1, iy, 1)
        let c = hash(ix, iy &+ 1, 1), d = hash(ix &+ 1, iy &+ 1, 1)
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }
}

/// Draws one row of strikes into a bitmap. Rows are re-rendered whole whenever they change,
/// which makes overtyping, striking out and lifting ink off fall out naturally.
final class LineRenderer {
    let layout: Layout
    let glyphs: GlyphCache
    private let ctx: CGContext
    private let pw: Int
    private let ph: Int

    init(layout: Layout, glyphs: GlyphCache) {
        self.layout = layout
        self.glyphs = glyphs
        pw = max(2, Int((layout.rowSize.width * layout.ps).rounded()))
        ph = max(2, Int((layout.rowSize.height * layout.ps).rounded()))
        ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
    }

    /// Where and how one strike sits on its row: every strike is a little off-square and a
    /// little lighter or darker than its neighbours, decided once by its seed.
    struct Placement {
        let glyph: GlyphCache.Glyph
        /// Centre of the glyph image in the row bitmap, in pixels from its bottom-left corner.
        let centre: CGPoint
        let rotation: CGFloat
        let alpha: CGFloat
        /// Left edge of the strike's cell, in points.
        let cellX: CGFloat
        /// The generator, positioned after the values above, for anything else that must vary.
        var rng: SplitMix
    }

    func placement(of st: Strike) -> Placement {
        let ps = layout.ps
        let zoom = layout.zoom
        var rng = SplitMix(UInt64(st.s) &* 2654435761 &+ UInt64(st.x))
        let variant = UInt8(rng.next() % UInt64(GlyphCache.variants))
        let g = glyphs.glyph(st.c, ink: st.k, variant: variant)
        let dx = rng.signed() * 0.55 * zoom
        let dy = rng.signed() * 0.80 * zoom
        let rot = rng.signed() * (g.wide ? 0.007 : 0.016)
        let alpha = 0.66 + 0.34 * CGFloat(st.p) / 255
        let cellX = layout.rowPadX + CGFloat(st.x) * layout.cellW
        let cx = (cellX - glyphs.pad + dx) * ps + CGFloat(g.width) / 2
        let cy = (layout.rowPadY - glyphs.pad + dy) * ps + CGFloat(g.height) / 2
        return Placement(glyph: g, centre: CGPoint(x: cx, y: cy), rotation: rot, alpha: alpha, cellX: cellX, rng: rng)
    }

    /// Returns nil when there is no ink on the row yet. Ink lifted by the correction tape is
    /// not drawn here; the scene shows its trace fading away separately.
    func render(_ strikes: [Strike], now: Double) -> CGImage? {
        var any = false
        let ps = layout.ps
        let zoom = layout.zoom
        ctx.clear(CGRect(x: 0, y: 0, width: pw, height: ph))
        for st in strikes where st.land <= now && st.d != 2 {
            any = true
            let placed = placement(of: st)
            let g = placed.glyph
            var rng = placed.rng
            let cellX = placed.cellX
            ctx.saveGState()
            ctx.translateBy(x: placed.centre.x, y: placed.centre.y)
            ctx.rotate(by: placed.rotation)
            ctx.setAlpha(placed.alpha)
            ctx.draw(g.image, in: CGRect(x: -CGFloat(g.width) / 2, y: -CGFloat(g.height) / 2,
                                         width: CGFloat(g.width), height: CGFloat(g.height)))
            ctx.restoreGState()

            if st.d == 1 {
                // Struck out: a hyphen hammered over the character.
                let ink = GlyphCache.inkColors[Int(min(st.k, 1))]
                let cells = CGFloat(g.wide ? 2 : 1)
                let y = (layout.rowPadY + layout.lineH - layout.baselineDrop + layout.fontSize * 0.23 + rng.signed() * 0.4 * zoom) * ps
                let x0 = (cellX - 1.2 * zoom) * ps
                let x1 = (cellX + cells * layout.cellW + 1.2 * zoom) * ps
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           components: [CGFloat(ink.x), CGFloat(ink.y), CGFloat(ink.z), 0.86])!)
                ctx.setLineWidth(1.7 * zoom * ps)
                ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: x0, y: y + rng.signed() * 0.5 * zoom * ps))
                ctx.addLine(to: CGPoint(x: x1, y: y + rng.signed() * 0.5 * zoom * ps))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        return any ? ctx.makeImage() : nil
    }
}
