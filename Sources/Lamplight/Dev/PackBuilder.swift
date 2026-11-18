import AVFoundation
import Accelerate

/// Signal processing used to turn raw recordings into finished samples.
enum DSP {
    struct Filter {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> Filter {
            Filter(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }

        static func highpass(_ f: Double, q: Double = 0.707, sr: Double) -> Filter {
            let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
            return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        }

        static func lowpass(_ f: Double, q: Double = 0.707, sr: Double) -> Filter {
            let w = 2 * Double.pi * min(f, sr * 0.45) / sr, c = cos(w), alpha = sin(w) / (2 * q)
            return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
        }

        static func peak(_ f: Double, db: Double, q: Double, sr: Double) -> Filter {
            let a = pow(10, db / 40), w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
            return make(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
        }

        static func notch(_ f: Double, q: Double, sr: Double) -> Filter {
            let w = 2 * Double.pi * f / sr, c = cos(w), alpha = sin(w) / (2 * q)
            return make(1, -2 * c, 1, 1 + alpha, -2 * c, 1 - alpha)
        }

        static func lowShelf(_ f: Double, db: Double, sr: Double) -> Filter {
            let a = pow(10, db / 40), w = 2 * Double.pi * f / sr, c = cos(w)
            let alpha = sin(w) / 2 * 2.0.squareRoot(), k = 2 * a.squareRoot() * alpha
            return make(a * ((a + 1) - (a - 1) * c + k), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - k),
                        (a + 1) + (a - 1) * c + k, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - k)
        }

        static func highShelf(_ f: Double, db: Double, sr: Double) -> Filter {
            let a = pow(10, db / 40), w = 2 * Double.pi * f / sr, c = cos(w)
            let alpha = sin(w) / 2 * 2.0.squareRoot(), k = 2 * a.squareRoot() * alpha
            return make(a * ((a + 1) + (a - 1) * c + k), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - k),
                        (a + 1) - (a - 1) * c + k, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - k)
        }

        func run(_ x: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let v = Double(x[i])
                let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = y
                out[i] = Float(y)
            }
            return out
        }
    }

    static func filter(_ clip: Clip, _ filters: [Filter]) -> Clip {
        var c = clip
        for f in filters {
            c.left = f.run(c.left)
            c.right = f.run(c.right)
        }
        return c
    }

    static func gain(_ clip: Clip, db: Double) -> Clip {
        var c = clip
        var g = Float(pow(10, db / 20))
        vDSP_vsmul(c.left, 1, &g, &c.left, 1, vDSP_Length(c.count))
        vDSP_vsmul(c.right, 1, &g, &c.right, 1, vDSP_Length(c.count))
        return c
    }

    static func normalize(_ clip: Clip, peakDB: Double) -> Clip {
        let p = clip.peak
        guard p > 0 else { return clip }
        return gain(clip, db: peakDB - 20 * log10(Double(p)))
    }

    /// Raised-cosine fades so nothing starts or stops with a click.
    static func fade(_ clip: Clip, inMs: Double, outMs: Double) -> Clip {
        var c = clip
        let nIn = min(c.count, Int(inMs / 1000 * c.sampleRate))
        let nOut = min(c.count, Int(outMs / 1000 * c.sampleRate))
        for i in 0..<nIn {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(max(1, nIn))))
            c.left[i] *= g; c.right[i] *= g
        }
        for i in 0..<nOut {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(max(1, nOut))))
            c.left[c.count - 1 - i] *= g; c.right[c.count - 1 - i] *= g
        }
        return c
    }

    static func pad(_ clip: Clip, before: Int = 0, after: Int = 0) -> Clip {
        let zb = [Float](repeating: 0, count: max(0, before)), za = [Float](repeating: 0, count: max(0, after))
        return Clip(left: zb + clip.left + za, right: zb + clip.right + za, sampleRate: clip.sampleRate)
    }

    static func concat(_ parts: [Clip]) -> Clip {
        guard let first = parts.first else { return Clip(mono: [], sampleRate: 48000) }
        return Clip(left: parts.flatMap { $0.left }, right: parts.flatMap { $0.right }, sampleRate: first.sampleRate)
    }

    /// Joins two clips with an overlap so the seam cannot be heard.
    static func crossfade(_ a: Clip, _ b: Clip, ms: Double) -> Clip {
        let n = min(a.count, b.count, Int(ms / 1000 * a.sampleRate))
        guard n > 0 else { return concat([a, b]) }
        var left = Array(a.left.dropLast(n)), right = Array(a.right.dropLast(n))
        for i in 0..<n {
            let t = Float(i) / Float(n)
            let gOut = cos(t * .pi / 2), gIn = sin(t * .pi / 2)
            left.append(a.left[a.count - n + i] * gOut + b.left[i] * gIn)
            right.append(a.right[a.count - n + i] * gOut + b.right[i] * gIn)
        }
        left.append(contentsOf: b.left.dropFirst(n))
        right.append(contentsOf: b.right.dropFirst(n))
        return Clip(left: left, right: right, sampleRate: a.sampleRate)
    }

    /// Plays a clip faster or slower (which also raises or lowers its pitch), by cubic interpolation.
    static func resample(_ clip: Clip, speed: Double) -> Clip {
        guard clip.count > 4, speed > 0 else { return clip }
        let n = Int(Double(clip.count) / speed)
        func run(_ x: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let pos = Double(i) * speed
                let k = Int(pos)
                let t = Float(pos - Double(k))
                let p0 = x[max(0, k - 1)], p1 = x[min(x.count - 1, k)]
                let p2 = x[min(x.count - 1, k + 1)], p3 = x[min(x.count - 1, k + 2)]
                let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3
                let b = p0 - 2.5 * p1 + 2 * p2 - 0.5 * p3
                let c = -0.5 * p0 + 0.5 * p2
                out[i] = ((a * t + b) * t + c) * t + p1
            }
            return out
        }
        return Clip(left: run(clip.left), right: run(clip.right), sampleRate: clip.sampleRate)
    }

    /// Mixes a heavily compressed copy under the original. Loud moments stay as they were,
    /// while the quiet parts — the key travelling, the mechanism settling, the tail — come
    /// forward. This is most of what makes a recording feel close to the ear.
    ///
    /// Only the detail above `detailAbove` Hz is lifted. Lifting everything also lifts the
    /// low rumble in each tail, which turns a row of keystrokes into a continuous boom.
    static func bringForward(_ clip: Clip, thresholdDB: Double = -34, ratio: Double = 8, makeupDB: Double = 14, mix: Double = 0.40,
                             detailAbove: Double = 650) -> Clip {
        var c = clip
        let sr = clip.sampleRate
        let hp = Filter.highpass(detailAbove, sr: sr)
        let detailL = hp.run(clip.left), detailR = hp.run(clip.right)
        let attack = exp(-1 / (0.0006 * sr)), release = exp(-1 / (0.045 * sr))
        var env = 0.0
        let makeup = pow(10, makeupDB / 20)
        for i in 0..<clip.count {
            let level = Double(max(abs(clip.left[i]), abs(clip.right[i])))
            env = level > env ? attack * env + (1 - attack) * level : release * env + (1 - release) * level
            let db = 20 * log10(max(env, 1e-9))
            let over = max(0, db - thresholdDB)
            // Below the threshold nothing is added either: silence stays silent.
            let under = max(0, thresholdDB - 18 - db)
            let g = pow(10, (-over * (1 - 1 / ratio) - under * 1.5) / 20) * makeup * mix
            c.left[i] = clip.left[i] + detailL[i] * Float(g)
            c.right[i] = clip.right[i] + detailR[i] * Float(g)
        }
        return c
    }

    /// Lets the low end of a strike sound and then stop. The "thock" stays deep, but it does
    /// not hang on as a hum under the next key.
    static func tighten(_ clip: Clip, after seconds: Double, below cutoff: Double = 420, decay: Double = 0.060) -> Clip {
        var c = clip
        let sr = clip.sampleRate
        let lp = Filter.lowpass(cutoff, sr: sr)
        let lowL = lp.run(lp.run(clip.left)), lowR = lp.run(lp.run(clip.right))
        let hold = Int(seconds * sr)
        for i in 0..<clip.count where i > hold {
            let g = Float(exp(-Double(i - hold) / sr / decay))
            // Remove the part of the low band the envelope takes away.
            c.left[i] -= lowL[i] * (1 - g)
            c.right[i] -= lowR[i] * (1 - g)
        }
        return c
    }

    /// Level of a clip around given moments, relative to its peak, for comparing voicings.
    static func profile(_ clip: Clip, lead: Double) -> String {
        let sr = clip.sampleRate
        let p = Double(max(clip.peak, 1e-9))
        func rms(_ a: Double, _ b: Double) -> Double {
            let lo = max(0, Int(a * sr)), hi = min(clip.count, Int(b * sr))
            guard hi > lo else { return -120 }
            var sum = 0.0
            for i in lo..<hi { let v = Double(clip.left[i] + clip.right[i]) * 0.5; sum += v * v }
            return 20 * log10(max((sum / Double(hi - lo)).squareRoot() / p, 1e-6))
        }
        return String(format: "travel %5.1f  impact %5.1f  +0.1s %5.1f  +0.2s %5.1f  +0.3s %5.1f dB",
                      rms(max(0, lead - 0.040), max(0.002, lead - 0.004)), rms(lead, lead + 0.03), rms(lead + 0.08, lead + 0.13),
                      rms(lead + 0.18, lead + 0.23), rms(lead + 0.28, lead + 0.33))
    }

    /// Rounds off the very top of the loudest peaks.
    static func soften(_ clip: Clip, drive: Double) -> Clip {
        var c = clip
        let p = Double(max(clip.peak, 1e-6))
        let norm = tanh(drive)
        for i in 0..<clip.count {
            c.left[i] = Float(tanh(Double(clip.left[i]) / p * drive) / norm * p)
            c.right[i] = Float(tanh(Double(clip.right[i]) / p * drive) / norm * p)
        }
        return c
    }

    /// Widens a stereo recording, or gives a mono one a little room: a few quiet, dulled
    /// reflections that differ between the ears.
    static func widen(_ clip: Clip, sideGain: Double, reflections: Double) -> Clip {
        var c = clip
        if sideGain != 1 {
            for i in 0..<c.count {
                let mid = (c.left[i] + c.right[i]) * 0.5, side = (c.left[i] - c.right[i]) * 0.5 * Float(sideGain)
                c.left[i] = mid + side
                c.right[i] = mid - side
            }
        }
        guard reflections > 0 else { return c }
        let sr = clip.sampleRate
        let dull = Filter.lowpass(3600, sr: sr)
        let softL = dull.run(c.left), softR = dull.run(c.right)
        let taps: [(Double, Double, Double)] = [(0.0063, 0.0087, 1.0), (0.0127, 0.0109, 0.7), (0.0191, 0.0223, 0.5), (0.0287, 0.0259, 0.33)]
        let tail = Int(0.032 * sr)
        c = pad(c, after: tail)
        for (dl, dr, g) in taps {
            let ol = Int(dl * sr), or = Int(dr * sr), gain = Float(g * reflections)
            for i in 0..<softL.count {
                c.left[i + ol] += softR[i] * gain
                c.right[i + or] += softL[i] * gain
            }
        }
        return c
    }

    /// Share of energy in each band, for checking what an equaliser actually did.
    static func balance(_ clip: Clip) -> [Double] {
        let mono = clip.mono
        let log2n = 15
        let spec = AudioLab.powerSpectrum(mono[0..<min(mono.count, 1 << log2n)], log2n: log2n)
        let binHz = clip.sampleRate / Double(1 << log2n)
        let edges = [0.0, 150, 400, 1200, 3500, 8000, 24000]
        var bands = [Double](repeating: 0, count: edges.count - 1)
        var total = 0.0
        for (k, p) in spec.enumerated() where k > 0 {
            let f = Double(k) * binHz
            total += Double(p)
            for b in 0..<bands.count where f >= edges[b] && f < edges[b + 1] { bands[b] += Double(p) }
        }
        return total > 0 ? bands.map { $0 / total } : bands
    }
}

/// What the app reads to know what is in a pack.
struct PackManifest: Codable {
    struct Entry: Codable {
        var file: String
    }
    var id: String
    var name: String
    var machine: String
    var credit: String
    /// Seconds from the start of every strike sample to the moment of impact.
    var strikeLead: Double
    /// The samples already contain the sound of the key going down.
    var hasKeyTravel: Bool
    var sounds: [String: [Entry]]
}

/// Builds the sound packs from the recordings in `SoundSources/`.
///   Lamplight --build-packs
enum PackBuilder {
    struct Take {
        var clip: Clip
        var lead: Double
    }

    /// How the samples of one pack are finished.
    struct Voicing {
        var id: String
        var name: String
        var strike: (Clip) -> Clip
        var soft: (Clip) -> Clip       // space bar and backspace
        var carriage: (Clip) -> Clip
        var bell: (Clip) -> Clip
    }

    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static var sources: URL { root.appendingPathComponent("SoundSources") }
    static var output: URL { root.appendingPathComponent("Resources/Sounds") }
    static var samples: URL { root.appendingPathComponent("docs/sound-samples") }

    // MARK: - Cutting

    /// Single, well-separated key strikes, each starting exactly `lead` seconds before impact.
    static func strikes(in clip: Clip, lead: Double, maxLength: Double = 0.52, limit: Int = 40) -> [Take] {
        let sr = clip.sampleRate
        let (events, _) = AudioLab.events(in: clip)
        let mono = clip.mono
        let top = clip.peak
        var out: [(score: Float, take: Take)] = []
        for (i, e) in events.enumerated() {
            guard e.peak > top * 0.42 else { continue }
            let length = Double(e.end - e.start) / sr
            guard length > 0.10, length < 0.60 else { continue }
            // The impact: loudest sample in the first 150 ms.
            var peakAt = e.start
            var peak: Float = 0
            for k in e.start..<min(mono.count, e.start + Int(0.15 * sr)) where abs(mono[k]) > peak {
                peak = abs(mono[k]); peakAt = k
            }
            // Quiet before, and nothing else starting for a third of a second after.
            if i > 0, events[i - 1].end > peakAt - Int((lead + 0.03) * sr) { continue }
            if i + 1 < events.count, events[i + 1].start < peakAt + Int(0.33 * sr) { continue }
            // One strike only: nothing nearly as loud later in the same event.
            var second: Float = 0
            let after = peakAt + Int(0.06 * sr)
            if after < e.end { for k in after..<e.end { second = max(second, abs(mono[k])) } }
            guard second < peak * 0.55 else { continue }

            let start = peakAt - Int(lead * sr)
            guard start >= 0 else { continue }
            let end = min(clip.count, min(e.end + Int(0.03 * sr), start + Int(maxLength * sr)))
            let slice = DSP.fade(clip.slice(start..<end), inMs: 2, outMs: 30)
            out.append((peak, Take(clip: slice, lead: lead)))
        }
        // Keep the firmer strikes if there are more than needed, in recording order otherwise.
        if out.count > limit {
            let cut = out.map { $0.score }.sorted(by: >)[limit - 1]
            out = out.filter { $0.score >= cut }
        }
        return out.map { $0.take }
    }

    /// The whole of one event, with a little air before it.
    static func whole(_ clip: Clip, event e: AudioEvent, preMs: Double = 4, maxLength: Double = 1.6, fadeOutMs: Double = 40) -> Clip {
        let sr = clip.sampleRate
        let start = max(0, e.start - Int(preMs / 1000 * sr))
        let end = min(clip.count, min(e.end + Int(0.03 * sr), start + Int(maxLength * sr)))
        return DSP.fade(clip.slice(start..<end), inMs: 1.5, outMs: fadeOutMs)
    }

    static func cut(_ clip: Clip, from: Double, to: Double) -> Clip {
        clip.slice(Int(from * clip.sampleRate)..<Int(to * clip.sampleRate))
    }

    /// Assembles a carriage return of a chosen length from the parts of a real one: the lever
    /// clicks, as much of the slide as the distance needs, then the stop and the lever letting go.
    /// The stop lands exactly `stopAt` seconds in, which is when the carriage arrives on screen.
    static func carriage(lever: Clip, slide: Clip, stop: Clip, stopAt: Double) -> Clip {
        let sr = lever.sampleRate
        let target = Int(stopAt * sr)
        var body = DSP.fade(lever, inMs: 3, outMs: 0)
        if body.count > target - Int(0.03 * sr) {
            // A short hop: there is only room for the first of the lever's clicks.
            body = DSP.fade(body.slice(0..<max(Int(0.05 * sr), target - Int(0.03 * sr))), inMs: 0, outMs: 18)
        } else {
            let room = target - body.count
            let piece = slide.count > room ? slide.slice(0..<room) : slide
            body = DSP.crossfade(body, DSP.fade(piece, inMs: 0, outMs: 30), ms: 25)
        }
        if body.count < target { body = DSP.pad(body, after: target - body.count) }
        if body.count > target { body = DSP.fade(body.slice(0..<target), inMs: 0, outMs: 12) }
        return DSP.concat([body, DSP.fade(stop, inMs: 0.5, outMs: 60)])
    }

    /// Frequencies at which a clip rings: the strongest narrow lines in its tail.
    static func ringing(_ clip: Clip, count: Int) -> [Double] {
        let mono = clip.mono
        let start = min(mono.count - 1, Int(0.12 * clip.sampleRate))
        let log2n = 14
        let spec = AudioLab.powerSpectrum(mono[start..<min(mono.count, start + (1 << log2n))], log2n: log2n)
        let binHz = clip.sampleRate / Double(1 << log2n)
        var peaks: [(Float, Double)] = []
        for k in 40..<(spec.count - 2) where spec[k] > spec[k - 1] && spec[k] > spec[k + 1] && spec[k] > spec[k - 2] && spec[k] > spec[k + 2] {
            peaks.append((spec[k], Double(k) * binHz))
        }
        var chosen: [Double] = []
        for (_, f) in peaks.sorted(by: { $0.0 > $1.0 }) {
            if chosen.allSatisfy({ abs($0 - f) > 120 }) { chosen.append(f) }
            if chosen.count == count { break }
        }
        return chosen.sorted()
    }

    // MARK: - Writing

    static func write(_ manifest: PackManifest, takes: [String: [Clip]]) {
        let dir = output.appendingPathComponent(manifest.id)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m = manifest
        for (kind, clips) in takes.sorted(by: { $0.key < $1.key }) {
            var entries: [PackManifest.Entry] = []
            for (i, clip) in clips.enumerated() {
                let name = String(format: "%@-%02d.wav", kind, i + 1)
                do {
                    try AudioLab.save(clip, to: dir.appendingPathComponent(name))
                    entries.append(.init(file: name))
                } catch {
                    print("could not write \(name): \(error.localizedDescription)")
                }
            }
            m.sounds[kind] = entries
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(m) { try? data.write(to: dir.appendingPathComponent("pack.json")) }
        let summary = takes.sorted(by: { $0.key < $1.key }).map { "\($0.key)×\($0.value.count)" }.joined(separator: "  ")
        print("pack \(m.id): \(summary)")
    }

    // MARK: - Demo

    /// A few seconds of typing as the app would play it: a line of text at an easy pace,
    /// a mistake corrected, the bell, and the carriage coming home.
    static func demo(_ takes: [String: [Clip]], strikeLead: Double, seed: UInt64 = 7) -> Clip {
        let sr = 48000.0
        var rng = SplitMix(seed)
        var mix = Clip(mono: [Float](repeating: 0, count: Int(sr * 20)), sampleRate: sr)
        var last: [String: Int] = [:]
        func add(_ kind: String, at time: Double, pan: Double, gainDB: Double) {
            guard let list = takes[kind], !list.isEmpty else { return }
            var index = Int(rng.next() % UInt64(list.count))
            if list.count > 1, index == last[kind] { index = (index + 1) % list.count }
            last[kind] = index
            let clip = list[index]
            let start = Int(time * sr)
            let g = Float(pow(10, gainDB / 20))
            let gl = g * Float(min(1, 1 - pan)), gr = g * Float(min(1, 1 + pan))
            for i in 0..<clip.count where start + i >= 0 && start + i < mix.count {
                mix.left[start + i] += clip.left[i] * gl
                mix.right[start + i] += clip.right[i] * gr
            }
        }
        var t = 0.35
        var end = t
        func key(_ ch: Character) {
            if ch == " " {
                add("space", at: t, pan: 0, gainDB: -1 + Double(rng.signed()))
            } else {
                add("strike", at: t + 0.05 - strikeLead, pan: Double(KeyMap.position(of: String(ch))) * 0.32, gainDB: -1.5 + Double(rng.signed()) * 1.5)
            }
            t += 0.15 + Double(rng.unit()) * 0.13 + (ch == " " ? 0.05 : 0)
            end = t
        }
        for ch in "the lamp is lit " { key(ch) }
        for ch in "adn" { key(ch) }
        t += 0.22
        for _ in 0..<2 { add("back", at: t, pan: 0, gainDB: 0); t += 0.24 }
        t += 0.1
        for ch in "nd the room is " { key(ch) }
        key("q")
        add("bell", at: t - 0.16, pan: 0.1, gainDB: 0)
        for ch in "uiet" { key(ch) }
        t += 0.25
        add("carriage3", at: t, pan: 0, gainDB: 0)
        t += 1.25
        for ch in "one key at a time" { key(ch) }
        end = t + 0.9
        return DSP.fade(mix.slice(0..<min(mix.count, Int(end * sr))), inMs: 0, outMs: 200)
    }

    static func saveCompressed(_ clip: Clip, to url: URL) {
        // AAC keeps the page small; the app itself uses the uncompressed files.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: clip.sampleRate, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 224_000,
        ]
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, clip.count))),
              let data = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(clip.count)
        clip.left.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress!, count: clip.count) }
        clip.right.withUnsafeBufferPointer { data[1].update(from: $0.baseAddress!, count: clip.count) }
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        } catch {
            print("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
