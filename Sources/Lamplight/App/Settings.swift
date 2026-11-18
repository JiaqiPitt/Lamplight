import Foundation
import Combine
import Carbon

enum Prefs {
    /// Where preferences are kept. A test launch — one given its own data folder through
    /// LAMPLIGHT_DATA_DIR — gets its own preferences as well, so that trying things out can
    /// never read, change or erase the owner's real settings.
    static let store: UserDefaults = {
        if let dir = ProcessInfo.processInfo.environment["LAMPLIGHT_DATA_DIR"], !dir.isEmpty,
           let testing = UserDefaults(suiteName: "app.lamplight.typewriter.testing") {
            return testing
        }
        return .standard
    }()
}

/// Preferences, remembered between launches in the user's defaults.
final class Settings: ObservableObject {
    private let d = Prefs.store

    @Published var lampPower: Double { didSet { d.set(lampPower, forKey: "lampPower") } }
    @Published var ambient: Double { didSet { d.set(ambient, forKey: "ambient") } }
    @Published var lightsOn: Bool { didSet { d.set(lightsOn, forKey: "lightsOn") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "volume") } }
    @Published var muted: Bool { didSet { d.set(muted, forKey: "muted") } }
    @Published var paperMoves: Bool { didSet { d.set(paperMoves, forKey: "paperMoves") } }
    /// 0 correction tape, 1 strike out, 2 plain backspace.
    @Published var backspaceMode: Int { didSet { d.set(backspaceMode, forKey: "backspaceMode") } }
    @Published var autoReturn: Bool { didSet { d.set(autoReturn, forKey: "autoReturn") } }
    @Published var textScale: Double { didSet { d.set(textScale, forKey: "textScale") } }
    @Published var cjkFont: String { didSet { d.set(cjkFont, forKey: "cjkFont") } }
    @Published var dust: Bool { didSet { d.set(dust, forKey: "dust") } }
    /// Which set of recorded sounds to play; "synth" for the generated ones.
    @Published var soundPack: String { didSet { d.set(soundPack, forKey: "soundPack") } }

    static let cjkFonts: [(name: String, label: String)] = [
        ("STFangsong", "FangSong"), ("Songti SC", "Song"), ("Kaiti SC", "Kai"),
    ]

    init() {
        d.register(defaults: [
            "lampPower": 1.0, "ambient": 1.0, "lightsOn": false, "volume": 0.7, "muted": false,
            "paperMoves": false, "backspaceMode": 0, "autoReturn": true, "textScale": 1.0,
            "cjkFont": "STFangsong", "dust": true, "soundPack": "hermes-asmr",
        ])
        lampPower = d.double(forKey: "lampPower")
        ambient = d.double(forKey: "ambient")
        lightsOn = d.bool(forKey: "lightsOn")
        volume = d.double(forKey: "volume")
        muted = d.bool(forKey: "muted")
        paperMoves = d.bool(forKey: "paperMoves")
        backspaceMode = d.integer(forKey: "backspaceMode")
        autoReturn = d.bool(forKey: "autoReturn")
        textScale = d.double(forKey: "textScale")
        cjkFont = d.string(forKey: "cjkFont") ?? "STFangsong"
        dust = d.bool(forKey: "dust")
        soundPack = d.string(forKey: "soundPack") ?? "hermes-asmr"
    }

    var sceneOptions: SceneOptions {
        var o = SceneOptions()
        o.lampPower = CGFloat(lampPower)
        o.ambient = CGFloat(ambient)
        o.lightsOn = lightsOn
        o.paperMoves = paperMoves
        o.backspaceMode = backspaceMode
        o.autoReturn = autoReturn
        o.textScale = CGFloat(min(1.35, max(0.75, textScale)))
        o.cjkFont = cjkFont
        o.dust = dust
        return o
    }
}

/// Reads which keyboard input source is active, so the carriage can show it for a moment
/// when the user switches.
enum InputSource {
    static let changed = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// A one-character mark: "A" for Latin layouts, "中" for Chinese, "あ" for Japanese, and so on.
    static func currentMark() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        func string(_ key: CFString) -> String {
            guard let p = TISGetInputSourceProperty(source, key) else { return "" }
            return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String).lowercased()
        }
        let id = string(kTISPropertyInputSourceID)
        let mode = string(kTISPropertyInputModeID)
        var lang = ""
        if let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let list = Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String], let first = list.first {
            lang = first.lowercased()
        }

        if id.contains("kotoeri") || id.contains("japanese") || lang.hasPrefix("ja") {
            if id.hasSuffix(".roman") || mode.hasSuffix(".roman") { return "A" }
            if id.contains("katakana") || mode.contains("katakana") { return "ア" }
            return "あ"
        }
        if id.contains("korean") || lang.hasPrefix("ko") { return "한" }
        let chineseHints = ["scim", "tcim", "pinyin", "wubi", "shuangpin", "zhuyin", "cangjie", "sogou", "wetype", "baidu", "rime", "squirrel"]
        if lang.hasPrefix("zh") || chineseHints.contains(where: { id.contains($0) }) {
            return (lang.contains("hant") || id.contains("tcim")) ? "繁" : "中"
        }
        if lang.isEmpty || lang.hasPrefix("en") { return "A" }
        return String(lang.prefix(2)).uppercased()
    }
}
