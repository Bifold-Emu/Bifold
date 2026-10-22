import AzaharCore
import UIKit

/// On-screen 3DS controls. Multi-touch, slide-between-buttons, analog circle pad.
/// Only the controls themselves capture touches; everything else falls through to the
/// emulated touch screen underneath.
final class VirtualControllerView: UIView {
    private enum Kind {
        case button(AZButton)
        case dpad
        case circlePad
    }

    private final class Control {
        let kind: Kind
        let label: String
        var frame: CGRect = .zero
        let shape = CAShapeLayer()
        let text = CATextLayer()
        let knob = CAShapeLayer() // circle pad thumb
        var pressed = false { didSet { if pressed != oldValue { refresh() } } }

        init(kind: Kind, label: String) {
            self.kind = kind
            self.label = label
            shape.lineWidth = 1
            // A dark lip under each control so it reads as a physical key.
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.55
            shape.shadowRadius = 0
            text.alignmentMode = .center
            text.contentsScale = UIScreen.main.scale
            text.string = label
            let rounded = UIFont.systemFont(ofSize: 17, weight: .heavy).fontDescriptor.withDesign(.rounded)
            text.font = rounded.map { UIFont(descriptor: $0, size: 17) } ?? UIFont.systemFont(ofSize: 17, weight: .heavy)
            knob.fillColor = UIColor(hex: 0x9AA6B8).cgColor
            knob.strokeColor = UIColor(white: 1, alpha: 0.45).cgColor
            knob.lineWidth = 1
            knob.shadowColor = UIColor.black.cgColor
            knob.shadowOpacity = 0.5
            knob.shadowRadius = 3
            knob.shadowOffset = CGSize(width: 0, height: 3)
        }

        var isRound: Bool {
            if case .button(let b) = kind { return [AZ_BUTTON_A, AZ_BUTTON_B, AZ_BUTTON_X, AZ_BUTTON_Y, AZ_BUTTON_HOME].contains(b) }
            if case .circlePad = kind { return true }
            return false
        }

        func layout() {
            let bounds = CGRect(origin: .zero, size: frame.size)
            shape.frame = frame
            switch kind {
            case .dpad:
                shape.path = Self.crossPath(in: bounds).cgPath
            default:
                shape.path = (isRound ? UIBezierPath(ovalIn: bounds)
                                      : UIBezierPath(roundedRect: bounds, cornerRadius: min(bounds.height / 2, 12))).cgPath
            }
            shape.shadowPath = shape.path
            let fontSize = max(10, min(frame.height * (frame.width > frame.height * 1.6 ? 0.42 : 0.4), 22))
            text.fontSize = fontSize
            text.frame = CGRect(x: frame.minX, y: frame.midY - fontSize * 0.65, width: frame.width, height: fontSize * 1.3)
            if case .dpad = kind { text.isHidden = true }
            if case .circlePad = kind {
                text.isHidden = true
                let r = frame.width * 0.28
                knob.frame = CGRect(x: frame.midX - r, y: frame.midY - r, width: r * 2, height: r * 2)
                knob.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2)).cgPath
            }
            refresh()
        }

        func refresh() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let isPad: Bool = { if case .circlePad = kind { return true }; return false }()
            // Light slate keys with a white rim stand out against the black around the screens and
            // against dark game scenes; a pressed key turns amber (the app's action colour).
            if isPad {
                shape.fillColor = UIColor(hex: pressed ? 0x46536A : 0x3A4657, alpha: 0.9).cgColor
            } else {
                shape.fillColor = (pressed ? UIColor(hex: 0xFFB24A) : UIColor(hex: 0x5A6880, alpha: 0.92)).cgColor
            }
            shape.strokeColor = UIColor(white: 1, alpha: pressed ? 0.6 : 0.32).cgColor
            shape.lineWidth = 1.5
            shape.shadowOffset = CGSize(width: 0, height: isPad ? 0 : (pressed ? 1 : 3))
            text.foregroundColor = (pressed ? UIColor(hex: 0x2B1B00) : UIColor.white).cgColor
            CATransaction.commit()
        }

        func moveKnob(dx: CGFloat, dy: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let r = knob.frame.width / 2
            knob.position = CGPoint(x: frame.midX + dx, y: frame.midY + dy)
            _ = r
            CATransaction.commit()
        }

        static func crossPath(in r: CGRect) -> UIBezierPath {
            let t = r.width / 3
            let p = UIBezierPath()
            p.move(to: CGPoint(x: t, y: 0))
            p.addLine(to: CGPoint(x: 2 * t, y: 0))
            p.addLine(to: CGPoint(x: 2 * t, y: t))
            p.addLine(to: CGPoint(x: r.width, y: t))
            p.addLine(to: CGPoint(x: r.width, y: 2 * t))
            p.addLine(to: CGPoint(x: 2 * t, y: 2 * t))
            p.addLine(to: CGPoint(x: 2 * t, y: r.height))
            p.addLine(to: CGPoint(x: t, y: r.height))
            p.addLine(to: CGPoint(x: t, y: 2 * t))
            p.addLine(to: CGPoint(x: 0, y: 2 * t))
            p.addLine(to: CGPoint(x: 0, y: t))
            p.addLine(to: CGPoint(x: t, y: t))
            p.close()
            return p
        }
    }

    var hapticsEnabled = true
    /// Portrait only: where the control area starts (set by EmulatorContainerView).
    var portraitControlsTop: CGFloat? { didSet { if oldValue != portraitControlsTop { setNeedsLayout() } } }
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private let controls: [Control] = [
        Control(kind: .circlePad, label: ""),
        Control(kind: .dpad, label: ""),
        Control(kind: .button(AZ_BUTTON_A), label: "A"),
        Control(kind: .button(AZ_BUTTON_B), label: "B"),
        Control(kind: .button(AZ_BUTTON_X), label: "X"),
        Control(kind: .button(AZ_BUTTON_Y), label: "Y"),
        Control(kind: .button(AZ_BUTTON_L), label: "L"),
        Control(kind: .button(AZ_BUTTON_R), label: "R"),
        Control(kind: .button(AZ_BUTTON_ZL), label: "ZL"),
        Control(kind: .button(AZ_BUTTON_ZR), label: "ZR"),
        Control(kind: .button(AZ_BUTTON_START), label: "START"),
        Control(kind: .button(AZ_BUTTON_SELECT), label: "SELECT"),
        Control(kind: .button(AZ_BUTTON_HOME), label: "⌂"),
    ]

    /// Which control each active touch is driving.
    private var touchControl: [ObjectIdentifier: Int] = [:]
    private var touchPoint: [ObjectIdentifier: CGPoint] = [:]
    private var pressedButtons = Set<UInt32>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        for c in controls {
            layer.addSublayer(c.shape)
            layer.addSublayer(c.text)
            if case .circlePad = c.kind { layer.addSublayer(c.knob) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds.inset(by: safeAreaInsets)
        let landscape = bounds.width > bounds.height
        let unit = min(max(min(bounds.width, bounds.height) / 8.0, 40), 64) // base button size

        func place(_ label: Kind, _ rect: CGRect) {
            for c in controls where Self.same(c.kind, label) { c.frame = rect.integral }
        }

        let pad = unit * 2.6          // d-pad / circle pad size
        let face = unit * 0.95        // ABXY button size
        let shoulderW = unit * 1.5, shoulderH = unit * 0.7
        let margin = unit * 0.35

        // Face buttons diamond centred at (cx, cy).
        func faceButtons(cx: CGFloat, cy: CGFloat) {
            let d = face * 1.05
            place(.button(AZ_BUTTON_X), CGRect(x: cx - face / 2, y: cy - d - face / 2, width: face, height: face))
            place(.button(AZ_BUTTON_B), CGRect(x: cx - face / 2, y: cy + d - face / 2, width: face, height: face))
            place(.button(AZ_BUTTON_Y), CGRect(x: cx - d - face / 2, y: cy - face / 2, width: face, height: face))
            place(.button(AZ_BUTTON_A), CGRect(x: cx + d - face / 2, y: cy - face / 2, width: face, height: face))
        }

        if landscape {
            // Controls hug the left and right edges, over the sides of the screens.
            let leftX = b.minX + margin, rightX = b.maxX - margin
            place(.circlePad, CGRect(x: leftX, y: b.midY - pad - margin * 0.5, width: pad, height: pad))
            place(.dpad, CGRect(x: leftX + pad * 0.1, y: b.midY + margin * 0.5, width: pad * 0.8, height: pad * 0.8))
            faceButtons(cx: rightX - face * 1.55, cy: b.midY - face * 0.6)
            place(.button(AZ_BUTTON_L), CGRect(x: leftX, y: b.minY + margin, width: shoulderW, height: shoulderH))
            place(.button(AZ_BUTTON_ZL), CGRect(x: leftX + shoulderW + margin, y: b.minY + margin, width: shoulderW * 0.8, height: shoulderH))
            place(.button(AZ_BUTTON_R), CGRect(x: rightX - shoulderW, y: b.minY + margin, width: shoulderW, height: shoulderH))
            place(.button(AZ_BUTTON_ZR), CGRect(x: rightX - shoulderW * 1.8 - margin, y: b.minY + margin, width: shoulderW * 0.8, height: shoulderH))
            let smallW = unit * 1.25, smallH = unit * 0.5
            place(.button(AZ_BUTTON_SELECT), CGRect(x: rightX - smallW * 2 - margin, y: b.maxY - smallH - margin, width: smallW, height: smallH))
            place(.button(AZ_BUTTON_START), CGRect(x: rightX - smallW, y: b.maxY - smallH - margin, width: smallW, height: smallH))
            place(.button(AZ_BUTTON_HOME), CGRect(x: leftX + pad + margin, y: b.maxY - smallH * 1.4 - margin, width: smallH * 1.4, height: smallH * 1.4))
        } else {
            // Portrait: screens fill the top (PortraitTopFullWidth), controls use the bottom.
            let fallbackTop = b.maxY - min(max(bounds.height * 0.36, 260), 360)
            let top = (portraitControlsTop ?? fallbackTop) + margin * 0.5
            let areaMidY = (top + b.maxY) / 2
            let leftX = b.minX + margin, rightX = b.maxX - margin
            place(.button(AZ_BUTTON_L), CGRect(x: leftX, y: top, width: shoulderW, height: shoulderH))
            place(.button(AZ_BUTTON_ZL), CGRect(x: leftX + shoulderW + margin, y: top, width: shoulderW * 0.8, height: shoulderH))
            place(.button(AZ_BUTTON_R), CGRect(x: rightX - shoulderW, y: top, width: shoulderW, height: shoulderH))
            place(.button(AZ_BUTTON_ZR), CGRect(x: rightX - shoulderW * 1.8 - margin, y: top, width: shoulderW * 0.8, height: shoulderH))
            // Left column: circle pad above the d-pad. Right: ABXY. Centre column (between them):
            // HOME, START, SELECT stacked, so nothing overlaps on narrow phones.
            let controlsTop = top + shoulderH + margin
            let stick = min(pad * 0.9, (b.maxY - controlsTop - margin) * 0.52)
            let dpadSize = stick * 0.85
            place(.circlePad, CGRect(x: leftX, y: controlsTop, width: stick, height: stick))
            place(.dpad, CGRect(x: leftX + (stick - dpadSize) / 2, y: min(controlsTop + stick + margin * 0.3, b.maxY - dpadSize - margin),
                                width: dpadSize, height: dpadSize))
            faceButtons(cx: rightX - face * 1.55, cy: max(controlsTop + face * 1.6, areaMidY - face * 0.3))
            let smallW = unit * 1.1, smallH = unit * 0.5
            let centerX = (leftX + stick + (rightX - face * 3.1)) / 2
            let bottomY = b.maxY - smallH - margin
            place(.button(AZ_BUTTON_SELECT), CGRect(x: centerX - smallW / 2, y: bottomY, width: smallW, height: smallH))
            place(.button(AZ_BUTTON_START), CGRect(x: centerX - smallW / 2, y: bottomY - smallH - margin * 0.6, width: smallW, height: smallH))
            place(.button(AZ_BUTTON_HOME), CGRect(x: centerX - smallH * 0.7, y: bottomY - smallH * 2 - smallH * 1.4 - margin * 1.2,
                                                  width: smallH * 1.4, height: smallH * 1.4))
        }
        controls.forEach { $0.layout() }
    }

    private static func same(_ a: Kind, _ b: Kind) -> Bool {
        switch (a, b) {
        case (.dpad, .dpad), (.circlePad, .circlePad): return true
        case let (.button(x), .button(y)): return x == y
        default: return false
        }
    }

    // MARK: Hit testing

    private func controlIndex(at p: CGPoint, slack: CGFloat = 8) -> Int? {
        for (i, c) in controls.enumerated() {
            let hit = c.frame.insetBy(dx: -slack, dy: -slack)
            if hit.contains(p) { return i }
        }
        return nil
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        !isHidden && alpha > 0.01 && controlIndex(at: point) != nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            guard let idx = controlIndex(at: p) else { continue }
            touchControl[ObjectIdentifier(t)] = idx
            touchPoint[ObjectIdentifier(t)] = p
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            guard let idx = touchControl[id] else { continue }
            let p = t.location(in: self)
            touchPoint[id] = p
            // Let face buttons "slide": a thumb can roll from B to A without lifting.
            if case .button = controls[idx].kind, let newIdx = controlIndex(at: p, slack: 0),
               case .button = controls[newIdx].kind {
                touchControl[id] = newIdx
            }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            touchControl.removeValue(forKey: ObjectIdentifier(t))
            touchPoint.removeValue(forKey: ObjectIdentifier(t))
        }
        update()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    private func update() {
        var buttons = Set<UInt32>()
        var stick = CGPoint.zero
        var stickActive = false
        for c in controls { c.pressed = false }

        for (id, idx) in touchControl {
            guard let p = touchPoint[id] else { continue }
            let c = controls[idx]
            switch c.kind {
            case .button(let b):
                buttons.insert(b.rawValue)
                c.pressed = true
            case .dpad:
                let dx = p.x - c.frame.midX, dy = p.y - c.frame.midY
                let dead = c.frame.width * 0.12
                if hypot(dx, dy) > dead {
                    let twoPi = CGFloat.pi * 2
                    let angle: CGFloat = atan2(-dy, dx) // 0 = right, counter-clockwise
                    let normalized: CGFloat = (angle + twoPi).truncatingRemainder(dividingBy: twoPi)
                    let sector: Int = Int((normalized + CGFloat.pi / 8) / (CGFloat.pi / 4)) % 8
                    let dirs: [[AZButton]] = [[AZ_BUTTON_RIGHT], [AZ_BUTTON_RIGHT, AZ_BUTTON_UP], [AZ_BUTTON_UP],
                                              [AZ_BUTTON_UP, AZ_BUTTON_LEFT], [AZ_BUTTON_LEFT],
                                              [AZ_BUTTON_LEFT, AZ_BUTTON_DOWN], [AZ_BUTTON_DOWN],
                                              [AZ_BUTTON_DOWN, AZ_BUTTON_RIGHT]]
                    dirs[sector].forEach { buttons.insert($0.rawValue) }
                    c.pressed = true
                }
            case .circlePad:
                let radius = c.frame.width / 2
                var dx = (p.x - c.frame.midX) / radius
                var dy = (p.y - c.frame.midY) / radius
                let len = hypot(dx, dy)
                if len > 1 { dx /= len; dy /= len }
                stick = CGPoint(x: dx, y: -dy)
                stickActive = true
                c.pressed = true
                c.moveKnob(dx: dx * radius * 0.6, dy: dy * radius * 0.6)
            }
        }
        if !stickActive, let pad = controls.first(where: { if case .circlePad = $0.kind { return true }; return false }) {
            pad.moveKnob(dx: 0, dy: 0)
        }

        let newlyPressed = buttons.subtracting(pressedButtons)
        for raw in buttons.symmetricDifference(pressedButtons) {
            az_button(AZButton(rawValue: raw), buttons.contains(raw))
        }
        if hapticsEnabled, !newlyPressed.isEmpty { haptic.impactOccurred(intensity: 0.6) }
        pressedButtons = buttons
        az_stick(AZ_STICK_CIRCLE_PAD, Float(stick.x), Float(stick.y))
    }
}
