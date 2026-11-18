import Foundation

/// The fixed character grid of a sheet. Latin characters take one cell,
/// CJK and other full-width characters take two.
enum Grid {
    static let cols = 60
    /// The bell rings when the carriage crosses this column.
    static let bellCol = 52
    static let tab = 4

    static func width(of s: String) -> Int {
        guard let u = s.unicodeScalars.first else { return 1 }
        return isWide(u.value) ? 2 : 1
    }

    static func isWide(_ v: UInt32) -> Bool {
        if v < 0x1100 { return false }
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...0x3FFFD:
            return true
        // Punctuation that Chinese input methods produce and CJK fonts draw full-width.
        case 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026:
            return true
        default:
            return false
        }
    }

    /// Characters that may hang past the right margin instead of starting a new line.
    static let closers: Set<String> = [
        "，", "。", "、", "；", "：", "？", "！", "）", "》", "」", "』", "”", "’", "…",
        ",", ".", ";", ":", "?", "!", ")", "]", "}",
    ]
}

enum EntryKind: String, Codable, CaseIterable, Identifiable {
    case diary, reading, essay
    var id: String { rawValue }
    var label: String {
        switch self {
        case .diary: return "Diary"
        case .reading: return "Reading Notes"
        case .essay: return "Essays"
        }
    }
}

/// One impression of a type slug on the paper.
struct Strike: Codable, Equatable {
    /// The character (a single grapheme).
    var c: String
    /// Column of the left edge of the character.
    var x: Int
    /// Ribbon colour: 0 black, 1 red.
    var k: UInt8 = 0
    /// How hard the key was hit (0–255), which decides how dark the ink is.
    var p: UInt8 = 220
    /// Seed for the small misalignments every strike has.
    var s: UInt16 = 0
    /// 0 normal, 1 struck out, 2 lifted off with correction tape.
    var d: UInt8 = 0
    /// Scene time at which the slug reaches the paper. Not saved.
    var land: Double = 0

    enum CodingKeys: String, CodingKey { case c, x, k, p, s, d }

    init(c: String, x: Int, k: UInt8 = 0, p: UInt8 = 220, s: UInt16 = 0, d: UInt8 = 0, land: Double = 0) {
        self.c = c; self.x = x; self.k = k; self.p = p; self.s = s; self.d = d; self.land = land
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        c = try v.decode(String.self, forKey: .c)
        x = try v.decode(Int.self, forKey: .x)
        k = try v.decodeIfPresent(UInt8.self, forKey: .k) ?? 0
        p = try v.decodeIfPresent(UInt8.self, forKey: .p) ?? 220
        s = try v.decodeIfPresent(UInt16.self, forKey: .s) ?? 0
        d = try v.decodeIfPresent(UInt8.self, forKey: .d) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var v = encoder.container(keyedBy: CodingKeys.self)
        try v.encode(c, forKey: .c)
        try v.encode(x, forKey: .x)
        if k != 0 { try v.encode(k, forKey: .k) }
        try v.encode(p, forKey: .p)
        try v.encode(s, forKey: .s)
        if d != 0 { try v.encode(d, forKey: .d) }
    }

    var width: Int { Grid.width(of: c) }
    var isVisible: Bool { d == 0 }
}

/// A sheet of paper: a diary day, a reading note or a loose essay.
struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EntryKind
    var title = ""
    var book = ""
    var author = ""
    /// For a diary sheet, the day it belongs to as yyyy-MM-dd.
    var day = ""
    var createdAt = Date()
    var updatedAt = Date()
    var rows: [[Strike]] = [[]]
    /// Rows that ended because the line was full; they join the next row without a space.
    var soft: Set<Int> = []
    /// Rows that ended on a space near the margin; they join the next row with a space.
    var softSpace: Set<Int> = []
    var cursorRow = 0
    var cursorCol = 0
    /// Rows at the top that the machine typed by itself (date, book title).
    var headerRows = 0

    init(kind: EntryKind) { self.kind = kind }

    mutating func ensureRow(_ r: Int) {
        while rows.count <= r { rows.append([]) }
    }

    /// The column just past the last ink on a row.
    func endCol(ofRow r: Int) -> Int {
        guard r >= 0, r < rows.count else { return 0 }
        var end = 0
        for st in rows[r] where st.d != 2 { end = max(end, st.x + st.width) }
        return end
    }

    var lastInkedRow: Int {
        var r = rows.count - 1
        while r > 0 && rows[r].allSatisfy({ !$0.isVisible }) { r -= 1 }
        return max(r, 0)
    }

    /// The readable text of one row: the last visible strike in each cell wins.
    func lineText(_ r: Int) -> String {
        guard r >= 0, r < rows.count else { return "" }
        var top: [Int: Strike] = [:]
        for st in rows[r] where st.isVisible { top[st.x] = st }
        var out = ""
        var pos = 0
        for x in top.keys.sorted() {
            guard let st = top[x], x >= pos else { continue }
            if x > pos { out += String(repeating: " ", count: x - pos) }
            out += st.c
            pos = x + st.width
        }
        return out
    }

    /// The text of the sheet, with lines the machine wrapped joined back together.
    func text(includeHeader: Bool = true) -> String {
        var out = ""
        let last = lastInkedRow
        let first = includeHeader ? 0 : min(headerRows, last + 1)
        guard first <= last else { return "" }
        for r in first...last {
            out += lineText(r)
            if r == last { break }
            if soft.contains(r) { continue }
            if softSpace.contains(r) { out += " "; continue }
            out += "\n"
        }
        return out
    }

    /// Words in the body. Each Chinese, Japanese or Korean character counts as a word of its own.
    var wordCount: Int {
        var n = 0
        var inWord = false
        for u in text(includeHeader: false).unicodeScalars {
            if Grid.isWide(u.value) {
                if !u.properties.generalCategory.isPunctuation { n += 1 }
                inWord = false
            } else if u.properties.isWhitespace {
                inWord = false
            } else if !inWord {
                inWord = true
                n += 1
            }
        }
        return n
    }

    var characterCount: Int {
        var n = 0
        for (r, row) in rows.enumerated() where r >= headerRows {
            n += row.reduce(0) { $0 + ($1.isVisible ? 1 : 0) }
        }
        return n
    }

    var preview: String {
        let body = text(includeHeader: false)
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(body.prefix(60))
    }

    var isBlank: Bool { characterCount == 0 }
}

extension Entry {
    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func date(fromDayKey key: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: key)
    }

    static func longDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: date)
    }

    static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    static func plainDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM d, yyyy"
        return f.string(from: date)
    }

    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    /// A fresh sheet and the header the machine types on it by itself.
    static func make(kind: EntryKind, date: Date = Date(), book: String = "", author: String = "") -> (Entry, String) {
        var e = Entry(kind: kind)
        e.createdAt = date
        e.updatedAt = date
        var header: String
        switch kind {
        case .diary:
            e.day = dayKey(date)
            header = longDate(date) + "\n\n"
            e.headerRows = 2
        case .reading:
            e.book = book
            e.author = author
            // Title, author, date — one to a line, then a blank line.
            header = (book.isEmpty ? "Reading notes" : book) + "\n"
            if !author.isEmpty { header += "by " + author + "\n" }
            header += plainDate(date) + "\n\n"
            e.headerRows = author.isEmpty ? 3 : 4
        case .essay:
            header = plainDate(date) + "\n\n"
            e.headerRows = 2
        }
        return (e, header)
    }

    /// What the drawer shows as the name of this sheet.
    var displayTitle: String {
        switch kind {
        case .diary:
            if let d = Entry.date(fromDayKey: day) { return Entry.shortDate(d) }
            return Entry.shortDate(createdAt)
        case .reading:
            return Entry.shortDate(createdAt)
        case .essay:
            let firstLine = text(includeHeader: false)
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return firstLine.map { String($0.prefix(28)) } ?? "Untitled"
        }
    }
}

private extension Unicode.GeneralCategory {
    var isPunctuation: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }
}
