import Cocoa

// What the HUD shows the recorder doing: the soft colours its light runs through (muted, easy on the eye), and the
// symbol the orb settles on once the outcome is known.
enum HUDState {
    case waiting, listening, transcribing, sent, typed, copied, warning, failed

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
    private static let teal = rgb(0.40, 0.82, 0.88), blue = rgb(0.44, 0.57, 0.98), violet = rgb(0.67, 0.53, 0.98)
    private static let rose = rgb(0.93, 0.57, 0.80), amber = rgb(0.93, 0.75, 0.48), coral = rgb(0.93, 0.52, 0.52)
    private static let green = rgb(0.46, 0.85, 0.66)

    var colors: [NSColor] {
        switch self {
        case .waiting: return [Self.amber, Self.rose, Self.amber]
        case .listening: return [Self.teal, Self.blue, Self.violet, Self.blue]
        case .transcribing: return [Self.violet, Self.rose, Self.blue, Self.rose]
        case .sent: return [Self.green, Self.teal]
        case .typed, .copied: return [Self.blue, Self.teal]
        case .warning: return [Self.amber, Self.coral]
        case .failed: return [Self.coral, Self.rose]
        }
    }

    // While the recorder is working the light keeps moving; an outcome holds still.
    var turnSeconds: CFTimeInterval? {
        switch self {
        case .waiting, .listening: return 5
        case .transcribing: return 1.6
        default: return nil
        }
    }

    var symbol: String? {
        switch self {
        case .waiting, .listening, .transcribing: return nil
        case .sent: return nil // its checkmark is drawn as with a pen (VoiceOrb)
        case .typed: return "text.cursor"
        case .copied: return "doc.on.clipboard"
        case .warning: return "exclamationmark"
        case .failed: return "xmark"
        }
    }

    // Only what needs a second look colours its message.
    var needsAttention: Bool { self == .warning || self == .failed }
}

// A conic gradient of the state's colours that turns, seamless where it wraps around.
class TurningGradient: CAGradientLayer {
    override init() {
        super.init()
        type = .conic
        startPoint = CGPoint(x: 0.5, y: 0.5)
        endPoint = CGPoint(x: 0.5, y: 0)
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: HUDState) {
        colors = (state.colors + [state.colors[0]]).map(\.cgColor)
        removeAnimation(forKey: "turn")
        guard let seconds = state.turnSeconds, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * CGFloat.pi
        turn.duration = seconds
        turn.repeatCount = .infinity
        add(turn, forKey: "turn")
    }
}

// The light around the panel's edge: a thin line of the turning gradient with a soft glow inside it.
class GlowRim: NSView {
    static let radius: CGFloat = 24
    private let clip = CALayer()
    private let line = CAShapeLayer()
    private let gradient = TurningGradient()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius // the glow stays inside the glass, not in the window's square corners
        layer?.masksToBounds = true
        line.fillColor = nil
        line.strokeColor = NSColor.black.cgColor
        line.lineWidth = 1.5
        line.shadowColor = NSColor.black.cgColor
        line.shadowOffset = .zero
        line.shadowRadius = 7
        line.shadowOpacity = 0.9
        clip.mask = line
        clip.addSublayer(gradient)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        line.frame = bounds
        line.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: Self.radius - 0.75,
                           cornerHeight: Self.radius - 0.75, transform: nil)
        // A square over the whole panel, so the gradient covers every edge at any angle.
        let side = hypot(bounds.width, bounds.height)
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    func show(_ state: HUDState) { gradient.show(state) }
}

// A small sphere of the same light that swells with the voice; an outcome shows its symbol on it.
class VoiceOrb: NSView {
    private let sphere = CALayer()
    private let gradient = TurningGradient()
    private let icon = NSImageView()
    private let check = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        sphere.frame = bounds.insetBy(dx: 3, dy: 3)
        sphere.cornerRadius = sphere.frame.width / 2
        sphere.masksToBounds = true
        sphere.borderWidth = 1
        sphere.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        gradient.frame = sphere.bounds
        sphere.addSublayer(gradient)
        layer?.addSublayer(sphere)
        icon.frame = bounds.insetBy(dx: 7, dy: 7)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        icon.contentTintColor = .white
        addSubview(icon)
        // Laid out for the 28 pt orb, y up: the short stroke down, then the long one up, as a hand writes it.
        let tick = CGMutablePath()
        tick.move(to: CGPoint(x: 9.5, y: 14.2))
        tick.addLine(to: CGPoint(x: 12.6, y: 11))
        tick.addLine(to: CGPoint(x: 18.8, y: 17.6))
        check.path = tick
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = 2.2
        check.lineCap = .round
        check.lineJoin = .round
        check.shadowColor = NSColor.white.cgColor // a faint glow, like the rim's light
        check.shadowOffset = .zero
        check.shadowRadius = 2
        check.shadowOpacity = 0.45
        check.strokeEnd = 0
        layer?.addSublayer(check)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // A layer added by hand keeps contentsScale 1, which would draw the stroke soft on a Retina screen.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        check.contentsScale = window?.backingScaleFactor ?? 2
    }

    func show(_ state: HUDState) {
        gradient.show(state)
        icon.image = state.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        swell(0)
        drawCheck(state == .sent)
    }

    // The checkmark writes itself once as the colours turn, and the sphere settles under it; Reduce Motion shows it
    // whole at once.
    private func drawCheck(_ shown: Bool) {
        check.removeAllAnimations()
        sphere.removeAnimation(forKey: "settle")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        check.strokeEnd = shown ? 1 : 0
        CATransaction.commit()
        guard shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let stroke = CABasicAnimation(keyPath: "strokeEnd")
        stroke.fromValue = 0
        stroke.beginTime = CACurrentMediaTime() + 0.1
        stroke.duration = 0.42
        stroke.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1) // quick, easing out like a pen
        stroke.fillMode = .backwards // hidden until it starts
        check.add(stroke, forKey: "stroke")
        let settle = CASpringAnimation(keyPath: "transform.scale")
        settle.fromValue = 0.88
        settle.toValue = 1
        settle.damping = 11
        settle.stiffness = 260
        settle.duration = settle.settlingDuration
        sphere.add(settle, forKey: "settle")
    }

    // level 0…1, as the meter reads it.
    func swell(_ level: CGFloat) {
        let level = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : level // and undo a swell left on
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        sphere.setAffineTransform(CGAffineTransform(scaleX: 1 + 0.18 * level, y: 1 + 0.18 * level))
        CATransaction.commit()
    }
}

// The microphone's level as bars, newest on the right: speech moves them, a muted or dead microphone leaves them flat.
class LevelMeter: NSView {
    private var levels = [CGFloat](repeating: 0, count: 28) // one per tap buffer (~21 ms at 48 kHz)
    // The room's level: the 10th percentile of the last ~4 s of buffers in dB, which the gaps between words reach
    // (1.5 s was all speech in a fast sentence). Recordings put it at -45…-27 dB with speech at -20 and peaks at -11,
    // so a fixed scale moved without speech; the lowest instead would hold a lone dip (-62 dB as the mic starts).
    private var recent: [Float] = []
    var latest: CGFloat { levels.last ?? 0 }

    // A buffer's peak above the room's level: 8 dB over it starts a bar, 36 dB over it fills one.
    func push(peak: Float) {
        let decibels = 20 * log10(max(peak, 1e-6))
        recent = recent.suffix(187) + [decibels]
        levels.removeFirst()
        let floor = recent.sorted()[recent.count / 10]
        levels.append(CGFloat(min(max((decibels - floor - 8) / 28, 0), 1)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let width = (bounds.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        for (i, level) in levels.enumerated() {
            // Older bars fade to the left, so the sound just heard reads first.
            NSColor.white.withAlphaComponent(0.15 + 0.75 * CGFloat(i + 1) / CGFloat(levels.count)).setFill()
            let height = max(width, bounds.height * level)
            let bar = NSRect(x: CGFloat(i) * (width + gap), y: (bounds.height - height) / 2, width: width, height: height)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }
}

class HUDWindow: NSPanel {
    private let rim = GlowRim()
    private let orb = VoiceOrb(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    private let statusLabel = NSTextField(labelWithString: "")
    private let meter = LevelMeter()
    private let transcriptLabel = NSTextField(wrappingLabelWithString: "แตะ: พูดจบแล้วพิมพ์รอ · กดค้าง: ปล่อยเพื่อส่ง · Esc ยกเลิก")
    // The transcript area grows upward with the text (bottom edge stays put); past the cap only the latest text shows.
    private static let minTextHeight: CGFloat = 28 // one 17 pt Thai line, so the first words do not grow it
    private static let maxTextHeight: CGFloat = 360
    private static let chromeHeight: CGFloat = 72 // status row + paddings around the transcript

    init() {
        let width: CGFloat = 560
        let height = Self.minTextHeight + Self.chromeHeight
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height) // present() places it

        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.appearance = NSAppearance(named: .darkAqua) // dark glass under light text, whatever the wallpaper

        setupUI(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    private func setupUI(frame: NSRect) {
        let glass = NSGlassEffectView(frame: frame)
        glass.cornerRadius = GlowRim.radius
        glass.tintColor = NSColor.black.withAlphaComponent(0.4)
        let content = NSView(frame: frame)
        content.autoresizingMask = [.width, .height]
        rim.frame = frame
        rim.autoresizingMask = [.width, .height]

        orb.frame.origin = NSPoint(x: 16, y: frame.height - 44)
        orb.autoresizingMask = [.minYMargin]

        meter.frame = NSRect(x: frame.width - 140, y: frame.height - 40, width: 116, height: 20)
        meter.autoresizingMask = [.minYMargin, .minXMargin]

        statusLabel.frame = NSRect(x: 54, y: frame.height - 39, width: frame.width - 210, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail // a long error ends in "…" instead of being cut mid-word
        statusLabel.autoresizingMask = [.minYMargin, .width]

        transcriptLabel.frame = NSRect(x: 22, y: 16, width: frame.width - 44, height: frame.height - Self.chromeHeight)
        transcriptLabel.font = NSFont.systemFont(ofSize: 13)
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        transcriptLabel.maximumNumberOfLines = 0
        transcriptLabel.lineBreakMode = .byWordWrapping
        transcriptLabel.autoresizingMask = [.height, .width]

        show("กำลังเตรียมไมค์…", state: .waiting)
        content.addSubview(rim)
        content.addSubview(orb)
        content.addSubview(statusLabel)
        content.addSubview(meter)
        content.addSubview(transcriptLabel)
        glass.contentView = content
        self.contentView = glass
    }

    // Fades in rather than popping up over what the user is looking at.
    // Placed on the screen that is main now: a standby's HUD was built before the press, maybe on another screen.
    func present() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        setFrameOrigin(NSPoint(x: screenRect.origin.x + (screenRect.width - frame.width) / 2,
                               y: screenRect.origin.y + 90))
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func updateTranscript(_ text: String) {
        DispatchQueue.main.async { self.setTranscript(text) }
    }

    // The first text replaces the hint and takes the transcript's larger, brighter style.
    private func setTranscript(_ text: String) {
        transcriptLabel.font = NSFont.systemFont(ofSize: 17, weight: .medium)
        transcriptLabel.textColor = .white
        let bounds = NSRect(x: 0, y: 0, width: transcriptLabel.frame.width, height: .greatestFiniteMagnitude)
        func height(of value: String) -> CGFloat {
            transcriptLabel.stringValue = value
            return transcriptLabel.cell?.cellSize(forBounds: bounds).height ?? Self.minTextHeight
        }
        var shown = text
        while height(of: shown) > Self.maxTextHeight, shown.count > 20 {
            shown = "…" + shown.dropFirst(max(shown.count / 10, 1))
        }
        let textHeight = min(max(height(of: shown), Self.minTextHeight), Self.maxTextHeight)
        var newFrame = frame
        newFrame.size.height = textHeight + Self.chromeHeight
        setFrame(newFrame, display: true)
    }

    private func show(_ status: String, state: HUDState) {
        statusLabel.stringValue = status
        statusLabel.textColor = state.needsAttention ? state.colors[0] : NSColor.white.withAlphaComponent(0.6)
        rim.show(state)
        orb.show(state)
    }

    func showStatus(_ status: String, state: HUDState) {
        DispatchQueue.main.async { self.show(status, state: state) }
    }

    func showLevel(peak: Float) {
        DispatchQueue.main.async {
            self.meter.push(peak: peak)
            self.orb.swell(self.meter.latest)
        }
    }

    func showResult(_ text: String, status: String, state: HUDState) {
        DispatchQueue.main.async {
            self.meter.isHidden = true // listening is over: the status (a long error or hint) takes the meter's place
            self.statusLabel.frame.size.width = self.meter.frame.maxX - self.statusLabel.frame.minX
            self.show(status, state: state)
            self.setTranscript(text)
        }
    }
}
