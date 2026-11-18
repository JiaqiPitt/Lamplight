import SwiftUI
import AppKit

struct LamplightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        Window("Lamplight", id: "main") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 920, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Today’s Diary") { state.openToday() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("New Essay") { state.newEssay() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Reading Note…") {
                    state.drawerKind = .reading
                    state.newBookOpen = true
                    if !state.drawerOpen { state.toggleDrawer() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open Drawer") { state.toggleDrawer() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Export as Text…") { state.exportText() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Copy All Text") { state.copyAll() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Show Sheets in Finder") { state.revealData() }
            }
            // A typewriter has no undo.
            CommandGroup(replacing: .undoRedo) {}
            CommandMenu("Typewriter") {
                Button("Lights On / Off") { state.toggleLights() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Switch Ribbon (Black / Red)") { state.toggleRibbon() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Type the Current Time") { state.stampTime() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Sound On / Off") { state.toggleMute() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // `--no-activate` keeps a test launch from taking the keyboard away from whatever is in use.
        if !CommandLine.arguments.contains("--no-activate") {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async {
            for window in NSApp.windows { self.configure(window) }
        }
        runDeveloperHooks()
    }

    private func configure(_ window: NSWindow) {
        window.backgroundColor = .black
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        // A test launch must not overwrite the remembered size and position of the real window.
        if Prefs.store !== UserDefaults.standard { window.setFrameAutosaveName("") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.saveNow(wait: true)
    }

    /// Developer aid: drags the carriage with real mouse events sent through the view, the
    /// pointer easing `cells` cells along the line (negative is left) in `seconds`.
    private func drag(cells: Double, seconds: Double) {
        guard let view = AppState.shared.view, let window = view.window else { return }
        let scene = view.typewriter
        let start = view.convert(view.convert(scene.carriageHandle, from: scene), to: nil)
        let reach = CGFloat(cells) * scene.L.cellW
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let down = event(.leftMouseDown, x: start.x) { view.mouseDown(with: down) }
        let began = CACurrentMediaTime()
        // About as often as a mouse reports.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + 0.008, repeating: 0.008, leeway: .milliseconds(1))
        timer.setEventHandler {
            let u = CGFloat(min(1, (CACurrentMediaTime() - began) / max(seconds, 0.01)))
            let x = start.x + reach * u * u * (3 - 2 * u)
            if let moved = event(.leftMouseDragged, x: x) { view.mouseDragged(with: moved) }
            if u >= 1 {
                timer.cancel()
                if let up = event(.leftMouseUp, x: x) { view.mouseUp(with: up) }
            }
        }
        timer.resume()
    }

    /// Developer conveniences for checking the real app without a keyboard:
    ///   --demo "text"     types the text shortly after launch
    ///   --window-id       prints the main window's number, for capturing it
    ///   --open-drawer     opens the drawer after the demo text
    ///   --quit-after N    quits after N seconds
    private func runDeveloperHooks() {
        let args = CommandLine.arguments
        if args.contains("--window-id") {
            onTime(1.0) {
                if let window = NSApp.windows.first(where: { $0.isVisible }) {
                    print("WINDOW \(window.windowNumber)")
                    fflush(stdout)
                }
            }
        }
        if let i = args.firstIndex(of: "--demo"), i + 1 < args.count {
            let text = args[i + 1].replacingOccurrences(of: "\\n", with: "\n")
            onTime(2.2) {
                AppState.shared.scene?.type(text)
            }
        }
        if args.contains("--show-chrome") {
            onTime(3.0) {
                AppState.shared.chromeHover = true
                AppState.shared.pointerMoved()
            }
        }
        if args.contains("--open-drawer") {
            onTime(4.0) {
                AppState.shared.toggleDrawer()
                if let i = args.firstIndex(of: "--drawer-kind"), i + 1 < args.count, let kind = EntryKind(rawValue: args[i + 1]) {
                    AppState.shared.drawerKind = kind
                }
            }
        }
        if args.contains("--open-settings") {
            onTime(4.0) {
                AppState.shared.chromeHover = true
                AppState.shared.pointerMoved()
                AppState.shared.settingsOpen = true
            }
        }
        if let i = args.firstIndex(of: "--open-last"), i + 1 < args.count, let kind = EntryKind(rawValue: args[i + 1]) {
            onTime(2.0) {
                if let entry = AppState.shared.store.list(kind).first { AppState.shared.open(entry) }
            }
        }
        if args.contains("--flash-source") {
            onTime(3.0) {
                AppState.shared.scene?.flashIndicator(InputSource.currentMark())
            }
        }
        if let i = args.firstIndex(of: "--keys"), i + 1 < args.count {
            // Sends real key-down events through the view, exercising the same path as a keyboard.
            // Use <ret> <del> <tab> <left> <right> <up> <down> for the named keys.
            let script = args[i + 1]
            onTime(2.2) {
                guard let view = AppState.shared.view, let window = view.window else { return }
                let named: [String: (UInt16, String)] = [
                    "ret": (36, "\r"), "del": (51, "\u{7F}"), "tab": (48, "\t"),
                    "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "up": (126, "\u{F700}"), "down": (125, "\u{F701}"),
                ]
                // Also: <wait> pauses half a second, and <hold> marks the next key as an auto-repeat
                // (what the system sends while a key is held down).
                // <glide-left:0.4> and <glide-right:0.4> hold Control-F / Control-J for that many
                // seconds: key down, the repeats the system sends from 0.4 s on, then key up.
                var keys: [(code: UInt16, text: String, at: Double, repeating: Bool, flags: NSEvent.ModifierFlags, up: Bool)] = []
                var rest = Substring(script)
                var time = 0.0
                var repeating = false
                while let ch = rest.first {
                    if ch == "<", let end = rest.firstIndex(of: ">") {
                        let name = String(rest[rest.index(after: rest.startIndex)..<end])
                        rest = rest[rest.index(after: end)...]
                        if name == "wait" { time += 0.5; continue }
                        if name == "hold" { repeating = true; continue }
                        if name.hasPrefix("glide-"), let colon = name.firstIndex(of: ":"),
                           let seconds = Double(name[name.index(after: colon)...]) {
                            let left = name.hasPrefix("glide-left")
                            let code: UInt16 = left ? 3 : 38
                            // What the system reports for Control-F and Control-J.
                            let text = left ? "\u{06}" : "\n"
                            let flags = TypewriterView.glideModifier
                            keys.append((code, text, time, false, flags, false))
                            var t = 0.4
                            while t < seconds {
                                keys.append((code, text, time + t, true, flags, false))
                                t += 0.033
                            }
                            keys.append((code, text, time + seconds, false, flags, true))
                            time += seconds + 0.09
                            continue
                        }
                        if let key = named[name] {
                            keys.append((key.0, key.1, time, repeating, [], false))
                            time += repeating ? 0.033 : 0.09
                            repeating = false
                        }
                    } else {
                        keys.append((0, String(ch), time, false, [], false))
                        time += 0.09
                        rest = rest.dropFirst()
                    }
                }
                for key in keys {
                    onTime(key.at) {
                        if let event = NSEvent.keyEvent(with: key.up ? .keyUp : .keyDown, location: .zero, modifierFlags: key.flags,
                                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, characters: key.text,
                                                        charactersIgnoringModifiers: key.text, isARepeat: key.repeating, keyCode: key.code) {
                            if key.up { view.keyUp(with: event) } else { view.keyDown(with: event) }
                        }
                    }
                }
            }
        }
        if args.contains("--carriage-log") {
            // Prints where the carriage is, twenty times a second: seconds since launch, its
            // position in cells from the left margin, the cursor's column, and whether it is
            // being moved by hand. For checking drags and glides in the real window.
            let launched = CACurrentMediaTime()
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                guard let scene = AppState.shared.scene else { return }
                let left = (scene.L.size.width - scene.L.textW) / 2
                let cells = (scene.carriageHandle.x - left) / scene.L.cellW - 0.5
                print(String(format: "CARRIAGE %5.2f s  at %6.2f  cursor %2d  %@  queued %d", CACurrentMediaTime() - launched, cells,
                             scene.entry.cursorCol, scene.isFloating ? "in hand" : "-", scene.pendingCount))
            }
        }
        if let i = args.firstIndex(of: "--drag"), i + 1 < args.count {
            // "-20:0.5@4,12.5:0.3@6": at 4 s, press on the carriage, move the pointer 20 cells to
            // the left over half a second and let go; at 6 s, 12.5 cells to the right in 0.3 s.
            // Real mouse events, sent through the view.
            for step in args[i + 1].split(separator: ",") {
                let parts = step.split(separator: "@")
                let move = (parts.first ?? "").split(separator: ":")
                guard parts.count == 2, move.count == 2, let cells = Double(move[0]), let seconds = Double(move[1]),
                      let at = Double(parts[1]) else { continue }
                onTime(at) { self.drag(cells: cells, seconds: seconds) }
            }
        }
        if let i = args.firstIndex(of: "--pointer"), i + 1 < args.count {
            // "0.3,0.7@3": at 3 s the pointer moves to that point of the view (fractions of its
            // width and height from the bottom-left). Prints what becomes of it when it rests.
            let launched = CACurrentMediaTime()
            onTime(0.5) {
                AppState.shared.view?.pointerLog = { message in
                    print(String(format: "POINTER %.2f s  %@", CACurrentMediaTime() - launched, message))
                    fflush(stdout)
                }
            }
            for step in args[i + 1].split(separator: ",").map(String.init).chunked(2) {
                guard step.count == 2 else { continue }
                let tail = step[1].split(separator: "@")
                guard tail.count == 2, let fx = Double(step[0]), let fy = Double(tail[0]), let at = Double(tail[1]) else { continue }
                onTime(at) {
                    guard let view = AppState.shared.view, let window = view.window else { return }
                    let p = view.convert(CGPoint(x: view.bounds.width * fx, y: view.bounds.height * fy), to: nil)
                    if let event = NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                        view.mouseMoved(with: event)
                        print(String(format: "POINTER %.2f s  moved", CACurrentMediaTime() - launched))
                        fflush(stdout)
                    }
                }
            }
        }
        if let i = args.firstIndex(of: "--record-audio"), i + 1 < args.count {
            // Records what the app plays (even when muted) so the sound can be checked by measurement.
            AppState.shared.sound.record(to: URL(fileURLWithPath: args[i + 1]))
            var at = 6.0
            if let j = args.firstIndex(of: "--quit-after"), j + 1 < args.count, let t = Double(args[j + 1]) { at = t - 0.3 }
            onTime(at) {
                print("SOUND", AppState.shared.sound.status)
                AppState.shared.sound.stopRecording()
                fflush(stdout)
            }
        }
        if let i = args.firstIndex(of: "--audio-flap"), i + 1 < args.count {
            // "Some Device@4,default@6.5": moves the sound to another output device at the given
            // seconds after launch, to check that playing survives the hardware changing under it.
            for step in args[i + 1].split(separator: ",") {
                let parts = step.split(separator: "@")
                guard parts.count == 2, let at = Double(parts[1]) else { continue }
                let name = String(parts[0])
                onTime(at) {
                    AppState.shared.sound.debugRoute(to: name == "default" ? nil : name)
                }
            }
        }
        if args.contains("--audio-log") {
            // Prints what the sound engine went through (starts, stops, device changes) before quitting.
            var at = 6.0
            if let j = args.firstIndex(of: "--quit-after"), j + 1 < args.count, let t = Double(args[j + 1]) { at = t - 0.2 }
            onTime(at) {
                print("AUDIO LOG\n" + AppState.shared.sound.history)
                print("SOUND", AppState.shared.sound.status)
                fflush(stdout)
            }
        }
        if let i = args.firstIndex(of: "--sound-pack"), i + 1 < args.count {
            AppState.shared.settings.soundPack = args[i + 1]
        }
        if args.contains("--profile") {
            onTime(2.6) { AppState.shared.scene?.resetProfile() }
            var at = 6.0
            if let j = args.firstIndex(of: "--quit-after"), j + 1 < args.count, let t = Double(args[j + 1]) { at = t - 0.4 }
            onTime(at) {
                print("PROFILE", AppState.shared.scene?.profileSummary ?? "-")
                print("TEXT", (AppState.shared.scene?.entry.text(includeHeader: false) ?? "").replacingOccurrences(of: "\n", with: "⏎"))
                if let entry = AppState.shared.scene?.entry { print("CURSOR row \(entry.cursorRow) col \(entry.cursorCol)") }
                fflush(stdout)
            }
        }
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
            let first = URL(fileURLWithPath: args[i + 1])
            // `--capture-at 4,6.5` photographs at each of those seconds; the later ones are
            // named after the first with -2, -3 … added.
            var times = [6.0]
            if let j = args.firstIndex(of: "--capture-at"), j + 1 < args.count {
                let given = args[j + 1].split(separator: ",").compactMap { Double($0) }
                if !given.isEmpty { times = given }
            }
            for (k, at) in times.enumerated() {
                let stem = first.deletingPathExtension().lastPathComponent + (k == 0 ? "" : "-\(k + 1)")
                let url = first.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(first.pathExtension)
                onTime(at) {
                    // The main window goes to the named file; popovers and panels get a numbered suffix.
                    for (n, window) in NSApp.windows.filter({ $0.isVisible }).enumerated() {
                        let target = n == 0 ? url : url.deletingPathExtension().appendingPathExtension("\(n).png")
                        print(WindowCapture.save(window, to: target) ? "CAPTURED \(target.lastPathComponent)" : "CAPTURE FAILED")
                    }
                    fflush(stdout)
                }
            }
        }
        if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count, let seconds = Double(args[i + 1]) {
            onTime(seconds) {
                NSApp.terminate(nil)
            }
        }
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Runs `work` on the main thread `seconds` from now, on time. `asyncAfter` allows itself a
/// tenth of the delay in lateness — far too loose for a scripted key press and its release.
private func onTime(_ seconds: Double, _ work: @escaping () -> Void) {
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
    timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(1))
    timer.setEventHandler {
        work()
        timer.cancel()
    }
    timer.resume()
}
