import SpriteKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Developer aid: films a short performance on the machine, for the project's front page.
///   Lamplight --make-demo <output folder>       (run from the project folder)
///
/// Nothing is opened and nothing is played: the scene is stepped by hand and drawn offscreen,
/// and the soundtrack is mixed from the same recordings the app plays, at the moments the scene
/// asks for them. It writes `demo.mp4` (60 frames a second, with sound) and, in `frames/`, every
/// other picture at half size together with `frames.txt`, the argument file for
/// `img2webp frames.txt -o demo.webp`.
///
/// The camera is the only thing here that the app does not do: the film moves in on the
/// carriage while a line is typed, so that the typebars can be seen, and back out again.
enum DemoFilm {
    /// The window being filmed: a large one, so that the close view is still sharp. (It has to
    /// be drawn at two pixels to the point: SKRenderer sizes a scene by its viewport on that
    /// assumption, and at any other scale the scene's own coordinates stop matching these.)
    static let window = CGSize(width: 1998, height: 1248)
    static let scale: CGFloat = 2
    /// What the film shows when it stands back: the paper and the carriage, without the empty
    /// night around them. The close view is the same shape, `closest` times nearer, and keeps
    /// the same bottom edge; at that distance one pixel of the scene is one pixel of the film.
    static let wide = CGRect(x: 279, y: 150, width: 1440, height: 720)
    static let closest: CGFloat = 1.5
    static let movieSize = (width: 1920, height: 960)
    static let pack = "hermes-asmr"

    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir, isDirectory: true)
        let frames = dir.appendingPathComponent("frames", isDirectory: true)
        try? FileManager.default.removeItem(at: frames)
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // Once without pictures, to hear everything the machine will play.
        guard let track = Soundtrack(pack: pack) else {
            print("cannot read Resources/Sounds/\(pack); run this from the project folder")
            return
        }
        let (count, opening) = perform(sound: track, picture: nil)
        let seconds = Double(count) / 60
        track.finish(seconds: seconds)
        print(String(format: "performance: %.2f s, %d pictures, %d sounds, soundtrack peak %.1f dBFS",
                     seconds, count, track.count, 20 * log10(max(track.peak, 1e-6))))

        // Then again, filming. The scene is deterministic, so this is the same performance.
        let movie = dir.appendingPathComponent("demo.mp4")
        guard let film = FilmWriter(url: movie, width: movieSize.width, height: movieSize.height, track: track) else {
            print("could not start writing \(movie.lastPathComponent)")
            return
        }
        let sw = movieSize.width / 2, sh = movieSize.height / 2
        // Every frame whole (-kmax 1): left to reuse parts of the frame before, the encoder
        // leaves seams all over the dark of the room.
        var list: [String] = []
        var small = 0
        var first = 0
        let (again, _) = perform(sound: Soundtrack.none) { renderer, index, camera in
            guard let whole = renderer.snapshot() else { return }
            film.append(index: index) { paint(whole, camera: camera, into: $0, width: movieSize.width, height: movieSize.height) }
            guard index % 2 == 0 || index == count - 1 else { return }
            // Thirty pictures a second for the animation; a WebP frame lasts a whole number of milliseconds.
            guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            paint(whole, camera: camera, into: ctx, width: sw, height: sh)
            let name = String(format: "f%05d.png", small)
            RenderTest.write(ctx.makeImage(), frames.appendingPathComponent(name), quiet: true)
            if index <= opening { first = small }
            list.append("-d \(small % 3 == 2 ? 34 : 33) \(frames.appendingPathComponent(name).path)")
            small += 1
        }
        film.finish()
        // The film runs from the sheet feeding in; the animation is the same loop entered at
        // its opening picture.
        let turned = Array(list[first...] + list[..<first])
        let arguments = ["-loop 0 -kmax 1 -sharp_yuv -lossy -q 80 -m 4"] + turned + ["-o \(dir.appendingPathComponent("demo.webp").path)"]
        try? arguments.joined(separator: "\n").write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        print("the animation opens on frame \(first) of \(small); encode it with:  img2webp \(dir.appendingPathComponent("frames.txt").path)")
        print("wrote \(movie.lastPathComponent) \(movieSize.width) x \(movieSize.height), \(again) pictures;  \(small) frames for the animation")
        if again != count { print("WARNING: the two performances differ (\(count) and \(again) pictures); sound and picture may not agree") }
        if let problem = film.problem { print("WARNING: \(problem)") }
    }

    /// Draws the part of the whole picture that the camera sees, filling the context. Placing
    /// the whole image with a transform, rather than cropping it first, lets the camera move
    /// by fractions of a pixel.
    private static func paint(_ whole: CGImage, camera: CGRect, into ctx: CGContext, width: Int, height: Int) {
        let k = CGFloat(width) / camera.width
        ctx.interpolationQuality = .high
        ctx.draw(whole, in: CGRect(x: -camera.minX * k, y: -camera.minY * k, width: window.width * k, height: window.height * k))
    }

    /// The performance. `picture` is called with each picture as it is ready to be taken,
    /// sixty times a second of scene time, and with what the camera sees at that moment;
    /// `sound` hears everything the machine plays. Returns the number of pictures.
    private static func perform(sound: Soundtrack, picture: ((OffscreenRenderer, Int, CGRect) -> Void)?) -> (pictures: Int, opening: Int) {
        let scene = TypewriterScene(size: window, entry: Entry(kind: .diary), options: SceneOptions(), pixelScale: scale)
        guard let r = OffscreenRenderer(scene: scene, pixelScale: scale) else {
            print("no Metal device")
            return (0, 0)
        }
        // Let the lamp warm up and the dust spread out before anything is filmed.
        r.advance(2.5)
        if scene.L.size != window { print("WARNING: the scene was laid out at \(scene.L.size), not \(window); the camera will be off") }
        scene.sound = sound

        var tick = 0
        var pictures = 0
        var opening = 0
        var hand = SplitMix(1117)

        // The camera: how near it is (1 = standing back), eased from one distance to another,
        // and the point along the line it is looking at, which follows the carriage gently.
        var near: CGFloat = 1
        var move: (from: CGFloat, to: CGFloat, start: Int, ticks: Int) = (1, 1, 0, 1)
        var lookX = wide.midX
        func camera() -> CGRect {
            let w = wide.width / near
            return CGRect(x: lookX - w / 2, y: wide.minY, width: w, height: w * wide.height / wide.width)
        }
        func moveCamera(to distance: CGFloat, over seconds: Double) {
            move = (near, distance, tick, max(1, Int((seconds * 120).rounded())))
        }

        /// Moves time on, taking a picture every other step: the scene runs at 120 steps a
        /// second as it does on screen, the film at 60.
        func run(_ seconds: Double) {
            for _ in 0..<max(1, Int((seconds * 120).rounded())) {
                tick += 1
                sound.clock = Double(tick) / 120
                r.advance(1.0 / 120)
                let u = min(1, CGFloat(tick - move.start) / CGFloat(move.ticks))
                near = move.from + (move.to - move.from) * u * u * (3 - 2 * u)
                // It never looks past the edges of the wide view.
                let half = wide.width / near / 2
                let aim = min(max(scene.carriageHandle.x, wide.minX + half), wide.maxX - half)
                lookX += (aim - lookX) * (1 - exp(-CGFloat(1.0 / 120) * 5))
                lookX = min(max(lookX, wide.minX + half), wide.maxX - half)
                if tick % 2 == 0 {
                    picture?(r, pictures, camera())
                    pictures += 1
                }
            }
        }
        func settle() {
            var waited = 0
            while !scene.isSettled && waited < 1200 {
                run(1.0 / 120)
                waited += 1
            }
        }
        /// Typed by hand: about `rate` keys a second, never quite evenly, with a breath after
        /// punctuation. `cues` are things to do just before the character at that place is typed.
        func typeOut(_ text: String, rate: Double, cues: [Int: () -> Void] = [:]) {
            for (i, ch) in text.enumerated() {
                cues[i]?()
                scene.type(String(ch))
                var gap = (0.70 + 0.60 * Double(hand.unit())) / rate
                if ch == "," { gap += 0.10 }
                if ch == "." { gap += 0.22 }
                run(gap)
            }
        }

        // A new sheet feeds in and the machine types the date by itself. The film begins with
        // the sheet still below the deck, which is also how it ends, so it can run in a loop.
        let (entry, header) = Entry.make(kind: .diary)
        sound.clock = 0
        scene.load(entry, animated: true, header: header)
        r.advance(1.0 / 120)
        picture?(r, 0, camera())
        pictures = 1
        settle()
        run(0.35)

        // A line typed by hand. The camera goes in to watch the typebars, and stands back
        // again in time for the bell and the carriage's flight home.
        moveCamera(to: closest, over: 1.5)
        let first = "Lights off. One lamp, one page, the sound of every key."
        typeOut(first, rate: 10.5, cues: [
            // The animation on the front page opens here, on a typebar about to land: where
            // moving pictures are switched off, its first picture is all that is seen.
            26: { opening = pictures + 3 },
            first.count - 17: { moveCamera(to: 1, over: 1.4) },
        ])
        run(0.30)
        scene.pressReturn()
        settle()
        run(0.25)

        // A slip, lifted off with the correction tape and typed again — seen from close by.
        moveCamera(to: closest, over: 1.3)
        typeOut("No undo. Only correction taep", rate: 10.5)
        run(0.40)
        scene.pressBackspace()
        run(0.17)
        scene.pressBackspace()
        run(0.38)
        typeOut("pe.", rate: 9)
        moveCamera(to: 1, over: 1.2)
        run(0.75)

        // The carriage run along the line with the glide keys, and back to the margin.
        scene.glide(1)
        run(0.30)
        scene.glide(0)
        settle()
        run(0.20)
        scene.glide(-1)
        run(0.80)
        scene.glide(0)
        settle()
        run(0.45)

        // The sheet rolls out. The film ends on the first picture after it has gone and the
        // next one is about to feed in — the same sight it began with.
        let next = Entry(kind: .diary)
        scene.load(next, animated: true, header: "")
        var waited = 0
        while scene.entry.id != next.id && waited < 240 {
            run(1.0 / 120)
            waited += 1
        }
        if tick % 2 != 0 { run(1.0 / 120) }
        return (pictures, opening)
    }
}

/// Stands in for the sound bank while a film is made: notes every sound the scene asks for
/// against the film's clock and adds it to one stereo track, from the pack's own recordings.
///
/// It follows the app's rules for which recording to use (the pack's; nothing for the key
/// click when the strikes already contain it; the generated sound otherwise). Two things are
/// simpler than in the app: sounds are only ever added together, never cut short by a later
/// one, and `pan` is applied as a plain balance.
final class Soundtrack: SoundPlaying {
    let strikeLead: Double
    private let rate = Synth.sampleRate
    private var takes: [Sound: [(left: [Float], right: [Float])]] = [:]
    private var lastTake: [Sound: Int] = [:]
    private var pick = SplitMix(4242)
    private(set) var left: [Float] = []
    private(set) var right: [Float] = []
    private(set) var count = 0
    private(set) var peak: Float = 0
    /// Seconds since the film began. Whoever steps the scene keeps this up to date.
    var clock: Double = 0

    /// Hears nothing; for the second performance, when the soundtrack is already made.
    static var none: Soundtrack { Soundtrack() }

    private init() { strikeLead = 0 }

    init?(pack id: String) {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sounds/\(id)")
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")),
              let manifest = try? JSONDecoder().decode(PackManifest.self, from: data),
              let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2) else { return nil }
        strikeLead = manifest.strikeLead
        takes = Synth.all()
        if manifest.hasKeyTravel { takes[.key] = nil }
        for (name, entries) in manifest.sounds {
            guard let sound = SoundBank.kind(name) else { continue }
            let loaded = entries.compactMap { entry -> (left: [Float], right: [Float])? in
                guard let buffer = SoundBank.read(dir.appendingPathComponent(entry.file), format: format),
                      let channels = buffer.floatChannelData else { return nil }
                let n = Int(buffer.frameLength)
                return (Array(UnsafeBufferPointer(start: channels[0], count: n)), Array(UnsafeBufferPointer(start: channels[1], count: n)))
            }
            if !loaded.isEmpty { takes[sound] = loaded }
        }
    }

    func play(_ sound: Sound, gain: Float, pan: Float) {
        guard let options = takes[sound], !options.isEmpty else { return }
        // Never the same take twice running, as in the app.
        var index = Int(pick.next() % UInt64(options.count))
        if options.count > 1, index == lastTake[sound] {
            index = (index + 1 + Int(pick.next() % UInt64(options.count - 1))) % options.count
        }
        lastTake[sound] = index
        let take = options[index]
        let g = max(0, min(1, gain)), p = max(-1, min(1, pan))
        let gl = g * (p > 0 ? 1 - p : 1), gr = g * (p < 0 ? 1 + p : 1)
        let start = max(0, Int((clock * rate).rounded()))
        let n = min(take.left.count, take.right.count)
        if left.count < start + n {
            left.append(contentsOf: repeatElement(0, count: start + n - left.count))
            right.append(contentsOf: repeatElement(0, count: start + n - right.count))
        }
        for i in 0..<n {
            left[start + i] += take.left[i] * gl
            right[start + i] += take.right[i] * gr
        }
        count += 1
    }

    /// Cuts the track to the length of the film, sets it to the volume the app starts out at,
    /// eases the last moment out, and brings the whole of it down if it would still clip.
    func finish(seconds: Double) {
        let n = Int((seconds * rate).rounded())
        let volume: Float = 0.7
        left = (left + [Float](repeating: 0, count: max(0, n - left.count))).prefix(n).map { $0 * volume }
        right = (right + [Float](repeating: 0, count: max(0, n - right.count))).prefix(n).map { $0 * volume }
        let fade = min(n, Int(0.08 * rate))
        for i in 0..<fade {
            let k = Float(i) / Float(fade)
            left[n - 1 - i] *= k
            right[n - 1 - i] *= k
        }
        peak = max(left.map { abs($0) }.max() ?? 0, right.map { abs($0) }.max() ?? 0)
        let ceiling: Float = 0.89
        if peak > ceiling {
            let down = ceiling / peak
            for i in 0..<n {
                left[i] *= down
                right[i] *= down
            }
            peak = ceiling
        }
    }

    /// Length of the finished track.
    var seconds: Double { Double(left.count) / rate }

    /// The stretch of the track between two moments, as interleaved 16-bit samples.
    func samples(from a: Double, to b: Double) -> [Int16] {
        let i0 = max(0, Int((a * rate).rounded())), i1 = min(left.count, Int((b * rate).rounded()))
        guard i1 > i0 else { return [] }
        var out = [Int16](repeating: 0, count: (i1 - i0) * 2)
        for i in i0..<i1 {
            out[(i - i0) * 2] = Int16(max(-1, min(1, left[i])) * 32767)
            out[(i - i0) * 2 + 1] = Int16(max(-1, min(1, right[i])) * 32767)
        }
        return out
    }
}

/// Writes pictures and the soundtrack into one MP4 file, a picture's worth of sound after each picture.
final class FilmWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let track: Soundtrack
    private let width: Int
    private let height: Int
    private var format: CMAudioFormatDescription?
    private(set) var problem: String?

    init?(url: URL, width: Int, height: Int, track: Soundtrack) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        self.writer = writer
        self.width = width
        self.height = height
        self.track = track
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Synth.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(audio) else { return nil }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        var description = AudioStreamBasicDescription(
            mSampleRate: Synth.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }

    /// How much of the soundtrack has been handed over, in seconds of film.
    private var soundGiven = 0.0
    private var soundClosed = false

    /// Hands over sound for as long as the writer will take it, up to `limit` seconds of film.
    /// The writer keeps picture and sound in step by refusing whichever is ahead, so sound has
    /// to be on offer whenever it stops taking pictures.
    private func giveSound(upTo limit: Double) {
        let end = min(limit, track.seconds)
        while soundGiven < end - 1e-9, audio.isReadyForMoreMediaData, problem == nil {
            let next = min(soundGiven + 0.1, end)
            appendSound(from: soundGiven, to: next)
            soundGiven = next
        }
        // With all of it handed over, say so: otherwise the writer goes on waiting for more
        // sound before it will take the last pictures.
        if soundGiven >= track.seconds - 1e-9, !soundClosed {
            audio.markAsFinished()
            soundClosed = true
        }
    }

    /// Adds picture number `index` (sixty a second). `draw` paints it into the film's own
    /// picture buffer.
    func append(index: Int, draw: (CGContext) -> Void) {
        guard problem == nil else { return }
        guard let pool = adaptor.pixelBufferPool else {
            problem = "no pixel buffers: \(writer.error?.localizedDescription ?? "unknown")"
            return
        }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let buffer = made else {
            problem = "could not make a pixel buffer"
            return
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            draw(ctx)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let time = Double(index) / 60
        var spent = 0.0
        while !video.isReadyForMoreMediaData {
            giveSound(upTo: time + 2)
            if writer.status != .writing || spent > 30 {
                problem = "picture \(index) was refused: \(writer.error?.localizedDescription ?? "writer not ready")"
                return
            }
            Thread.sleep(forTimeInterval: 0.002)
            spent += 0.002
        }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 60)) else {
            problem = "picture \(index) was refused: \(writer.error?.localizedDescription ?? "unknown")"
            return
        }
        giveSound(upTo: time + 0.5)
    }

    private func appendSound(from a: Double, to b: Double) {
        var samples = track.samples(from: a, to: b)
        guard !samples.isEmpty, let format else { return }
        let frames = samples.count / 2
        let bytes = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard let block else { return }
        CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        var sample: CMSampleBuffer?
        let start = CMTime(value: CMTimeValue((a * Synth.sampleRate).rounded()), timescale: CMTimeScale(Synth.sampleRate))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                                             sampleCount: frames, presentationTimeStamp: start,
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample, audio.append(sample) else {
            problem = "sound at \(a) s was refused: \(writer.error?.localizedDescription ?? "unknown")"
            return
        }
    }

    func finish() {
        video.markAsFinished()
        // Whatever sound is left.
        var spent = 0.0
        while soundGiven < track.seconds - 1e-9, problem == nil, writer.status == .writing, spent < 30 {
            giveSound(upTo: track.seconds)
            Thread.sleep(forTimeInterval: 0.002)
            spent += 0.002
        }
        if !soundClosed {
            audio.markAsFinished()
            soundClosed = true
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed, problem == nil {
            problem = "the film was not finished: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")"
        }
    }
}
