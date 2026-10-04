import AppKit

/// One chamfered button (design.md sections 2, 4, 5).
///
/// A real NSButton subclass so `panel.defaultButtonCell` gets a real cell:
/// that is what drives Return for the panel and VoiceOver alike (section 10).
/// Visuals are layer-drawn: 7pt top-left and bottom-right cuts, the section 2
/// state table for fill/border/label, and the default button's own r8 glow.
@MainActor
final class ChamferButton: NSButton {

    enum Kind {
        case ghost
        case defaultFilled
    }

    private enum VisualState {
        case idle, hover, pressed
    }

    let kind: Kind
    private var isHovered = false { didSet { restyle() } }
    private var isPressed = false { didSet { restyle() } }
    private var isFocused = false { didSet { restyle() } }
    private let borderLayer = CAShapeLayer()
    private var trackingArea: NSTrackingArea?

    init(title: String, kind: Kind) {
        self.kind = kind
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.buttonMinWidth, height: Theme.buttonRowHeight))
        self.title = title
        setAttributedTitle(labelColor: kind == .ghost ? Theme.textBody : Theme.buttonDarkLabel)
        isBordered = false
        alignment = .center
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        if kind == .defaultFilled {
            keyEquivalent = "\r"
            keyEquivalentModifierMask = []
        }
        wantsLayer = true
        layer?.masksToBounds = false
        if let layer {
            layer.mask = CAShapeLayer()
            borderLayer.fillColor = NSColor.clear.cgColor
            layer.addSublayer(borderLayer)
        }
        updateTrackingAreas()
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ChamferButton is created in code only")
    }

    var buttonTitle: String { self.title }

    /// Width per section 5: label + 16pt padding each side, floor 64pt.
    static func width(for title: String, kind: Kind) -> CGFloat {
        let font = kind == .ghost ? Theme.buttonGhostFont : Theme.buttonDefaultFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let labelWidth = (title as NSString).size(withAttributes: attributes).width
        return max(Theme.buttonMinWidth, ceil(labelWidth) + 2 * Theme.buttonHPadding)
    }

    // MARK: Interaction state

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { isFocused = true }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isFocused = false }
        return resigned
    }

    override func layout() {
        super.layout()
        refreshShapes()
    }

    // MARK: Visual state machine (section 2 table)

    private var visualState: VisualState {
        if isPressed { return .pressed }
        // A focused (or hovered) ghost button shows the hover treatment (section 5).
        if isHovered || (isFocused && kind == .ghost) { return .hover }
        return .idle
    }

    private func restyle() {
        guard let layer else { return }
        let state = visualState
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : Theme.hoverCrossfade)
        switch (kind, state) {
        case (.ghost, .idle):
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.02).cgColor
            borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
            setAttributedTitle(labelColor: Theme.textBody)
        case (.ghost, .hover):
            layer.backgroundColor = Theme.accent.withAlphaComponent(0.08).cgColor
            borderLayer.strokeColor = Theme.accent.withAlphaComponent(0.65).cgColor
            setAttributedTitle(labelColor: .white)
        case (.ghost, .pressed):
            layer.backgroundColor = Theme.accent.withAlphaComponent(0.16).cgColor
            borderLayer.strokeColor = Theme.accent.cgColor
            setAttributedTitle(labelColor: .white)
        case (.defaultFilled, .idle):
            layer.backgroundColor = Theme.accent.cgColor
            setAttributedTitle(labelColor: Theme.buttonDarkLabel)
        case (.defaultFilled, .hover):
            layer.backgroundColor = Theme.accentHover.cgColor
            setAttributedTitle(labelColor: Theme.buttonDarkLabel)
        case (.defaultFilled, .pressed):
            layer.backgroundColor = Theme.accentPressed.cgColor
            setAttributedTitle(labelColor: Theme.buttonDarkLabel)
        }
        CATransaction.commit()

        // The default button carries its own smaller glow (r8, 35%); ghosts have none.
        if kind == .defaultFilled {
            layer.shadowColor = Theme.accent.cgColor
            layer.shadowRadius = Theme.defaultGlowRadius
            layer.shadowOpacity = Theme.defaultGlowOpacity
            layer.shadowOffset = .zero
            layer.shadowPath = Chamfer.path(cut: Theme.buttonCut, in: bounds)
        } else {
            layer.shadowOpacity = 0
        }
    }

    private func refreshShapes() {
        guard let layer, let mask = layer.mask as? CAShapeLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = Chamfer.path(cut: Theme.buttonCut, in: bounds)
        borderLayer.frame = bounds
        borderLayer.path = Chamfer.borderPath(cut: Theme.buttonCut, in: bounds)
        if kind == .defaultFilled {
            layer.shadowPath = Chamfer.path(cut: Theme.buttonCut, in: bounds)
        }
        CATransaction.commit()
    }

    private func setAttributedTitle(labelColor: NSColor) {
        let font = kind == .ghost ? Theme.buttonGhostFont : Theme.buttonDefaultFont
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font,
                .kern: Theme.buttonKerning,
                .foregroundColor: labelColor,
            ]
        )
    }

    private func kindRelatedSetup() {}
}
