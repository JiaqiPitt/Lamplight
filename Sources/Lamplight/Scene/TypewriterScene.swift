import SpriteKit
import simd

enum Sound: Hashable {
    case key, strike, space, back, tape, bell, feed, tick, lock, lampSwitch, paperIn, paperOut
    /// Carriage return; the index picks one of `Mechanics.carriageDurations`.
    case carriage(Int)
}

protocol SoundPlaying: AnyObject {
    func play(_ sound: Sound, gain: Float, pan: Float)
    /// Seconds from the start of a strike sound to the impact within it.
    var strikeLead: Double { get }
}

enum Mechanics {
    /// How long the carriage takes to fly home, by how far it has to go.
    /// The sounds are synthesised to exactly these lengths.
    static let carriageDurations: [Double] = [0.30, 0.40, 0.50, 0.62]
    static let paperInDuration: Double = 0.5
    static let paperInSteps = 9
    /// Running the carriage along the line while a glide key is held. It sets off at
    /// `glideStart` columns a second, gains `glideGain` a second until it reaches `glideFull`,
    /// and once the key is up brakes evenly, taking at least `glideCoast` seconds, to stop
    /// exactly on a cell. A tap moves it about a word; holding crosses the line in about 0.7 s.
    static let glideStart: CGFloat = 22
    static let glideFull: CGFloat = 100
    static let glideGain: CGFloat = 260
    static let glideCoast: CGFloat = 0.06
    /// Braking when the other glide key is pressed while it is still running.
    static let glideBrake: CGFloat = 1400
    /// Least time between the clicks the carriage makes passing over cells when moved by hand.
    static let passClickGap: Double = 0.04
}

struct SceneOptions: Equatable {
    var lampPower: CGFloat = 1.0
    var ambient: CGFloat = 1.0
    var lightsOn = false
    /// false: the lamp carriage travels along the paper. true: the paper slides under a fixed carriage.
    var paperMoves = false
    /// 0 correction tape, 1 strike out, 2 plain backspace (overtype).
    var backspaceMode = 0
    var autoReturn = true
    var textScale: CGFloat = 1.0
    var latinFont = "CourierNewPSMT"
    var cjkFont = "STFangsong"
    var dust = true
    /// 0 black, 1 red.
    var ribbon: UInt8 = 0
}

/// The whole machine: paper, carriage, lamp and typebars, and the mechanism that turns
/// keystrokes into timed strikes. Everything is driven from `update(_:)`, so the scene
/// behaves identically on screen and in the offscreen test renderer.
final class TypewriterScene: SKScene {

    // MARK: - Public surface

    var options: SceneOptions {
        didSet { if ready { optionsChanged(from: oldValue) } }
    }
    private(set) var entry: Entry
    /// Called whenever the sheet's contents or cursor change.
    var onChange: (() -> Void)?
    weak var sound: SoundPlaying?

    private(set) var L: Layout
    private var glyphs: GlyphCache
    private var liner: LineRenderer
    private var pixelScale: CGFloat
    private var ready = false
    private var staleSince: Double?

    // MARK: - Nodes

    private let backdrop = SKSpriteNode(color: .black, size: CGSize(width: 1, height: 1))
    private let platen = SKSpriteNode(texture: Art.platen())
    private let paperNode = SKNode()
    private let paperSprite = SKSpriteNode(color: .white, size: CGSize(width: 1, height: 1))
    private let edgeL = SKSpriteNode(texture: Art.edgeShadow(flipped: false))
    private let edgeR = SKSpriteNode(texture: Art.edgeShadow(flipped: true))
    private let rowsNode = SKNode()
    private let rail = SKSpriteNode(texture: Art.rail())
    private let deck = SKSpriteNode(color: NSColor(srgbRed: 0.060, green: 0.062, blue: 0.066, alpha: 1), size: CGSize(width: 1, height: 1))
    private let deckEdge = SKSpriteNode(texture: Art.deckEdge())
    private let headNode = SKNode()
    private let housing = SKSpriteNode()
    private let guide = SKSpriteNode()
    private let ribbonBlack = Art.ribbon(red: false)
    private let ribbonRed = Art.ribbon(red: true)
    private let ribbon = SKSpriteNode()
    private let tape = SKSpriteNode(color: NSColor(srgbRed: 0.93, green: 0.92, blue: 0.88, alpha: 1), size: CGSize(width: 1, height: 1))
    private let shadowLayer = SKNode()
    private let barLayer = SKNode()
    private let lightMap = SKSpriteNode(color: .white, size: CGSize(width: 1, height: 1))
    private let slotGlow = SKSpriteNode(texture: Art.slotGlow())
    private let bloom = SKSpriteNode(texture: Art.blob(1.0, 0.80, 0.52, sharpness: 3.2))
    private let jewel = SKSpriteNode(texture: Art.blob(1.0, 0.60, 0.16, sharpness: 5.0))
    private let display = SKSpriteNode()
    private let ghost = SKSpriteNode()
    private let dustLayer = SKNode()

    private let armTexture = Art.arm()
    private let armShadowTexture = Art.armShadow()
    private let shadowBlob = Art.blob(0, 0, 0, sharpness: 2.6)
    private let moteTexture = Art.blob(1.0, 0.93, 0.80, sharpness: 4.0)
    private var slugNarrow: (texture: SKTexture, size: CGSize)
    private var slugWide: (texture: SKTexture, size: CGSize)
    private var housingSize = CGSize.zero

    // MARK: - Shader uniforms

    private let uPaperOrg = SKUniform(name: "u_org", vectorFloat2: vector_float2(0, 0))
    private let uPaperSize = SKUniform(name: "u_size", vectorFloat2: vector_float2(1, 1))
    private let uPaperZoom = SKUniform(name: "u_zoom", float: 1)
    private let uPaperEdge = SKUniform(name: "u_edge", vectorFloat2: vector_float2(0, 1))
    private let uPaperTop = SKUniform(name: "u_top", float: 0)
    private let uPaperTint = SKUniform(name: "u_tint", vectorFloat3: vector_float3(0.962, 0.945, 0.900))
    private let uBackSize = SKUniform(name: "u_size", vectorFloat2: vector_float2(1, 1))
    private let uBackZoom = SKUniform(name: "u_zoom", float: 1)
    private let uLightSize = SKUniform(name: "u_size", vectorFloat2: vector_float2(1, 1))
    private let uLamp = SKUniform(name: "u_lamp", vectorFloat2: vector_float2(0, 0))
    private let uH = SKUniform(name: "u_h", float: 110)
    private let uTilt = SKUniform(name: "u_tilt", float: Float(TypewriterScene.lampTilt))
    private let uCone = SKUniform(name: "u_cone", vectorFloat2: vector_float2(Float(TypewriterScene.coneOuter), Float(TypewriterScene.coneInner)))
    private let uPower = SKUniform(name: "u_power", float: 6)
    private let uTorch = SKUniform(name: "u_torch", vectorFloat4: vector_float4(0, 0, 0, 100))
    private let uAmbient = SKUniform(name: "u_ambient", float: 1)
    private let uRoom = SKUniform(name: "u_room", float: 0)
    private let uPx = SKUniform(name: "u_px", float: 2)
    private let uT = SKUniform(name: "u_t", float: 0)

    // MARK: - Motion state

    private var now: Double = 0
    private var lastUpdate: Double = 0
    private var rng = SplitMix(20261117)
    private(set) var lastActivity: Double = 0

    private var headCol: CGFloat = 0
    private var headVel: CGFloat = 0
    private var headTarget: CGFloat = 0
    private var returnAnim: (start: Double, dur: Double, from: CGFloat)?
    private var rowF: CGFloat = 0
    private var rowTarget: CGFloat = 0
    private var scrollRows: CGFloat = 0
    private var scrollTarget: CGFloat = 0
    private var lastScrollTick = 0
    private var feedOffset: CGFloat = 0
    private var feedAnim: (start: Double, dur: Double, from: CGFloat, to: CGFloat, steps: Int)?
    private var modeMix: CGFloat = 0
    private var shake = CGPoint.zero
    private var shakeVel = CGPoint.zero
    private var headDip: CGFloat = 0
    private var headDipVel: CGFloat = 0
    private var roomMix: CGFloat = 0
    private var lampMix: CGFloat = 0
    private var lampOn = true
    private var torchPos = CGPoint.zero
    private var torchPower: CGFloat = 0
    private var torchTarget: CGFloat = 0
    private var jewelPulse: CGFloat = 0
    private var tapeStart: Double = -10
    private var composition = ""
    private var shownGhost = ""
    private var indicatorText = ""
    private var shownIndicator: String?
    private var indicatorStart: Double = -100
    private var indicatorPending = false
    private var headX: CGFloat = 0
    private var lampPos = CGPoint.zero
    private var lampPowerNow: CGFloat = 0
    private var hasSheet = false
    private var pendingLoad: (entry: Entry, animated: Bool, header: String)?

    // MARK: - The carriage in the hand

    /// Where the pointer is while it holds the carriage, in scene coordinates; nil once it lets go.
    private var holdX: CGFloat?
    /// Where the hold took effect: the pointer's position then, and the column the carriage was at.
    private var holdBase: (x: CGFloat, col: CGFloat)?
    /// -1 or 1 while a glide key is held, 0 otherwise.
    private var glideDir: CGFloat = 0
    /// Columns per second, signed, at which a glide is carrying `headTarget` along.
    private var glideVel: CGFloat = 0
    /// Set once the glide key is up: the cell to stop on and the braking that ends exactly there.
    private var coast: (stop: CGFloat, braking: CGFloat)?
    /// True while the carriage is off its cells, following the pointer or a glide key.
    private var floating = false
    private var lastCell = 0
    private var lastPassClick: Double = -1

    // MARK: - Mechanism state

    private enum Op {
        case type(String)
        case space
        case backspace
        case newline
        case tab
        case move(Int, Int)
    }
    private enum Wrap { case none, full, space }
    private struct Event {
        let t: Double
        let run: () -> Void
    }
    private final class Flight {
        let start: Double
        let impact: Double
        let theta: CGFloat
        let wide: Bool
        var baseSize = CGSize.zero
        let arm = SKSpriteNode()
        let slug = SKSpriteNode()
        let slugShadow = SKSpriteNode()
        let armShadow = SKSpriteNode()
        init(start: Double, impact: Double, theta: CGFloat, wide: Bool) {
            self.start = start; self.impact = impact; self.theta = theta; self.wide = wide
        }
        func remove() {
            arm.removeFromParent(); slug.removeFromParent()
            slugShadow.removeFromParent(); armShadow.removeFromParent()
        }
    }
    private struct Mote {
        var p: CGPoint
        var v: CGVector
        var age: CGFloat
        var life: CGFloat
        var size: CGFloat
        var phase: CGFloat
        let node: SKSpriteNode
    }

    private var ops: [Op] = []
    private var opHead = 0
    private var nextOpAt: Double = 0
    /// When the mechanism is next free: no slug in the air, carriage at rest.
    private var lastMech: Double = 0
    private var events: [Event] = []
    private var flights: [Flight] = []
    private var motes: [Mote] = []
    private var rowNodes: [Int: SKSpriteNode] = [:]
    private var emptyRows = Set<Int>()
    private var dirtyRows = Set<Int>()
    /// What is left of a character after the correction tape has lifted it: a faint trace
    /// that fades to nothing, so a corrected page ends up clean.
    private struct Trace {
        let node: SKSpriteNode
        let start: Double
        let base: CGFloat
    }
    private var traces: [Trace] = []
    /// Seconds a lifted character takes to disappear completely.
    private static let traceFade: Double = 10

    private static let lampHeight: CGFloat = 140
    private static let lampBase: CGFloat = 5.5
    private static let lampTilt: CGFloat = 0.50
    private static let coneOuter: CGFloat = 0.12
    private static let coneInner: CGFloat = 0.84
    private static let holdTime: Double = 0.016
    private static let fallTime: Double = 0.085

    // MARK: - Setup

    init(size: CGSize, entry: Entry, options: SceneOptions, pixelScale: CGFloat) {
        self.options = options
        self.entry = entry
        self.pixelScale = pixelScale
        let layout = Layout(size: size, textScale: options.textScale, pixelScale: pixelScale)
        L = layout
        let cache = GlyphCache(layout: layout, latinFont: options.latinFont, cjkFont: options.cjkFont)
        glyphs = cache
        liner = LineRenderer(layout: layout, glyphs: cache)
        slugNarrow = Art.slug(z: layout.zoom, wide: false, ps: layout.ps)
        slugWide = Art.slug(z: layout.zoom, wide: true, ps: layout.ps)
        super.init(size: size)
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = .black
        build()
        applyArt()
        applyLayout()
        self.entry.ensureRow(self.entry.cursorRow)
        resetMechanics()
        hasSheet = false
        ready = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        backdrop.anchorPoint = .zero
        backdrop.zPosition = 0
        let backShader = SKShader(source: Shaders.backdrop)
        backShader.uniforms = [uBackSize, uBackZoom]
        backdrop.shader = backShader
        addChild(backdrop)

        platen.anchorPoint = .zero
        platen.zPosition = 5
        addChild(platen)

        paperNode.zPosition = 20
        addChild(paperNode)
        paperSprite.anchorPoint = .zero
        let paperShader = SKShader(source: Shaders.paper)
        paperShader.uniforms = [uPaperOrg, uPaperSize, uPaperZoom, uPaperEdge, uPaperTop, uPaperTint]
        paperSprite.shader = paperShader
        paperNode.addChild(paperSprite)
        edgeL.anchorPoint = CGPoint(x: 1, y: 0)
        edgeL.zPosition = -1
        paperNode.addChild(edgeL)
        edgeR.anchorPoint = .zero
        edgeR.zPosition = -1
        paperNode.addChild(edgeR)
        rowsNode.zPosition = 1
        paperNode.addChild(rowsNode)
        ghost.anchorPoint = .zero
        ghost.zPosition = 2
        ghost.isHidden = true
        paperNode.addChild(ghost)

        rail.anchorPoint = CGPoint(x: 0, y: 0.5)
        rail.zPosition = 40
        addChild(rail)
        deck.anchorPoint = .zero
        deck.zPosition = 45
        addChild(deck)
        deckEdge.anchorPoint = CGPoint(x: 0, y: 1)
        deckEdge.zPosition = 46
        addChild(deckEdge)

        addChild(headNode)
        shadowLayer.zPosition = 30
        headNode.addChild(shadowLayer)
        ribbon.zPosition = 32
        headNode.addChild(ribbon)
        tape.zPosition = 32.5
        tape.isHidden = true
        headNode.addChild(tape)
        guide.anchorPoint = CGPoint(x: 0.5, y: 0)
        guide.zPosition = 33
        headNode.addChild(guide)
        housing.zPosition = 50
        headNode.addChild(housing)
        barLayer.zPosition = 55
        headNode.addChild(barLayer)

        lightMap.anchorPoint = .zero
        lightMap.zPosition = 100
        lightMap.blendMode = .multiply
        let lightShader = SKShader(source: Shaders.light)
        lightShader.uniforms = [uLightSize, uLamp, uH, uTilt, uCone, uPower, uTorch, uAmbient, uRoom, uPx, uT]
        lightMap.shader = lightShader
        addChild(lightMap)

        dustLayer.zPosition = 105
        addChild(dustLayer)

        // Things that glow by themselves sit above the light map.
        bloom.zPosition = 109
        bloom.blendMode = .add
        headNode.addChild(bloom)
        slotGlow.zPosition = 110
        slotGlow.blendMode = .add
        headNode.addChild(slotGlow)
        jewel.zPosition = 111
        jewel.blendMode = .add
        headNode.addChild(jewel)
        display.zPosition = 112
        display.blendMode = .add
        headNode.addChild(display)

        for _ in 0..<56 {
            let node = SKSpriteNode(texture: moteTexture)
            node.blendMode = .add
            node.alpha = 0
            dustLayer.addChild(node)
            var m = Mote(p: .zero, v: .zero, age: 0, life: 1, size: 1, phase: 0, node: node)
            respawn(&m, scatterAge: true)
            motes.append(m)
        }
    }

    /// Textures whose detail depends on the zoom level.
    private func applyArt() {
        let z = L.zoom
        let h = Art.housing(z: z, ps: L.ps)
        housing.texture = h.texture
        housingSize = h.size
        let g = Art.guide(z: z, cellW: L.cellW, ps: L.ps)
        guide.texture = g.texture
        guide.size = g.size
        slugNarrow = Art.slug(z: z, wide: false, ps: L.ps)
        slugWide = Art.slug(z: z, wide: true, ps: L.ps)
        shownIndicator = nil
        shownGhost = ""
    }

    private func applyLayout() {
        let z = L.zoom
        let w = L.size.width, h = L.size.height
        backdrop.size = L.size
        uBackSize.vectorFloat2Value = vector_float2(Float(w), Float(h))
        uBackZoom.floatValue = Float(z)
        platen.position = CGPoint(x: 0, y: L.deckTop)
        platen.size = CGSize(width: w, height: L.lineY + 58 * z - L.deckTop)
        rail.position = CGPoint(x: -20, y: L.railY)
        rail.size = CGSize(width: w + 40, height: 9 * z)
        deck.size = CGSize(width: w, height: L.deckTop)
        deckEdge.position = CGPoint(x: 0, y: L.deckTop)
        deckEdge.size = CGSize(width: w, height: 7 * z)
        lightMap.size = L.size
        uLightSize.vectorFloat2Value = vector_float2(Float(w), Float(h))
        uPx.floatValue = Float(L.ps)
        uPaperZoom.floatValue = Float(z)
        uPaperEdge.vectorFloat2Value = vector_float2(Float(-L.marginX), Float(L.textW + L.marginX))

        let top = L.housingTop - L.lineY
        housing.size = housingSize.width > 0 ? CGSize(width: 176 * z, height: 54 * z) : .zero
        housing.position = CGPoint(x: 0, y: top - 27 * z)
        guide.size = CGSize(width: L.cellW + 9 * z, height: 31 * z)
        guide.position = CGPoint(x: 0, y: top - z)
        ribbon.size = CGSize(width: 46 * z, height: 17 * z)
        tape.size = CGSize(width: 30 * z, height: 18 * z)
        slotGlow.size = CGSize(width: 150 * z, height: 50 * z)
        slotGlow.position = CGPoint(x: 0, y: top + 3 * z)
        bloom.size = CGSize(width: 460 * z, height: 460 * z)
        bloom.position = CGPoint(x: 0, y: top + 40 * z)
        jewel.size = CGSize(width: 30 * z, height: 30 * z)
        jewel.position = CGPoint(x: -62 * z, y: top - 32 * z)
        display.size = CGSize(width: 54 * z, height: 26 * z)
        display.position = CGPoint(x: 52 * z, y: top - 31 * z)

        for (r, node) in rowNodes {
            node.size = L.rowSize
            node.position = rowPosition(r)
        }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard ready, size.width > 50, size.height > 50, size != L.size else { return }
        L = Layout(size: size, textScale: options.textScale, pixelScale: pixelScale)
        applyLayout()
        staleSince = now
    }

    func setPixelScale(_ scale: CGFloat) {
        guard scale > 0, scale != pixelScale else { return }
        pixelScale = scale
        L = Layout(size: size, textScale: options.textScale, pixelScale: pixelScale)
        applyLayout()
        rerasterize()
    }

    private func optionsChanged(from old: SceneOptions) {
        if old.textScale != options.textScale || old.latinFont != options.latinFont || old.cjkFont != options.cjkFont {
            L = Layout(size: size, textScale: options.textScale, pixelScale: pixelScale)
            applyLayout()
            rerasterize()
        }
        lastActivity = now
    }

    /// Rebuilds every bitmap for the current zoom: glyphs, rows of ink and machine parts.
    private func rerasterize() {
        glyphs = GlyphCache(layout: L, latinFont: options.latinFont, cjkFont: options.cjkFont)
        liner = LineRenderer(layout: L, glyphs: glyphs)
        applyArt()
        applyLayout()
        for (_, node) in rowNodes { node.removeFromParent() }
        rowNodes.removeAll()
        emptyRows.removeAll()
        clearTraces()
    }

    private func resetMechanics() {
        headCol = CGFloat(entry.cursorCol)
        headTarget = headCol
        headVel = 0
        returnAnim = nil
        rowF = CGFloat(entry.cursorRow)
        rowTarget = rowF
        scrollRows = 0
        scrollTarget = 0
        for (_, node) in rowNodes { node.removeFromParent() }
        rowNodes.removeAll()
        emptyRows.removeAll()
        dirtyRows.removeAll()
        clearTraces()
    }

    private func clearTraces() {
        for t in traces { t.node.removeFromParent() }
        traces.removeAll()
    }

    /// Leaves the fading trace of a character the tape has just lifted.
    private func leaveTrace(of st: Strike, row: Int) {
        let placed = liner.placement(of: st)
        let node = SKSpriteNode(texture: SKTexture(cgImage: placed.glyph.image))
        node.size = CGSize(width: CGFloat(placed.glyph.width) / L.ps, height: CGFloat(placed.glyph.height) / L.ps)
        let origin = rowPosition(row)
        node.position = CGPoint(x: origin.x + placed.centre.x / L.ps, y: origin.y + placed.centre.y / L.ps)
        node.zRotation = placed.rotation
        // Above the paper, below the rows of ink: anything typed over it stays on top.
        node.zPosition = 0.5
        let base = placed.alpha * 0.11
        node.alpha = base
        paperNode.addChild(node)
        traces.append(Trace(node: node, start: now, base: base))
    }

    private func stepTraces() {
        guard !traces.isEmpty else { return }
        traces.removeAll { t in
            let u = CGFloat((now - t.start) / TypewriterScene.traceFade)
            if u >= 1 {
                t.node.removeFromParent()
                return true
            }
            // Quick at first, then lingering: most of it is gone within a few seconds.
            t.node.alpha = t.base * (1 - u) * (1 - u)
            return false
        }
    }

    // MARK: - Input

    /// Types text as if the keys were pressed in order.
    func type(_ text: String) {
        for ch in text {
            if ch == "\n" || ch == "\r" || ch == "\r\n" {
                ops.append(.newline)
            } else if ch == "\t" {
                ops.append(.tab)
            } else if ch == " " {
                ops.append(.space)
            } else if ch == "\u{3000}" {
                ops.append(.space)
                ops.append(.space)
            } else if let u = ch.unicodeScalars.first,
                      u.value < 0x20 || u.value == 0x7F || (0xF700...0xF8FF).contains(u.value) {
                continue
            } else {
                ops.append(.type(String(ch)))
            }
        }
        lastActivity = now
    }

    func pressReturn() { ops.append(.newline); lastActivity = now }
    func pressBackspace() { ops.append(.backspace); lastActivity = now }
    func pressTab() { ops.append(.tab); lastActivity = now }
    func nudge(dx: Int, dy: Int) { ops.append(.move(dx, dy)); lastActivity = now }

    /// Drops whatever has been queued but not yet typed (a long paste, say).
    func cancelPending() {
        ops.removeAll()
        opHead = 0
    }

    var pendingCount: Int { ops.count - opHead }

    /// Text an input method is still composing; shown in the carriage window.
    func setComposition(_ text: String) {
        // While an input method is still composing, nothing is struck yet. Give each keystroke
        // a small click of its own so that typing is never silent.
        if text.count > composition.count { play(.tick, 0.6) }
        composition = text
        lastActivity = now
    }

    /// Rolls the paper to look at earlier lines. It springs back when typing resumes.
    func scroll(rows: CGFloat) {
        let lo = -CGFloat(max(0, entry.rows.count - 1 - entry.cursorRow))
        let hi = CGFloat(entry.cursorRow) + 2
        scrollTarget = max(lo, min(hi, scrollTarget + rows))
        lastActivity = now
    }

    /// Where the pointer is, in scene coordinates; nil when it should stop lighting the page.
    func pointer(at p: CGPoint?) {
        if let p, p.y > L.deckTop {
            torchPos = p
            torchTarget = 1
        } else {
            torchTarget = 0
        }
        lastActivity = now
    }

    func setLamp(on: Bool) {
        lampOn = on
        lastActivity = now
    }

    // MARK: - Moving the carriage by hand

    /// The middle of the carriage, in scene coordinates: where a hand takes hold of it.
    var carriageHandle: CGPoint {
        CGPoint(x: headX, y: L.housingTop - 27 * L.zoom)
    }

    /// Whether pressing at `p` takes hold of the carriage. When it is the paper that travels,
    /// the paper can be held too, along the line being typed.
    func canGrab(at p: CGPoint) -> Bool {
        guard hasSheet, pendingLoad == nil, feedAnim == nil else { return false }
        let z = L.zoom
        let dx = abs(p.x - headX)
        // The housing with a little room around it, and the type guide standing on top of it.
        if dx <= 98 * z, p.y >= L.housingTop - 62 * z, p.y <= L.housingTop + 8 * z { return true }
        if dx <= L.cellW / 2 + 14 * z, p.y > L.housingTop, p.y <= L.housingTop + 36 * z { return true }
        if options.paperMoves {
            let left = paperNode.position.x - L.marginX
            return p.x >= left && p.x <= left + L.paperW && p.y >= L.deckTop && p.y <= L.lineY + L.lineH
        }
        return false
    }

    /// The pointer pressed down at `p`. Returns whether it took hold of the carriage; if it did,
    /// follow with `drag(to:)` as the pointer moves and `letGo()` when the button comes up.
    func grab(at p: CGPoint) -> Bool {
        guard canGrab(at: p) else { return false }
        holdX = p.x
        // Measured from where the button went down, unless the carriage is still busy; then
        // from wherever the pointer has got to by the time the carriage can be moved.
        holdBase = atRest ? (p.x, headTarget) : nil
        lastActivity = now
        return true
    }

    func drag(to x: CGFloat) {
        // Ignored once a struck key has taken the carriage out of the hand.
        guard holdX != nil else { return }
        holdX = x
        lastActivity = now
    }

    func letGo() {
        holdX = nil
        lastActivity = now
    }

    /// Runs the carriage along the line for as long as a key is held: -1 left, 1 right, 0 to stop.
    func glide(_ direction: Int) {
        let d: CGFloat = direction < 0 ? -1 : (direction > 0 ? 1 : 0)
        guard d != glideDir else { return }
        glideDir = d
        lastActivity = now
    }

    /// True while the carriage is being moved by hand rather than by the mechanism.
    var isFloating: Bool { floating }

    /// Replaces the sheet in the machine. With `animated`, the old one rolls out and the new one feeds in.
    func load(_ e: Entry, animated: Bool, header: String = "") {
        pendingLoad = (e, animated, header)
        ops.removeAll()
        opHead = 0
        lastActivity = now
    }

    func updateEntry(_ change: (inout Entry) -> Void) {
        change(&entry)
    }

    /// The cell about to be typed, in scene coordinates. Input methods anchor their candidates here.
    var caretRect: CGRect {
        CGRect(x: headX - L.cellW / 2, y: L.deckTop - 6, width: L.cellW, height: L.lineY + L.lineH - L.deckTop)
    }

    var isSettled: Bool {
        flights.isEmpty && events.isEmpty && pendingCount == 0 && pendingLoad == nil
            && returnAnim == nil && feedAnim == nil && !floating
    }

    // MARK: - Frame

    /// Developer aid: time spent inside `update` since the last `resetProfile()`.
    private(set) var profileTime: Double = 0
    private(set) var profileFrames = 0
    private(set) var profileWorst: Double = 0
    private var profileStart: Double = 0

    func resetProfile() {
        profileTime = 0
        profileFrames = 0
        profileWorst = 0
        profileStart = CACurrentMediaTime()
    }

    /// Whether `update` has ever been called off the main thread. Everything here assumes it is not.
    private(set) var updatedOffMain = false

    var profileSummary: String {
        let wall = max(0.001, CACurrentMediaTime() - profileStart)
        let avg = profileFrames > 0 ? profileTime / Double(profileFrames) * 1000 : 0
        return String(format: "frames %d  %.1f fps  update avg %.3f ms  worst %.3f ms  %@", profileFrames, Double(profileFrames) / wall, avg, profileWorst * 1000,
                      updatedOffMain ? "UPDATE RAN OFF THE MAIN THREAD" : "main thread only")
    }

    override func update(_ currentTime: TimeInterval) {
        guard ready else { return }
        if !Thread.isMainThread { updatedOffMain = true }
        let profileT0 = CACurrentMediaTime()
        defer {
            let spent = CACurrentMediaTime() - profileT0
            profileTime += spent
            profileFrames += 1
            profileWorst = max(profileWorst, spent)
        }
        let first = lastUpdate == 0
        let dt = first ? 0 : CGFloat(min(max(currentTime - lastUpdate, 0), 0.05))
        lastUpdate = currentTime
        now = currentTime
        if first {
            lastActivity = now
            lastMech = now
            nextOpAt = now
        }
        if let s = staleSince, now - s > 0.18 {
            staleSince = nil
            rerasterize()
        }
        if let p = pendingLoad {
            pendingLoad = nil
            performLoad(p.entry, animated: p.animated, header: p.header)
        }
        runEvents()
        runOps()
        runEvents()
        stepHand(dt)
        stepMotion(dt)
        passCells()
        place()
        stepFlights()
        stepDust(dt)
        stepTraces()
        refreshRows()
        pushUniforms()
        refreshDisplay()
    }

    private func at(_ t: Double, _ run: @escaping () -> Void) {
        var i = events.count
        while i > 0 && events[i - 1].t > t { i -= 1 }
        events.insert(Event(t: t, run: run), at: i)
    }

    private func runEvents() {
        while let e = events.first, e.t <= now {
            events.removeFirst()
            e.run()
        }
    }

    private func play(_ s: Sound, _ gain: Float = 1, pan: Float = 0) {
        sound?.play(s, gain: gain, pan: pan)
    }

    private func changed(touch: Bool = true) {
        if touch { entry.updatedAt = Date() }
        onChange?()
    }

    // MARK: - Mechanism

    private func runOps() {
        if opHead < ops.count, floating {
            // A key struck takes the carriage out of the hand, wherever it has got to.
            // (A hand that is still waiting for the mechanism to finish goes on waiting.)
            holdX = nil
            glideDir = 0
            dropIntoCell()
        }
        while opHead < ops.count && now >= nextOpAt {
            let op = ops[opHead]
            opHead += 1
            scrollTarget = 0
            torchTarget = 0
            let backlog = ops.count - opHead
            switch op {
            case .type(let c): planStrike(c, backlog: backlog)
            case .space: planSpace(backlog: backlog)
            case .backspace: planBackspace()
            case .newline: nextOpAt = planReturn(at: max(now, lastMech + 0.02), wrap: .none)
            case .tab: planTab()
            case .move(let dx, let dy): planMove(dx, dy)
            }
            lastActivity = now
        }
        if opHead > 0 && opHead == ops.count {
            ops.removeAll(keepingCapacity: true)
            opHead = 0
        }
    }

    /// How fast queued text is typed out. A phrase committed by an input method goes at about
    /// thirteen strikes a second, slow enough for each one to be heard; a long paste hurries.
    private func burstGap(_ backlog: Int) -> Double {
        if backlog > 160 { return 0.010 }
        if backlog > 40 { return 0.026 }
        return 0.075
    }

    private func nextPressure() -> UInt8 {
        let r = rng.unit()
        if r < 0.07 { return UInt8(118 + rng.unit() * 44) }
        if r > 0.95 { return 255 }
        return UInt8(198 + rng.unit() * 50)
    }

    private func planStrike(_ c: String, backlog: Int) {
        let w = Grid.width(of: c)
        var t0 = now

        // After striking words out, carry on past them rather than typing over the wreckage.
        if options.backspaceMode == 1, entry.cursorRow < entry.rows.count {
            var moved = false
            var searching = true
            while searching {
                searching = false
                for st in entry.rows[entry.cursorRow] where st.d == 1 && st.x == entry.cursorCol {
                    entry.cursorCol += st.width
                    searching = true
                    moved = true
                    break
                }
            }
            if moved {
                let col = entry.cursorCol
                let tm = max(now, lastMech)
                at(tm) { [weak self] in self?.headTarget = CGFloat(col) }
                t0 = tm + 0.05
            }
        }

        let limit = Grid.cols + (Grid.closers.contains(c) ? 2 : 0)
        if entry.cursorCol + w > limit {
            if options.autoReturn {
                t0 = planReturn(at: max(t0, lastMech + 0.02), wrap: .full)
            } else {
                at(now) { [weak self] in self?.play(.lock) }
                nextOpAt = now + 0.07
                return
            }
        }

        let swing: Double = backlog > 3 ? 0.040 : 0.050
        let impact = max(t0 + swing, lastMech + 0.012)
        lastMech = impact

        entry.ensureRow(entry.cursorRow)
        let row = entry.cursorRow
        let col = entry.cursorCol
        var st = Strike(c: c, x: col, k: options.ribbon, p: nextPressure(), s: UInt16(truncatingIfNeeded: rng.next()))
        st.land = impact
        entry.rows[row].append(st)
        let index = entry.rows[row].count - 1
        entry.cursorCol = col + w
        let after = entry.cursorCol
        changed()

        let pos = KeyMap.position(of: c)
        launchFlight(theta: pos * 0.64, wide: w == 2, start: impact - swing, impact: impact)
        let pan = Float(pos) * 0.32
        let ring = col < Grid.bellCol && after >= Grid.bellCol
        // A recorded strike begins with the key travelling down; start it early so that the
        // impact inside the recording coincides with the slug reaching the paper.
        let lead = min(sound?.strikeLead ?? 0, swing)
        let strikeGain = 0.82 + Float(rng.unit()) * 0.18
        at(impact - swing) { [weak self] in self?.play(.key, 0.5, pan: pan) }
        at(impact - lead) { [weak self] in self?.play(.strike, strikeGain, pan: pan) }
        at(impact) { [weak self] in
            guard let self else { return }
            if row < self.entry.rows.count, index < self.entry.rows[row].count {
                self.entry.rows[row][index].land = 0
            }
            self.dirtyRows.insert(row)
            self.headTarget = CGFloat(after)
            self.kick(w == 2 ? 1.2 : 1.0)
            if ring { self.ringBell() }
        }
        nextOpAt = max(t0, now) + (backlog > 0 ? burstGap(backlog) : 0.016)
    }

    private func ringBell() {
        at(now + 0.035) { [weak self] in
            guard let self else { return }
            self.play(.bell, 0.9)
            self.jewelPulse = 1.6
        }
    }

    private func planSpace(backlog: Int) {
        let col = entry.cursorCol
        let rowHasInk = entry.endCol(ofRow: entry.cursorRow) > 0
        if col >= Grid.cols || (options.autoReturn && rowHasInk && col >= Grid.cols - 7) {
            if options.autoReturn {
                nextOpAt = planReturn(at: max(now, lastMech + 0.02), wrap: .space)
            } else {
                at(now) { [weak self] in self?.play(.lock) }
                nextOpAt = now + 0.07
            }
            return
        }
        let t0 = max(now, lastMech)
        entry.cursorCol = col + 1
        let after = entry.cursorCol
        changed()
        let ring = col < Grid.bellCol && after >= Grid.bellCol
        at(t0) { [weak self] in
            guard let self else { return }
            self.headTarget = CGFloat(after)
            self.play(.space, 0.8)
            self.headDipVel -= 60 * self.L.zoom
            if ring { self.ringBell() }
        }
        lastMech = t0 + 0.012
        nextOpAt = t0 + (backlog > 0 ? burstGap(backlog) : 0.016)
    }

    /// Carriage return and line feed. Returns the time at which typing may resume.
    private func planReturn(at t0: Double, wrap: Wrap) -> Double {
        let row = entry.cursorRow
        entry.soft.remove(row)
        entry.softSpace.remove(row)
        switch wrap {
        case .full: entry.soft.insert(row)
        case .space: entry.softSpace.insert(row)
        case .none: break
        }
        let dist = entry.cursorCol
        entry.cursorRow = row + 1
        entry.cursorCol = 0
        entry.ensureRow(entry.cursorRow)
        changed()

        let newRow = entry.cursorRow
        let cls = min(Mechanics.carriageDurations.count - 1, dist / 16)
        let dur = dist < 1 ? 0.085 : Mechanics.carriageDurations[cls]
        at(t0) { [weak self] in
            guard let self else { return }
            self.rowTarget = CGFloat(newRow)
            self.headTarget = 0
            if dist >= 1 {
                self.returnAnim = (t0, dur, self.headCol)
                self.play(.carriage(cls), 0.9)
            } else {
                self.play(.feed, 0.8)
            }
        }
        if dist >= 1 {
            at(t0 + dur) { [weak self] in
                guard let self else { return }
                self.shakeVel.x -= 330 * self.L.zoom
                self.headDipVel -= 150 * self.L.zoom
            }
        }
        lastMech = t0 + dur
        return t0 + dur + 0.03
    }

    private func planBackspace() {
        let t0 = max(now, lastMech + 0.015)
        let row = entry.cursorRow
        let col = entry.cursorCol

        if col == 0 {
            // At the left margin: roll back to the end of the line above.
            guard row > 0 else { nextOpAt = now + 0.03; return }
            let prev = row - 1
            let end = min(entry.endCol(ofRow: prev), Grid.cols)
            entry.cursorRow = prev
            entry.cursorCol = end
            changed(touch: false)
            at(t0) { [weak self] in
                guard let self else { return }
                self.rowTarget = CGFloat(prev)
                self.headTarget = CGFloat(end)
                self.play(.feed, 0.7)
            }
            lastMech = t0 + 0.14
            nextOpAt = t0 + 0.16
            return
        }

        var target = col - 1
        if row < entry.rows.count {
            for st in entry.rows[row] where st.d != 2 && st.x + st.width == col { target = st.x }
        }
        entry.cursorCol = target

        let mode = options.backspaceMode
        var hit = false
        var lifted: [Strike] = []
        if mode != 2, row < entry.rows.count {
            for i in entry.rows[row].indices {
                let st = entry.rows[row][i]
                guard st.x < col, st.x + st.width > target else { continue }
                if mode == 0, st.d != 2 {
                    if st.d == 0 { lifted.append(st) }
                    entry.rows[row][i].d = 2
                    hit = true
                } else if mode == 1, st.d == 0 {
                    entry.rows[row][i].d = 1
                    hit = true
                }
            }
        }
        changed(touch: hit)

        at(t0) { [weak self] in
            guard let self else { return }
            self.headTarget = CGFloat(target)
            self.play(.back, 0.8)
        }
        guard hit else {
            lastMech = t0 + 0.03
            nextOpAt = t0 + 0.04
            return
        }
        if mode == 0 {
            // Correction tape flicks up and lifts the ink away.
            at(t0 + 0.02) { [weak self] in self?.tapeStart = t0 + 0.02 }
            at(t0 + 0.05) { [weak self] in
                guard let self else { return }
                self.dirtyRows.insert(row)
                for st in lifted { self.leaveTrace(of: st, row: row) }
                self.play(.tape, 0.8)
                self.kick(0.35)
            }
            lastMech = t0 + 0.085
            nextOpAt = t0 + 0.095
        } else {
            // A hyphen comes down over the mistake.
            let impact = t0 + 0.075
            launchFlight(theta: KeyMap.position(of: "-") * 0.64, wide: col - target >= 2, start: t0 + 0.03, impact: impact)
            at(impact - min(sound?.strikeLead ?? 0, 0.045)) { [weak self] in self?.play(.strike, 0.85) }
            at(impact) { [weak self] in
                guard let self else { return }
                self.dirtyRows.insert(row)
                self.kick(1.0)
            }
            lastMech = impact
            nextOpAt = impact + 0.02
        }
    }

    private func planTab() {
        let t0 = max(now, lastMech)
        let next = min(Grid.cols, (entry.cursorCol / Grid.tab + 1) * Grid.tab)
        guard next != entry.cursorCol else { nextOpAt = now + 0.02; return }
        entry.cursorCol = next
        changed(touch: false)
        at(t0) { [weak self] in
            guard let self else { return }
            self.headTarget = CGFloat(next)
            self.play(.space, 0.9)
        }
        lastMech = t0 + 0.05
        nextOpAt = t0 + 0.06
    }

    private func planMove(_ dx: Int, _ dy: Int) {
        let t0 = max(now, lastMech)
        let col = max(0, min(Grid.cols, entry.cursorCol + dx))
        let row = max(0, min(entry.lastInkedRow + 1, entry.cursorRow + dy))
        guard col != entry.cursorCol || row != entry.cursorRow else { nextOpAt = now + 0.02; return }
        entry.cursorCol = col
        entry.cursorRow = row
        entry.ensureRow(row)
        changed(touch: false)
        at(t0) { [weak self] in
            guard let self else { return }
            self.headTarget = CGFloat(col)
            self.rowTarget = CGFloat(row)
            self.play(dy != 0 ? .feed : .tick, 0.55)
        }
        lastMech = t0 + 0.02
        nextOpAt = t0 + 0.03
    }

    /// The jolt the machine gives when a slug lands.
    private func kick(_ strength: CGFloat) {
        let z = L.zoom
        shakeVel.x += rng.signed() * 70 * z * strength
        shakeVel.y += (150 + rng.unit() * 50) * z * strength
        headDipVel -= 190 * z * strength
    }

    private func performLoad(_ e: Entry, animated: Bool, header: String) {
        events.removeAll()
        for f in flights { f.remove() }
        flights.removeAll()
        returnAnim = nil
        ops.removeAll()
        opHead = 0
        composition = ""
        holdX = nil
        holdBase = nil
        glideDir = 0
        glideVel = 0
        coast = nil
        floating = false

        let swap: () -> Void = { [weak self] in
            guard let self else { return }
            self.entry = e
            self.entry.ensureRow(self.entry.cursorRow)
            self.resetMechanics()
        }

        guard animated else {
            swap()
            feedOffset = 0
            feedAnim = nil
            hasSheet = true
            nextOpAt = now
            lastMech = now
            if !header.isEmpty { type(header) }
            return
        }

        var t = now
        if hasSheet {
            feedAnim = (t, 0.34, feedOffset, L.size.height * 1.1, 0)
            play(.paperOut, 0.9)
            t += 0.36
        }
        at(t) { [weak self] in
            guard let self else { return }
            swap()
            let topEdge = self.L.lineY + CGFloat(self.entry.cursorRow) * self.L.lineH + self.L.baselineDrop + self.L.topPad
            let rise = min(topEdge - self.L.deckTop + 6, self.L.size.height * 0.62)
            self.feedOffset = -rise
            self.feedAnim = (self.now, Mechanics.paperInDuration, -rise, 0, Mechanics.paperInSteps)
            self.play(.paperIn, 0.9)
            self.hasSheet = true
        }
        nextOpAt = t + Mechanics.paperInDuration + 0.08
        lastMech = nextOpAt
        if !header.isEmpty { type(header) }
    }

    // MARK: - The carriage in the hand

    /// The carriage follows the pointer that holds it, or runs along the line while a glide key
    /// is down. It is moved by steering `headTarget`, so the same spring that carries it from
    /// cell to cell in typing gives it its weight here; let go, it drops into a cell.
    private func stepHand(_ dt: CGFloat) {
        if !floating {
            guard holdX != nil || glideDir != 0 else { return }
            // A slug in the air lands first, and a carriage flying home arrives first.
            guard atRest else {
                holdBase = nil
                return
            }
            floating = true
            glideVel = 0
            coast = nil
            lastCell = Int(headCol.rounded())
            scrollTarget = 0
        }
        if let x = holdX {
            let base = holdBase ?? (x, headTarget)
            holdBase = base
            // Whatever moves follows the hand: the carriage, or the paper under a fixed carriage.
            let sign: CGFloat = options.paperMoves ? -1 : 1
            headTarget = max(0, min(CGFloat(Grid.cols), base.col + sign * (x - base.x) / L.cellW))
            glideVel = 0
            coast = nil
        } else if glideDir != 0 {
            // The glide itself is advanced inside the motion steps (`stepGlide`).
            holdBase = nil
            coast = nil
        } else {
            holdBase = nil
            if glideVel != 0, coast == nil { planCoast() }
            if glideVel == 0 {
                dropIntoCell()
                return
            }
        }
        lastActivity = now
    }

    /// Nothing in the air, nothing queued, the carriage where the mechanism left it.
    private var atRest: Bool {
        hasSheet && events.isEmpty && returnAnim == nil && feedAnim == nil && pendingLoad == nil && pendingCount == 0
    }

    /// The glide key is up while the carriage is still running: pick the cell it will stop on,
    /// far enough ahead to brake evenly, never behind it.
    private func planCoast() {
        let dir: CGFloat = glideVel < 0 ? -1 : 1
        let speed = abs(glideVel)
        let least = speed * Mechanics.glideCoast / 2
        var stop = dir > 0 ? (headTarget + least).rounded(.up) : (headTarget - least).rounded(.down)
        stop = max(0, min(CGFloat(Grid.cols), stop))
        let distance = (stop - headTarget) * dir
        guard distance > 0.01 else {
            headTarget = stop
            glideVel = 0
            return
        }
        coast = (stop, speed * speed / (2 * distance))
    }

    /// One small step of a glide: `headTarget` gains speed while the key is held, and brakes
    /// to a stop on its cell once it is let go. Run inside the motion steps so that the spring
    /// is led by a smooth ramp, not by a staircase of frames.
    private func stepGlide(_ h: CGFloat) {
        guard holdX == nil else { return }
        if let c = coast {
            let dir: CGFloat = glideVel < 0 ? -1 : 1
            let speed = abs(glideVel) - c.braking * h
            let to = headTarget + dir * max(speed, 0) * h
            if speed <= 0 || (c.stop - to) * dir <= 0 {
                headTarget = c.stop
                glideVel = 0
                coast = nil
            } else {
                headTarget = to
                glideVel = dir * speed
            }
            return
        }
        guard glideDir != 0 else { return }
        // Speed in the direction now asked for; negative while it is still running the other way.
        var speed = glideVel * glideDir
        if speed < 0 {
            speed += Mechanics.glideBrake * h
        } else {
            speed = min(Mechanics.glideFull, max(speed, Mechanics.glideStart) + Mechanics.glideGain * h)
        }
        let to = headTarget + speed * glideDir * h
        if to <= 0 || to >= CGFloat(Grid.cols) {
            // The margin stop.
            headTarget = max(0, min(CGFloat(Grid.cols), to))
            glideVel = 0
        } else {
            headTarget = to
            glideVel = speed * glideDir
        }
    }

    /// The escapement clicks as the carriage passes over each cell — lighter the faster it runs,
    /// and never more often than `passClickGap`.
    private func passCells() {
        guard floating else { return }
        let cell = Int(headCol.rounded())
        guard cell != lastCell else { return }
        lastCell = cell
        guard now - lastPassClick >= Mechanics.passClickGap else { return }
        lastPassClick = now
        let gain = max(0.14, 0.30 - 0.0014 * Float(abs(headVel))) * (0.9 + 0.2 * Float(rng.unit()))
        play(.tick, gain)
    }

    /// Let go, the carriage drops into the nearest cell. (A glide has already braked onto one.)
    private func dropIntoCell() {
        floating = false
        holdBase = nil
        glideVel = 0
        coast = nil
        let cell = max(0, min(Grid.cols, Int(headTarget.rounded())))
        headTarget = CGFloat(cell)
        // Nothing is struck until it has come to rest there.
        lastMech = max(lastMech, now + 0.03)
        guard cell != entry.cursorCol else { return }
        entry.cursorCol = cell
        changed(touch: false)
        play(.tick, 0.5)
    }

    // MARK: - Motion

    private func smooth(_ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, x))
        return t * t * (3 - 2 * t)
    }

    private func stepMotion(_ dt: CGFloat) {
        guard dt > 0 else { return }

        if let ra = returnAnim {
            let u = CGFloat((now - ra.start) / ra.dur)
            if u >= 1 {
                headCol = 0
                headVel = -85
                returnAnim = nil
            } else {
                // The mainspring pulls harder and harder until the carriage hits its stop.
                headCol = ra.from * (1 - u * u)
                headVel = 0
            }
        }

        let steps = max(1, Int((dt * 480).rounded(.up)))
        let h = dt / CGFloat(steps)
        let wHead: CGFloat = 2 * .pi * 24, zHead: CGFloat = 0.78
        let wShake: CGFloat = 2 * .pi * 31, zShake: CGFloat = 0.36
        let wDip: CGFloat = 2 * .pi * 27, zDip: CGFloat = 0.42
        for _ in 0..<steps {
            if returnAnim == nil {
                if floating { stepGlide(h) }
                headVel += (-wHead * wHead * (headCol - headTarget) - 2 * zHead * wHead * headVel) * h
                headCol += headVel * h
            }
            shakeVel.x += (-wShake * wShake * shake.x - 2 * zShake * wShake * shakeVel.x) * h
            shakeVel.y += (-wShake * wShake * shake.y - 2 * zShake * wShake * shakeVel.y) * h
            shake.x += shakeVel.x * h
            shake.y += shakeVel.y * h
            headDipVel += (-wDip * wDip * headDip - 2 * zDip * wDip * headDipVel) * h
            headDip += headDipVel * h
        }

        rowF += (rowTarget - rowF) * (1 - exp(-dt * 24))
        scrollRows += (scrollTarget - scrollRows) * (1 - exp(-dt * 16))
        let tick = Int(scrollRows.rounded())
        if tick != lastScrollTick {
            lastScrollTick = tick
            play(.tick, 0.3)
        }

        if let fa = feedAnim {
            let u = CGFloat((now - fa.start) / fa.dur)
            if u >= 1 {
                feedOffset = fa.to
                feedAnim = nil
            } else if fa.steps > 0 {
                // The platen turns one ratchet tooth at a time.
                let n = CGFloat(fa.steps)
                let k = (u * n).rounded(.down)
                let e = (k + smooth((u * n - k) / 0.62)) / n
                feedOffset = fa.from + (fa.to - fa.from) * e
            } else {
                feedOffset = fa.from + (fa.to - fa.from) * u * u * u
            }
        }

        modeMix += ((options.paperMoves ? 1 : 0) - modeMix) * (1 - exp(-dt * 7))
        roomMix += ((options.lightsOn ? 1 : 0) - roomMix) * (1 - exp(-dt * 6))
        lampMix += ((lampOn ? 1 : 0) - lampMix) * (1 - exp(-dt * 4.5))
        torchPower += (torchTarget - torchPower) * (1 - exp(-dt * 7))
        jewelPulse *= exp(-dt * 4)
    }

    private func place() {
        let z = L.zoom
        let fixedLeft = (L.size.width - L.textW) / 2
        let travelling = fixedLeft + (headCol + 0.5) * L.cellW
        headX = travelling + (L.size.width / 2 - travelling) * modeMix
        let textLeft = headX - (headCol + 0.5) * L.cellW
        let py = L.lineY + (rowF - scrollRows) * L.lineH + L.baselineDrop + feedOffset
        paperNode.position = CGPoint(x: textLeft + shake.x, y: py + shake.y)

        // The paper sprite is only as tall as the part of the sheet that is in view.
        let bottom = (L.deckTop - 4 * z) - py
        let top = min(L.topPad, L.size.height + 8 - py)
        let visible = top - bottom > 1
        paperSprite.isHidden = !visible
        edgeL.isHidden = !visible
        edgeR.isHidden = !visible
        if visible {
            let height = top - bottom
            paperSprite.position = CGPoint(x: -L.marginX, y: bottom)
            paperSprite.size = CGSize(width: L.paperW, height: height)
            // Keep shader coordinates small so the paper grain stays sharp on long sheets.
            let period = 4096 * z
            let wrap = (bottom / period).rounded(.down) * period
            uPaperOrg.vectorFloat2Value = vector_float2(Float(-L.marginX), Float(bottom - wrap))
            uPaperSize.vectorFloat2Value = vector_float2(Float(L.paperW), Float(height))
            uPaperTop.floatValue = Float(L.topPad - wrap)
            edgeL.position = CGPoint(x: -L.marginX, y: bottom)
            edgeL.size = CGSize(width: 13 * z, height: height)
            edgeR.position = CGPoint(x: L.textW + L.marginX, y: bottom)
            edgeR.size = CGSize(width: 13 * z, height: height)
        }

        headNode.position = CGPoint(x: headX, y: L.lineY + headDip)
        lampPos = CGPoint(x: headX, y: L.housingTop + 2 * z + headDip)
    }

    // MARK: - Typebars

    private func launchFlight(theta: CGFloat, wide: Bool, start: Double, impact: Double) {
        let f = Flight(start: start, impact: impact, theta: theta, wide: wide)
        let s = wide ? slugWide : slugNarrow
        f.slug.texture = s.texture
        f.baseSize = s.size
        f.slug.zPosition = 1
        f.arm.texture = armTexture
        f.arm.anchorPoint = CGPoint(x: 0.5, y: 1)
        f.slugShadow.texture = shadowBlob
        f.armShadow.texture = armShadowTexture
        f.armShadow.anchorPoint = CGPoint(x: 0.5, y: 1)
        for n in [f.arm, f.slug] {
            n.isHidden = true
            barLayer.addChild(n)
        }
        for n in [f.armShadow, f.slugShadow] {
            n.isHidden = true
            shadowLayer.addChild(n)
        }
        flights.append(f)
    }

    /// How far the ribbon has lifted for this strike, 0...1.
    private func ribbonPulse(_ f: Flight) -> CGFloat {
        let up = f.impact - f.start
        let a = f.impact - 0.55 * up, b = f.impact - 0.006
        let c = f.impact + 0.020, d = f.impact + 0.065
        if now <= a || now >= d { return 0 }
        if now < b { return smooth(CGFloat((now - a) / (b - a))) }
        if now <= c { return 1 }
        return 1 - smooth(CGFloat((now - c) / (d - c)))
    }

    private func stepFlights() {
        let z = L.zoom
        // A typebar pivots on an arc below the print point and swings up and away from the
        // viewer until its slug meets the paper. These are the dimensions of that little model.
        let reach = 118 * z
        let camera = 520 * z
        let rest: CGFloat = 78 * .pi / 180
        let lampHeight = 85 * z
        let armWidth = 6.4 * z
        var lift: CGFloat = 0

        var i = 0
        while i < flights.count {
            let f = flights[i]
            if now < f.start {
                i += 1
                continue
            }
            var phi: CGFloat
            var fade: CGFloat = 1
            if now < f.impact {
                let u = CGFloat((now - f.start) / (f.impact - f.start))
                phi = rest * (1 - u * u * (0.55 + 0.45 * u))
                fade = smooth(u / 0.22)
            } else if now < f.impact + TypewriterScene.holdTime {
                phi = 0
            } else {
                let v = CGFloat((now - f.impact - TypewriterScene.holdTime) / TypewriterScene.fallTime)
                if v >= 1 {
                    f.remove()
                    flights.remove(at: i)
                    continue
                }
                phi = rest * (1 - (1 - v) * (1 - v))
                fade = 1 - smooth((v - 0.62) / 0.38)
            }
            lift = max(lift, ribbonPulse(f))

            // Where the slug should land: the middle of the glyph, relative to the carriage.
            let target = CGPoint(x: f.wide ? L.cellW * 0.5 : 0, y: L.fontSize * (f.wide ? 0.36 : 0.30))
            let dir = CGPoint(x: sin(f.theta), y: -cos(f.theta))
            let along = reach * (1 - cos(phi))
            let depth = 2 * z + reach * sin(phi)
            let persp = camera / (camera - depth)
            let tip = CGPoint(x: dir.x * along * persp, y: dir.y * along * persp)
            let pivot = CGPoint(x: dir.x * reach, y: dir.y * reach)

            f.slug.isHidden = false
            f.slug.position = CGPoint(x: target.x + tip.x, y: target.y + tip.y)
            f.slug.size = CGSize(width: f.baseSize.width * persp, height: f.baseSize.height * persp)
            f.slug.zRotation = f.theta
            f.slug.alpha = fade

            let neck = f.baseSize.height * 0.42 * persp
            let length = (pivot.x - tip.x) * dir.x + (pivot.y - tip.y) * dir.y - neck
            if length > 2 {
                f.arm.isHidden = false
                f.arm.position = CGPoint(x: target.x + tip.x + dir.x * neck, y: target.y + tip.y + dir.y * neck)
                f.arm.size = CGSize(width: armWidth * (1 + (persp - 1) * 0.5), height: length)
                f.arm.zRotation = f.theta
                f.arm.alpha = fade
            } else {
                f.arm.isHidden = true
            }

            // Shadows: the lamp sits below the print point, so a rising bar throws its shadow
            // up the page, and the shadow races in to meet the slug at the moment of contact.
            let lamp = CGPoint(x: -target.x, y: (L.housingTop + 2 * z - L.lineY) - target.y)
            if depth < lampHeight * 0.93 {
                let k = lampHeight / (lampHeight - depth)
                let along2D = CGPoint(x: dir.x * along, y: dir.y * along)
                let s = CGPoint(x: lamp.x + (along2D.x - lamp.x) * k, y: lamp.y + (along2D.y - lamp.y) * k)
                let a = fade * min(1, 0.62 / pow(k, 1.5))
                f.slugShadow.isHidden = false
                f.slugShadow.position = CGPoint(x: target.x + s.x, y: target.y + s.y)
                f.slugShadow.size = CGSize(width: f.baseSize.width * k * 1.7, height: f.baseSize.height * k * 1.6)
                f.slugShadow.zRotation = f.theta
                f.slugShadow.alpha = a
                let vx = pivot.x - s.x, vy = pivot.y - s.y
                let len = sqrt(vx * vx + vy * vy)
                if len > 4 {
                    f.armShadow.isHidden = false
                    f.armShadow.position = CGPoint(x: target.x + s.x, y: target.y + s.y)
                    f.armShadow.size = CGSize(width: armWidth * (1.6 + k), height: len)
                    f.armShadow.zRotation = atan2(vy, vx) + .pi / 2
                    f.armShadow.alpha = a * 0.6
                } else {
                    f.armShadow.isHidden = true
                }
            } else {
                f.slugShadow.isHidden = true
                f.armShadow.isHidden = true
            }
            i += 1
        }

        // The ribbon rests just under the line and jumps up to meet each slug.
        ribbon.texture = options.ribbon == 1 ? ribbonRed : ribbonBlack
        ribbon.position = CGPoint(x: 0, y: -20.5 * z + 26 * z * lift)

        // Correction tape: up, press, away.
        let tt = now - tapeStart
        if tt >= 0 && tt < 0.09 {
            let u = CGFloat(tt)
            let lifted: CGFloat = u < 0.03 ? smooth(u / 0.03) : (u < 0.05 ? 1 : 1 - smooth((u - 0.05) / 0.04))
            tape.isHidden = false
            tape.position = CGPoint(x: 0, y: -24 * z + 30 * z * lifted)
            tape.alpha = min(1, lifted * 1.4)
        } else {
            tape.isHidden = true
        }
    }

    // MARK: - Dust

    private func respawn(_ m: inout Mote, scatterAge: Bool) {
        let w = max(L.size.width, 100), h = max(L.size.height - L.deckTop, 100)
        m.p = CGPoint(x: rng.unit() * w, y: L.deckTop + rng.unit() * h)
        let a = rng.unit() * 2 * .pi
        let sp = (2 + rng.unit() * 5) * L.zoom
        m.v = CGVector(dx: cos(a) * sp, dy: sin(a) * sp * 0.6 + 1.2 * L.zoom)
        m.life = 9 + rng.unit() * 12
        m.age = scatterAge ? rng.unit() * m.life : 0
        m.size = (1.6 + rng.unit() * rng.unit() * 4.2) * L.zoom
        m.phase = rng.unit() * 6.28
    }

    /// The lamp's brightness at a point on the page, matching the light-map shader.
    private func lampLit(at p: CGPoint) -> CGFloat {
        let h = TypewriterScene.lampHeight * L.zoom
        let tilt = TypewriterScene.lampTilt
        let dx = p.x - lampPos.x, dy = p.y - lampPos.y
        let d2 = dx * dx + dy * dy + h * h
        let d = sqrt(d2)
        let c = (dy + h * tilt) / (d * sqrt(1 + tilt * tilt))
        let spot = smooth((c - TypewriterScene.coneOuter) / (TypewriterScene.coneInner - TypewriterScene.coneOuter))
        let e = lampPowerNow * (spot * 0.965 + 0.035) * (h / d) * (h * h) / d2
        return 1 - exp(-e)
    }

    private func stepDust(_ dt: CGFloat) {
        let on: CGFloat = options.dust ? 1 : 0
        for i in motes.indices {
            motes[i].age += dt
            if motes[i].age > motes[i].life { respawn(&motes[i], scatterAge: false) }
            let m = motes[i]
            let sway = sin(CGFloat(now) * 0.6 + m.phase) * 3 * L.zoom
            motes[i].p.x += (m.v.dx + sway * 0.4) * dt
            motes[i].p.y += m.v.dy * dt
            let u = m.age / m.life
            let env = smooth(u / 0.18) * (1 - smooth((u - 0.75) / 0.25))
            let twinkle = 0.75 + 0.25 * sin(CGFloat(now) * 1.7 + m.phase * 3)
            let a = env * lampLit(at: motes[i].p) * 0.34 * on * twinkle
            m.node.position = motes[i].p
            m.node.size = CGSize(width: m.size, height: m.size)
            m.node.alpha = a
            m.node.isHidden = a < 0.004
        }
    }

    // MARK: - Ink

    private func rowPosition(_ r: Int) -> CGPoint {
        CGPoint(x: -L.rowPadX, y: -CGFloat(r + 1) * L.lineH - L.rowPadY)
    }

    private func refreshRows() {
        let py = paperNode.position.y
        let lo = max(0, Int(((py - L.size.height) / L.lineH).rounded(.down)) - 1)
        let hi = min(entry.rows.count - 1, Int(((py - L.deckTop) / L.lineH).rounded(.up)) + 1)
        for (r, node) in rowNodes where r < lo || r > hi {
            node.removeFromParent()
            rowNodes[r] = nil
        }
        if !emptyRows.isEmpty {
            emptyRows = emptyRows.filter { $0 >= lo && $0 <= hi }
        }
        if lo <= hi {
            // Rows that just changed are redrawn at once. Rows merely coming into view (a sheet
            // being loaded, a long scroll) are spread over a few frames so no single frame is slow.
            var fresh = 0
            for r in stride(from: hi, through: lo, by: -1) {
                if dirtyRows.contains(r) {
                    renderRow(r)
                } else if rowNodes[r] == nil && !emptyRows.contains(r) && fresh < 3 {
                    renderRow(r)
                    fresh += 1
                }
            }
        }
        dirtyRows.removeAll(keepingCapacity: true)
    }

    private func renderRow(_ r: Int) {
        guard r < entry.rows.count, let image = liner.render(entry.rows[r], now: now) else {
            rowNodes[r]?.removeFromParent()
            rowNodes[r] = nil
            emptyRows.insert(r)
            return
        }
        emptyRows.remove(r)
        let texture = SKTexture(cgImage: image)
        if let node = rowNodes[r] {
            node.texture = texture
        } else {
            let node = SKSpriteNode(texture: texture)
            node.anchorPoint = .zero
            node.size = L.rowSize
            node.position = rowPosition(r)
            rowsNode.addChild(node)
            rowNodes[r] = node
        }
    }

    // MARK: - Light

    private func pushUniforms() {
        let z = L.zoom
        let t = now
        let flicker = 1 + 0.010 * sin(t * 6.1) + 0.007 * sin(t * 14.7 + 1.3) + 0.004 * sin(t * 31.0 + 0.4)
        // A filament does not come on all at once.
        let warm = lampMix * lampMix * (3 - 2 * lampMix)
        lampPowerNow = TypewriterScene.lampBase * options.lampPower * warm * CGFloat(flicker)
        uLamp.vectorFloat2Value = vector_float2(Float(lampPos.x), Float(lampPos.y))
        uH.floatValue = Float(TypewriterScene.lampHeight * z)
        uPower.floatValue = Float(lampPowerNow)
        uAmbient.floatValue = Float(options.ambient)
        uRoom.floatValue = Float(roomMix)
        uTorch.vectorFloat4Value = vector_float4(Float(torchPos.x), Float(torchPos.y), Float(torchPower * 0.5), Float(150 * z))
        uT.floatValue = Float(t.truncatingRemainder(dividingBy: 1.0) * 61.0)

        slotGlow.alpha = warm * (0.86 + 0.14 * CGFloat(flicker))
        bloom.alpha = 0.085 * warm * min(1.4, options.lampPower)
        jewel.alpha = min(1, 0.50 + 0.5 * jewelPulse)
    }

    // MARK: - Indicator and composing text

    /// Lights a short mark on the carriage for a moment. The carriage is otherwise blank;
    /// this is used only to say which input source was just switched to.
    func flashIndicator(_ text: String) {
        indicatorText = text
        indicatorPending = true
        lastActivity = now
    }

    private func refreshDisplay() {
        if indicatorPending {
            indicatorPending = false
            indicatorStart = now
        }
        if indicatorText != shownIndicator {
            shownIndicator = indicatorText
            let d = Art.indicator(indicatorText, z: L.zoom, ps: L.ps)
            display.texture = d.texture
            display.size = d.size
        }
        let t = CGFloat(now - indicatorStart)
        var glow: CGFloat = 0
        if t >= 0 && t < 2.1 {
            glow = t < 0.12 ? smooth(t / 0.12) : (t < 1.4 ? 1 : 1 - smooth((t - 1.4) / 0.7))
        }
        display.alpha = glow
        display.isHidden = glow < 0.004

        // Text still being composed is pencilled in at the cursor.
        guard !composition.isEmpty else {
            if !ghost.isHidden {
                ghost.isHidden = true
                shownGhost = ""
            }
            return
        }
        let row = entry.cursorRow, col = entry.cursorCol
        let key = "\(composition)\u{1}\(row)\u{1}\(col)\u{1}\(L.zoom)"
        guard key != shownGhost else { return }
        shownGhost = key
        let cells = composition.reduce(0) { $0 + Grid.width(of: String($1)) }
        let limit = Grid.cols + 2
        let overflow = col + cells > limit
        let start = overflow ? max(0, limit - cells) : col
        let g = Art.ghost(composition, layout: L, latinFont: options.latinFont, cjkFont: options.cjkFont, backed: overflow)
        ghost.texture = g.texture
        ghost.size = g.size
        ghost.position = CGPoint(x: CGFloat(start) * L.cellW - g.pad, y: -CGFloat(row + 1) * L.lineH - g.pad)
        ghost.isHidden = false
    }
}
