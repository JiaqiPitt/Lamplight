import SwiftUI
import AppKit

enum Palette {
    static let amber = Color(red: 0.93, green: 0.72, blue: 0.42)
    static let ink = Color(red: 0.90, green: 0.87, blue: 0.80)
    static let dim = Color(red: 0.90, green: 0.87, blue: 0.80).opacity(0.50)
    static let faint = Color(red: 0.90, green: 0.87, blue: 0.80).opacity(0.28)
    static let panel = Color(red: 0.070, green: 0.068, blue: 0.064)
    static let red = Color(red: 0.74, green: 0.22, blue: 0.17)
}

/// Hosts the SpriteKit machine inside the SwiftUI window.
struct SceneContainer: NSViewRepresentable {
    let state: AppState

    func makeNSView(context: Context) -> TypewriterView {
        let view = TypewriterView(state: state)
        DispatchQueue.main.async { state.attach(view) }
        return view
    }

    func updateNSView(_ nsView: TypewriterView, context: Context) {}
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Color.black
            SceneContainer(state: state)

            if state.drawerOpen {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture { state.closePanels() }
                    .transition(.opacity)
            }

            HStack(spacing: 0) {
                if state.drawerOpen {
                    DrawerView()
                        .transition(.move(edge: .leading))
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 14) {
                Spacer()
                if state.showHint {
                    Text("Just start typing. Move the pointer for the toolbar; scroll to read back.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.dim)
                        .transition(.opacity)
                }
                ToolbarView(settings: state.settings)
                    .opacity(state.chromeVisible ? 1 : 0)
                    .allowsHitTesting(state.chromeVisible)
            }
            .padding(.bottom, 28)
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.24), value: state.drawerOpen)
        .animation(.easeInOut(duration: 0.30), value: state.chromeVisible)
        .animation(.easeInOut(duration: 0.8), value: state.showHint)
    }
}

// MARK: - Toolbar

struct ToolButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void

    init(symbol: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.active = active
        self.action = action
    }
    // Written as a plain `State` value rather than `@State`: the attribute needs a compiler
    // plugin that ships only with full Xcode, and this project builds with the Command Line Tools.
    private var hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Palette.amber : (hover.wrappedValue ? Palette.ink : Palette.dim))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.wrappedValue = $0 }
    }
}

struct ToolbarView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 2) {
            ToolButton(symbol: "tray.full", help: "Drawer: every diary, reading note and essay (⌘O)", active: state.drawerOpen) {
                state.toggleDrawer()
            }
            Menu {
                Button("Today’s Diary") { state.openToday() }
                Button("New Reading Note…") {
                    state.drawerKind = .reading
                    state.newBookOpen = true
                    if !state.drawerOpen { state.toggleDrawer() }
                }
                Button("New Essay") { state.newEssay() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.dim)
                    .frame(width: 34, height: 30)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Feed a new sheet")

            divider

            Button { state.toggleRibbon() } label: {
                ZStack {
                    Circle().fill(state.ribbonRed ? Palette.red : Color(white: 0.16))
                    Circle().strokeBorder(Palette.dim, lineWidth: 1)
                }
                .frame(width: 13, height: 13)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ribbon: black / red (⌘R)")

            ToolButton(symbol: settings.lightsOn ? "lightbulb.fill" : "lightbulb", help: "Lights on / off (⌘L)", active: settings.lightsOn) {
                state.toggleLights()
            }
            ToolButton(symbol: settings.muted ? "speaker.slash" : "speaker.wave.2", help: "Sound on / off (⇧⌘M)") {
                state.toggleMute()
            }
            ToolButton(symbol: "slider.horizontal.3", help: "Lamp, sound and typing options", active: state.settingsOpen) {
                state.settingsOpen.toggle()
            }
            .popover(isPresented: $state.settingsOpen, arrowEdge: .top) {
                SettingsPanel(settings: settings, state: state)
            }

            if !state.status.isEmpty {
                divider
                Text(state.status)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Palette.panel.opacity(0.94))
                .overlay(Capsule().strokeBorder(Palette.amber.opacity(0.16), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 14, y: 4)
        )
        .onHover { state.chromeHover = $0 }
    }

    private var divider: some View {
        Rectangle().fill(Palette.faint).frame(width: 1, height: 16).padding(.horizontal, 6)
    }
}

// MARK: - Settings

struct SettingsPanel: View {
    @ObservedObject var settings: Settings
    @ObservedObject var output: OutputMonitor
    let state: AppState

    init(settings: Settings, state: AppState) {
        self.settings = settings
        self.state = state
        self.output = state.output
    }
    private var scale = State(initialValue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            slider("Lamp", $settings.lampPower, 0.35...1.8)
            slider("Night", $settings.ambient, 0...2.6)
            slider("Volume", $settings.volume, 0...1)
            HStack {
                Text("Output").frame(width: SettingsPanel.labelWidth, alignment: .leading)
                Text(output.name.isEmpty ? "No sound output" : output.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .help("Lamplight plays through the Mac's sound output. Choose another from the Sound menu in the menu bar.")
            HStack {
                Text("Sound").frame(width: SettingsPanel.labelWidth, alignment: .leading)
                Picker("", selection: $settings.soundPack) {
                    ForEach(state.sound.packs) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            HStack {
                Text("Size").frame(width: SettingsPanel.labelWidth, alignment: .leading)
                Slider(value: scale.projectedValue, in: 0.8...1.3) { editing in
                    // Re-inking every glyph is heavy; do it once the slider is let go.
                    if !editing { settings.textScale = scale.wrappedValue }
                }
            }
            Divider()
            picker("Travel") {
                Picker("", selection: $settings.paperMoves) {
                    Text("Lamp moves").tag(false)
                    Text("Paper moves").tag(true)
                }
            }
            picker("Delete") {
                Picker("", selection: $settings.backspaceMode) {
                    Text("Tape").tag(0)
                    Text("Strike out").tag(1)
                    Text("Overtype").tag(2)
                }
            }
            picker("Chinese font") {
                Picker("", selection: $settings.cjkFont) {
                    ForEach(Settings.cjkFonts, id: \.name) { Text($0.label).tag($0.name) }
                }
            }
            Toggle("Return automatically at the end of a line", isOn: $settings.autoReturn)
            Toggle("Dust in the lamplight", isOn: $settings.dust)
            Divider()
            Button("Show Sheets in Finder") { state.revealData() }
                .buttonStyle(.link)
        }
        .font(.system(size: 12.5))
        .padding(18)
        .frame(width: 350)
        .onAppear { scale.wrappedValue = settings.textScale }
    }

    static let labelWidth: CGFloat = 92

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: SettingsPanel.labelWidth, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private func picker<P: View>(_ label: String, @ViewBuilder _ content: () -> P) -> some View {
        HStack {
            Text(label).frame(width: SettingsPanel.labelWidth, alignment: .leading)
            content().pickerStyle(.segmented).labelsHidden()
        }
    }
}

// MARK: - Drawer

struct DrawerView: View {
    @EnvironmentObject var state: AppState
    private var query = State(initialValue: "")
    private var pendingDelete = State<Entry?>(initialValue: nil)
    private var book = State(initialValue: "")
    private var author = State(initialValue: "")

    private var entries: [Entry] {
        _ = state.revision
        let all = state.list(state.drawerKind)
        let q = query.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.book.localizedCaseInsensitiveContains(q) || $0.text().localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drawer")
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                Spacer()
                ToolButton(symbol: "xmark", help: "Close the drawer") { state.toggleDrawer() }
            }
            .padding(.top, 40)

            Picker("", selection: $state.drawerKind) {
                ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.faint)
                TextField("Search", text: query.projectedValue)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05)))

            newSheet

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let list = entries
                    if list.isEmpty {
                        Text(query.wrappedValue.isEmpty ? "Nothing written yet." : "Nothing found.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.faint)
                            .padding(.top, 18)
                            .frame(maxWidth: .infinity)
                    }
                    switch state.drawerKind {
                    case .diary:
                        ForEach(grouped(list) { String($0.day.prefix(7)) }, id: \.key) { group in
                            header(monthTitle(group.key))
                            ForEach(group.items) { row($0) }
                        }
                    case .reading:
                        ForEach(grouped(list) { $0.book.isEmpty ? "Untitled" : $0.book }, id: \.key) { group in
                            HStack {
                                header(group.key + (group.items.first.map { $0.author.isEmpty ? "" : " — \($0.author)" } ?? ""))
                                Spacer()
                                ToolButton(symbol: "plus", help: "Another note on this book") {
                                    state.newReading(book: group.items.first?.book ?? "", author: group.items.first?.author ?? "")
                                }
                            }
                            ForEach(group.items) { row($0) }
                        }
                    case .essay:
                        ForEach(list) { row($0) }
                    }
                }
                .padding(.bottom, 20)
            }

            Button("Show Sheets in Finder") { state.revealData() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.faint)
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
        .frame(width: 340)
        .frame(maxHeight: .infinity)
        .background(Palette.panel.opacity(0.975))
        .overlay(alignment: .trailing) { Rectangle().fill(Palette.amber.opacity(0.14)).frame(width: 1) }
        .confirmationDialog("Throw this sheet away?", isPresented: Binding(get: { pendingDelete.wrappedValue != nil }, set: { if !$0 { pendingDelete.wrappedValue = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let e = pendingDelete.wrappedValue { state.delete(e) }
                pendingDelete.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete.wrappedValue = nil }
        } message: {
            Text("The file goes to the Trash, where it can still be recovered.")
        }
    }

    @ViewBuilder private var newSheet: some View {
        switch state.drawerKind {
        case .diary:
            actionButton("Today’s Diary", "sun.max") { state.openToday() }
        case .essay:
            actionButton("New Essay", "plus") { state.newEssay() }
        case .reading:
            if state.newBookOpen {
                VStack(alignment: .leading, spacing: 8) {
                    field("Title", book.projectedValue)
                    field("Author (optional)", author.projectedValue)
                    HStack {
                        Button("Start Taking Notes") {
                            state.newReading(book: book.wrappedValue, author: author.wrappedValue)
                            book.wrappedValue = ""
                            author.wrappedValue = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.amber.opacity(0.75))
                        .disabled(book.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { state.newBookOpen = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.dim)
                    }
                    .font(.system(size: 12.5))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            } else {
                actionButton("Start a New Book", "plus") { state.newBookOpen = true }
            }
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    private func actionButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
                Spacer()
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.amber)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.amber.opacity(0.28), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Palette.faint)
            .padding(.top, 14)
            .padding(.bottom, 3)
            .padding(.horizontal, 10)
    }

    private func row(_ entry: Entry) -> some View {
        EntryRow(entry: entry, current: entry.id == state.currentID) { state.open(entry) }
            .contextMenu {
                Button("Throw This Sheet Away…", role: .destructive) { pendingDelete.wrappedValue = entry }
            }
    }

    private struct Group {
        let key: String
        var items: [Entry]
    }

    /// Groups while keeping the order the entries arrive in.
    private func grouped(_ list: [Entry], by key: (Entry) -> String) -> [Group] {
        var groups: [Group] = []
        var index: [String: Int] = [:]
        for e in list {
            let k = key(e)
            if let i = index[k] {
                groups[i].items.append(e)
            } else {
                index[k] = groups.count
                groups.append(Group(key: k, items: [e]))
            }
        }
        return groups
    }

    private func monthTitle(_ key: String) -> String {
        guard let date = Entry.date(fromDayKey: key + "-01") else { return key }
        return Entry.monthTitle(date)
    }
}

struct EntryRow: View {
    let entry: Entry
    let current: Bool
    let action: () -> Void
    private var hover = State(initialValue: false)

    init(entry: Entry, current: Bool, action: @escaping () -> Void) {
        self.entry = entry
        self.current = current
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(current ? Palette.amber : Palette.ink)
                    let preview = entry.preview
                    Text(preview.isEmpty ? "(blank)" : preview)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Text("\(entry.wordCount)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(current ? 0.07 : (hover.wrappedValue ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
    }
}
