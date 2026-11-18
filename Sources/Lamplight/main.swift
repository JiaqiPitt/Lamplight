import Foundation
import SwiftUI

let arguments = CommandLine.arguments

// Developer mode: render the scene to PNG files without opening a window.
//   Lamplight --render-test <output folder> [scenario ...]
if let i = arguments.firstIndex(of: "--render-test") {
    let out = i + 1 < arguments.count ? arguments[i + 1] : NSTemporaryDirectory()
    RenderTest.run(outputDir: out, args: Array(arguments.dropFirst(i + 2)))
    exit(0)
}

// Developer mode: write every synthesised sound to WAV files and print their levels.
//   Lamplight --dump-sounds <output folder>
if let i = arguments.firstIndex(of: "--dump-sounds") {
    let out = i + 1 < arguments.count ? arguments[i + 1] : NSTemporaryDirectory()
    SoundBank.dump(to: URL(fileURLWithPath: out, isDirectory: true))
    exit(0)
}

// Developer mode: fill a folder with sample sheets (use it with LAMPLIGHT_DATA_DIR).
//   Lamplight --seed-demo <folder>
if let i = arguments.firstIndex(of: "--seed-demo"), i + 1 < arguments.count {
    Seed.run(directory: arguments[i + 1])
    exit(0)
}

// Developer mode: draw the app icon from the scene.
//   Lamplight --make-icon <output.png>
if let i = arguments.firstIndex(of: "--make-icon"), i + 1 < arguments.count {
    IconMaker.run(output: arguments[i + 1])
    exit(0)
}

// Developer mode: film a short performance for the project's front page, offscreen and unheard.
// Run it from the project folder.
//   Lamplight --make-demo <output folder>
if let i = arguments.firstIndex(of: "--make-demo"), i + 1 < arguments.count {
    DemoFilm.run(outputDir: arguments[i + 1])
    exit(0)
}

// Developer mode: decode a FLAC file and report whether it matches its own checksum.
//   Lamplight --flac-info <file>
if let i = arguments.firstIndex(of: "--flac-info"), i + 1 < arguments.count {
    do {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[i + 1])))
        let r = try FLACDecoder.decode(bytes)
        let peak = r.channels.map { $0.map { abs(Int($0)) }.max() ?? 0 }.max() ?? 0
        print("rate \(r.sampleRate)  bits \(r.bitsPerSample)  channels \(r.channels.count)  samples \(r.channels[0].count)  verified \(r.verified)  peak \(peak)")
        print("first:", r.channels[0].prefix(12).map { String($0) }.joined(separator: " "))
        print("features:", FLACDecoder.stats.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
        // A wrong decode shows up as blocks of full-scale noise. Report level per 4096-sample block.
        let x = r.channels[0]
        let full = Double(1 << (r.bitsPerSample - 1))
        var levels: [Double] = []
        var jump = 0.0
        var i = 0
        while i + 4096 <= x.count {
            var sum = 0.0
            for k in i..<(i + 4096) { let v = Double(x[k]) / full; sum += v * v }
            levels.append(10 * log10(max(sum / 4096, 1e-12)))
            if i > 0 { jump = max(jump, abs(Double(x[i]) - Double(x[i - 1])) / full) }
            i += 4096
        }
        let sortedLevels = levels.sorted()
        if !sortedLevels.isEmpty {
            print(String(format: "block RMS dB: min %.1f  median %.1f  max %.1f   largest step across a block edge %.4f",
                         sortedLevels.first!, sortedLevels[sortedLevels.count / 2], sortedLevels.last!, jump))
        }
    } catch {
        print("failed: \(error)")
    }
    exit(0)
}

// Developer mode: rebuild the sound packs in Resources/Sounds from the recordings in SoundSources.
// Run it from the project folder.
//   Lamplight --build-packs
if arguments.contains("--build-packs") {
    PackBuilder.run()
    exit(0)
}

// Developer mode: draw part of a recording as a picture, to inspect it without hearing it.
//   Lamplight --spectrogram <file> <start seconds> <length seconds> <output.png>
if let i = arguments.firstIndex(of: "--spectrogram"), i + 4 < arguments.count,
   let start = Double(arguments[i + 2]), let length = Double(arguments[i + 3]) {
    AudioLab.spectrogram(path: arguments[i + 1], start: start, length: length, output: arguments[i + 4])
    exit(0)
}

// Developer mode: print the level over a stretch of a recording, with clicks marked.
//   Lamplight --audio-trace <file> <start seconds> <length seconds>
if let i = arguments.firstIndex(of: "--audio-trace"), i + 3 < arguments.count,
   let start = Double(arguments[i + 2]), let length = Double(arguments[i + 3]) {
    AudioLab.trace(path: arguments[i + 1], start: start, length: length)
    exit(0)
}

// Developer mode: report the tonal balance and loudness of whole recordings.
//   Lamplight --audio-balance <file> [file ...]
if let i = arguments.firstIndex(of: "--audio-balance") {
    for path in arguments.dropFirst(i + 1) { AudioLab.balanceReport(path: path) }
    exit(0)
}

// Developer mode: list the separate sounds found in recordings, with measurements.
//   Lamplight --audio-scan <file> [file ...]
if let i = arguments.firstIndex(of: "--audio-scan") {
    for path in arguments.dropFirst(i + 1) { AudioLab.scan(path: path) }
    exit(0)
}

// One-off: retype a diary sheet's Chinese date line in English, leaving everything else alone.
//   Lamplight --english-header <sheet.json>
if let i = arguments.firstIndex(of: "--english-header"), i + 1 < arguments.count {
    HeaderFix.run(path: arguments[i + 1])
    exit(0)
}

// A developer command given too few arguments must stop here. Falling through would open the
// real app — on the owner's own sheets, with sound, taking the keyboard — from what was meant
// as a measuring tool. (That happened once, with `--audio-trace <file>` and nothing after it.)
let toolFlags = ["--render-test", "--dump-sounds", "--seed-demo", "--make-icon", "--make-demo", "--flac-info", "--build-packs",
                 "--spectrogram", "--audio-trace", "--audio-balance", "--audio-scan", "--english-header"]
if let flag = toolFlags.first(where: { arguments.contains($0) }) {
    FileHandle.standardError.write(Data("Lamplight: \(flag) is missing arguments; see main.swift for its usage.\n".utf8))
    exit(2)
}

// Every other "--" option is a hook for trying the app out, and those must never run against
// the owner's sheets and settings: they are only accepted together with a separate data folder.
if arguments.dropFirst().contains(where: { $0.hasPrefix("--") }),
   (ProcessInfo.processInfo.environment["LAMPLIGHT_DATA_DIR"] ?? "").isEmpty {
    FileHandle.standardError.write(Data("Lamplight: developer options need LAMPLIGHT_DATA_DIR=<temp folder> (with LAMPLIGHT_MUTE=1 and --no-activate). Not opening the real app.\n".utf8))
    exit(2)
}

// Holding a key should repeat it, like holding a typewriter key down — not offer accents.
UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])

LamplightApp.main()
