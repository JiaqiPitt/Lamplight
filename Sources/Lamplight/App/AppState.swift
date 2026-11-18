import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Ties the machine, the library of sheets and the controls together.
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = Store()
    let settings = Settings()
    let sound = SoundBank()
    /// Which device the Mac is sending sound to, shown in Settings.
    let output = OutputMonitor()
    weak var view: TypewriterView?
    var scene: TypewriterScene? { view?.typewriter }

    @Published var chromeVisible = false
    @Published var drawerOpen = false
    @Published var settingsOpen = false
    @Published var newBookOpen = false
    @Published var ribbonRed = false
    @Published var drawerKind: EntryKind = .diary
    @Published var status = ""
    @Published var currentID: UUID?
    /// Bumped whenever the set of saved sheets changes, so lists redraw.
    @Published var revision = 0
    @Published var showHint = false

    var chromeHover = false
    private var saveWork: DispatchWorkItem?
    private var chromeWork: DispatchWorkItem?
    private var statusPending = false
    private var bag = Set<AnyCancellable>()
    private var lastSourceFlash = Date.distantPast
    private var lastMark = ""
    /// Set by LAMPLIGHT_MUTE=1, for running the app silently while testing.
    private let forceMute = ProcessInfo.processInfo.environment["LAMPLIGHT_MUTE"] == "1"

    private init() {
        sound.volume = Float(settings.volume)
        sound.muted = settings.muted || forceMute
        // Fall back to the generated sounds if the chosen pack is not installed.
        sound.packID = sound.packs.contains { $0.id == settings.soundPack } ? settings.soundPack : SoundBank.synthPack.id
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &bag)

        // The carriage shows the input source only at the moment it changes.
        DistributedNotificationCenter.default().addObserver(forName: InputSource.changed, object: nil, queue: .main) { [weak self] _ in
            self?.inputSourceChanged()
        }
        lastMark = InputSource.currentMark()
    }

    // MARK: - Machine

    func attach(_ view: TypewriterView) {
        self.view = view
        view.typewriter.sound = sound
        view.typewriter.onChange = { [weak self] in self?.sceneChanged() }
        applySettings()
        openToday()
        if !Prefs.store.bool(forKey: "hintShown") {
            Prefs.store.set(true, forKey: "hintShown")
            showHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in self?.showHint = false }
        }
    }

    func applySettings() {
        var options = settings.sceneOptions
        options.ribbon = ribbonRed ? 1 : 0
        if let scene, scene.options != options { scene.options = options }
        sound.volume = Float(settings.volume)
        sound.muted = settings.muted || forceMute
        if sound.packs.contains(where: { $0.id == settings.soundPack }) { sound.packID = settings.soundPack }
    }

    func focus() {
        guard let view else { return }
        view.window?.makeFirstResponder(view)
    }

    private func inputSourceChanged() {
        let now = Date()
        let mark = InputSource.currentMark()
        // The system sometimes announces one switch twice.
        if mark == lastMark && now.timeIntervalSince(lastSourceFlash) < 0.4 { return }
        lastMark = mark
        lastSourceFlash = now
        guard NSApp.isActive, !mark.isEmpty else { return }
        scene?.flashIndicator(mark)
    }

    // MARK: - Saving

    private func sceneChanged() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
        if chromeVisible && !statusPending {
            statusPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.statusPending = false
                self?.refreshStatus()
            }
        }
    }

    /// Writes the sheet in the machine to disk. A sheet with nothing typed on it is not kept.
    func saveNow(wait: Bool = false) {
        saveWork?.cancel()
        guard let entry = scene?.entry, currentID == entry.id else { return }
        if entry.isBlank && !store.isSaved(entry.id) { return }
        let isNew = !store.isSaved(entry.id)
        store.save(entry, wait: wait)
        if isNew || drawerOpen { revision += 1 }
    }

    /// Updates the line in the toolbar. While a new sheet is still feeding in, the machine
    /// holds the old one, so the sheet being loaded can be passed in directly.
    func refreshStatus(for loading: Entry? = nil) {
        let live = scene?.entry
        guard let entry = loading ?? (live?.id == currentID ? live : currentID.flatMap { store.entries[$0] }) else { return }
        var parts = [entry.kind.label]
        switch entry.kind {
        case .diary: parts.append(entry.displayTitle)
        case .reading: parts.append(entry.book.isEmpty ? entry.displayTitle : entry.book)
        case .essay: parts.append(entry.displayTitle)
        }
        let words = entry.wordCount
        parts.append(words == 1 ? "1 word" : "\(words) words")
        let text = parts.joined(separator: " · ")
        if text != status { status = text }
    }

    // MARK: - Sheets

    private func load(_ entry: Entry, header: String) {
        saveNow()
        currentID = entry.id
        scene?.load(entry, animated: true, header: header)
        drawerOpen = false
        newBookOpen = false
        refreshStatus(for: entry)
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    func openToday() {
        let key = Entry.dayKey()
        if let entry = scene?.entry, entry.kind == .diary, entry.day == key, currentID == entry.id {
            drawerOpen = false
            focus()
            return
        }
        if let existing = store.diary(day: key) {
            load(existing, header: "")
        } else {
            let (entry, header) = Entry.make(kind: .diary)
            load(entry, header: header)
        }
    }

    func open(_ entry: Entry) {
        if entry.id == currentID {
            drawerOpen = false
            focus()
            return
        }
        // Take the saved copy, which is the freshest for any sheet not in the machine.
        load(store.entries[entry.id] ?? entry, header: "")
    }

    func newReading(book: String, author: String) {
        let (entry, header) = Entry.make(kind: .reading, book: book.trimmingCharacters(in: .whitespaces),
                                         author: author.trimmingCharacters(in: .whitespaces))
        load(entry, header: header)
    }

    func newEssay() {
        let (entry, header) = Entry.make(kind: .essay)
        load(entry, header: header)
    }

    func delete(_ entry: Entry) {
        store.delete(entry.id)
        revision += 1
        if entry.id == currentID {
            currentID = nil
            let key = Entry.dayKey()
            if let existing = store.diary(day: key) {
                currentID = existing.id
                scene?.load(existing, animated: true)
                refreshStatus(for: existing)
            } else {
                let (fresh, header) = Entry.make(kind: .diary)
                currentID = fresh.id
                scene?.load(fresh, animated: true, header: header)
                refreshStatus(for: fresh)
            }
        }
    }

    /// The sheets of one kind, with the one in the machine shown as it is right now.
    func list(_ kind: EntryKind) -> [Entry] {
        var all = store.list(kind)
        if let live = scene?.entry, live.id == currentID, let i = all.firstIndex(where: { $0.id == live.id }) {
            all[i] = live
        }
        return all
    }

    // MARK: - Controls

    func toggleDrawer() {
        if !drawerOpen {
            saveNow()
            if let kind = scene?.entry.kind { drawerKind = kind }
            revision += 1
        }
        drawerOpen.toggle()
        if drawerOpen { chromeVisible = true } else { focus() }
    }

    func closePanels() {
        if settingsOpen { settingsOpen = false }
        if drawerOpen { drawerOpen = false }
        newBookOpen = false
        scene?.cancelPending()
        focus()
    }

    func toggleLights() {
        settings.lightsOn.toggle()
        sound.play(.lampSwitch, gain: 0.8, pan: 0)
    }

    func toggleRibbon() {
        ribbonRed.toggle()
        sound.play(.tick, gain: 0.7, pan: 0)
        applySettings()
    }

    func toggleMute() {
        settings.muted.toggle()
    }

    /// Types the current time, for marking when a paragraph was written.
    func stampTime() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        scene?.type(f.string(from: Date()) + " ")
        focus()
    }

    func copyAll() {
        guard let text = scene?.entry.text() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func exportText() {
        guard let entry = scene?.entry else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let base: String
        switch entry.kind {
        case .diary: base = "Diary \(entry.day)"
        case .reading: base = (entry.book.isEmpty ? "Reading notes" : entry.book) + " \(Entry.dayKey(entry.createdAt))"
        case .essay: base = "Essay \(Entry.dayKey(entry.createdAt))"
        }
        panel.nameFieldStringValue = base + ".txt"
        let text = entry.text()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func revealData() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }

    // MARK: - Chrome

    /// The pointer moved: bring the controls up, and let them fade once it rests.
    func pointerMoved() {
        if !chromeVisible {
            chromeVisible = true
            refreshStatus()
        }
        scheduleChromeHide()
    }

    private func scheduleChromeHide() {
        chromeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.drawerOpen || self.settingsOpen || self.chromeHover {
                self.scheduleChromeHide()
            } else {
                self.chromeVisible = false
            }
        }
        chromeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    /// Typing began: get everything out of the way.
    func typingStarted() {
        if showHint { showHint = false }
        guard chromeVisible, !drawerOpen, !settingsOpen else { return }
        chromeWork?.cancel()
        chromeVisible = false
    }
}
