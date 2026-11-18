import AppKit
import SpriteKit

/// The view the machine lives in. It turns keystrokes — including text composed by
/// Chinese, Japanese and other input methods — into typing on the scene.
final class TypewriterView: SKView, NSTextInputClient {
    let typewriter: TypewriterScene
    weak var state: AppState?
    private var marked = ""
    private var tracking: NSTrackingArea?
    private var rateTimer: Timer?

    /// Seconds the pointer may rest before it, and the light it carries, go away.
    static let pointerRest: TimeInterval = 6
    private var restTimer: Timer?
    private var pointerMovedAt: CFTimeInterval = 0
    /// True while the pointer holds the carriage.
    private var dragging = false
    private var handShown = false
    /// Developer aid: told what the pointer logic decided, to check it from a test launch.
    var pointerLog: ((String) -> Void)?

    /// The keys under the two index fingers, by position on the keyboard: with Control held,
    /// F runs the carriage left along the line and J runs it right, for as long as they are down.
    /// (Shift cannot be the modifier: Shift-F and Shift-J are how capital F and J are typed.)
    static let glideKeys: [UInt16: Int] = [3: -1, 38: 1]
    static let glideModifier: NSEvent.ModifierFlags = .control
    /// Glide keys that are down, in the order they went down.
    private var glideDown: [UInt16] = []
    /// Whether they are still driving the carriage (letting go of Control stops it early).
    private var gliding = false

    init(state: AppState) {
        self.state = state
        typewriter = TypewriterScene(size: CGSize(width: 1280, height: 832), entry: Entry(kind: .diary),
                                     options: state.settings.sceneOptions,
                                     pixelScale: NSScreen.main?.backingScaleFactor ?? 2)
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 832))
        ignoresSiblingOrder = true
        allowsTransparency = false
        preferredFramesPerSecond = 120
        presentScene(typewriter)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appActivity), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivity), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        // Ease off when nothing has happened for a while; the lamp and dust do not need 120 frames a second.
        rateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.updateFrameRate() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        rateTimer?.invalidate()
        restTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appActivity() {
        updateFrameRate()
        if NSApp.isActive {
            // A pointer left lying over the window goes away like one that has stopped moving.
            armRest()
        } else {
            cancelRest()
            endGlide()
        }
    }

    /// The key-up that ends a glide never arrives if the window stops being the key window first.
    @objc private func windowResigned(_ note: Notification) {
        if let window, (note.object as? NSWindow) === window { endGlide() }
    }

    private func updateFrameRate() {
        let rate: Int
        if ProcessInfo.processInfo.environment["LAMPLIGHT_FULLRATE"] == "1" {
            // For measuring frame rate from a test launch that never becomes the active app.
            rate = 120
        } else if !NSApp.isActive {
            rate = 15
        } else if CACurrentMediaTime() - lastInput > 45 {
            rate = 40
        } else {
            rate = 120
        }
        if preferredFramesPerSecond != rate { preferredFramesPerSecond = rate }
    }

    private var lastInput = CACurrentMediaTime()

    private func woke() {
        lastInput = CACurrentMediaTime()
        // Have the sound hardware running before the first key lands.
        state?.sound.wake()
        if preferredFramesPerSecond != 120 && NSApp.isActive { preferredFramesPerSecond = 120 }
    }

    // MARK: - Window

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        typewriter.setPixelScale(window.backingScaleFactor)
        window.makeFirstResponder(self)
        window.acceptsMouseMovedEvents = true
        armRest()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { typewriter.setPixelScale(scale) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: - Pointer

    private func scenePoint(_ event: NSEvent) -> CGPoint {
        convert(convert(event.locationInWindow, from: nil), to: typewriter)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        state?.closePanels()
        woke()
        // Pressing on the carriage takes hold of it; it then follows the pointer along the line.
        if typewriter.grab(at: scenePoint(event)) {
            dragging = true
            NSCursor.closedHand.set()
            armRest()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        pointerMoved(event)
        if dragging { typewriter.drag(to: scenePoint(event).x) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        typewriter.letGo()
        showHand(at: scenePoint(event))
        // Let go outside the view, the pointer has left: no light stays behind.
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            cancelRest()
            typewriter.pointer(at: nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerMoved(event)
        state?.pointerMoved()
    }

    /// The pointer moved, with or without the button down.
    private func pointerMoved(_ event: NSEvent) {
        woke()
        // Over the paper, the pointer carries a little light of its own for reading back.
        let p = scenePoint(event)
        typewriter.pointer(at: p)
        showHand(at: p)
        armRest()
    }

    /// An open hand over the carriage says it can be picked up; a closed one, that it has been.
    private func showHand(at p: CGPoint) {
        if dragging {
            NSCursor.closedHand.set()
            handShown = true
        } else if typewriter.canGrab(at: p) {
            NSCursor.openHand.set()
            handShown = true
        } else if handShown {
            NSCursor.arrow.set()
            handShown = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else { return }
        cancelRest()
        typewriter.pointer(at: nil)
        if handShown {
            NSCursor.arrow.set()
            handShown = false
        }
    }

    /// Starts counting towards the pointer's rest, or starts the count again. One timer serves
    /// however often the pointer moves: when it fires, it waits out whatever is left.
    private func armRest() {
        pointerMovedAt = CACurrentMediaTime()
        if restTimer == nil { scheduleRest(after: TypewriterView.pointerRest) }
    }

    private func scheduleRest(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restTimer = nil
            let left = TypewriterView.pointerRest - (CACurrentMediaTime() - self.pointerMovedAt)
            if left > 0.01 { self.scheduleRest(after: left) } else { self.pointerRested() }
        }
        RunLoop.main.add(timer, forMode: .common)
        restTimer = timer
    }

    private func cancelRest() {
        restTimer?.invalidate()
        restTimer = nil
    }

    private var pointerInside: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// The pointer has not moved for six seconds: it goes away, and its light with it, until it
    /// is moved again. It stays while it is in use — holding the carriage, or on the controls.
    private func pointerRested() {
        if dragging || state?.drawerOpen == true || state?.settingsOpen == true || state?.chromeHover == true {
            pointerLog?("rested, but in use: stays")
            armRest()
            return
        }
        typewriter.pointer(at: nil)
        // Only a pointer that is over this window, while it is the one being typed in, is ours to hide.
        let ours = NSApp.isActive && window?.isKeyWindow == true && pointerInside
        if ours { NSCursor.setHiddenUntilMouseMoves(true) }
        pointerLog?(ours ? "rested: light off, pointer hidden" : "rested: light off (pointer is not over the active window, left alone)")
    }

    override func scrollWheel(with event: NSEvent) {
        woke()
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 30 : event.scrollingDeltaY * 1.2
        typewriter.scroll(rows: delta)
    }

    // MARK: - Keys

    override func keyDown(with event: NSEvent) {
        woke()
        // A key takes the pointer away, and the light it carries with it.
        NSCursor.setHiddenUntilMouseMoves(true)
        cancelRest()
        typewriter.pointer(at: nil)
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if glideKeyDown(event) { return }
        state?.typingStarted()
        // A held key repeats faster than the mechanism can strike; let the extra repeats go
        // rather than queueing them up to keep hammering after the key is released.
        if event.isARepeat && typewriter.pendingCount > 2 { return }
        // Routes through the current input method, which calls back into the methods below.
        interpretKeyEvents([event])
    }

    /// Control-F and Control-J: the carriage runs for as long as the key is held.
    private func glideKeyDown(_ event: NSEvent) -> Bool {
        guard let direction = TypewriterView.glideKeys[event.keyCode] else { return false }
        // While one is down, its own repeats belong to the hold, whatever the modifiers now say.
        if glideDown.contains(event.keyCode) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard flags == TypewriterView.glideModifier, !hasMarkedText() else { return false }
        if event.isARepeat { return true }
        glideDown.append(event.keyCode)
        gliding = true
        state?.typingStarted()
        typewriter.glide(direction)
        return true
    }

    override func keyUp(with event: NSEvent) {
        guard let i = glideDown.firstIndex(of: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        glideDown.remove(at: i)
        if glideDown.isEmpty { gliding = false }
        syncGlide()
    }

    override func flagsChanged(with event: NSEvent) {
        // Letting go of Control stops the glide, even with the letter still down.
        let flags = event.modifierFlags
        if gliding, !flags.contains(TypewriterView.glideModifier) || flags.contains(.command) {
            gliding = false
            syncGlide()
        }
        super.flagsChanged(with: event)
    }

    /// With both keys down, the one pressed last decides the direction.
    private func syncGlide() {
        let direction = gliding ? (glideDown.last.flatMap { TypewriterView.glideKeys[$0] } ?? 0) : 0
        typewriter.glide(direction)
    }

    private func endGlide() {
        glideDown.removeAll()
        gliding = false
        typewriter.glide(0)
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            typewriter.pressReturn()
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)):
            typewriter.pressBackspace()
        case #selector(insertTab(_:)):
            typewriter.pressTab()
        case #selector(moveLeft(_:)):
            typewriter.nudge(dx: -1, dy: 0)
        case #selector(moveRight(_:)):
            typewriter.nudge(dx: 1, dy: 0)
        case #selector(moveUp(_:)):
            typewriter.nudge(dx: 0, dy: -1)
        case #selector(moveDown(_:)):
            typewriter.nudge(dx: 0, dy: 1)
        case #selector(cancelOperation(_:)):
            state?.closePanels()
        default:
            break
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        woke()
        state?.typingStarted()
        typewriter.type(text)
    }

    @objc func copy(_ sender: Any?) {
        state?.copyAll()
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = ""
        typewriter.setComposition("")
        typewriter.type(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        typewriter.setComposition(marked)
    }

    func unmarkText() {
        marked = ""
        typewriter.setComposition("")
    }

    func hasMarkedText() -> Bool { !marked.isEmpty }

    func markedRange() -> NSRange {
        marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (marked as NSString).length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: (marked as NSString).length, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method should put its candidate list: just under the cell being typed.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = typewriter.caretRect
        let origin = convert(r.origin, from: typewriter)
        let inWindow = convert(NSRect(origin: origin, size: r.size), to: nil)
        return window?.convertToScreen(inWindow) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}
