import Foundation
import CryptoKit

/// One-off helper: retypes the date at the top of a diary sheet in English.
///
/// Sheets started before the app switched to English carry the date as the machine typed it
/// then, in Chinese. This replaces that one line. It acts only when the first line is exactly
/// the date the machine typed — still there, or erased with the correction tape and nothing
/// typed in its place — so a line the owner wrote or changed is never overwritten. Ink that
/// was lifted off the page is dropped, as the app itself does when it next saves the sheet.
/// It never prints the body of the sheet.
///   Lamplight --english-header <sheet.json>
enum HeaderFix {
    /// A fingerprint of the visible ink below the header, to show the body was not touched.
    private static func bodyFingerprint(_ entry: Entry) -> String {
        var hasher = SHA256()
        for row in entry.rows.dropFirst() {
            for st in row where st.d != 2 {
                hasher.update(data: Data("\(st.c)|\(st.x)|\(st.k)|\(st.p)|\(st.s)|\(st.d);".utf8))
            }
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url), var entry = try? Store.decoder().decode(Entry.self, from: data) else {
            print("Could not read that sheet.")
            return
        }
        guard entry.kind == .diary, entry.headerRows >= 1, !entry.rows.isEmpty, let date = Entry.date(fromDayKey: entry.day) else {
            print("That is not a diary sheet with a typed date; nothing changed.")
            return
        }
        let chinese = DateFormatter()
        chinese.locale = Locale(identifier: "zh_CN")
        chinese.dateFormat = "yyyy年M月d日 EEEE"
        let old = entry.lineText(0)
        let english = Entry.longDate(date)
        if old == english {
            print("The date is already in English: \(old)")
            return
        }
        // What the correction tape lifted off the first line, read the same way as visible ink.
        var liftedOnly = Entry(kind: .diary)
        liftedOnly.rows = [entry.rows[0].filter { $0.d == 2 }.map { st in
            var s = st
            s.d = 0
            return s
        }]
        let erased = liftedOnly.lineText(0)
        let machineDate = chinese.string(from: date)
        let stillThere = old == machineDate
        let wasErased = old.isEmpty && erased == machineDate
        guard stillThere || wasErased else {
            print("The first line is not the date the machine typed, so it was left alone.")
            return
        }

        let before = bodyFingerprint(entry)
        // Type the new line the way the machine does: each strike with its own pressure and seed.
        var rng = SplitMix(UInt64(truncatingIfNeeded: entry.id.hashValue) ^ 0x1D47)
        var row: [Strike] = []
        var col = 0
        for ch in english {
            if ch == " " {
                col += 1
                continue
            }
            let c = String(ch)
            let r = rng.unit()
            let pressure: UInt8 = r < 0.07 ? UInt8(118 + rng.unit() * 44) : (r > 0.95 ? 255 : UInt8(198 + rng.unit() * 50))
            row.append(Strike(c: c, x: col, k: 0, p: pressure, s: UInt16(truncatingIfNeeded: rng.next())))
            col += Grid.width(of: c)
        }
        entry.rows[0] = row
        entry = Store.withoutLiftedInk(entry)
        if entry.cursorRow < entry.headerRows {
            // The carriage was parked on the date line. Put it where writing continues:
            // after the last ink on the page, or on the first line of the body if there is none.
            let lastInked = entry.rows.indices.last { $0 >= entry.headerRows && entry.endCol(ofRow: $0) > 0 }
            if let lastInked {
                entry.cursorRow = lastInked
                entry.cursorCol = entry.endCol(ofRow: lastInked)
            } else {
                entry.cursorRow = entry.headerRows
                entry.cursorCol = 0
                entry.ensureRow(entry.cursorRow)
                entry.soft = []
                entry.softSpace = []
            }
        }
        let after = bodyFingerprint(entry)
        guard before == after, let out = try? Store.encoder().encode(entry) else {
            print("Something did not add up; nothing was written.")
            return
        }
        do {
            try out.write(to: url, options: .atomic)
            print("date line: \(stillThere ? old : "(erased) " + erased)  ->  \(english)")
            let inked = entry.rows.dropFirst().filter { row in row.contains { $0.d == 0 } }.count
            print("lines with ink below the date: \(inked); visible-ink fingerprint \(before) before, \(after) after (unchanged)")
            print("carriage now at line \(entry.cursorRow), column \(entry.cursorCol)")
        } catch {
            print("Could not write the sheet: \(error.localizedDescription)")
        }
    }
}
