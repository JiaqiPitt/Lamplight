import Foundation

/// Builds every sound of the machine from noise bursts and ringing modes.
/// Nothing is recorded: a strike is a click, a slap on rubber and a handful of
/// short metallic resonances, each detuned a little so no two are identical.
enum Synth {
    static let sampleRate: Double = 48000

    struct Biquad {
        var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        static func lowpass(_ fc: Double, q: Double = 0.707) -> Biquad {
            let w = 2 * Double.pi * min(fc, sampleRate * 0.45) / sampleRate
            let alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            return Biquad(b0: Float((1 - c) / 2 / a0), b1: Float((1 - c) / a0), b2: Float((1 - c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        static func highpass(_ fc: Double, q: Double = 0.707) -> Biquad {
            let w = 2 * Double.pi * max(fc, 10) / sampleRate
            let alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha
            return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                          a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// A mono sound under construction.
    struct Voice {
        var samples: [Float]
        var rng: SplitMix

        init(duration: Double, seed: UInt64) {
            samples = [Float](repeating: 0, count: Int(duration * sampleRate))
            rng = SplitMix(seed)
        }

        mutating func rand() -> Float { Float(rng.signed()) }
        mutating func unit() -> Float { Float(rng.unit()) }

        /// Filtered noise with an exponential decay — clicks, slaps and thumps.
        mutating func burst(at t: Double, amp: Float, decay: Double, low: Double, high: Double, attack: Double = 0) {
            let start = Int(t * sampleRate)
            let n = min(samples.count - start, Int((attack + decay * 9) * sampleRate))
            guard start >= 0, n > 0 else { return }
            var hp1 = Biquad.highpass(low), hp2 = Biquad.highpass(low)
            var lp1 = Biquad.lowpass(high), lp2 = Biquad.lowpass(high)
            // Narrow bands lose energy; make up for it so `amp` means roughly the same everywhere.
            let makeup = Float(1.0 / max(0.12, sqrt((high - low) / 9000)))
            for i in 0..<n {
                let time = Double(i) / sampleRate
                var env = Float(exp(-max(0, time - attack) / decay))
                if attack > 0 && time < attack { env *= Float(time / attack) }
                let x = lp2.process(lp1.process(hp2.process(hp1.process(rand()))))
                samples[start + i] += x * env * amp * makeup
            }
        }

        /// A decaying sine — one resonance of a piece of metal.
        mutating func mode(at t: Double, freq: Double, amp: Float, decay: Double) {
            let start = Int(t * sampleRate)
            let n = min(samples.count - start, Int(decay * 9 * sampleRate))
            guard start >= 0, n > 0 else { return }
            let phase = Double(unit()) * 2 * .pi
            let w = 2 * Double.pi * freq / sampleRate
            for i in 0..<n {
                let env = Float(exp(-Double(i) / sampleRate / decay))
                // A two-sample ramp keeps the onset from clicking by itself.
                let ramp = Float(min(1, Double(i) / 12))
                samples[start + i] += Float(sin(w * Double(i) + phase)) * env * amp * ramp
            }
        }

        /// Continuous filtered noise shaped by an arbitrary envelope.
        mutating func wash(from t0: Double, to t1: Double, low: Double, high: Double, envelope: (Double) -> Float) {
            let start = max(0, Int(t0 * sampleRate))
            let end = min(samples.count, Int(t1 * sampleRate))
            guard end > start else { return }
            var hp = Biquad.highpass(low), lp = Biquad.lowpass(high)
            for i in start..<end {
                let u = Double(i - start) / Double(end - start)
                samples[i] += lp.process(hp.process(rand())) * envelope(u)
            }
        }
    }

    // MARK: - The sounds

    static func strike(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.20, seed: seed)
        let detune = 1 + Double(v.rand()) * 0.045
        v.burst(at: 0, amp: 0.85, decay: 0.0011, low: 2600, high: 9000)
        v.burst(at: 0, amp: 0.55, decay: 0.0085, low: 1400, high: 4200)
        v.burst(at: 0, amp: 0.80, decay: 0.026, low: 90, high: 380)
        v.mode(at: 0, freq: 172 * detune, amp: 0.34, decay: 0.034)
        let modes: [(Double, Float, Double)] = [
            (455, 0.20, 0.024), (1020, 0.17, 0.016), (1730, 0.13, 0.011),
            (2840, 0.10, 0.008), (4100, 0.07, 0.006), (5600, 0.04, 0.004),
        ]
        for (f, a, d) in modes {
            v.mode(at: 0, freq: f * detune * (1 + Double(v.rand()) * 0.03), amp: a * (0.8 + 0.4 * v.unit()), decay: d)
        }
        // The bar dropping back onto its felt rest.
        let back = 0.078 + Double(v.unit()) * 0.012
        v.burst(at: back, amp: 0.15, decay: 0.006, low: 700, high: 2200)
        v.burst(at: back, amp: 0.16, decay: 0.014, low: 120, high: 420)
        return v.samples
    }

    static func key(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.07, seed: seed)
        v.burst(at: 0, amp: 0.30, decay: 0.004, low: 900, high: 3000)
        v.burst(at: 0, amp: 0.26, decay: 0.012, low: 150, high: 600)
        v.mode(at: 0, freq: 780 * (1 + Double(v.rand()) * 0.06), amp: 0.07, decay: 0.010)
        return v.samples
    }

    static func space(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.16, seed: seed)
        v.burst(at: 0, amp: 0.62, decay: 0.020, low: 100, high: 520)
        v.mode(at: 0, freq: 128 * (1 + Double(v.rand()) * 0.04), amp: 0.32, decay: 0.040)
        v.burst(at: 0, amp: 0.20, decay: 0.003, low: 1500, high: 5000)
        v.burst(at: 0.062, amp: 0.13, decay: 0.010, low: 200, high: 900)
        return v.samples
    }

    static func back(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.12, seed: seed)
        v.burst(at: 0, amp: 0.34, decay: 0.005, low: 1200, high: 3500)
        v.burst(at: 0, amp: 0.30, decay: 0.014, low: 140, high: 520)
        v.burst(at: 0.030, amp: 0.20, decay: 0.004, low: 1000, high: 3000)
        v.mode(at: 0.030, freq: 940, amp: 0.06, decay: 0.012)
        return v.samples
    }

    static func tape(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.14, seed: seed)
        v.burst(at: 0, amp: 0.26, decay: 0.026, low: 3000, high: 9000, attack: 0.004)
        v.burst(at: 0.012, amp: 0.22, decay: 0.008, low: 400, high: 1200)
        return v.samples
    }

    static func bell(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 1.5, seed: seed)
        let f0 = 2093.0
        v.burst(at: 0, amp: 0.22, decay: 0.002, low: 2000, high: 8000)
        v.mode(at: 0, freq: f0, amp: 0.34, decay: 0.42)
        v.mode(at: 0, freq: f0 * 1.0035, amp: 0.18, decay: 0.36)
        v.mode(at: 0, freq: f0 * 2.76, amp: 0.15, decay: 0.20)
        v.mode(at: 0, freq: f0 * 5.40, amp: 0.07, decay: 0.09)
        v.mode(at: 0, freq: f0 * 8.93, amp: 0.03, decay: 0.05)
        return v.samples
    }

    static func feed(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.14, seed: seed)
        for k in 0..<3 {
            let t = Double(k) * 0.019
            v.burst(at: t, amp: 0.36, decay: 0.004, low: 900, high: 2600)
            v.mode(at: t, freq: 1150 * (1 + Double(v.rand()) * 0.04), amp: 0.10, decay: 0.010)
        }
        v.burst(at: 0, amp: 0.25, decay: 0.020, low: 120, high: 400)
        return v.samples
    }

    static func tick(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.06, seed: seed)
        v.burst(at: 0, amp: 0.30, decay: 0.003, low: 1000, high: 3200)
        v.mode(at: 0, freq: 1300 * (1 + Double(v.rand()) * 0.05), amp: 0.07, decay: 0.008)
        return v.samples
    }

    static func lock(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.25, seed: seed)
        v.mode(at: 0, freq: 96, amp: 0.50, decay: 0.050)
        v.burst(at: 0, amp: 0.45, decay: 0.030, low: 80, high: 300)
        v.burst(at: 0, amp: 0.10, decay: 0.004, low: 600, high: 1500)
        return v.samples
    }

    static func lampSwitch(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.22, seed: seed)
        for (t, a) in [(0.0, Float(0.50)), (0.046, Float(0.36))] {
            v.burst(at: t, amp: a, decay: 0.0025, low: 1500, high: 6000)
            v.mode(at: t, freq: 2400, amp: a * 0.26, decay: 0.012)
            v.mode(at: t, freq: 620, amp: a * 0.36, decay: 0.020)
        }
        return v.samples
    }

    /// The carriage flying home: line-feed ratchet, the rack zipping past, then the stop.
    static func carriage(duration d: Double, seed: UInt64) -> [Float] {
        var v = Voice(duration: d + 0.75, seed: seed)
        for k in 0..<3 {
            let t = Double(k) * 0.017
            v.burst(at: t, amp: 0.30, decay: 0.004, low: 900, high: 2600)
            v.mode(at: t, freq: 1150, amp: 0.08, decay: 0.010)
        }
        // Rack teeth, faster and faster as the mainspring wins.
        var t = 0.012
        while t < d - 0.004 {
            let u = t / d
            let rate = 150 + 290 * u
            v.burst(at: t, amp: 0.13 * (0.7 + 0.3 * v.unit()), decay: 0.0022, low: 1500, high: 5200)
            t += (1 / rate) * (1 + Double(v.rand()) * 0.07)
        }
        v.wash(from: 0, to: d, low: 200, high: 900) { u in 0.035 + 0.075 * Float(u) }
        // The stop.
        v.burst(at: d, amp: 0.95, decay: 0.030, low: 70, high: 300)
        v.mode(at: d, freq: 88, amp: 0.50, decay: 0.070)
        v.burst(at: d, amp: 0.50, decay: 0.010, low: 500, high: 2000)
        v.mode(at: d, freq: 640, amp: 0.20, decay: 0.050)
        v.mode(at: d, freq: 1320, amp: 0.13, decay: 0.040)
        v.mode(at: d, freq: 2150, amp: 0.07, decay: 0.030)
        // The bell rings along faintly.
        v.mode(at: d, freq: 2093, amp: 0.025, decay: 0.45)
        return v.samples
    }

    static func paperIn(_ seed: UInt64) -> [Float] {
        let d = Mechanics.paperInDuration
        var v = Voice(duration: d + 0.3, seed: seed)
        let n = Mechanics.paperInSteps
        for k in 0..<n {
            let t = Double(k) * d / Double(n)
            v.burst(at: t, amp: 0.33 * (0.85 + 0.3 * v.unit()), decay: 0.0035, low: 1000, high: 3000)
            v.mode(at: t, freq: 900 * (1 + Double(v.rand()) * 0.05), amp: 0.09, decay: 0.012)
            v.burst(at: t, amp: 0.10, decay: 0.014, low: 2500, high: 7000)
        }
        v.wash(from: 0, to: d + 0.1, low: 2500, high: 7000) { u in 0.035 * Float(sin(u * .pi)) }
        return v.samples
    }

    static func paperOut(_ seed: UInt64) -> [Float] {
        var v = Voice(duration: 0.6, seed: seed)
        var t = 0.0
        while t < 0.33 {
            let u = t / 0.33
            v.burst(at: t, amp: 0.20 * (0.8 + 0.3 * v.unit()), decay: 0.003, low: 1000, high: 3200)
            t += 1 / (38 + 80 * u)
        }
        v.wash(from: 0.02, to: 0.44, low: 1200, high: 6000) { u in 0.13 * Float(sin(u * .pi)) * Float(0.4 + 0.6 * u) }
        return v.samples
    }

    // MARK: - Finishing

    /// Places a mono sound in a small room: a few soft early reflections that differ between
    /// the ears, then a gentle limiter.
    static func stereo(_ mono: [Float], gain: Float = 1) -> (left: [Float], right: [Float]) {
        let tail = Int(0.045 * sampleRate)
        let n = mono.count + tail
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let taps: [(Double, Double, Float)] = [(0.0071, 0.0093, 0.13), (0.0137, 0.0119, 0.09), (0.0213, 0.0241, 0.06), (0.0317, 0.0289, 0.04)]
        var dampL = Biquad.lowpass(3200), dampR = Biquad.lowpass(3200)
        var softL = [Float](repeating: 0, count: mono.count)
        var softR = [Float](repeating: 0, count: mono.count)
        for i in 0..<mono.count {
            softL[i] = dampL.process(mono[i])
            softR[i] = dampR.process(mono[i])
        }
        for i in 0..<mono.count {
            left[i] += mono[i]
            right[i] += mono[i]
        }
        for (dl, dr, g) in taps {
            let ol = Int(dl * sampleRate), or = Int(dr * sampleRate)
            for i in 0..<mono.count {
                left[i + ol] += softL[i] * g
                right[i + or] += softR[i] * g
            }
        }
        for i in 0..<n {
            left[i] = tanh(left[i] * gain * 1.05) * 0.92
            right[i] = tanh(right[i] * gain * 1.05) * 0.92
        }
        // Fade the very end so nothing clicks off.
        let fade = min(n, Int(0.004 * sampleRate))
        for i in 0..<fade {
            let g = Float(i) / Float(fade)
            left[n - 1 - i] *= g
            right[n - 1 - i] *= g
        }
        return (left, right)
    }

    /// Every sound, with a few variants of those that are heard most.
    static func all() -> [Sound: [(left: [Float], right: [Float])]] {
        var out: [Sound: [(left: [Float], right: [Float])]] = [:]
        out[.strike] = (0..<10).map { stereo(strike(UInt64(100 + $0)), gain: 0.92) }
        out[.key] = (0..<6).map { stereo(key(UInt64(200 + $0))) }
        out[.space] = (0..<4).map { stereo(space(UInt64(300 + $0))) }
        out[.back] = (0..<3).map { stereo(back(UInt64(400 + $0))) }
        out[.tape] = (0..<3).map { stereo(tape(UInt64(500 + $0))) }
        out[.bell] = [stereo(bell(600), gain: 0.9)]
        out[.feed] = (0..<3).map { stereo(feed(UInt64(700 + $0))) }
        out[.tick] = (0..<4).map { stereo(tick(UInt64(800 + $0))) }
        out[.lock] = [stereo(lock(900))]
        out[.lampSwitch] = [stereo(lampSwitch(1000))]
        out[.paperIn] = [stereo(paperIn(1100))]
        out[.paperOut] = [stereo(paperOut(1200))]
        for (i, d) in Mechanics.carriageDurations.enumerated() {
            out[.carriage(i)] = (0..<2).map { stereo(carriage(duration: d, seed: UInt64(1300 + i * 10 + $0)), gain: 0.9) }
        }
        return out
    }
}
