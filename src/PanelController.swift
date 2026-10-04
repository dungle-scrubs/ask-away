import AppKit
import SwiftUI

/// Key-taking borderless panel that never activates its app (section 10):
/// `orderFront` + `makeKey` take key status for Return/Escape without
/// `activate()`, so the host app keeps focus.
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The panel's view tree. Layer chrome (ambient shadow, masked content,
/// neon border) plus the hosted SwiftUI content and the chamfered buttons.
@MainActor
final class PanelRootView: NSView {

    private(set) var drainLayer: CAShapeLayer?

    func configure(
        size: CGSize,
        title: String,
        markdown: AttributedString,
        countdown: CountdownModel,
        buttons: [ChamferButton],
        bodyHeight: CGFloat
    ) {
        wantsLayer = true
        layer?.masksToBounds = false

        // The window is larger than the visual panel by windowMargin on every
        // side; all chrome is built on the inset panel rect.
        let panelRect = bounds.insetBy(dx: Theme.windowMargin, dy: Theme.windowMargin)
        let panelBounds = NSRect(origin: .zero, size: panelRect.size)

        // Ambient separation shadow on the panel shape (section 4): black,
        // r20, 35%, offset down. Core Animation y-up coordinates flip the
        // spec's CSS-style "down 4" sign.
        let ambient = CAShapeLayer()
        let shapePath = Chamfer.path(cut: Theme.panelCut, in: panelRect)
        ambient.path = shapePath
        ambient.fillColor = NSColor.black.cgColor
        ambient.shadowColor = NSColor.black.cgColor
        ambient.shadowRadius = Theme.ambientRadius
        ambient.shadowOpacity = Theme.ambientOpacity
        ambient.shadowOffset = CGSize(width: 0, height: -4)
        ambient.shadowPath = shapePath
        ambient.masksToBounds = false
        ambient.zPosition = -10
        layer?.addSublayer(ambient)

        // Content container masked by the chamfer path - the same CGPath
        // that draws the border (section 10: built once, used three times;
        // the ambient backplate above is the third use).
        let content = NSView(frame: panelRect)
        content.wantsLayer = true
        let maskShape = CAShapeLayer()
        maskShape.frame = NSRect(origin: .zero, size: panelRect.size)
        maskShape.path = Chamfer.path(cut: Theme.panelCut, in: panelBounds)
        content.layer?.mask = maskShape
        addSubview(content)

        let effect = NSVisualEffectView(frame: panelBounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        content.addSubview(effect)

        let scrim = NSView(frame: panelBounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = Theme.panelBase.withAlphaComponent(0.9).cgColor
        content.addSubview(scrim)

        let hostingFrame = NSRect(
            x: Theme.horizontalPadding,
            y: Theme.bottomPadding + Theme.buttonRowHeight + Theme.bodyToButtons,
            width: panelRect.width - 2 * Theme.horizontalPadding,
            height: Theme.metadataHeight + Theme.metadataToBody + bodyHeight
        )
        let hosting = NSHostingView(
            rootView: PanelContentView(
                title: title,
                bodyMarkdown: markdown,
                bodyWidth: hostingFrame.width,
                countdown: countdown
            )
        )
        hosting.frame = hostingFrame
        content.addSubview(hosting)

        placeButtons(buttons, in: content, size: panelRect.size)

        // Drain line: 2pt along the bottom edge, full inner width (section 6).
        // High zPosition: AppKit keeps view-backed sublayers above plain
        // sublayers regardless of insertion order, so the line must pin itself.
        let drain = CAShapeLayer()
        drain.fillColor = Theme.accent.cgColor
        drain.zPosition = 100
        drain.actions = ["path": NSNull()]
        content.layer?.addSublayer(drain)
        drainLayer = drain

        // Neon border, section 4: the glow is one layer (shadow of the panel
        // shape, behind the content so it reads as an outer halo), the 1px
        // accent hairline another (above the content, crisp at the edges).
        let glow = CAShapeLayer()
        glow.path = shapePath
        glow.fillColor = NSColor.clear.cgColor
        glow.shadowColor = Theme.accent.cgColor
        glow.shadowRadius = Theme.glowRadius
        glow.shadowOpacity = Theme.glowOpacity
        glow.shadowOffset = .zero
        glow.shadowPath = shapePath
        glow.masksToBounds = false
        glow.zPosition = -5
        layer?.addSublayer(glow)

        let border = CAShapeLayer()
        let borderPath = Chamfer.borderPath(cut: Theme.panelCut, in: panelRect)
        border.path = borderPath
        border.strokeColor = Theme.accent.cgColor
        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1
        border.masksToBounds = false
        // AppKit orders view-backed sublayers above plain sublayers regardless
        // of insertion order; the chrome pins itself with zPosition instead.
        border.zPosition = 10
        layer?.addSublayer(border)
    }

    /// The transparent margin is decoration room, not hit area: clicks there
    /// fall through instead of landing on an invisible band of window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let panelRect = bounds.insetBy(dx: Theme.windowMargin, dy: Theme.windowMargin)
        guard panelRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    private func placeButtons(_ buttons: [ChamferButton], in content: NSView, size: CGSize) {
        let widths = buttons.map { ChamferButton.width(for: $0.buttonTitle, kind: $0.kind) }
        let totalWidth = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * Theme.buttonGap
        var x = size.width - Theme.horizontalPadding - totalWidth
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(
                x: x,
                y: Theme.bottomPadding,
                width: width,
                height: Theme.buttonRowHeight
            )
            content.addSubview(button)
            x += width + Theme.buttonGap
        }
    }
}

/// Owns one question: builds the panel, runs the app loop, prints the
/// outcome, and exits with the contract code. One process per invocation.
@MainActor
final class PanelController {

    enum Outcome {
        case answered(String)
        case canceled
        case gaveUp

        var stdout: String {
            switch self {
            case let .answered(text): return text
            case .canceled: return "CANCELED"
            case .gaveUp: return "GAVE-UP"
            }
        }

        var exitCode: Int32 {
            switch self {
            case .answered: return 0
            case .canceled: return 2
            case .gaveUp: return 3
            }
        }
    }

    private let question: Question
    private var panel: AskPanel?
    private var root: PanelRootView?
    private var keyMonitor: Any?
    private var ticker: DrainTicker?
    private var deadline: Date?
    private var boundSeconds: Double = 1
    private var finished = false
    private var screenID = ""
    private var panelSize: CGSize = .zero
    private let countdown = CountdownModel()

    init(question: Question) {
        self.question = question
    }

    /// Never returns: exits the process with the outcome's contract code
    /// after the exit animation.
    func run() -> Never {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? NSScreen.main
        else {
            FileHandle.standardError.write(Data("ask-away: no screen available\n".utf8))
            exit(1)
        }
        screenID = Self.screenIdentifier(for: screen)
        let cascadeIndex = Cascade.claimIndex(screenID: screenID)

        let markdown = PanelContentView.prepareBody(question.text)
        let (width, bodyHeight) = Self.pickDimensions(markdown: markdown)
        panelSize = CGSize(
            width: width,
            height: Theme.topPadding + Theme.metadataHeight + Theme.metadataToBody + bodyHeight
                + Theme.bodyToButtons + Theme.buttonRowHeight + Theme.bottomPadding
        )

        buildPanel(screen: screen, cascadeIndex: cascadeIndex, markdown: markdown, bodyHeight: bodyHeight)
        showAndAnimate()

        if let bound = question.giveUpAfter {
            boundSeconds = bound
            deadline = Date().addingTimeInterval(bound)
            let ticker = DrainTicker { [weak self] in self?.tick() }
            ticker.start()
            self.ticker = ticker
            tick()
        }

        if question.beep {
            NSSound.beep()
        }

        NSApp.run()
        fatalError("NSApplication.run() returned; the process exits from finish(_:)")
    }

    // MARK: Window construction

    private func buildPanel(screen: NSScreen, cascadeIndex: Int, markdown: AttributedString, bodyHeight: CGFloat) {
        let visualFrame = Self.placement(size: panelSize, screen: screen, cascadeIndex: cascadeIndex)
        // The window is larger than the visual panel: transparent margin for
        // the outer glow, the ambient shadow, and clear of the system's
        // rounded-window edge treatment.
        let windowFrame = visualFrame.insetBy(dx: -Theme.windowMargin, dy: -Theme.windowMargin)
        let panel = AskPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The spec's "becomesKeyOnlyOnClick = false" maps to this API: a
        // panel becomes key on click, and we take key explicitly via makeKey().
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = question.title
        panel.isReleasedWhenClosed = false

        let buttons: [ChamferButton] = question.buttons.enumerated().map { index, title in
            let button = ChamferButton(
                title: title,
                kind: index == question.defaultIndex ? .defaultFilled : .ghost
            )
            button.target = self
            button.action = #selector(buttonClicked(_:))
            return button
        }

        let root = PanelRootView(frame: NSRect(origin: .zero, size: windowFrame.size))
        root.configure(
            size: panelSize,
            title: question.title,
            markdown: markdown,
            countdown: countdown,
            buttons: buttons,
            bodyHeight: bodyHeight
        )
        panel.contentView = root

        // Return plumbing: the default button cell drives Return for the
        // panel and VoiceOver alike (section 10).
        panel.defaultButtonCell = buttons[question.defaultIndex].cell as? NSButtonCell

        // Tab cycling across the row for full-keyboard-access users (section 5).
        for (button, next) in zip(buttons, buttons.dropFirst()) {
            button.nextKeyView = next
        }

        // Escape is not free in a borderless panel: bind it via a local
        // keyDown monitor (section 10).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finished else { return event }
            if event.keyCode == 53 {
                self.finish(.canceled)
                return nil
            }
            return event
        }

        self.panel = panel
        self.root = root
    }

    /// Screen holding the pointer, horizontally centered, top edge at 42% of
    /// screen height; cascade offset +24pt per index down-right, wrapped
    /// modulo 6, clamped to a 24pt margin inside the visible frame (section 9).
    static func placement(size: CGSize, screen: NSScreen, cascadeIndex: Int) -> NSRect {
        let screenFrame = screen.frame
        let baseX = screenFrame.midX - size.width / 2
        let baseY = screenFrame.minY + screenFrame.height * 0.42 - size.height

        func frameWith(offset: Int) -> NSRect {
            NSRect(
                x: baseX + CGFloat(offset) * 24,
                y: baseY + CGFloat(offset) * 24,
                width: size.width,
                height: size.height
            )
        }

        let candidate = frameWith(offset: cascadeIndex % 6)
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let fits = candidate.minX >= visible.minX + margin
            && candidate.maxX <= visible.maxX - margin
            && candidate.minY >= visible.minY + margin
            && candidate.maxY <= visible.maxY - margin
        return fits ? candidate : frameWith(offset: 0)
    }

    /// Width rule (section 1): smallest of 340/420/520 where the body fits in
    /// 2 lines measured in the real renderer; otherwise the largest width and
    /// a taller body capped at 4 lines.
    static func pickDimensions(markdown: AttributedString) -> (width: CGFloat, bodyHeight: CGFloat) {
        let cap = CGFloat(Theme.maxBodyLines) * Theme.bodyLineHeight
        var overflowHeight: CGFloat = 0
        for candidate in Theme.widthCandidates {
            let height = BodyMeasurer.height(markdown: markdown, width: candidate)
            if height <= Theme.twoLineBudget + 0.5 {
                return (candidate, min(height, cap))
            }
            overflowHeight = height
        }
        return (Theme.widthCandidates.last!, min(overflowHeight, cap))
    }

    private static func screenIdentifier(for screen: NSScreen) -> String {
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return displayID.uint32Value.description
        }
        return screen.localizedName
    }

    // MARK: Show and animate

    private func showAndAnimate() {
        guard let panel, let layer = root?.layer else { return }
        panel.orderFront(nil)
        panel.makeKey()
        animateEntrance(layer: layer)
    }

    /// Entrance: opacity 0->1 and scale 0.98->1.0 about the center, 180ms,
    /// CubicBezier(0.2, 0.8, 0.2, 1); opacity-only 100ms under Reduce Motion
    /// (section 7).
    private func animateEntrance(layer: CALayer) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? Theme.reduceMotionEntranceDuration : Theme.entranceDuration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        if !reduceMotion {
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = CATransform3DMakeScale(0.98, 0.98, 1)
            scale.toValue = CATransform3DIdentity
            scale.duration = duration
            scale.timingFunction = Theme.mainCurve
            layer.add(scale, forKey: "entrance.scale")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = duration
        fade.timingFunction = Theme.mainCurve
        layer.add(fade, forKey: "entrance.opacity")
    }

    // MARK: Countdown

    private func tick() {
        guard !finished, let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            updateCountdown(remaining: 0)
            ticker?.stop()
            finish(.gaveUp)
            return
        }
        updateCountdown(remaining: remaining)
    }

    private func updateCountdown(remaining: TimeInterval) {
        countdown.secondsLeft = Int(remaining.rounded(.up))
        let fraction = boundSeconds > 0 ? max(0, min(1, remaining / boundSeconds)) : 0
        let color = Theme.rampColor(remainingFraction: fraction)
        countdown.color = SwiftUI.Color(nsColor: color)

        guard let drainLayer = root?.drainLayer else { return }
        let width = (panelSize.width - Theme.drainLineWidth) * CGFloat(fraction)
        // Width moves continuously; color steps crossfade over 300ms (section 7).
        // The line sits just inside the border stroke (section 6): y 1..3.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drainLayer.path = CGPath(
            rect: CGRect(x: 0, y: 1, width: width, height: Theme.drainLineHeight),
            transform: nil
        )
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(Theme.drainCrossfade)
        drainLayer.fillColor = color.cgColor
        CATransaction.commit()
    }

    // MARK: Outcomes

    @objc private func buttonClicked(_ sender: ChamferButton) {
        guard !finished else { return }
        // A button named "Cancel" maps to CANCELED (predecessor contract).
        if sender.buttonTitle == "Cancel" {
            finish(.canceled)
        } else {
            finish(.answered(sender.buttonTitle))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true

        print(outcome.stdout)
        fflush(stdout)
        Cascade.release(screenID: screenID)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        ticker?.stop()
        ticker = nil

        // Exit: opacity -> 0 and scale -> 1.01, 140ms, same curve; opacity-
        // only 100ms under Reduce Motion (section 7).
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? Theme.reduceMotionExitDuration : Theme.exitDuration
        if let layer = root?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.transform = CATransform3DMakeScale(1.01, 1.01, 1)
            CATransaction.commit()

            if !reduceMotion {
                let scale = CABasicAnimation(keyPath: "transform")
                scale.toValue = CATransform3DMakeScale(1.01, 1.01, 1)
                scale.duration = duration
                scale.timingFunction = Theme.mainCurve
                layer.add(scale, forKey: "exit.scale")
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = Theme.mainCurve
            layer.add(fade, forKey: "exit.opacity")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.close()
            exit(outcome.exitCode)
        }
    }
}
