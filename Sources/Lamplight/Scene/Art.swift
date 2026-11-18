import SpriteKit
import CoreGraphics
import CoreText

/// Everything on screen is drawn here at launch; the app ships no image files.
/// Colours are the surfaces as they would look fully lit — the light map darkens them.
enum Art {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: srgb, components: [r, g, b, a])!
    }

    static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
        CGGradient(colorsSpace: srgb, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
    }

    /// Draws into a bitmap with a y-up coordinate system measured in points.
    static func image(size: CGSize, scale: CGFloat, _ draw: (CGContext, CGSize) -> Void) -> CGImage {
        let w = max(1, Int((size.width * scale).rounded(.up)))
        let h = max(1, Int((size.height * scale).rounded(.up)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx, size)
        return ctx.makeImage()!
    }

    static func texture(size: CGSize, scale: CGFloat, _ draw: (CGContext, CGSize) -> Void) -> SKTexture {
        SKTexture(cgImage: image(size: size, scale: scale, draw))
    }

    /// Builds an image pixel by pixel. `f` gets u (left→right) and v (bottom→top) in 0...1
    /// and returns straight (not premultiplied) RGBA.
    static func procedural(width: Int, height: Int, _ f: (Float, Float) -> SIMD4<Float>) -> CGImage {
        let w = max(1, width), h = max(1, height)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let v = 1 - (Float(y) + 0.5) / Float(h)
            for x in 0..<w {
                let u = (Float(x) + 0.5) / Float(w)
                let c = f(u, v)
                let a = max(0, min(1, c.w))
                let i = (y * w + x) * 4
                data[i] = UInt8(max(0, min(1, c.x)) * a * 255 + 0.5)
                data[i + 1] = UInt8(max(0, min(1, c.y)) * a * 255 + 0.5)
                data[i + 2] = UInt8(max(0, min(1, c.z)) * a * 255 + 0.5)
                data[i + 3] = UInt8(a * 255 + 0.5)
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: srgb, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }

    static func proceduralTexture(width: Int, height: Int, _ f: (Float, Float) -> SIMD4<Float>) -> SKTexture {
        SKTexture(cgImage: procedural(width: width, height: height, f))
    }

    private static func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Machine parts

    /// A steel rod seen from the side. One texture column, stretched across the window.
    static func rail() -> SKTexture {
        proceduralTexture(width: 2, height: 48) { _, v in
            let hi = exp(-pow((v - 0.72) / 0.085, 2))
            let body = 0.10 + 0.24 * exp(-pow((v - 0.60) / 0.30, 2))
            let low = 0.10 * exp(-pow((v - 0.16) / 0.10, 2))
            let c = body + 0.62 * hi + low
            let edge = smooth(0, 0.07, v) * smooth(0, 0.07, 1 - v)
            return SIMD4(c * 0.98, c, c * 1.03, edge)
        }
    }

    /// The rubber roller behind the paper.
    static func platen() -> SKTexture {
        proceduralTexture(width: 2, height: 96) { _, v in
            let band = exp(-pow((v - 0.70) / 0.16, 2))
            let c = 0.040 + 0.085 * band + 0.02 * exp(-pow((v - 0.22) / 0.2, 2))
            return SIMD4(c, c, c * 1.04, 1)
        }
    }

    /// The bevelled front edge of the deck.
    static func deckEdge() -> SKTexture {
        proceduralTexture(width: 2, height: 32) { _, v in
            let lip = exp(-pow((v - 0.90) / 0.06, 2))
            let c = 0.070 + 0.30 * lip + 0.05 * v
            return SIMD4(c, c * 1.01, c * 1.02, 1)
        }
    }

    /// A horizontal fall-off from black to clear, for the shadow the paper casts beside itself.
    static func edgeShadow(flipped: Bool) -> SKTexture {
        proceduralTexture(width: 32, height: 2) { u, _ in
            let t = flipped ? 1 - u : u
            return SIMD4(0, 0, 0, 0.55 * t * t)
        }
    }

    /// A soft round blob. Used black for shadows and warm for glows.
    static func blob(_ r: Float, _ g: Float, _ b: Float, sharpness: Float = 2.4) -> SKTexture {
        proceduralTexture(width: 96, height: 96) { u, v in
            let d = sqrt(pow(u - 0.5, 2) + pow(v - 0.5, 2)) * 2
            let a = exp(-d * d * sharpness) * smooth(1.0, 0.82, d)
            return SIMD4(r, g, b, a)
        }
    }

    /// The glowing slit of the lamp along the top of the carriage.
    static func slotGlow() -> SKTexture {
        proceduralTexture(width: 192, height: 64) { u, v in
            let x = (u - 0.5) * 2
            let y = (v - 0.32) * 2
            let core = exp(-pow(y / 0.085, 2)) * smooth(1.0, 0.72, abs(x) * 1.18)
            let halo = exp(-(x * x * 1.6 + y * y * 5.5)) * 0.38
            let a = min(1, core + halo)
            return SIMD4(1.0, 0.86 + 0.10 * core, 0.58 + 0.30 * core, a)
        }
    }

    /// The carriage that rides the rail and carries the lamp.
    static func housing(z: CGFloat, ps: CGFloat) -> (texture: SKTexture, size: CGSize) {
        let size = CGSize(width: 176 * z, height: 54 * z)
        let tex = texture(size: size, scale: ps) { ctx, s in
            let rect = CGRect(origin: .zero, size: s).insetBy(dx: z, dy: z)
            let body = CGPath(roundedRect: rect, cornerWidth: 12 * z, cornerHeight: 12 * z, transform: nil)

            ctx.saveGState()
            ctx.addPath(body)
            ctx.clip()
            ctx.drawLinearGradient(gradient([
                (0.00, color(0.060, 0.064, 0.062)),
                (0.50, color(0.105, 0.112, 0.108)),
                (0.86, color(0.165, 0.175, 0.168)),
                (1.00, color(0.30, 0.31, 0.30)),
            ]), start: .zero, end: CGPoint(x: 0, y: s.height), options: [])
            // Crinkle enamel: a scatter of tiny highlights.
            var g = SplitMix(0xC0FFEE)
            for _ in 0..<520 {
                let x = g.unit() * s.width, y = g.unit() * s.height
                let r = (0.25 + g.unit() * 0.5) * z
                ctx.setFillColor(color(1, 1, 1, 0.025 + 0.05 * g.unit()))
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
            ctx.restoreGState()

            ctx.addPath(body)
            ctx.setStrokeColor(color(0.01, 0.01, 0.01, 0.95))
            ctx.setLineWidth(z)
            ctx.strokePath()

            // Brass trim along the top.
            let strip = CGRect(x: 15 * z, y: s.height - 7.2 * z, width: s.width - 30 * z, height: 2.4 * z)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: strip, cornerWidth: 1.2 * z, cornerHeight: 1.2 * z, transform: nil))
            ctx.clip()
            ctx.drawLinearGradient(gradient([
                (0, color(0.40, 0.30, 0.13)), (0.55, color(0.88, 0.74, 0.44)), (1, color(0.52, 0.41, 0.20)),
            ]), start: CGPoint(x: 0, y: strip.minY), end: CGPoint(x: 0, y: strip.maxY), options: [])
            ctx.restoreGState()

            // The slit the lamp shines through.
            let slot = CGRect(x: s.width / 2 - 41 * z, y: s.height - 8.6 * z, width: 82 * z, height: 5.2 * z)
            ctx.addPath(CGPath(roundedRect: slot, cornerWidth: 2.6 * z, cornerHeight: 2.6 * z, transform: nil))
            ctx.setFillColor(color(0.015, 0.012, 0.010))
            ctx.fillPath()

            // The face carries no lettering. The input-source mark shines through the enamel
            // only when it has something to say.

            // Socket for the pilot jewel.
            let jc = CGPoint(x: 26 * z, y: 22 * z)
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: jc.x - 7 * z, y: jc.y - 7 * z, width: 14 * z, height: 14 * z))
            ctx.clip()
            ctx.drawLinearGradient(gradient([
                (0, color(0.36, 0.27, 0.12)), (0.6, color(0.86, 0.72, 0.42)), (1, color(0.60, 0.48, 0.24)),
            ]), start: CGPoint(x: 0, y: jc.y - 7 * z), end: CGPoint(x: 0, y: jc.y + 7 * z), options: [])
            ctx.restoreGState()
            ctx.setFillColor(color(0.10, 0.045, 0.012))
            ctx.fillEllipse(in: CGRect(x: jc.x - 4.6 * z, y: jc.y - 4.6 * z, width: 9.2 * z, height: 9.2 * z))

            // Two screws.
            for x in [s.width - 10.5 * z, 10.5 * z] {
                let c = CGPoint(x: x, y: 9 * z)
                ctx.setFillColor(color(0.30, 0.30, 0.29))
                ctx.fillEllipse(in: CGRect(x: c.x - 2.2 * z, y: c.y - 2.2 * z, width: 4.4 * z, height: 4.4 * z))
                ctx.setStrokeColor(color(0.04, 0.04, 0.04))
                ctx.setLineWidth(0.7 * z)
                ctx.move(to: CGPoint(x: c.x - 1.5 * z, y: c.y - 0.9 * z))
                ctx.addLine(to: CGPoint(x: c.x + 1.5 * z, y: c.y + 0.9 * z))
                ctx.strokePath()
            }
        }
        return (tex, size)
    }

    /// Two steel prongs that frame the cell about to be typed — the cursor.
    static func guide(z: CGFloat, cellW: CGFloat, ps: CGFloat) -> (texture: SKTexture, size: CGSize) {
        let size = CGSize(width: cellW + 9 * z, height: 31 * z)
        let tex = texture(size: size, scale: ps) { ctx, s in
            let prongW = 2.2 * z
            for x in [0.6 * z, s.width - prongW - 0.6 * z] {
                let r = CGRect(x: x, y: 0, width: prongW, height: s.height - z)
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: prongW / 2, cornerHeight: prongW / 2, transform: nil))
                ctx.clip()
                ctx.drawLinearGradient(gradient([
                    (0, color(0.34, 0.35, 0.37)), (0.45, color(0.86, 0.87, 0.88)), (1, color(0.42, 0.43, 0.45)),
                ]), start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
                ctx.restoreGState()
            }
            ctx.setFillColor(color(0.30, 0.31, 0.33))
            ctx.fill(CGRect(x: 0.6 * z, y: 0, width: s.width - 1.2 * z, height: 2.2 * z))
        }
        return (tex, size)
    }

    /// The stretch of ribbon held in front of the paper at the print point.
    static func ribbon(red: Bool) -> SKTexture {
        proceduralTexture(width: 128, height: 48) { u, v in
            let weave = 0.84 + 0.16 * sin(u * 128 * 1.7) * sin(v * 48 * 1.7)
            let base = red ? SIMD3<Float>(0.40, 0.062, 0.050) : SIMD3<Float>(0.074, 0.068, 0.080)
            var c = base * weave
            let selvedge = exp(-pow((v - 0.05) / 0.035, 2)) + exp(-pow((v - 0.95) / 0.035, 2))
            c += SIMD3(repeating: 0.045 * selvedge)
            let a = smooth(0, 0.22, u) * smooth(0, 0.22, 1 - u)
            return SIMD4(c.x, c.y, c.z, a)
        }
    }

    /// The back of a type slug: a small block of polished steel.
    static func slug(z: CGFloat, wide: Bool, ps: CGFloat) -> (texture: SKTexture, size: CGSize) {
        let size = wide ? CGSize(width: 28 * z, height: 29 * z) : CGSize(width: 15 * z, height: 25 * z)
        let tex = texture(size: size, scale: ps) { ctx, s in
            let r = CGRect(origin: .zero, size: s).insetBy(dx: 0.6 * z, dy: 0.6 * z)
            let path = CGPath(roundedRect: r, cornerWidth: 2.6 * z, cornerHeight: 2.6 * z, transform: nil)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(gradient([
                (0.00, color(0.30, 0.31, 0.33)), (0.30, color(0.90, 0.90, 0.91)),
                (0.52, color(0.62, 0.63, 0.65)), (1.00, color(0.24, 0.25, 0.27)),
            ]), start: CGPoint(x: r.minX, y: 0), end: CGPoint(x: r.maxX, y: 0), options: [])
            ctx.drawLinearGradient(gradient([(0, color(0, 0, 0, 0.30)), (0.5, color(0, 0, 0, 0)), (1, color(1, 1, 1, 0.18))]),
                                   start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(color(0.08, 0.08, 0.09, 0.9))
            ctx.setLineWidth(0.8 * z)
            ctx.strokePath()
        }
        return (tex, size)
    }

    /// A typebar, fading out toward its pivot so it seems to rise out of the dark.
    static func arm() -> SKTexture {
        proceduralTexture(width: 20, height: 128) { u, v in
            let c = 0.20 + 0.62 * exp(-pow((u - 0.36) / 0.17, 2))
            let side = smooth(0, 0.16, u) * smooth(0, 0.16, 1 - u)
            let a = side * smooth(0.0, 0.62, v)
            return SIMD4(c * 0.97, c, c * 1.03, a)
        }
    }

    /// A long soft bar, for the shadow of a typebar.
    static func armShadow() -> SKTexture {
        proceduralTexture(width: 24, height: 128) { u, v in
            let side = exp(-pow((u - 0.5) / 0.22, 2))
            return SIMD4(0, 0, 0, side * smooth(0.0, 0.5, v) * smooth(0.0, 0.08, 1 - v))
        }
    }

    /// The mark that glows on the carriage for a moment when the input source changes:
    /// "A", "中", "あ" and so on.
    static func indicator(_ text: String, z: CGFloat, ps: CGFloat) -> (texture: SKTexture, size: CGSize) {
        let size = CGSize(width: 54 * z, height: 26 * z)
        let tex = texture(size: size, scale: ps) { ctx, s in
            guard !text.isEmpty else { return }
            let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 14 * z, nil)
            let str = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(1.0, 0.72, 0.30),
            ])
            let line = CTLineCreateWithAttributedString(str)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.setShadow(offset: .zero, blur: 4.5 * z, color: color(1.0, 0.55, 0.12, 0.95))
            ctx.textPosition = CGPoint(x: (s.width - width) / 2, y: 8 * z)
            CTLineDraw(line, ctx)
        }
        return (tex, size)
    }

    /// Text an input method is still composing, pencilled on the paper where it will be typed.
    /// With `backed`, it sits on a slip of paper so it stays legible over existing ink.
    static func ghost(_ text: String, layout: Layout, latinFont: String, cjkFont: String, backed: Bool)
        -> (texture: SKTexture, size: CGSize, cells: Int, pad: CGFloat) {
        let z = layout.zoom
        let pad = 5 * z
        let chars = text.map { String($0) }
        let cells = chars.reduce(0) { $0 + Grid.width(of: $1) }
        let size = CGSize(width: CGFloat(max(cells, 1)) * layout.cellW + 2 * pad, height: layout.lineH + 2 * pad)
        let tex = texture(size: size, scale: layout.ps) { ctx, s in
            if backed {
                let slip = CGRect(origin: .zero, size: s).insetBy(dx: z, dy: 2 * z)
                ctx.addPath(CGPath(roundedRect: slip, cornerWidth: 2 * z, cornerHeight: 2 * z, transform: nil))
                ctx.setFillColor(color(0.925, 0.905, 0.855))
                ctx.fillPath()
            }
            let latin = CTFontCreateWithName(latinFont as CFString, layout.fontSize, nil)
            let cjk = CTFontCreateWithName(cjkFont as CFString, layout.fontSize * 1.07, nil)
            let graphite = color(0.28, 0.28, 0.32, 0.66)
            let baseline = pad + layout.lineH - layout.baselineDrop
            var x = pad
            for c in chars {
                let wide = Grid.width(of: c) == 2
                let w = CGFloat(wide ? 2 : 1) * layout.cellW
                let str = NSAttributedString(string: c, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): wide ? cjk : latin,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): graphite,
                ])
                let line = CTLineCreateWithAttributedString(str)
                let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                ctx.textPosition = CGPoint(x: x + (w - advance) / 2, y: baseline)
                CTLineDraw(line, ctx)
                x += w
            }
            ctx.setStrokeColor(color(0.28, 0.28, 0.32, 0.55))
            ctx.setLineWidth(1.1 * z)
            ctx.move(to: CGPoint(x: pad, y: baseline - 4.5 * z))
            ctx.addLine(to: CGPoint(x: s.width - pad, y: baseline - 4.5 * z))
            ctx.strokePath()
        }
        return (tex, size, cells, pad)
    }
}
