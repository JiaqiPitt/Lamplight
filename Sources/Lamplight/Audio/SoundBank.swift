import AVFoundation
import AppKit
import CoreAudio
import ObjCSafe
import os

/// Plays the machine's sounds with as little delay as the system allows.
///
/// Sounds come from a *pack*: a folder of recordings of a real typewriter, cut into single
/// strikes, space-bar presses, carriage returns and so on (see `Resources/Sounds`). Anything a
/// pack does not provide falls back to the synthesised version. Short sounds and long ones
/// use separate pools of players so that fast typing never cuts off a ringing bell.
///
/// The output hardware is not a fixed thing. Wireless headphones change format when another app
/// opens their microphone, hand their sound over to a phone, come and go — and each time the
/// system stops the engine underneath us. So everything that touches the engine happens on one
/// private queue, never on the main thread (starting a Bluetooth device can take half a second,
/// and typing must not wait for it), and the engine is brought back up by itself whenever it is
/// wanted and found stopped.
final class SoundBank: SoundPlaying {
    struct PackInfo: Identifiable, Equatable {
        let id: String
        let name: String
    }

    static let synthPack = PackInfo(id: "synth", name: "Synthesised")

    // MARK: - Used from the main thread

    /// Packs found on disk, plus the synthesised one.
    private(set) var packs: [PackInfo] = [SoundBank.synthPack]
    private var folders: [String: URL] = [:]
    /// Seconds from the start of a strike sample to the impact inside it. The scene starts the
    /// sample this much early so the recorded impact lands when the slug does.
    private(set) var strikeLead: Double = 0
    private var loadToken = 0
    private var lastWake = 0.0
    private var observers: [NSObjectProtocol] = []

    var volume: Float = 0.7 {
        didSet { pushLevels() }
    }
    var muted = false {
        didSet { pushLevels() }
    }
    var packID: String = SoundBank.synthPack.id {
        didSet { if packID != oldValue { loadPack() } }
    }

    // MARK: - Used only on the audio queue

    private let audio = DispatchQueue(label: "lamplight.audio", qos: .userInteractive)
    private let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
    private var engine: AVAudioEngine?
    /// Everything is mixed here first. Volume and mute act after this point, so a test run can
    /// record exactly what was played even while the speakers stay silent.
    private var bus: AVAudioMixerNode?
    private var shortPlayers: [AVAudioPlayerNode] = []
    private var longPlayers: [AVAudioPlayerNode] = []
    private var shortCursor = 0
    private var longCursor = 0
    private var synth: [Sound: [AVAudioPCMBuffer]] = [:]
    private var recorded: [Sound: [AVAudioPCMBuffer]] = [:]
    /// The pack's strikes already include the key travelling down, so no separate click is needed.
    private var hasKeyTravel = false
    private var lastTake: [Sound: Int] = [:]
    private var level: Float = 0.7
    private var silent = false
    /// The engine is started and sounds can be scheduled.
    private var live = false
    /// Every player has been stopped since the engine last stopped. A player that was playing
    /// when the engine stopped goes on reporting that it is playing, and `play()` then does
    /// nothing — it stays silent for good. That was why the app went quiet after the output
    /// device changed. Stopping the player clears it, and costs little while the engine is down.
    private var playersClean = true
    private var appActive = true
    private var lastUse = SoundBank.now()
    private var failures = 0
    private var nextAttempt = 0.0
    private var heartbeat: DispatchSourceTimer?
    private var recording: AVAudioFile?
    private var journal: [String] = []
    private var counts = (played: 0, late: 0, starts: 0, changes: 0)
    private let born = SoundBank.now()
    private let log = Logger(subsystem: "app.lamplight.typewriter", category: "audio")
    /// For tests: how long without a sound before the hardware is released.
    private let idleOverride = ProcessInfo.processInfo.environment["LAMPLIGHT_AUDIO_IDLE"].flatMap { Double($0) }
    /// For tests: play to this device instead of the Mac's own choice, so that a test launch
    /// leaves whatever headphones the owner is wearing alone.
    private let deviceOverride = ProcessInfo.processInfo.environment["LAMPLIGHT_AUDIO_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }

    /// How long after the last sound (or sign of typing) the engine keeps running. An engine that
    /// runs holds the output device open and keeps the Mac from going to sleep, so it must not run
    /// for ever: a few minutes while the app is in front, a few seconds once it is not.
    private var idleLimit: Double { idleOverride ?? (appActive ? 300 : 15) }

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    init() {
        discoverPacks()

        // Synthesis takes a moment; do it off the main thread.
        let format = self.format
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let made = SoundBank.makeBuffers(format)
            guard let self else { return }
            self.audio.async {
                self.synth = made
                self.touch()
            }
        }

        let center = NotificationCenter.default
        // Headphones changing mode, the output device replaced: the engine has been stopped for us.
        // This arrives on one of the engine's own threads, and the engine must not be restarted
        // or released from there.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] notice in
            guard let self, let source = notice.object as? AVAudioEngine else { return }
            self.audio.async { self.configurationChanged(source) }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        heartbeat?.cancel()
    }

    // MARK: - Packs

    /// Looks for packs inside the app, and beside the project when run straight from a build folder.
    private func discoverPacks() {
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources.appendingPathComponent("Sounds")) }
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Sounds"))
        var found: [PackInfo] = []
        for root in roots {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard folders[dir.lastPathComponent] == nil,
                      let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")),
                      let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else { continue }
                folders[manifest.id] = dir
                found.append(PackInfo(id: manifest.id, name: manifest.name))
            }
        }
        packs = found + [SoundBank.synthPack]
    }

    static func kind(_ name: String) -> Sound? {
        switch name {
        case "strike": return .strike
        case "key": return .key
        case "space": return .space
        case "back": return .back
        case "tape": return .tape
        case "bell": return .bell
        case "feed": return .feed
        case "tick": return .tick
        case "lock": return .lock
        case "lampSwitch": return .lampSwitch
        case "paperIn": return .paperIn
        case "paperOut": return .paperOut
        default:
            if name.hasPrefix("carriage"), let i = Int(name.dropFirst("carriage".count)) { return .carriage(i) }
            return nil
        }
    }

    private func loadPack() {
        loadToken += 1
        let token = loadToken
        guard let dir = folders[packID] else {
            strikeLead = 0
            audio.async {
                self.recorded = [:]
                self.hasKeyTravel = false
                self.lastTake = [:]
            }
            return
        }
        let format = self.format
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")),
                  let manifest = try? JSONDecoder().decode(PackManifest.self, from: data) else { return }
            var loaded: [Sound: [AVAudioPCMBuffer]] = [:]
            for (name, entries) in manifest.sounds {
                guard let sound = SoundBank.kind(name) else { continue }
                loaded[sound] = entries.compactMap { SoundBank.read(dir.appendingPathComponent($0.file), format: format) }
            }
            let kept = loaded.filter { !$0.value.isEmpty }
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.strikeLead = manifest.strikeLead
                self.audio.async {
                    self.recorded = kept
                    self.hasKeyTravel = manifest.hasKeyTravel
                    self.lastTake = [:]
                }
            }
        }
    }

    /// Reads a sample file into memory in the engine's own format.
    static func read(_ url: URL, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let source = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        if source.sampleRate == format.sampleRate && source.channelCount == format.channelCount { return buffer }
        // A file at another rate or channel count: convert it once, here.
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / source.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return failure == nil && out.frameLength > 0 ? out : nil
    }

    private static func makeBuffers(_ format: AVAudioFormat) -> [Sound: [AVAudioPCMBuffer]] {
        var out: [Sound: [AVAudioPCMBuffer]] = [:]
        for (sound, takes) in Synth.all() {
            out[sound] = takes.compactMap { buffer(left: $0.left, right: $0.right, format: format) }
        }
        return out
    }

    static func buffer(left: [Float], right: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = min(left.count, right.count)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let channels = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        left.withUnsafeBufferPointer { channels[0].update(from: $0.baseAddress!, count: n) }
        right.withUnsafeBufferPointer { channels[1].update(from: $0.baseAddress!, count: n) }
        return buf
    }

    // MARK: - Playing (main thread)

    func play(_ sound: Sound, gain: Float, pan: Float) {
        let asked = SoundBank.now()
        audio.async { self.playNow(sound, gain: gain, pan: pan, asked: asked) }
    }

    /// Call on any sign that typing is about to happen — a key, the pointer moving — so the
    /// hardware is already running when the first slug lands.
    func wake() {
        let t = SoundBank.now()
        guard t - lastWake > 1 else { return }
        lastWake = t
        audio.async { self.touch() }
    }

    private func setActive(_ active: Bool) {
        audio.async {
            self.appActive = active
            if active { self.touch() }
        }
    }

    private func pushLevels() {
        let level = muted ? 0 : volume
        let silent = muted
        audio.async {
            self.level = level
            self.silent = silent
            if let engine = self.engine {
                self.guarded("set volume") { engine.mainMixerNode.outputVolume = level }
            }
        }
    }

    // MARK: - The engine (audio queue)

    /// Whether the engine should be running right now.
    private var wanted: Bool {
        // When muted there is nothing to play — unless a test run is recording what would have played.
        if silent && recording == nil { return false }
        return SoundBank.now() - lastUse <= idleLimit
    }

    private func touch() {
        if silent && recording == nil { return }
        lastUse = SoundBank.now()
        if !live { bringUp() }
        armHeartbeat()
    }

    /// Runs AVFoundation calls that may raise instead of returning an error.
    @discardableResult
    private func guarded(_ what: String, _ body: () -> Void) -> Bool {
        guard let raised = LLTry(body) else { return true }
        note("exception in \(what): \(raised.name.rawValue) \(raised.reason ?? "")")
        return false
    }

    private func build() {
        let engine = AVAudioEngine()
        let bus = AVAudioMixerNode()
        var short: [AVAudioPlayerNode] = []
        var long: [AVAudioPlayerNode] = []
        let format = self.format
        if let deviceOverride { route(engine, to: deviceOverride) }
        let ok = guarded("build") {
            engine.attach(bus)
            engine.connect(bus, to: engine.mainMixerNode, format: format)
            for i in 0..<16 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: bus, format: format)
                if i < 10 { short.append(player) } else { long.append(player) }
            }
        }
        guard ok else { return }
        self.engine = engine
        self.bus = bus
        shortPlayers = short
        longPlayers = long
        shortCursor = 0
        longCursor = 0
        playersClean = true
        installTap()
    }

    private func teardown() {
        if let engine {
            let bus = self.bus
            guarded("discard") {
                bus?.removeTap(onBus: 0)
                engine.stop()
            }
        }
        engine = nil
        bus = nil
        shortPlayers = []
        longPlayers = []
        live = false
        note("engine discarded")
    }

    private func bringUp() {
        guard !live, !synth.isEmpty else { return }
        let began = SoundBank.now()
        guard began >= nextAttempt else { return }
        if engine == nil { build() }
        guard let engine else {
            failed("could not build the engine")
            return
        }
        var started = false
        var problem = "unknown"
        let players = shortPlayers + longPlayers
        let level = self.level
        let resetPlayers = !playersClean
        let clean = guarded("start") {
            if engine.isRunning { engine.stop() }
            if resetPlayers { for player in players { player.stop() } }
            // The output's format is whatever the hardware is using at this moment; it changes when,
            // say, wireless headphones go from music to call mode. Connect the mixer in that format
            // each time, so it is the mixer that converts (and folds stereo to mono properly).
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
                problem = "no usable output device"
                return
            }
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardware)
            engine.mainMixerNode.outputVolume = level
            do {
                try engine.start()
            } catch {
                problem = "start failed: \(error.localizedDescription)"
                return
            }
            started = true
        }
        // Each player is set playing when it is first needed (`playNow`): starting one takes a
        // whole render cycle, and sixteen of them here would hold up the first sound.
        if clean { playersClean = true }
        guard clean, started else {
            failed(clean ? problem : "exception")
            return
        }
        failures = 0
        nextAttempt = 0
        live = true
        playersClean = false
        counts.starts += 1
        note(String(format: "running: %@, volume %.2f (start took %.0f ms)", describeOutput(), level, (SoundBank.now() - began) * 1000))
    }

    private func failed(_ why: String) {
        failures += 1
        // A device in the middle of changing often refuses for a moment: try again soon, then less eagerly.
        let delay = min(2.0, 0.15 * pow(2, Double(failures - 1)))
        nextAttempt = SoundBank.now() + delay
        note("could not start (attempt \(failures)): \(why)")
        // Now and then start over with a fresh engine, in case this one is in a bad way.
        if failures % 4 == 0 { teardown() }
        audio.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
            guard let self, !self.live, self.wanted else { return }
            self.bringUp()
        }
        armHeartbeat()
    }

    private func standDown(_ why: String) {
        if let engine {
            let players = shortPlayers + longPlayers
            // Leave the players properly stopped, so that waking up later is only a start.
            if guarded("stop", { engine.stop(); for player in players { player.stop() } }) { playersClean = true }
        }
        live = false
        note("stopped (\(why))")
    }

    private func configurationChanged(_ source: AVAudioEngine) {
        guard source === engine else { return }
        counts.changes += 1
        live = false
        playersClean = false
        failures = 0
        nextAttempt = 0
        note("output changed underneath: now \(describeOutput())")
        guard wanted else { return }
        bringUp()
        armHeartbeat()
    }

    /// While the engine is wanted, look in on it twice a second: restart it if it has stopped
    /// (not every stop is announced), and let it go once nothing has sounded for a while.
    private func armHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: audio)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.beat() }
        heartbeat = timer
        timer.resume()
    }

    private func beat() {
        guard wanted else {
            if live || engine?.isRunning == true { standDown("idle") }
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        if live, engine?.isRunning != true {
            live = false
            playersClean = false
            note("engine found stopped")
        }
        if !live { bringUp() }
    }

    private func isLong(_ sound: Sound) -> Bool {
        switch sound {
        case .bell, .carriage, .paperIn, .paperOut, .lock: return true
        default: return false
        }
    }

    private func playNow(_ sound: Sound, gain: Float, pan: Float, asked: Double) {
        if silent && recording == nil { return }
        lastUse = SoundBank.now()
        if !live {
            bringUp()
            armHeartbeat()
        }
        guard live else { return }
        // A request that had to wait behind a restart is no longer in step with the picture.
        // A strike that sounds late is worse than one that does not sound.
        if SoundBank.now() - asked > (isLong(sound) ? 0.25 : 0.08) {
            counts.late += 1
            return
        }
        let takes: [AVAudioPCMBuffer]
        if let real = recorded[sound] {
            takes = real
        } else if sound == .key && hasKeyTravel {
            return
        } else if let made = synth[sound] {
            takes = made
        } else {
            return
        }
        guard !takes.isEmpty else { return }
        // Never the same take twice running: repetition is what gives samples away.
        var index = Int.random(in: 0..<takes.count)
        if takes.count > 1, index == lastTake[sound] { index = (index + 1 + Int.random(in: 0..<(takes.count - 1))) % takes.count }
        lastTake[sound] = index

        let player: AVAudioPlayerNode
        if isLong(sound) {
            guard !longPlayers.isEmpty else { return }
            player = longPlayers[longCursor]
            longCursor = (longCursor + 1) % longPlayers.count
        } else {
            guard !shortPlayers.isEmpty else { return }
            player = shortPlayers[shortCursor]
            shortCursor = (shortCursor + 1) % shortPlayers.count
        }
        let buffer = takes[index]
        let ok = guarded("play") {
            player.volume = max(0, min(1, gain))
            player.pan = max(-1, min(1, pan))
            player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
        if ok {
            counts.played += 1
        } else {
            // The engine went away between the check and the call. The heartbeat brings it back.
            live = false
            playersClean = false
            armHeartbeat()
        }
    }

    // MARK: - Looking in

    private func note(_ text: String) {
        journal.append(String(format: "%8.3f  %@", SoundBank.now() - born, text))
        if journal.count > 400 { journal.removeFirst(100) }
        log.notice("\(text, privacy: .public)")
    }

    /// The device the engine is playing to and the format that device is in.
    private func describeOutput() -> String {
        guard let engine else { return "no engine" }
        var text = "unknown device"
        guarded("describe") {
            var id = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if let unit = engine.outputNode.audioUnit,
               AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr {
                text = AudioDevices.name(of: id) ?? "device \(id)"
            }
            let hardware = engine.outputNode.outputFormat(forBus: 0)
            text += String(format: ", %.0f Hz, %d ch", hardware.sampleRate, Int(hardware.channelCount))
        }
        return text
    }

    /// One line describing what is loaded, for test runs.
    var status: String {
        let pack = packID
        let lead = strikeLead
        return audio.sync {
            "pack \(pack)  recorded kinds \(recorded.count)  strikes \(recorded[.strike]?.count ?? 0)  lead \(String(format: "%.3f", lead))  key travel \(hasKeyTravel)  "
                + "running \(live && engine?.isRunning == true)  output [\(describeOutput())]  volume \(String(format: "%.2f", level))  starts \(counts.starts)  changes \(counts.changes)  played \(counts.played)  late \(counts.late)"
        }
    }

    /// What the engine has been through since launch, one event to a line (seconds since launch).
    var history: String {
        audio.sync { journal.joined(separator: "\n") }
    }

    // MARK: - Developer aids

    /// Writes everything the app plays to a file, taken before volume and mute. The file keeps
    /// real time: while the engine is down nothing arrives, and that stretch is written as silence.
    func record(to url: URL) {
        audio.async {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: self.format.sampleRate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            try? FileManager.default.removeItem(at: url)
            self.recording = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            self.recordingBegan = SoundBank.now()
            self.installTap()
            self.touch()
        }
    }

    private var recordingBegan = 0.0

    private func installTap() {
        guard let bus, let file = recording else { return }
        let format = self.format
        let began = recordingBegan
        let rate = format.sampleRate
        // Frames written so far; only the tap's own thread touches it.
        var written: Int64 = 0
        guarded("tap") {
            bus.removeTap(onBus: 0)
            bus.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                // Where this buffer belongs on the clock, and how much silence is missing before it.
                let due = Int64((SoundBank.now() - began) * rate) - Int64(buffer.frameLength)
                if written == 0 { written = file.length }
                let gap = due - written
                if gap > Int64(rate * 0.05), gap < Int64(rate * 120),
                   let quiet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(gap)) {
                    quiet.frameLength = AVAudioFrameCount(gap)
                    if let channels = quiet.floatChannelData {
                        for c in 0..<Int(format.channelCount) { channels[c].update(repeating: 0, count: Int(gap)) }
                    }
                    try? file.write(from: quiet)
                    written += gap
                }
                try? file.write(from: buffer)
                written += Int64(buffer.frameLength)
            }
        }
    }

    func stopRecording() {
        audio.sync {
            let bus = self.bus
            guarded("untap") { bus?.removeTap(onBus: 0) }
            recording = nil
        }
    }

    /// Moves the sound to another output device (nil for the Mac's own choice), to check that
    /// playing survives the hardware changing underneath it.
    func debugRoute(to name: String?) {
        audio.async {
            guard let engine = self.engine else { return }
            // Do what the system does when a device changes — stop the engine, then present a
            // different device — and run the handler a real change runs. (Changing the device
            // of a running engine from outside can hang for many seconds, which says nothing
            // about real device changes.)
            self.guarded("stop") { engine.stop() }
            self.route(engine, to: name)
            self.configurationChanged(engine)      // marks the players as needing a reset, as a real change does
        }
    }

    private func route(_ engine: AVAudioEngine, to name: String?) {
        var id: AudioDeviceID
        if let name {
            guard let device = AudioDevices.all().first(where: { $0.name == name && $0.outputs > 0 }) else {
                note("no output device named \(name); staying with the Mac's own choice")
                return
            }
            id = device.id
        } else {
            guard let device = AudioDevices.defaultOutput() else { return }
            id = device
        }
        var status: OSStatus = -1
        guarded("route") {
            guard let unit = engine.outputNode.audioUnit else { return }
            status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        note("output set to \(name ?? "the Mac's own choice") (status \(status))")
    }

    /// Writes every synthesised sound to WAV files, for listening to and measuring them.
    static func dump(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: Synth.sampleRate, channels: 2)!
        for (sound, takes) in Synth.all() {
            for (i, take) in takes.enumerated() {
                guard let buf = buffer(left: take.left, right: take.right, format: format) else { continue }
                let name: String
                switch sound {
                case .carriage(let c): name = "carriage\(c)"
                default: name = "\(sound)"
                }
                let url = directory.appendingPathComponent("\(name)-\(i).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Synth.sampleRate, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
                if let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) {
                    try? file.write(from: buf)
                }
                let peak = max(take.left.map { abs($0) }.max() ?? 0, take.right.map { abs($0) }.max() ?? 0)
                let rms = sqrt(take.left.reduce(0) { $0 + $1 * $1 } / Float(max(1, take.left.count)))
                print(String(format: "%@-%d  %.3fs  peak %.3f  rms %.4f", name, i, Double(take.left.count) / Synth.sampleRate, peak, rms))
            }
        }
    }
}
