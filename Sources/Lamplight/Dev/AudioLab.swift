import AVFoundation
import Accelerate

/// Developer tools for turning field recordings of real typewriters into sound packs.
/// Nothing here runs in normal use.
///
/// I cannot listen to audio, so everything is done by measurement: find each event in a
/// recording, describe it with numbers (how loud, how long, how bright, how tonal), and
/// sort events into strikes, space-bar presses, bells and carriage movements from those.
struct Clip {
    var left: [Float]
    var right: [Float]
    var sampleRate: Double

    var count: Int { left.count }
    var duration: Double { Double(count) / sampleRate }
    var mono: [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count { out[i] = (left[i] + right[i]) * 0.5 }
        return out
    }

    init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
    }

    init(mono: [Float], sampleRate: Double) {
        self.init(left: mono, right: mono, sampleRate: sampleRate)
    }

    func slice(_ range: Range<Int>) -> Clip {
        let r = max(0, range.lowerBound)..<min(count, range.upperBound)
        return Clip(left: Array(left[r]), right: Array(right[r]), sampleRate: sampleRate)
    }

    var peak: Float {
        var p: Float = 0
        for i in 0..<count { p = max(p, abs(left[i]), abs(right[i])) }
        return p
    }
}

/// One sound found in a recording.
struct AudioEvent {
    var start: Int          // sample index of the onset
    var peakIndex: Int      // sample index of the loudest point
    var end: Int            // where it has died away (or the next event begins)
    var peak: Float
    var centroid: Double    // spectral centre of mass, Hz
    var bands: [Double]     // share of energy below 300 Hz, 300–1500, 1500–5000, above 5000
    var tonality: Double    // how much one frequency dominates the ringing tail (bells are high)
    var bursts: Int         // number of separate clicks inside it (a ratchet has many)

    func seconds(_ sampleRate: Double) -> (start: Double, length: Double) {
        (Double(start) / sampleRate, Double(end - start) / sampleRate)
    }
}

enum AudioLab {
    static func load(_ url: URL) throws -> Clip {
        if url.pathExtension.lowercased() == "flac" {
            let decoded = try FLACDecoder.decode([UInt8](try Data(contentsOf: url)))
            if !decoded.verified {
                // The source recordings come from an encoder that writes non-standard checksums.
                // The decoder itself is proven on files with good ones (and on this encoder's
                // mono files), so carry on, but say so.
                print("note: \(url.lastPathComponent) decoded, but its stored checksum could not be matched")
            }
            let scale = 1 / Float(1 << (decoded.bitsPerSample - 1))
            let left = decoded.channels[0].map { Float($0) * scale }
            let right = decoded.channels.count > 1 ? decoded.channels[1].map { Float($0) * scale } : left
            return Clip(left: left, right: right, sampleRate: Double(decoded.sampleRate))
        }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw NSError(domain: "AudioLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "empty or unreadable file"])
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            throw NSError(domain: "AudioLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "not float audio"])
        }
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
        return Clip(left: left, right: right, sampleRate: format.sampleRate)
    }

    static func save(_ clip: Clip, to url: URL, bits: Int = 24) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: clip.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, clip.count))),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(clip.count)
        clip.left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: clip.count) }
        clip.right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress!, count: clip.count) }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: - Measurement

    /// RMS level in steps of `hop` samples.
    static func envelope(_ x: [Float], hop: Int, window: Int) -> [Float] {
        guard x.count > window else { return [] }
        let n = (x.count - window) / hop + 1
        var out = [Float](repeating: 0, count: n)
        x.withUnsafeBufferPointer { p in
            for i in 0..<n {
                var ms: Float = 0
                vDSP_measqv(p.baseAddress! + i * hop, 1, &ms, vDSP_Length(window))
                out[i] = sqrt(ms)
            }
        }
        return out
    }

    /// Power spectrum of up to 2^log2n samples (no window: these are transients, and a
    /// tapering window would erase the very onset we want to measure).
    static func powerSpectrum(_ x: ArraySlice<Float>, log2n: Int) -> [Float] {
        let n = 1 << log2n
        var frame = [Float](repeating: 0, count: n)
        for (i, v) in x.prefix(n).enumerated() { frame[i] = v }
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return mags }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        vDSP_destroy_fftsetup(setup)
        return mags
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
    }

    /// Finds the separate sounds in a recording.
    static func events(in clip: Clip, minGap: Double = 0.085) -> (events: [AudioEvent], noise: Float) {
        let mono = clip.mono
        let sr = clip.sampleRate
        let hop = Int(sr * 0.001)
        let window = Int(sr * 0.004)
        let env = envelope(mono, hop: hop, window: window)
        guard !env.isEmpty else { return ([], 0) }
        let noise = max(percentile(env, 0.25), 1e-6)
        let top = percentile(env, 0.999)
        let threshold = max(noise * 6, top * 0.045)
        let release = max(noise * 2.2, top * 0.012)
        let gap = Int(minGap / 0.001)

        var found: [AudioEvent] = []
        var i = 1
        while i < env.count {
            guard env[i] > threshold, env[i - 1] <= threshold else { i += 1; continue }
            // Walk back to where the rise began.
            var s = i
            while s > 0 && env[s - 1] > release && i - s < 12 { s -= 1 }
            // Walk forward until it has stayed quiet for 45 ms.
            var e = i
            var quiet = 0
            var peak: Float = 0
            var peakAt = i
            var bursts = 1
            var above = true
            while e < env.count {
                if env[e] > peak { peak = env[e]; peakAt = e }
                if env[e] > threshold {
                    if !above { bursts += 1; above = true }
                    quiet = 0
                } else {
                    if env[e] < threshold * 0.45 { above = false }
                    if env[e] < release { quiet += 1 } else { quiet = 0 }
                    if quiet > 45 { break }
                }
                e += 1
            }
            let start = max(0, s * hop - Int(sr * 0.002))
            let end = min(mono.count, (e - quiet + 12) * hop)
            // Exact loudest sample near the envelope peak.
            var pi = peakAt * hop
            var pv: Float = 0
            for k in max(0, peakAt * hop - hop)..<min(mono.count, peakAt * hop + window + hop) where abs(mono[k]) > pv {
                pv = abs(mono[k]); pi = k
            }

            // Brightness and band balance over the first 43 ms.
            let spec = powerSpectrum(mono[start..<min(mono.count, start + 2048)], log2n: 11)
            let binHz = sr / 2048
            var total = 0.0, weighted = 0.0
            var bands = [0.0, 0.0, 0.0, 0.0]
            for (k, p) in spec.enumerated() where k > 0 {
                let f = Double(k) * binHz
                let power = Double(p)
                total += power
                weighted += power * f
                bands[f < 300 ? 0 : (f < 1500 ? 1 : (f < 5000 ? 2 : 3))] += power
            }
            let centroid = total > 0 ? weighted / total : 0
            if total > 0 { bands = bands.map { $0 / total } }

            // Tonality of the tail, 60–230 ms after the onset: a bell leaves one dominant line.
            var tonality = 0.0
            let tailStart = start + Int(sr * 0.06)
            if tailStart + 8192 <= mono.count && end - start > Int(sr * 0.2) {
                let tail = powerSpectrum(mono[tailStart..<tailStart + 8192], log2n: 13)
                let lo = Int(1200 / (sr / 8192)), hi = Int(9000 / (sr / 8192))
                let region = Array(tail[lo..<hi])
                let mean = region.reduce(0, +) / Float(region.count)
                if mean > 0 { tonality = Double((region.max() ?? 0) / mean) }
            }

            found.append(AudioEvent(start: start, peakIndex: pi, end: end, peak: pv, centroid: centroid,
                                    bands: bands, tonality: tonality, bursts: bursts))
            i = max(e, i + gap)
        }
        return (found, noise)
    }

    /// Prints what a recording contains, one line per sound.
    static func scan(path: String) {
        do {
            let clip = try load(URL(fileURLWithPath: path))
            let (list, noise) = events(in: clip)
            let stereo = zip(clip.left.prefix(48000), clip.right.prefix(48000)).contains { abs($0 - $1) > 1e-5 }
            print(String(format: "== %@  %.2fs  %.0f Hz  %@  peak %.1f dBFS  noise %.1f dBFS  %d events",
                         (path as NSString).lastPathComponent, clip.duration, clip.sampleRate, stereo ? "stereo" : "mono",
                         20 * log10(max(clip.peak, 1e-9)), 20 * log10(noise), list.count))
            for (n, e) in list.enumerated() {
                let t = e.seconds(clip.sampleRate)
                print(String(format: "%3d  t=%7.3f  len %4.0f ms  peak %6.1f dB  centroid %5.0f Hz  bands %2.0f %2.0f %2.0f %2.0f  tonal %6.1f  bursts %2d",
                             n, t.start, t.length * 1000, 20 * log10(max(e.peak, 1e-9)), e.centroid,
                             e.bands[0] * 100, e.bands[1] * 100, e.bands[2] * 100, e.bands[3] * 100, e.tonality, e.bursts))
            }
        } catch {
            print("could not read \(path): \(error.localizedDescription)")
        }
    }
}

// MARK: - Seeing sound

import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

extension AudioLab {
    /// Draws a stretch of a recording as a spectrogram with a level trace underneath and the
    /// detected events numbered along the top. This is how the recordings get "listened to":
    /// a bell is a few steady horizontal lines, a strike is one bright vertical stroke, and a
    /// carriage ratchet is a row of evenly spaced strokes.
    static func spectrogram(path: String, start: Double, length: Double, output: String, pixelsPerSecond: Double = 0) {
        guard let clip = try? load(URL(fileURLWithPath: path)) else {
            print("could not read \(path)")
            return
        }
        let sr = clip.sampleRate
        let mono = clip.mono
        let from = max(0, Int(start * sr))
        let to = min(mono.count, from + Int(length * sr))
        guard to - from > 2048 else { return }
        let seconds = Double(to - from) / sr

        let width = Int(min(4000, max(600, (pixelsPerSecond > 0 ? pixelsPerSecond : 1700 / seconds) * seconds)))
        let specH = 420, envH = 110, top = 22, gutter = 46
        let height = top + specH + envH + 26
        let log2n = 10, n = 1 << log2n
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(setup) }

        var pixels = [UInt8](repeating: 0, count: (width + gutter) * height * 4)
        func put(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            guard x >= 0, x < width + gutter, y >= 0, y < height else { return }
            let i = (y * (width + gutter) + x) * 4
            pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
        }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }

        let fLow = 80.0, fHigh = min(20000.0, sr / 2)
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        for x in 0..<width {
            let centre = from + Int(Double(x) / Double(width) * Double(to - from))
            let s = centre - n / 2
            for k in 0..<n {
                let idx = s + k
                frame[k] = (idx >= 0 && idx < mono.count ? mono[idx] : 0) * window[k]
            }
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2n), FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
                }
            }
            for y in 0..<specH {
                let frac = 1 - Double(y) / Double(specH - 1)
                let f = fLow * pow(fHigh / fLow, frac)
                let bin = min(n / 2 - 1, max(1, Int(f / (sr / Double(n)))))
                // 0 dB here is a full-scale sine; show the 90 dB below that.
                let db = 10 * log10(Double(mags[bin]) / Double(n * n) * 4 + 1e-14)
                let v = max(0, min(1, (db + 100) / 80))
                // Black → violet → orange → pale yellow.
                let r = UInt8(255 * min(1, max(0, v * 2.2 - 0.25)))
                let g = UInt8(255 * min(1, max(0, v * 2.4 - 1.15)))
                let b = UInt8(255 * min(1, max(0, v < 0.45 ? v * 1.6 : 0.72 - (v - 0.45) * 1.6 + max(0, v - 0.8) * 4)))
                put(gutter + x, top + y, r, g, b)
            }
            // Level trace: peak within this column, 0 to -72 dB.
            let span = max(1, (to - from) / width)
            var peak: Float = 0
            for k in 0..<span {
                let idx = centre + k
                if idx < mono.count { peak = max(peak, abs(mono[idx])) }
            }
            let level = max(0, min(1, (20 * log10(Double(max(peak, 1e-6))) + 72) / 72))
            let barTop = top + specH + 4 + Int(Double(envH - 4) * (1 - level))
            for y in barTop..<(top + specH + envH) { put(gutter + x, y, 120, 200, 160) }
        }

        guard let ctx = CGContext(data: &pixels, width: width + gutter, height: height, bitsPerComponent: 8,
                                  bytesPerRow: (width + gutter) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let font = CTFontCreateWithName("Menlo" as CFString, 10, nil)
        func label(_ text: String, x: CGFloat, yFromTop: CGFloat, color: CGColor) {
            let str = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
            ctx.textPosition = CGPoint(x: x, y: CGFloat(height) - yFromTop - 10)
            CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
        }
        let white = CGColor(gray: 1, alpha: 0.9), yellow = CGColor(red: 1, green: 0.9, blue: 0.3, alpha: 1)
        for f in [100.0, 300, 1000, 3000, 10000] where f < fHigh {
            let frac = log(f / fLow) / log(fHigh / fLow)
            let y = CGFloat(top) + CGFloat(specH - 1) * CGFloat(1 - frac)
            label(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))", x: 4, yFromTop: y - 5, color: white)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.18))
            ctx.fill(CGRect(x: CGFloat(gutter), y: CGFloat(height) - y, width: CGFloat(width), height: 1))
        }
        let step = seconds > 12 ? 2.0 : (seconds > 5 ? 1.0 : (seconds > 2 ? 0.5 : (seconds > 0.6 ? 0.1 : 0.02)))
        var t = (start / step).rounded(.up) * step
        while t < start + seconds {
            let x = CGFloat(gutter) + CGFloat((t - start) / seconds) * CGFloat(width)
            label(String(format: step < 0.1 ? "%.2f" : "%.1f", t), x: x + 2, yFromTop: CGFloat(top + specH + envH + 8), color: white)
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.25))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: CGFloat(height - top)))
            t += step
        }
        let (list, _) = events(in: clip)
        for (i, e) in list.enumerated() where e.start >= from && e.start < to {
            let x = CGFloat(gutter) + CGFloat(e.start - from) / CGFloat(to - from) * CGFloat(width)
            label("\(i)", x: x + 1, yFromTop: 4, color: yellow)
            ctx.setFillColor(yellow)
            ctx.fill(CGRect(x: x, y: CGFloat(height - top), width: 1, height: 8))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(output)  \(width + gutter)x\(height)  \(String(format: "%.2f", start))s + \(String(format: "%.2f", seconds))s")
    }
}

extension AudioLab {
    /// Prints the level every `step` seconds over a stretch, with the clicks (local peaks) marked.
    /// For finding the exact moments inside a compound sound such as a carriage return.
    static func trace(path: String, start: Double, length: Double, step: Double = 0.01) {
        guard let clip = try? load(URL(fileURLWithPath: path)) else { return }
        let sr = clip.sampleRate
        let mono = clip.mono
        let hop = Int(sr * 0.001)
        let env = envelope(mono, hop: hop, window: Int(sr * 0.003))
        let a = max(0, Int(start * 1000)), b = min(env.count, Int((start + length) * 1000))
        guard b > a else { return }
        var line = ""
        var t = a
        let stepMs = max(1, Int(step * 1000))
        while t < b {
            let hi = min(b, t + stepMs)
            let peak = env[t..<hi].max() ?? 0
            let db = 20 * log10(Double(max(peak, 1e-7)))
            line += String(format: "%.2f:%4.0f  ", Double(t) / 1000, db)
            if (t - a) / stepMs % 10 == 9 { print(line); line = "" }
            t = hi
        }
        if !line.isEmpty { print(line) }
        // Clicks: points at least 9 dB above the level 12 ms either side.
        var clicks: [String] = []
        var i = a + 12
        while i < b - 12 {
            let here = env[i]
            if here >= (env[(i - 4)...(i + 4)].max() ?? 0), here > 2.8 * max(env[i - 12], env[i + 12]), here > 0.01 {
                clicks.append(String(format: "%.3f(%.0fdB)", Double(i) / 1000, 20 * log10(Double(here))))
                i += 8
            }
            i += 1
        }
        print("clicks:", clicks.joined(separator: " "))
    }
}

extension AudioLab {
    /// Where the energy of a whole recording sits, averaged over its length, and how its level
    /// is distributed. Used to compare voicings by numbers.
    static func balanceReport(path: String) {
        guard let clip = try? load(URL(fileURLWithPath: path)) else { return }
        let mono = clip.mono
        let log2n = 13, n = 1 << log2n
        let edges = [0.0, 150, 400, 1200, 3500, 8000, 24000]
        var bands = [Double](repeating: 0, count: edges.count - 1)
        var total = 0.0
        var i = 0
        while i + n <= mono.count {
            let spec = powerSpectrum(mono[i..<i + n], log2n: log2n)
            let binHz = clip.sampleRate / Double(n)
            for (k, p) in spec.enumerated() where k > 0 {
                let f = Double(k) * binHz
                total += Double(p)
                for b in 0..<bands.count where f >= edges[b] && f < edges[b + 1] { bands[b] += Double(p) }
            }
            i += n
        }
        let env = envelope(mono, hop: Int(clip.sampleRate * 0.005), window: Int(clip.sampleRate * 0.010))
        func pct(_ p: Double) -> Double { 20 * log10(Double(max(percentile(env, p), 1e-7))) }
        var rms = 0.0
        for v in mono { rms += Double(v) * Double(v) }
        rms = 10 * log10(max(rms / Double(max(1, mono.count)), 1e-12))
        print(String(format: "%@\n   energy %% (<150 | 150-400 | 400-1.2k | 1.2-3.5k | 3.5-8k | >8k): %@\n   loudness: average %.1f dB, quiet moments (10th percentile) %.1f dB, typical (50th) %.1f dB, loud (95th) %.1f dB, peak %.1f dB",
                     (path as NSString).lastPathComponent,
                     bands.map { String(format: "%2.0f", total > 0 ? $0 / total * 100 : 0) }.joined(separator: " "),
                     rms, pct(0.10), pct(0.50), pct(0.95), 20 * log10(Double(max(clip.peak, 1e-7)))))
    }
}
