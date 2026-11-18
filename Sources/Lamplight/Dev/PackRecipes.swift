import Foundation

/// The recipes: which stretch of which recording becomes which sound, and how each pack is voiced.
///
/// The cut points were found by looking at spectrograms and level traces of the recordings
/// (`--spectrogram`, `--audio-trace`), since the recordings cannot be auditioned here.
extension PackBuilder {
    static func run() {
        let hermes = sources.appendingPathComponent("hermes-precisa-305")
        func load(_ name: String) -> Clip? {
            do { return try AudioLab.load(hermes.appendingPathComponent(name)) } catch {
                print("could not load \(name): \(error)")
                return nil
            }
        }
        guard let keyFile = load("key.flac"), let spaceFile = load("space.flac"),
              let bell1 = load("bell1.flac"), let bell2 = load("bell2.flac"),
              let typing1 = load("typing1.flac"), let typing3 = load("typing3.flac"), let typing4 = load("typing4.flac"),
              let typing5 = load("typing5.flac"), let typing6 = load("typing6.flac"), let typing8 = load("typing8.flac") else {
            print("Recordings are missing from SoundSources/hermes-precisa-305.")
            return
        }
        let sr = 48000.0
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)

        // ---------------------------------------------------------------- Hermes Precisa 305
        // In these recordings the key takes about 46 ms to travel before the slug lands
        // (the sound of the lever is audible before the crack of the impact).
        let hermesLead = 0.046
        var hermesStrikes = strikes(in: typing4, lead: hermesLead) + strikes(in: typing3, lead: hermesLead)
        if hermesStrikes.count < 16 {
            hermesStrikes += strikes(in: typing6, lead: hermesLead) + strikes(in: keyFile, lead: hermesLead)
        }
        hermesStrikes = Array(hermesStrikes.prefix(24))

        let spaceEvent = AudioLab.events(in: spaceFile).events.first
        let hermesSpace = spaceEvent.map { whole(spaceFile, event: $0, maxLength: 0.62, fadeOutMs: 120) }
        // The space bar coming back up, on its own: a small soft click.
        let spaceRelease = DSP.fade(cut(spaceFile, from: 0.193, to: 0.330), inMs: 3, outMs: 40)
        // The key lever travelling, before any impact: used where a recording lacks it.
        let keyTravel = DSP.fade(cut(keyFile, from: 0.117, to: 0.157), inMs: 2, outMs: 8)

        let bells: [Clip] = [bell1, bell2].compactMap { file in
            AudioLab.events(in: file).events.first.map { whole(file, event: $0, preMs: 3, maxLength: 1.7, fadeOutMs: 350) }
        }

        // Two real carriage returns. Each followed the bell closely, so the bell's ringing
        // is notched out of them: in the app the bell and the return are separate sounds.
        let lines = ringing(bell1, count: 7)
        let notches = lines.map { DSP.Filter.notch($0, q: 28, sr: sr) }
        func clean(_ c: Clip) -> Clip { DSP.filter(c, notches + [DSP.Filter.highpass(70, sr: sr)]) }
        struct Return { var lever: Clip, slide: Clip, stop: Clip }
        let returns = [
            Return(lever: clean(cut(typing5, from: 27.205, to: 27.440)), slide: clean(cut(typing5, from: 27.440, to: 27.670)),
                   stop: clean(cut(typing5, from: 27.792, to: 28.330))),
            Return(lever: clean(cut(typing8, from: 25.935, to: 26.140)), slide: clean(cut(typing8, from: 26.140, to: 26.480)),
                   stop: clean(cut(typing8, from: 26.662, to: 27.260))),
        ]
        // One ratchet click and one small settling click, for line feeds and nudges.
        let ratchet = DSP.fade(clean(cut(typing8, from: 25.966, to: 26.060)), inMs: 1, outMs: 25)
        let settle = DSP.fade(clean(cut(typing8, from: 26.953, to: 27.012)), inMs: 1, outMs: 20)

        // ---------------------------------------------------------------- "Typewriter #1"
        // A fuller-sounding machine (BigSoundBank does not name the model). Its recording was
        // gated, so each strike begins almost at the impact.
        let classicLead = 0.006
        let classicStrikes = Array(strikes(in: typing1, lead: classicLead).prefix(24))
        let events1 = AudioLab.events(in: typing1).events
        let top1 = typing1.peak
        // Its space bar: much quieter and duller than a strike.
        let classicSpaces = events1.filter { $0.peak < top1 * 0.14 && $0.peak > top1 * 0.02 && $0.centroid < 2200 }
            .map { whole(typing1, event: $0, maxLength: 0.45, fadeOutMs: 60) }

        print(String(format: "found: Hermes strikes %d, space %@, bells %d, returns %d | Classic strikes %d, spaces %d",
                     hermesStrikes.count, hermesSpace == nil ? "no" : "yes", bells.count, returns.count, classicStrikes.count, classicSpaces.count))
        print("bell rings at:", lines.map { String(format: "%.0f Hz", $0) }.joined(separator: ", "))
        guard let hermesSpace, !hermesStrikes.isEmpty, !classicStrikes.isEmpty, !bells.isEmpty else {
            print("Not enough material found; stopping.")
            return
        }

        // ---------------------------------------------------------------- Voicings
        let natural: (Clip) -> Clip = { $0 }
        // Hermes is very bright and thin as recorded. For a close, soft sound: add the body it
        // lacks, take the edge off the top, and bring the quiet mechanical detail forward.
        let hermesWarm: (Clip) -> Clip = { c in
            var x = DSP.filter(c, [
                .highpass(85, sr: sr), .peak(210, db: 9, q: 0.8, sr: sr), .peak(1000, db: 4, q: 0.7, sr: sr),
                .peak(3400, db: -2, q: 1.3, sr: sr), .highShelf(8000, db: -5, sr: sr),
            ])
            x = DSP.bringForward(x)
            x = DSP.soften(x, drive: 1.4)
            return DSP.widen(x, sideGain: 1.25, reflections: 0.08)
        }
        // The other machine is already full; it only needs closeness and a gentler top.
        let classicWarm: (Clip) -> Clip = { c in
            var x = DSP.filter(c, [
                .highpass(55, sr: sr), .peak(3300, db: -2.5, q: 1.3, sr: sr), .highShelf(9000, db: -1.5, sr: sr),
            ])
            x = DSP.bringForward(x, mix: 0.32)
            x = DSP.soften(x, drive: 1.4)
            return DSP.widen(x, sideGain: 1.0, reflections: 0.09)
        }
        // The borrowed bell and carriage need a little more weight to sit with the fuller machine.
        let fuller: (Clip) -> Clip = { DSP.filter($0, [.lowShelf(220, db: 3.5, sr: sr)]) }

        struct Recipe {
            var id: String, name: String, machine: String, credit: String
            var strikes: [Take]
            var spaces: [Clip]
            var hasKeyTravel: Bool
            var voice: (Clip) -> Clip
            var bellVoice: (Clip) -> Clip
            var close: Bool     // the ASMR voicing evens the levels out a little
        }
        let credit = "Recorded by Joseph Sardin, BigSoundBank.com — CC0"
        let spaceVariants = [1.0, 0.975, 1.03].map { DSP.resample(hermesSpace, speed: $0) }
        let recipes = [
            Recipe(id: "hermes", name: "Hermes · Natural", machine: "Hermes Precisa 305", credit: credit, strikes: hermesStrikes,
                   spaces: spaceVariants, hasKeyTravel: true, voice: natural, bellVoice: natural, close: false),
            Recipe(id: "hermes-asmr", name: "Hermes · ASMR", machine: "Hermes Precisa 305", credit: credit, strikes: hermesStrikes,
                   spaces: spaceVariants, hasKeyTravel: true, voice: hermesWarm, bellVoice: { DSP.widen(DSP.filter($0, [.highShelf(8000, db: -3, sr: sr)]), sideGain: 1, reflections: 0.10) }, close: true),
            Recipe(id: "classic", name: "Classic · Natural", machine: "Mechanical typewriter (BigSoundBank “Typewriter #1”)", credit: credit, strikes: classicStrikes,
                   spaces: classicSpaces, hasKeyTravel: false, voice: natural, bellVoice: fuller, close: false),
            Recipe(id: "classic-asmr", name: "Classic · ASMR", machine: "Mechanical typewriter (BigSoundBank “Typewriter #1”)", credit: credit, strikes: classicStrikes,
                   spaces: classicSpaces, hasKeyTravel: false, voice: classicWarm, bellVoice: { DSP.widen(fuller(DSP.filter($0, [.highShelf(8000, db: -3, sr: sr)])), sideGain: 1, reflections: 0.10) }, close: true),
        ]

        var demos: [(id: String, name: String, files: [(label: String, url: URL)])] = []
        for r in recipes {
            let lead = r.strikes.first?.lead ?? 0.01
            // Strikes: voice each, then one common gain so their natural differences survive.
            var struck = r.strikes.map { take -> Clip in
                let voiced = r.voice(take.clip)
                return r.close ? DSP.tighten(voiced, after: take.lead + 0.055) : voiced
            }
            let loudest = struck.map { $0.peak }.max() ?? 1
            let strikeGain = -2.0 - 20 * log10(Double(max(loudest, 1e-6)))
            struck = struck.map { DSP.gain($0, db: strikeGain) }
            if r.close {
                // Pull the quietest strikes up toward the rest: evenness is restful.
                struck = struck.map { c in
                    let shortfall = -2.0 - 20 * log10(Double(max(c.peak, 1e-6)))
                    return DSP.gain(c, db: shortfall * 0.5)
                }
            }

            func level(_ c: Clip, _ db: Double) -> Clip { DSP.normalize(c, peakDB: db) }
            let spaceLevel = r.close ? -7.5 : -9.0
            let spaces = r.spaces.map { level(r.voice($0), spaceLevel) }
            let backs = r.spaces.prefix(3).enumerated().map { i, c in
                level(r.voice(DSP.resample(c, speed: [0.89, 0.86, 0.92][i % 3])), spaceLevel - 1.5)
            }
            let tape = level(r.voice(spaceRelease), -17)
            let bellClips = bells.map { level(r.bellVoice($0), r.close ? -10.0 : -11.0) }
            var carriages: [String: [Clip]] = [:]
            for (i, stopAt) in Mechanics.carriageDurations.enumerated() {
                carriages["carriage\(i)"] = returns.map { ret in
                    let built = carriage(lever: ret.lever, slide: ret.slide, stop: ret.stop, stopAt: stopAt)
                    var voiced = r.id.hasPrefix("classic") ? fuller(built) : built
                    if r.close {
                        voiced = DSP.widen(DSP.filter(voiced, [.peak(260, db: 3, q: 0.8, sr: sr), .highShelf(6500, db: -5, sr: sr)]), sideGain: 1, reflections: 0.08)
                    }
                    return level(voiced, r.close ? -10.0 : -11.0)
                }
            }
            let feed = level(r.voice(ratchet), -13)
            let tick = level(r.voice(settle), -15)
            // Feeding a sheet in: nine ratchet teeth over the same half second the paper takes.
            var paperIn = Clip(mono: [Float](repeating: 0, count: Int((Mechanics.paperInDuration + 0.25) * sr)), sampleRate: sr)
            for k in 0..<Mechanics.paperInSteps {
                let at = Int(Double(k) * Mechanics.paperInDuration / Double(Mechanics.paperInSteps) * sr)
                let click = DSP.resample(feed, speed: 1 + 0.03 * Double((k * 7) % 5 - 2))
                for i in 0..<click.count where at + i < paperIn.count {
                    paperIn.left[at + i] += click.left[i]
                    paperIn.right[at + i] += click.right[i]
                }
            }
            let slideOut = DSP.fade(DSP.concat([returns[1].slide, returns[0].slide]), inMs: 60, outMs: 120)
            let paperOut = level(r.voice(slideOut), -14)

            var takes: [String: [Clip]] = [
                "strike": struck, "space": spaces, "back": Array(backs), "tape": [tape], "bell": bellClips,
                "feed": [feed], "tick": [tick], "paperIn": [level(paperIn, -12)], "paperOut": [paperOut],
            ]
            for (k, v) in carriages { takes[k] = v }
            if !r.hasKeyTravel { takes["key"] = [level(r.voice(keyTravel), -22)] }

            write(PackManifest(id: r.id, name: r.name, machine: r.machine, credit: r.credit, strikeLead: lead,
                               hasKeyTravel: r.hasKeyTravel, sounds: [:]), takes: takes)
            // Average over the strikes: where the energy sits, and how the level falls away.
            var shares = [Double](repeating: 0, count: 6)
            for s in struck { for (i, v) in DSP.balance(s).enumerated() { shares[i] += v / Double(struck.count) } }
            print("   strikes, energy by band (<150 | 150-400 | 400-1.2k | 1.2-3.5k | 3.5-8k | >8k Hz): " + shares.map { String(format: "%2.0f", $0 * 100) }.joined(separator: " "))
            print("   strike level vs peak: " + DSP.profile(struck[0], lead: lead))
            print("   carriage (longest):   peak " + String(format: "%.1f dBFS, %.2f s", 20 * log10(Double(carriages["carriage3"]![0].peak)), carriages["carriage3"]![0].duration))

            // Things to listen to.
            func sequence(_ clips: [Clip], gap: Double) -> Clip {
                var parts: [Clip] = []
                for c in clips { parts.append(DSP.pad(c, after: max(0, Int(gap * sr) - c.count))) }
                return DSP.concat(parts)
            }
            let pieces: [(String, Clip)] = [
                ("Full demo", demo(takes, strikeLead: lead)),
                ("Strike", sequence(Array(struck.prefix(5)), gap: 0.55)),
                ("Space bar", sequence(Array(spaces.prefix(3)), gap: 0.7)),
                ("Carriage return", sequence([takes["carriage3"]![0]], gap: 1.3)),
                ("Backspace", sequence(Array(backs.prefix(3)), gap: 0.7)),
                ("Bell", sequence([bellClips[0]], gap: 1.6)),
            ]
            var files: [(String, URL)] = []
            for (n, (label, clip)) in pieces.enumerated() {
                let url = samples.appendingPathComponent("\(r.id)-\(n).m4a")
                saveCompressed(clip, to: url)
                files.append((label, url))
                if n == 0 { try? AudioLab.save(clip, to: samples.appendingPathComponent("\(r.id)-demo.wav"), bits: 16) }
            }
            demos.append((r.id, r.name, files))
        }
        writePage(demos)
    }

    /// One self-contained page with a play button for every sample.
    static func writePage(_ demos: [(id: String, name: String, files: [(label: String, url: URL)])]) {
        let notes = [
            "hermes": "A Hermes Precisa 305, as recorded: short, bright, metallic strikes.",
            "hermes-asmr": "The same machine, processed for a close sound: more body in the lows, the harsh treble taken down, and small sounds such as key travel and the key's return brought forward.",
            "classic": "Another mechanical typewriter, as recorded: lower and heavier, with a thud under every strike.",
            "classic-asmr": "The same machine, processed in the same way: closer and softer, with more even strikes. Its bell and carriage return are borrowed from the Hermes recordings.",
        ]
        var html = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lamplight sound samples</title>
        <style>
        :root { color-scheme: dark; }
        body { background: #0d0c0b; color: #e6dfcf; font: 15px/1.6 -apple-system, "PingFang SC", sans-serif; margin: 0; padding: 32px 16px 64px; }
        main { max-width: 760px; margin: 0 auto; }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 6px; }
        p.lead { color: #a49c8c; margin: 0 0 28px; }
        section { background: #171513; border: 1px solid #2a2622; border-radius: 12px; padding: 18px 18px 8px; margin-bottom: 18px; }
        h2 { font-size: 17px; margin: 0 0 4px; color: #edb96b; font-weight: 600; }
        section > p { color: #a49c8c; margin: 0 0 14px; font-size: 13.5px; }
        .row { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; flex-wrap: wrap; }
        .row span { width: 112px; flex: none; color: #cfc7b6; font-size: 13.5px; }
        audio { flex: 1; min-width: 220px; height: 34px; }
        footer { color: #7d766a; font-size: 12.5px; margin-top: 26px; }
        </style></head><body><main>
        <h1>Lamplight sound samples</h1>
        <p class="lead">All four sets are recordings of real typewriters. Headphones are recommended. Listen to each set's full demo first, then to the single sounds. To change the sound in the app: Settings → Sound.</p>

        """
        for (n, d) in demos.enumerated() {
            html += "<section><h2>\(n + 1). \(d.name)</h2><p>\(notes[d.id] ?? "")</p>\n"
            for f in d.files {
                let data = (try? Data(contentsOf: f.url)) ?? Data()
                html += "<div class=\"row\"><span>\(f.label)</span><audio controls preload=\"auto\" src=\"data:audio/mp4;base64,\(data.base64EncodedString())\"></audio></div>\n"
            }
            html += "</section>\n"
        }
        // The 1940 Erika recording is continuous fast typing at a low bit rate: no clean single
        // strikes can be cut from it. It is offered as a reference for the character of an older machine.
        let erika = sources.appendingPathComponent("erika-5/typing.mp3")
        if let data = try? Data(contentsOf: erika) {
            html += """
            <section><h2>For reference: an Erika 5 from 1940, as recorded</h2>
            <p>A machine from 1940. The recording is continuous fast typing at a low bit rate, so no clean single keystrokes can be cut from it, and it was not made into a pack. It is here for reference: this is what an older machine sounds like.</p>
            <div class="row"><span>Recording</span><audio controls preload="auto" src="data:audio/mpeg;base64,\(data.base64EncodedString())"></audio></div>
            </section>

            """
        }
        html += """
        <footer>The recordings for sets 1–4: Joseph Sardin, BigSoundBank.com, CC0. The Erika 5 recording: Work With Sounds / Konrad Gutkowski, Wikimedia Commons, CC BY 4.0.<br>The full demo imitates typing a line in the app, correcting a slip, the bell, and a carriage return. The sound can also be changed in the app: move the pointer → the sliders icon at the right end of the toolbar → Sound.</footer>
        </main></body></html>
        """
        // The page carries its own copies of the clips; the loose files are no longer needed.
        for d in demos { for f in d.files { try? FileManager.default.removeItem(at: f.url) } }
        let url = root.appendingPathComponent("docs/sound-samples.html")
        try? html.write(to: url, atomically: true, encoding: .utf8)
        print("wrote docs/sound-samples.html (\(html.utf8.count / 1024) KB)")
    }
}
