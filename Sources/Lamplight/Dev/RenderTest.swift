import SpriteKit
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Renders the scene into a Metal texture with no window, stepping time by hand.
/// Used by `--render-test` to check what the machine looks like at exact moments.
final class OffscreenRenderer {
    let scene: TypewriterScene
    let pixelScale: CGFloat
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SKRenderer
    private let target: MTLTexture
    private let pw: Int
    private let ph: Int
    private(set) var time: Double = 1000

    init?(scene: TypewriterScene, pixelScale: CGFloat) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.scene = scene
        self.pixelScale = pixelScale
        self.device = device
        self.queue = queue
        pw = Int(scene.size.width * pixelScale)
        ph = Int(scene.size.height * pixelScale)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return nil }
        self.target = target
        renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true
        renderer.scene = scene
        renderer.update(atTime: time)
        // Shaders compile in the background; the first frames come out black until they are ready.
        for _ in 0..<40 {
            guard let probe = snapshot() else { break }
            if OffscreenRenderer.hasLight(probe) { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func hasLight(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return false }
        let n = CFDataGetLength(data)
        var i = 0
        while i < n {
            if p[i] > 8 || p[i + 1] > 8 || p[i + 2] > 8 { return true }
            i += 4 * 97
        }
        return false
    }

    /// Advances the scene's clock in display-sized steps.
    func advance(_ seconds: Double, fps: Double = 120) {
        let end = time + seconds
        let dt = 1 / fps
        while time + dt <= end + 1e-9 {
            time += dt
            renderer.update(atTime: time)
        }
        if end - time > 1e-6 {
            time = end
            renderer.update(atTime: time)
        }
    }

    /// Runs until nothing is moving or queued.
    func settle(max seconds: Double = 120) {
        var waited = 0.0
        while !scene.isSettled && waited < seconds {
            advance(0.05)
            waited += 0.05
        }
        advance(0.5)
    }

    func snapshot() -> CGImage? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer() else { return nil }
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: pw, height: ph), commandBuffer: buffer, renderPassDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
        target.getBytes(&bytes, bytesPerRow: pw * 4, from: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pw * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A snapshot cropped to a rectangle given in scene points (origin bottom-left).
    func snapshot(crop: CGRect) -> CGImage? {
        guard let full = snapshot() else { return nil }
        let r = CGRect(x: crop.minX * pixelScale, y: (scene.size.height - crop.maxY) * pixelScale,
                       width: crop.width * pixelScale, height: crop.height * pixelScale)
        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let clipped = r.integral.intersection(bounds)
        if clipped.isEmpty { print("crop outside image:", crop, "->", r); return nil }
        return full.cropping(to: clipped)
    }
}

enum RenderTest {
    static func write(_ image: CGImage?, _ url: URL, quiet: Bool = false) {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("could not write", url.lastPathComponent)
            return
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        if !quiet { print("wrote", url.lastPathComponent, image.width, "x", image.height) }
    }

    /// Lays images out in a grid, for looking at an animation frame by frame.
    static func sheet(_ images: [CGImage], columns: Int) -> CGImage? {
        guard let first = images.first else { return nil }
        let w = first.width, h = first.height
        let rows = (images.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, image) in images.enumerated() {
            let col = i % columns, row = i / columns
            ctx.draw(image, in: CGRect(x: col * w, y: (rows - 1 - row) * h, width: w, height: h))
        }
        return ctx.makeImage()
    }

    static let sample = """
    今天下了一整天的雨。傍晚的时候雨停了，窗外的路灯一盏一盏亮起来。
    我关掉房间里的灯，只留桌上这一小片光，然后开始打字。

    The quick brown fox jumps over the lazy dog. I had forgotten how good it feels when every letter costs something.
    """

    static func run(outputDir: String, args: [String]) {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var size = CGSize(width: 1512, height: 982)
        var names = args
        // `--size 1000x700` renders at another window size.
        if let i = names.firstIndex(of: "--size"), i + 1 < names.count {
            let parts = names[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
            names.removeSubrange(i...(i + 1))
        }
        let which = Set(names)
        func wants(_ name: String) -> Bool { which.isEmpty || which.contains(name) }

        var options = SceneOptions()
        let (entry, header) = Entry.make(kind: .diary)
        let scene = TypewriterScene(size: size, entry: entry, options: options, pixelScale: 2)
        guard let r = OffscreenRenderer(scene: scene, pixelScale: 2) else {
            print("no Metal device")
            return
        }

        // A new sheet feeds in and the machine types the date by itself.
        scene.load(entry, animated: true, header: header)
        if wants("intro") {
            var frames: [CGImage] = []
            for step in [0.06, 0.20, 0.34, 0.60, 0.90, 1.40] {
                r.advance(step - (r.time - 1000))
                if let f = r.snapshot(crop: CGRect(x: size.width / 2 - 500, y: 150, width: 1000, height: 560)) { frames.append(f) }
            }
            write(sheet(frames, columns: 3), dir.appendingPathComponent("intro.png"))
        }
        r.settle()

        scene.type(sample)
        r.settle()
        scene.type("\n\n灯下的字，一个一个敲出来。Once upon a ti")
        r.settle()
        print("---- text ----")
        print(scene.entry.text())
        print("---- cursor", scene.entry.cursorRow, scene.entry.cursorCol, "rows", scene.entry.rows.count)

        if wants("hero") {
            write(r.snapshot(), dir.appendingPathComponent("hero.png"))
        }

        let head = scene.caretRect
        let close = CGRect(x: head.midX - 300, y: head.minY - 150, width: 600, height: 420)

        if wants("close") {
            write(r.snapshot(crop: close), dir.appendingPathComponent("close.png"))
        }

        if wants("strike") {
            // One keystroke, frame by frame.
            var frames: [CGImage] = []
            let t0 = r.time
            scene.type("m")
            for ms in [4.0, 16, 28, 38, 46, 52, 60, 72, 90, 110, 130, 160] {
                r.advance(ms / 1000 - (r.time - t0), fps: 1000)
                if let f = r.snapshot(crop: CGRect(x: head.midX - 170, y: head.minY - 110, width: 340, height: 300)) { frames.append(f) }
            }
            write(sheet(frames, columns: 4), dir.appendingPathComponent("strike.png"))
            r.settle()
        }

        if wants("cjk") {
            var frames: [CGImage] = []
            scene.setComposition("deng xia")
            scene.flashIndicator("中")
            r.advance(0.3)
            if let f = r.snapshot(crop: CGRect(x: head.midX - 170, y: head.minY - 110, width: 340, height: 300)) { frames.append(f) }
            scene.setComposition("")
            scene.type("灯")
            let t0 = r.time
            for ms in [46.0, 52, 62, 80, 120] {
                r.advance(ms / 1000 - (r.time - t0), fps: 1000)
                if let f = r.snapshot(crop: CGRect(x: head.midX - 170, y: head.minY - 110, width: 340, height: 300)) { frames.append(f) }
            }
            write(sheet(frames, columns: 3), dir.appendingPathComponent("cjk.png"))
            r.settle()
            r.advance(2.5)
        }

        if wants("return") {
            var frames: [CGImage] = []
            let t0 = r.time
            scene.pressReturn()
            for ms in [10.0, 80, 160, 240, 330, 420] {
                r.advance(ms / 1000 - (r.time - t0), fps: 500)
                if let f = r.snapshot(crop: CGRect(x: 200, y: 160, width: 1112, height: 360)) { frames.append(f) }
            }
            write(sheet(frames, columns: 2), dir.appendingPathComponent("return.png"))
            r.settle()
        }

        if wants("red") {
            options.ribbon = 1
            scene.options = options
            scene.type("摘抄用红色色带。")
            r.settle()
            options.ribbon = 0
            scene.options = options
            scene.type("感想用黑色。teh")
            r.settle()
            scene.pressBackspace()
            scene.pressBackspace()
            r.settle()
            scene.type("he end")
            r.settle()
            write(r.snapshot(crop: CGRect(x: 200, y: 160, width: 1112, height: 420)), dir.appendingPathComponent("red.png"))
        }

        if wants("fade") {
            // Characters removed with the correction tape: a faint trace that is gone in ten seconds.
            scene.type(" fading")
            r.settle()
            var frames: [CGImage] = []
            let near = scene.caretRect
            let crop = CGRect(x: near.midX - 330, y: near.minY - 40, width: 420, height: 190)
            if let f = r.snapshot(crop: crop) { frames.append(f) }
            for _ in 0..<4 { scene.pressBackspace() }
            let t0 = r.time
            for seconds in [0.6, 3.0, 6.0, 10.6] {
                r.advance(seconds - (r.time - t0))
                if let f = r.snapshot(crop: crop) { frames.append(f) }
            }
            write(sheet(frames, columns: 5), dir.appendingPathComponent("fade.png"))
        }

        if wants("glide") {
            // The carriage moved by hand: dragged with the pointer, then run along the line with
            // a glide key held. Prints how it moved frame by frame and where it came to rest.
            let clicks = ClickCounter()
            scene.sound = clicks
            var changes = 0
            scene.onChange = { changes += 1 }
            scene.type("\nA line to move along.")
            r.settle()
            let cellW = scene.L.cellW
            let strip = CGRect(x: 200, y: 150, width: 1112, height: 330)
            var frames: [CGImage] = []
            func shot() { if let f = r.snapshot(crop: strip) { frames.append(f) } }
            func col() -> Int { scene.entry.cursorCol }
            /// Steps the scene one display frame at a time, noting where the carriage is.
            func run(_ n: Int, each: ((Int) -> Void)? = nil) -> [CGFloat] {
                var xs = [scene.carriageHandle.x / cellW]
                for k in 1...n {
                    each?(k)
                    r.advance(1.0 / 120)
                    xs.append(scene.carriageHandle.x / cellW)
                }
                return xs
            }
            /// Largest step between frames, largest change from one step to the next, and the
            /// largest step against the direction of travel, all in cells.
            func motion(_ xs: [CGFloat], _ direction: CGFloat) -> String {
                let d = zip(xs.dropFirst(), xs).map { $0 - $1 }
                let dd = zip(d.dropFirst(), d).map { abs($0 - $1) }
                let back = d.map { -$0 * direction }.max() ?? 0
                return String(format: "largest step %.3f  largest change of step %.3f  backwards %.4f", d.map { abs($0) }.max() ?? 0, dd.max() ?? 0, max(0, back))
            }
            func took(_ label: String, _ from: Int, _ note: String = "") {
                print(String(format: "glide  %@: col %d -> %d   clicks %d   %@", label, from, col(), clicks.count(.tick), note))
                clicks.reset()
            }

            // 1. Drag: press on the carriage, carry it 30.4 cells to the right in 0.4 s, let go.
            var from = col()
            let handle = scene.carriageHandle
            print("glide  grab on the carriage:", scene.grab(at: handle), " on the paper far above it:", scene.canGrab(at: CGPoint(x: handle.x, y: handle.y + 300)))
            var xs = run(48) { k in
                let u = CGFloat(k) / 48
                scene.drag(to: handle.x + 30.4 * cellW * u * u * (3 - 2 * u))
                if k == 12 || k == 36 { shot() }
            }
            let dragged = motion(xs, 1)
            xs = run(12)
            let lag = String(format: "behind the pointer when it stopped %.2f, 0.1 s later %.3f", 30.4 + handle.x / cellW - xs[0], 30.4 + handle.x / cellW - xs[12])
            scene.letGo()
            r.settle()
            shot()
            took("drag right 30.4 cells in 0.4 s", from, dragged + "  " + lag)

            // 2. Glide left with the key held for 0.35 s.
            from = col()
            scene.glide(-1)
            xs = run(42)
            scene.glide(0)
            xs += run(24).dropFirst()
            shot()
            r.settle()
            took("glide left, key held 0.35 s", from, motion(xs, -1))

            // 3. A tap of the key.
            from = col()
            scene.glide(1)
            xs = run(11)
            scene.glide(0)
            xs += run(24).dropFirst()
            r.settle()
            took("glide right, tap of 0.09 s", from, motion(xs, 1))

            // 4. Held all the way into each margin.
            from = col()
            scene.glide(-1)
            xs = run(120)
            scene.glide(0)
            r.settle()
            took("glide left, held 1 s", from, motion(xs, -1) + String(format: "  past the margin %.3f", max(0, (xs.first ?? 0) - CGFloat(from) - (xs.min() ?? 0))))
            from = col()
            scene.glide(1)
            xs = run(120)
            scene.glide(0)
            r.settle()
            took("glide right, held 1 s", from, motion(xs, 1) + String(format: "  reached the margin after %.2f s", Double(xs.firstIndex { $0 - (xs.first ?? 0) >= CGFloat(Grid.cols - from) - 0.05 } ?? -120) / 120))

            // 5. A key struck while the carriage is in the hand: it is typed where the carriage is,
            //    and the hand no longer holds it.
            from = col()
            let here = scene.carriageHandle
            _ = scene.grab(at: here)
            _ = run(24) { k in scene.drag(to: here.x - 30 * cellW * CGFloat(k) / 24) }
            scene.type("x")
            r.settle()
            scene.drag(to: here.x)
            r.settle()
            scene.letGo()
            let last = scene.entry.rows[scene.entry.cursorRow].last
            took("drag left 30, then type x without letting go", from, "x is at col \(last?.x ?? -1)")

            // 6. A click that does not move, and one made while a slug is still in the air.
            from = col()
            changes = 0
            _ = scene.grab(at: scene.carriageHandle)
            _ = run(24)
            scene.letGo()
            r.settle()
            took("press and let go without moving", from, "changes \(changes)")
            from = col()
            scene.type("y")
            r.advance(0.004)
            _ = scene.grab(at: scene.carriageHandle)
            r.advance(0.03)
            scene.letGo()
            r.settle()
            took("press 4 ms after striking y", from, "y is at col \(scene.entry.rows[scene.entry.cursorRow].last?.x ?? -1)")

            // 7. With the paper travelling instead, it is the paper that follows the hand.
            options.paperMoves = true
            scene.options = options
            r.advance(1.5)
            from = col()
            let fixed = scene.carriageHandle
            _ = scene.grab(at: fixed)
            _ = run(36) { k in scene.drag(to: fixed.x + 10 * cellW * CGFloat(k) / 36) }
            shot()
            scene.letGo()
            r.settle()
            took("paper moves: pointer 10 cells to the right", from, String(format: "carriage moved %.2f", (scene.carriageHandle.x - fixed.x) / cellW))
            options.paperMoves = false
            scene.options = options
            r.advance(1.5)

            write(sheet(frames, columns: 1), dir.appendingPathComponent("glide.png"))
            scene.sound = nil
            scene.onChange = nil
        }

        if wants("torch") {
            scene.pointer(at: CGPoint(x: 560, y: 760))
            r.advance(1.0)
            write(r.snapshot(), dir.appendingPathComponent("torch.png"))
            scene.pointer(at: nil)
            r.advance(1.0)
        }

        if wants("lights") {
            options.lightsOn = true
            scene.options = options
            r.advance(1.5)
            write(r.snapshot(), dir.appendingPathComponent("lights.png"))
            options.lightsOn = false
            scene.options = options
            r.advance(1.5)
        }

        if wants("papermoves") {
            options.paperMoves = true
            scene.options = options
            r.advance(1.5)
            write(r.snapshot(), dir.appendingPathComponent("papermoves.png"))
            options.paperMoves = false
            scene.options = options
            r.advance(1.5)
        }

        if wants("scroll") {
            scene.scroll(rows: 6)
            r.advance(1.0)
            write(r.snapshot(), dir.appendingPathComponent("scroll.png"))
        }
    }
}

/// Developer aid: draws the app icon from the scene itself.
///   Lamplight --make-icon <output.png>
enum IconMaker {
    static func run(output: String) {
        var options = SceneOptions()
        options.textScale = 2.3
        options.paperMoves = true
        options.dust = false
        options.ambient = 0.9
        var entry = Entry(kind: .essay)
        entry.headerRows = 0
        let scene = TypewriterScene(size: CGSize(width: 512, height: 512), entry: entry, options: options, pixelScale: 2)
        guard let r = OffscreenRenderer(scene: scene, pixelScale: 2) else { return }
        scene.load(entry, animated: false, header: "\n\n            night\n         by lamplight\n         one key at")
        r.settle()
        r.advance(2)
        guard let shot = r.snapshot() else { return }

        // The rounded square every macOS icon sits in.
        let side = 1024
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset)
        let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0.03, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(shot, in: rect)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
        ctx.setLineWidth(2)
        ctx.strokePath()
        RenderTest.write(ctx.makeImage(), URL(fileURLWithPath: output))
    }
}

/// Stands in for the sound bank in a render test, to count what the scene asked to be played.
final class ClickCounter: SoundPlaying {
    private(set) var played: [Sound] = []
    let strikeLead: Double = 0
    func play(_ sound: Sound, gain: Float, pan: Float) { played.append(sound) }
    func count(_ sound: Sound) -> Int { played.filter { $0 == sound }.count }
    func reset() { played.removeAll() }
}
