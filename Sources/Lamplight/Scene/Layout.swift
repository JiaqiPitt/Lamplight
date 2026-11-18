import CoreGraphics

/// Every measurement of the scene, derived from the window size.
/// All values are in points; the scene's origin is the bottom-left corner.
struct Layout: Equatable {
    var size: CGSize
    /// Scale of the whole machine relative to the 1512×982 design size.
    var zoom: CGFloat
    /// Device pixels per point.
    var ps: CGFloat
    var cellW: CGFloat
    var lineH: CGFloat
    var fontSize: CGFloat
    /// Blank paper left and right of the text block.
    var marginX: CGFloat
    /// Baseline of the line being typed.
    var lineY: CGFloat
    var railY: CGFloat
    var housingTop: CGFloat
    /// Top edge of the machine's deck; the paper disappears behind it.
    var deckTop: CGFloat
    /// Distance from the top of a row down to its baseline.
    var baselineDrop: CGFloat
    /// Blank paper above the first row.
    var topPad: CGFloat

    init(size: CGSize, textScale: CGFloat, pixelScale: CGFloat) {
        self.size = size
        ps = max(pixelScale, 1)
        let fit = min(size.width * 0.635 / 960, size.height / 982 * 1.12)
        zoom = max(0.5, min(1.75, fit)) * textScale
        let scale = ps
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        cellW = snap(13.2 * zoom)
        lineH = snap(36 * zoom)
        // Courier New advances exactly 0.6 em, so one glyph fills one cell.
        fontSize = cellW / 0.6
        marginX = snap(84 * zoom)
        lineY = snap(max(size.height * 0.255, 190 * zoom))
        railY = lineY - snap(36 * zoom)
        housingTop = lineY - snap(15 * zoom)
        deckTop = railY - snap(17 * zoom)
        baselineDrop = snap(0.74 * lineH)
        topPad = snap(3.2 * lineH)
    }

    var textW: CGFloat { CGFloat(Grid.cols) * cellW }
    var paperW: CGFloat { textW + 2 * marginX }
    /// Size of one rendered row of ink, including room for misaligned glyphs.
    var rowPadX: CGFloat { 3 * cellW }
    var rowPadY: CGFloat { (8 * zoom * ps).rounded() / ps }
    var rowSize: CGSize { CGSize(width: textW + 2 * rowPadX, height: lineH + 2 * rowPadY) }
}

/// A small deterministic generator so each strike keeps its own quirks.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0xD1B54A32D192ED03 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    /// A value in 0..<1.
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) / CGFloat(1 << 53) }
    /// A value in -1..<1.
    mutating func signed() -> CGFloat { unit() * 2 - 1 }
}

/// Where a character sits on a QWERTY keyboard, from -1 (far left) to 1 (far right).
/// It decides which side its typebar swings in from and where its sound sits in stereo.
enum KeyMap {
    private static let rows: [(String, CGFloat)] = [
        ("`1234567890-=", 0), ("~!@#$%^&*()_+", 0),
        ("qwertyuiop[]\\", 0.5), ("QWERTYUIOP{}|", 0.5),
        ("asdfghjkl;'", 0.8), ("ASDFGHJKL:\"", 0.8),
        ("zxcvbnm,./", 1.3), ("ZXCVBNM<>?", 1.3),
    ]
    private static let table: [Character: CGFloat] = {
        var t: [Character: CGFloat] = [:]
        for (keys, offset) in rows {
            for (i, ch) in keys.enumerated() {
                t[ch] = ((CGFloat(i) + offset) / 12.5) * 2 - 1
            }
        }
        return t
    }()

    static func position(of s: String) -> CGFloat {
        if let ch = s.first, s.count == 1, let p = table[ch] { return max(-1, min(1, p)) }
        var h: UInt64 = 1469598103934665603
        for u in s.unicodeScalars { h = (h ^ UInt64(u.value)) &* 1099511628211 }
        var g = SplitMix(h)
        return g.signed() * 0.95
    }
}
