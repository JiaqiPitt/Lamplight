import Foundation
import SpriteKit

/// Developer aid: fills a folder with a few sample sheets, typed by the real mechanism,
/// so the drawer can be tried out without touching your own writing.
///   Lamplight --seed-demo <folder>
enum Seed {
    /// Types text on a fresh sheet with no window and no sound, and returns the result.
    static func typed(kind: EntryKind, date: Date, book: String = "", author: String = "", body: String) -> Entry {
        let (entry, header) = Entry.make(kind: kind, date: date, book: book, author: author)
        let scene = TypewriterScene(size: CGSize(width: 1280, height: 832), entry: entry, options: SceneOptions(), pixelScale: 1)
        var t = 10.0
        scene.update(t)
        scene.load(entry, animated: false, header: header + body)
        for _ in 0..<200_000 {
            t += 1.0 / 60
            scene.update(t)
            if scene.isSettled { break }
        }
        var result = scene.entry
        result.createdAt = date
        result.updatedAt = date
        return result
    }

    static func run(directory: String) {
        let store = Store(directory: URL(fileURLWithPath: directory, isDirectory: true))
        let day: TimeInterval = 86400
        let now = Date()
        let samples: [(EntryKind, Double, String, String, String)] = [
            (.diary, 1, "", "", "早上去了一趟旧书店，淘到一本一九八二年版的《围城》。\n店主说这书在架上放了三年，没人问过。"),
            (.diary, 2, "", "", "加班到很晚。回家的路上下了小雨，路灯下的雨丝看得很清楚。\nNote to self: call the landlord tomorrow."),
            (.diary, 9, "", "", "今天什么也没做，只是坐在窗边看了一下午的云。"),
            (.diary, 40, "", "", "搬家的第一天。箱子堆了一屋子，先把台灯和打字机找了出来。"),
            (.reading, 3, "百年孤独", "加西亚·马尔克斯", "多年以后，面对行刑队，奥雷里亚诺·布恩迪亚上校将会回想起父亲带他去见识冰块的那个遥远的下午。\n\n开头一句话里有三个时间。"),
            (.reading, 5, "百年孤独", "加西亚·马尔克斯", "读到第六章。家族里的名字一再重复，像是命运也在重复。"),
            (.reading, 12, "Walden", "Henry David Thoreau", "I went to the woods because I wished to live deliberately.\n\n要不要也找个地方住上一阵子。"),
            (.essay, 4, "", "", "关于慢\n\n打字机逼着人慢下来。每个字都要用力，所以落笔之前会多想一秒。"),
            (.essay, 20, "", "", "夜里的声音\n\n冰箱的嗡嗡声，楼上的脚步声，远处偶尔一辆车。"),
        ]
        for (kind, ago, book, author, body) in samples {
            let entry = typed(kind: kind, date: now.addingTimeInterval(-ago * day), book: book, author: author, body: body)
            store.save(entry, wait: true)
        }
        print("seeded \(samples.count) sheets into \(directory)")
    }
}
