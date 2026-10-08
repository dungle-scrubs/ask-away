import AppKit
import SwiftUI

/// Key-taking borderless panel that never activates its app (section 10):
/// `orderFront` + `makeKey` take key status for Return/Escape without
/// `activate()`, so the host app keeps focus.
final class AskPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One step of an invocation, fully prepared for layout: parsed body blocks
/// and, after sizing, the natural stack height at the chosen width.
@MainActor
struct PreparedStep {
    let question: Question
    var blocks: [BodyBlocks.Block]
    var naturalHeight: CGFloat = 0
}

/// A plain container transparent to hit-testing: children receive their
/// own hits, the container itself is not a mouse surface. Without this the
/// chrome containers swallow background mouse-downs and the root's drag
/// session (section 10) never starts - the regression the v0.3.0 screen
/// round exposed in the v0.2.0 tree.
@MainActor
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The vibrancy layer with the same pass-through rule.
@MainActor
final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The panel's view tree. Layer chrome (ambient shadow, masked content,
/// neon border) plus the hosted SwiftUI content and the chamfered buttons.
/// The step-swappable region (metadata, body, buttons) lives in one
/// `contentStack` container so a §12 transition can snapshot and crossfade
/// it while chamfer, border, glow, scrim, and drain line persist untouched.
@MainActor
final class PanelRootView: NSView {

    private(set) var drainLayer: CAShapeLayer?
    /// The masked content container (vibrancy + scrim + step content).
    private(set) var contentContainer: NSView?
    /// The step-swappable container above the scrim (section 10).
    private(set) var contentStack: NSView?
    private(set) var bodyDocument: NSHostingView<BodyDocumentView>?
    private(set) var metadataHost: NSHostingView<MetadataContentView>?
    private(set) var buttons: [ChamferButton] = []
    private(set) var closeButton: ChamferButton?
    private(set) var answerField: AnswerField?
    /// Invoked on a background mouse-down (the drag surface) so the panel
    /// can blur the field without committing (section 13).
    var onBackgroundMouseDown: (() -> Void)?
    /// Body link rectangles in document-view coordinates, for the mouse-moved
    /// cursor check (v0.1.1 amendment, section 8).
    private var linkRects: [NSRect] = []
    private var cursorArea: NSTrackingArea?

    func configure(
        title: String,
        model: StepModel,
        countdown: CountdownModel,
        blocks: [BodyBlocks.Block],
        naturalHeight: CGFloat,
        bodyWidth: CGFloat,
        bodyRegion: CGFloat,
        buttonRows: [[CGFloat]],
        buttons: [ChamferButton],
        closeButton: ChamferButton,
        field: AnswerField
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
        let content = PassthroughView(frame: panelRect)
        content.wantsLayer = true
        let maskShape = CAShapeLayer()
        maskShape.frame = NSRect(origin: .zero, size: panelRect.size)
        maskShape.path = Chamfer.path(cut: Theme.panelCut, in: panelBounds)
        content.layer?.mask = maskShape
        addSubview(content)
        contentContainer = content

        let effect = PassthroughEffectView(frame: panelBounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        content.addSubview(effect)

        let scrim = PassthroughView(frame: panelBounds)
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = Theme.panelBase.withAlphaComponent(0.9).cgColor
        content.addSubview(scrim)

        // The step-swappable container (sections 7 and 12): metadata row,
        // body scroll, buttons. Never the vibrancy or scrim - a scrim fade
        // would flash the desktop through the panel.
        let stack = PassthroughView(frame: panelBounds)
        stack.wantsLayer = true
        content.addSubview(stack)
        contentStack = stack

        // Metadata row hosting: fixed 14pt band at the top (section 1).
        let metadataFrame = NSRect(
            x: Theme.horizontalPadding,
            y: panelRect.height - Theme.topPadding - Theme.metadataHeight,
            width: panelRect.width - 2 * Theme.horizontalPadding - 32,
            height: Theme.metadataHeight
        )
        let metadata = NSHostingView(
            rootView: MetadataContentView(title: title, model: model)
        )
        metadata.frame = metadataFrame
        stack.addSubview(metadata)
        metadataHost = metadata

        closeButton.frame = NSRect(x: panelRect.width - 40, y: panelRect.height - 40, width: 28, height: 28)
        content.addSubview(closeButton)
        self.closeButton = closeButton

        let seconds = NSHostingView(rootView: CountdownView(countdown: countdown))
        seconds.frame = NSRect(x: Theme.horizontalPadding, y: Theme.countdownY, width: 80, height: Theme.metadataHeight)
        content.addSubview(seconds)

        // Body region: the only elastic element (section 1). An explicit
        // NSScrollView so scroller style is forced overlay regardless of the
        // system's scroll-bar setting - never a reserved gutter (section 10).
        // The answer field block (section 13) sits under the button row,
        // above the countdown band, so the body's bottom rises by the same
        // amount the buttons shifted.
        let bodyFrame = NSRect(
            x: Theme.horizontalPadding,
            y: Theme.contentBaseY + Theme.fieldBlockHeight + buttonBlockHeight(rows: buttonRows) + Theme.bodyToButtons,
            width: panelRect.width - 2 * Theme.horizontalPadding,
            height: bodyRegion
        )
        let scroll = Self.makeBodyScroll()
        scroll.frame = bodyFrame
        let document = NSHostingView(rootView: BodyDocumentView(blocks: blocks, width: bodyWidth))
        document.frame = NSRect(origin: .zero, size: CGSize(width: bodyWidth, height: max(naturalHeight, 1)))
        scroll.documentView = document
        stack.addSubview(scroll)
        bodyDocument = document

        updateLinkCursor(blocks: blocks, width: bodyWidth, viewHeight: max(naturalHeight, 1))

        swapButtons(buttons, rows: buttonRows)

        // The answer field (section 13): full inner width above the
        // countdown band, inside contentStack so the section 12 transition
        // snapshots it with the rest of the step content. It is added after
        // the buttons so the AX element order follows them.
        field.place(in: NSRect(
            x: Theme.horizontalPadding,
            y: Theme.contentBaseY,
            width: panelRect.width - 2 * Theme.horizontalPadding,
            height: Theme.answerFieldHeight
        ))
        stack.addSubview(field)
        answerField = field

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

    /// Body scroll view: overlay scrollers, light knobs, no background, no
    /// border (section 10).
    static func makeBodyScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        return scroll
    }

    private func buttonBlockHeight(rows: [[CGFloat]]) -> CGFloat {
        return CGFloat(rows.count) * Theme.buttonRowHeight
            + CGFloat(rows.count - 1) * Theme.secondRowGap
    }

    /// The transparent margin is decoration room, not hit area: clicks there
    /// fall through instead of landing on an invisible band of window.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let panelRect = bounds.insetBy(dx: Theme.windowMargin, dy: Theme.windowMargin)
        guard panelRect.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Keep the mouse-down's tracking session in AppKit instead of handing
    /// this nonactivating, transparent window to the native window-drag loop.
    /// Controls consume their own mouse-down before it reaches this view.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBackgroundMouseDown?()
        let origin = window.frame.origin
        let anchor = window.convertPoint(toScreen: event.locationInWindow)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .scrollWheel], timeout: .greatestFiniteMagnitude, mode: .eventTracking) { next, stop in
            guard let next else { stop.pointee = true; return }
            if next.type == .leftMouseUp {
                stop.pointee = true
            } else if next.type == .leftMouseDragged {
                let point = window.convertPoint(toScreen: next.locationInWindow)
                window.setFrameOrigin(NSPoint(x: origin.x + point.x - anchor.x, y: origin.y + point.y - anchor.y))
            }
        }
    }

    /// Cursor affordance for markdown links in the body (v0.1.1 amendment,
    /// section 8): store the link rectangles derived from the TextKit layout;
    /// the mouse-moved handler checks them per move. Re-run per step swap.
    func updateLinkCursor(blocks: [BodyBlocks.Block], width: CGFloat, viewHeight: CGFloat) {
        linkRects = LinkRects.inDocument(
            blocks: blocks,
            width: width,
            viewHeight: viewHeight,
            hostIsFlipped: bodyDocument?.isFlipped ?? false
        )
        if cursorArea == nil {
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            cursorArea = area
        }
    }

    /// The panel never activates, so WindowServer-managed cursor rects and
    /// cursorUpdate tracking do not engage here. The pointer is set from the
    /// delivered mouse-moved events instead: pointing hand over buttons and
    /// body links, arrow elsewhere (v0.1.1 amendment, section 8). The hit
    /// test reads NSEvent.mouseLocation and view-geometry conversions - the
    /// posted event locations proved unreliable to map in this window.
    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        let controls = buttons + (closeButton.map { [$0] } ?? [])
        let overButton = controls.contains { button in
            window.convertToScreen(button.convert(button.bounds, to: nil)).contains(global)
        }
        if let answerField {
            let fieldRect = window.convertToScreen(answerField.convert(answerField.bounds, to: nil))
            if fieldRect.contains(global) {
                NSCursor.iBeam.set()
                return
            }
        }
        var overLink = false
        if let bodyDocument, !linkRects.isEmpty {
            // Panel-local arithmetic from design constants and the doc's
            // visible rect - no NSView.convert: this window's event and view
            // conversions proved unreliable (measured), while window.frame
            // and NSEvent.mouseLocation share the AppKit-global space the
            // cascade placement already uses. Body top offset is fixed by
            // section 1: 18 top + 14 metadata + 10 gap.
            let visible = bodyDocument.visibleRect
            let panelX = window.frame.minX + Theme.windowMargin
            let panelTopY = window.frame.maxY - Theme.windowMargin
            let bodyTopOffset = Theme.topPadding + Theme.metadataHeight + Theme.metadataToBody
            for rect in linkRects {
                let left = panelX + Theme.horizontalPadding + rect.minX - visible.minX
                let top = panelTopY - bodyTopOffset - (rect.minY - visible.minY)
                if NSRect(x: left, y: top - rect.height, width: rect.width, height: rect.height).contains(global) {
                    overLink = true
                    break
                }
            }
        }
        (overLink || overButton ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Swap in a new step's buttons: remove the old row, place the new one.
    /// Rows are right-aligned; a wrapped second row sits below with the 8pt
    /// gap, both rows right-aligned, reading order preserved, and every
    /// button keeps its full 30 x width frame - wrapping never shrinks hit
    /// targets (section 12). The whole block sits above the answer field's
    /// band and the countdown band (section 13; Theme.contentBaseY).
    func swapButtons(_ newButtons: [ChamferButton], rows: [[CGFloat]]) {
        for button in buttons {
            button.removeFromSuperview()
        }
        buttons = newButtons
        guard let contentStack else { return }
        let panelWidth = contentStack.bounds.width
        var index = 0
        let rowCount = rows.count
        for (rowIndex, row) in rows.enumerated() {
            let totalWidth = row.reduce(0, +) + CGFloat(max(0, row.count - 1)) * Theme.buttonGap
            var x = panelWidth - Theme.horizontalPadding - totalWidth
            // First row on top when wrapped; the tail row sits at the bottom.
            let y = Theme.contentBaseY + Theme.fieldBlockHeight
                + CGFloat(rowCount - 1 - rowIndex) * (Theme.buttonRowHeight + Theme.secondRowGap)
            for width in row {
                guard index < newButtons.count else { break }
                let button = newButtons[index]
                button.frame = NSRect(x: x, y: y, width: width, height: Theme.buttonRowHeight)
                contentStack.addSubview(button)
                x += width + Theme.buttonGap
                index += 1
            }
        }
    }

    /// Snapshot of the step-swappable content for a §12 crossfade: render the
    /// contentStack's layer tree into an image layer placed exactly over it.
    func snapshotContent() -> CALayer? {
        guard let contentStack, let contentLayer = contentStack.layer else { return nil }
        let bounds = contentStack.bounds
        let scale = window?.backingScaleFactor ?? 2
        guard
            let context = CGContext(
                data: nil,
                width: max(1, Int(bounds.width * scale)),
                height: max(1, Int(bounds.height * scale)),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        // No manual flip here: CALayer.render(in:) on this AppKit view-backed
        // layer tree already yields a bitmap whose first row is the tree's
        // top, so a top-down CGImage assigned to contents displays right side
        // up. The old translate+scale(1,-1) recipe double-flipped it and the
        // outgoing content crossfaded upside down (frame-verified).
        context.scaleBy(x: scale, y: scale)
        contentLayer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let layer = CALayer()
        layer.contents = image
        layer.frame = contentStack.frame
        layer.zPosition = 100
        layer.masksToBounds = true
        return layer
    }
}

/// Production escalation effects against the live panel, in the section 14
/// order. The activation spelling is the macOS 13 floor-legal one; the
/// macOS 14 deprecation is expected and must not be upgraded past the
/// floor. Lives beside the panel it drives (AttentionController stays
/// compilable without the UI tree, so detection tests can exercise the
/// engine headlessly).
@MainActor
final class PanelAttentionEffects: AttentionEffectsObserver {
    private weak var panel: AskPanel?

    init(panel: AskPanel) {
        self.panel = panel
    }

    func activateApplication() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeKeyAndOrderFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func raiseLevelToScreenSaver() {
        panel?.level = .screenSaver
    }

    func playEscalationBeep(index: Int) {
        NSSound.beep()
    }

    func playAppearBeep() {
        NSSound.beep()
    }
}

/// Owns one invocation - a single question or a §12 sequence. Builds the
/// panel, runs the app loop, prints the outcome, and exits with the
/// contract code. One process per invocation; a sequence is one panel and
/// one cascade slot (section 9).
@MainActor
final class PanelController {

    enum Outcome {
        case answered(String)
        case canceled
        case gaveUp
        case closed

        var stdout: String {
            switch self {
            case let .answered(text): return text
            case .canceled: return "CANCELED"
            case .gaveUp: return "GAVE-UP"
            case .closed: return "CLOSED"
            }
        }

        var exitCode: Int32 {
            switch self {
            case .answered: return 0
            case .canceled: return 2
            case .gaveUp: return 3
            case .closed: return 4
            }
        }
    }

    /// One entry of the §12 batch output.
    struct StepResult {
        let index: Int
        let status: String
        let answer: String?
    }

    private var steps: [PreparedStep]
    private let isBatch: Bool
    private var currentStep = 0
    private var results: [StepResult] = []
    private var panel: AskPanel?
    private var root: PanelRootView?
    private var keyMonitor: Any?
    /// Interaction marker (round-2 regression fix): the first key or
    /// mouse event that reaches the panel stands down the initial-focus
    /// pin for the rest of the invocation. The pin exists only to undo
    /// the makeKey key-view steal at launch; once real interaction has
    /// begun, focus belongs to the interaction - NSApp.currentEvent
    /// sniffing in editingBegan cannot be relied on for posted or
    /// deferred transitions.
    private var interactionsStarted = false
    private var mouseMonitor: Any?
    private var ticker: DrainTicker?
    private var deadline: Date?
    private var boundSeconds: Double = 1
    private var finished = false
    private var screenID = ""
    private var panelSize: CGSize = .zero
    private var bodyWidth: CGFloat = 0
    private var bodyRegion: CGFloat = 0
    private var buttonRows: [[[CGFloat]]] = []
    private let model = StepModel()
    /// Per-tick countdown state, isolated from StepModel: a tick re-renders
    /// only the seconds text, never the title, indicator, or body.
    private let countdown = CountdownModel()
    /// True until the first Tab after a step starts: one Tab from the
    /// pinned initial focus must reach the field (section 13).
    private var freshTabPending = true
    private var initialDefaultButton: ChamferButton?
    private var currentDefaultButton: ChamferButton?
    private var fieldEditorProvider: AnswerFieldEditorProvider?
    /// Guards the printable-capture redispatch against monitor recursion.
    private var redispatchingFieldEvent = false
    private let attention: AttentionConfig
    /// Constructor-injected attention dependencies: the simulator's seam.
    /// nil means live production defaults.
    private let attentionDependencies: AttentionDependencies?
    private var attentionController: AttentionController?

    /// - Parameters:
    ///   - questions: one question, or a validated §12 sequence in file order.
    ///   - batch: true when the invocation came through --questions-file;
    ///     batch output is the JSON contract even for a single-question file.
    ///   - attention: invocation-level attention configuration; `.disabled`
    ///     instantiates no detector or discovery tasks at all.
    ///   - dependencies: injected probe/effects/clock/trace; nil selects the
    ///     live production set.
    init(
        questions: [Question],
        batch: Bool,
        attention: AttentionConfig = .standard,
        dependencies: AttentionDependencies? = nil
    ) {
        self.steps = questions.map { PreparedStep(question: $0, blocks: BodyBlocks($0.text).blocks) }
        self.isBatch = batch
        self.attention = attention
        self.attentionDependencies = dependencies
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

        let sizing = Self.size(prepared: &steps, screen: screen, allowWrap: isBatch)
        bodyWidth = sizing.width - 2 * Theme.horizontalPadding
        bodyRegion = sizing.panelHeight - Theme.chromeHeight(wrappedRows: sizing.anyWrap)
        panelSize = CGSize(width: sizing.width, height: sizing.panelHeight)
        buttonRows = steps.map { step in
            Self.buttonRows(
                question: step.question,
                innerWidth: sizing.width - 2 * Theme.horizontalPadding,
                allowWrap: isBatch
            ).0
        }
        buildPanel(screen: screen, cascadeIndex: cascadeIndex)
        showAndAnimate()

        // Step-0 model state that loadStep would otherwise only set on a
        // transition: the k/n indicator must show from the first frame.
        model.stepIndex = 1
        model.stepCount = steps.count
        model.indicator = isBatch && steps.count > 1 ? "1/\(steps.count)" : nil

        // One beep per invocation (sections 6, 12, 14). With attention on,
        // the appear beep waits for the first attention evaluation (within
        // 1s of appear): single for VISIBLE/UNKNOWN, the escalation triple
        // for ABSENT. With --no-attention, exactly the v0.2.0 immediate
        // beep at the moment the panel appears.
        let beepAllowed = steps.allSatisfy { $0.question.beep }
        if attention.enabled {
            guard let panel else { fatalError("attention started without a panel") }
            let dependencies = attentionDependencies ?? AttentionDependencies(
                probe: LiveAttentionEngine(),
                effects: PanelAttentionEffects(panel: panel),
                clock: .live,
                trace: nil
            )
            let controller = AttentionController(
                config: attention,
                beepAllowed: beepAllowed,
                dependencies: dependencies
            )
            controller.start()
            attentionController = controller
        } else if beepAllowed {
            NSSound.beep()
        }

        startTiming()
        if isBatch, steps.count > 1 {
            announceStep(currentStep)
        }

        NSApp.run()
        fatalError("NSApplication.run() returned; the process exits from finish(_:)")
    }

    // MARK: Sizing (sections 1, 11, 12)

    struct Sizing {
        var width: CGFloat
        var panelHeight: CGFloat
        var naturalHeights: [CGFloat]
        var anyWrap: Bool
    }

    /// Width: smallest of 340/420/520 at which every body fits in 2 lines
    /// (the rendered block stack, measured); otherwise 520. Height: the max
    /// per-question height under the §1 formula and caps; the body region is
    /// the only elastic element and scrolls beyond its cap. Ellipsis
    /// truncation does not exist. Also pins each code chip's rendered height
    /// (capped at 25% of the visible frame) into the step's blocks, so the
    /// render view and the measurement agree by construction.
    static func size(prepared: inout [PreparedStep], screen: NSScreen, allowWrap: Bool) -> Sizing {
        let visibleHeight = screen.visibleFrame.height
        let bodyCap = Theme.bodyCapFraction * visibleHeight
        let panelCap = Theme.panelCapFraction * visibleHeight
        let chipCap = Theme.codeChipCapFraction * visibleHeight

        var width = Theme.widthCandidates.last!
        for candidate in Theme.widthCandidates {
            let fits = prepared.allSatisfy { step in
                BodyMeasurer.stackHeight(step.blocks, width: candidate - 2 * Theme.horizontalPadding, chipCap: chipCap)
                    <= Theme.twoLineBudget + 0.5
            }
            if fits {
                width = candidate
                break
            }
        }

        var naturalHeights: [CGFloat] = []
        var anyWrap = false
        var panelHeight: CGFloat = 0
        for index in prepared.indices {
            // Pin the chip heights the render will use.
            for (blockIndex, block) in prepared[index].blocks.enumerated() {
                if case let .code(chip) = block {
                    prepared[index].blocks[blockIndex] = .code(BodyBlocks.CodeChip(
                        text: chip.text,
                        label: chip.label,
                        height: BodyMeasurer.chipHeight(chip, cap: chipCap)
                    ))
                }
            }
            let natural = BodyMeasurer.stackHeight(prepared[index].blocks, width: width - 2 * Theme.horizontalPadding, chipCap: chipCap)
            naturalHeights.append(natural)
            prepared[index].naturalHeight = natural
            let wraps = allowWrap && Self.buttonRows(
                question: prepared[index].question,
                innerWidth: width - 2 * Theme.horizontalPadding,
                allowWrap: true
            ).1
            anyWrap = anyWrap || wraps
            let chrome = Theme.chromeHeight(wrappedRows: wraps)
            let region = min(natural, bodyCap, panelCap - chrome)
            panelHeight = max(panelHeight, chrome + region)
        }
        return Sizing(width: width, panelHeight: panelHeight, naturalHeights: naturalHeights, anyWrap: anyWrap)
    }

    /// Button row layout (sections 5 and 12): right-aligned single row, or a
    /// greedy wrap to a second right-aligned row when the total exceeds the
    /// inner width. Returns the rows (widths per row, reading order) and
    /// whether a wrap happened. Single-question mode never wraps - its
    /// contract is byte-identical (section 12).
    static func buttonRows(question: Question, innerWidth: CGFloat, allowWrap: Bool) -> ([[CGFloat]], Bool) {
        let widths = question.buttons.enumerated().map { index, title in
            ChamferButton.width(for: title, kind: index == question.defaultIndex ? .defaultFilled : .ghost)
        }
        let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * Theme.buttonGap
        guard allowWrap, total > innerWidth else { return ([widths], false) }

        var first: [CGFloat] = []
        var consumed: CGFloat = 0
        for (index, buttonWidth) in widths.enumerated() {
            let added = buttonWidth + (first.isEmpty ? 0 : Theme.buttonGap)
            if consumed + added <= innerWidth {
                first.append(buttonWidth)
                consumed += added
            } else {
                // A tail always exists here: total > innerWidth means some
                // button failed to fit the first row.
                return ([first, Array(widths[index...])], true)
            }
        }
        return ([widths], false)
    }

    private static func screenIdentifier(for screen: NSScreen) -> String {
        if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return displayID.uint32Value.description
        }
        return screen.localizedName
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

    // MARK: Window construction

    private func buildPanel(screen: NSScreen, cascadeIndex: Int) {
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
        // The panel never activates, so cursor updates ride on mouse-moved
        // events: without this the window never sees them and hover cursors
        // (section 8 amendment) never engage.
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = steps[0].question.title
        panel.isReleasedWhenClosed = false

        let buttons = makeButtons(for: steps[0].question)
        let closeButton = ChamferButton(title: "X", kind: .ghost)
        closeButton.setAccessibilityLabel("Close")
        closeButton.setAccessibilityTitle("Close")
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))

        let answerField = AnswerField(frame: .zero)
        let editorProvider = AnswerFieldEditorProvider()
        editorProvider.answerField = answerField
        // The become-key moment is where the key-view-loop focus steal
        // lands (makeKey on a non-activating panel takes effect a turn
        // later, and AppKit can re-resolve the initial responder then);
        // the pin is re-asserted at exactly that event.
        editorProvider.onPanelBecameKey = { [weak self] in
            self?.enforceInitialFocusPin()
        }
        panel.delegate = editorProvider
        fieldEditorProvider = editorProvider

        let root = PanelRootView(frame: NSRect(origin: .zero, size: windowFrame.size))
        root.configure(
            title: steps[0].question.title,
            model: model,
            countdown: countdown,
            blocks: steps[0].blocks,
            naturalHeight: steps[0].naturalHeight,
            bodyWidth: bodyWidth,
            bodyRegion: bodyRegion,
            buttonRows: buttonRows[0],
            buttons: buttons,
            closeButton: closeButton,
            field: answerField
        )
        panel.contentView = root
        self.root = root
        // A background drag blurs the field without committing (section 13).
        root.onBackgroundMouseDown = { [weak self] in
            guard let self, let panel = self.panel else { return }
            self.root?.answerField?.endEditing(in: panel, discard: false)
            self.root?.answerField?.refreshFocusState(panel: panel)
        }

        applyStepChrome(to: panel, buttons: buttons, question: steps[0].question)

        // Mouse monitor: flags interaction start (pin stand-down) for
        // click-driven focus - posted or real, either counts.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, !self.finished else { return event }
            guard let panel = self.panel, event.window === panel else { return event }
            self.interactionsStarted = true
            return event
        }
        // One local keyDown monitor owns the whole keyboard surface
        // (sections 10 and 13): Escape first, then Return routing, then the
        // fresh-panel Tab entry, then printable capture. It stays put across
        // steps and is scoped to this panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finished else { return event }
            guard let panel = self.panel, event.window === panel else { return event }

            // Any key event means interaction has begun: the initial-focus
            // pin stands down from here on (see interactionsStarted).
            self.interactionsStarted = true

            // The focus pin runs ahead of the first key only: if the
            // makeKey key-view steal left the field holding focus the panel
            // never asked for (section 13: initial focus is never the
            // field), the first key event is exactly the deterministic
            // moment to undo it - no timer, and interaction start keeps it
            // from touching deliberate focus afterward.

            // Escape before the field editor, whatever the focus.
            if event.keyCode == 53 {
                self.escapePressed()
                return nil
            }

            // Return routes once (section 13 table): focused non-empty
            // answers with the typed string; anything else reaches the
            // default button. The event is consumed when the field is
            // focused (the editor would otherwise swallow it), and passed
            // through when it is not, so the default key equivalent fires
            // exactly once either way.
            if event.keyCode == 36, !Self.modifiersCarry(event) {
                if let field = self.root?.answerField, field.isFocused(in: panel) {
                    let text = field.liveStringValue
                    if text.isEmpty {
                        self.currentDefaultButton?.performClick(nil)
                    } else {
                        self.typedAnswerCommitted(text)
                    }
                    return nil
                }
                return event
            }

            // Tab and Shift-Tab (section 13). Two special cases, then a
            // deterministic cycle: the field editor's default Tab handling
            // only walks the text-input chain under system Full Keyboard
            // Access, so the monitor enforces the chain itself.
            if event.keyCode == 48, !Self.modifiersCarry(event) {
                // One Tab from the pinned initial focus reaches the field,
                // regardless of the default button's index in the chain
                // (the chain alone cannot express both orders).
                if self.freshTabPending {
                    self.freshTabPending = false
                    if
                        let field = self.root?.answerField,
                        !field.isFocused(in: panel),
                        let initial = self.initialDefaultButton,
                        panel.firstResponder === initial
                    {
                        field.focus(in: panel)
                        return nil
                    }
                }
                let shift = event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .contains(.shift)
                var effective: NSView?
                if let field = self.root?.answerField, field.isFocused(in: panel) {
                    effective = field.textField
                } else {
                    effective = panel.firstResponder as? NSView
                }
                // Walk the explicit cycle manually: selectNextKeyView does
                // not reliably move focus off a live field editor in this
                // non-activating panel (measured).
                let cycle: [NSView] = self.tabCycleViews()
                if let effective, let index = cycle.firstIndex(where: { $0 === effective }) {
                    let target = cycle[(index + (shift ? cycle.count - 1 : 1)) % cycle.count]
                    panel.makeFirstResponder(target)
                    return nil
                }
                return event
            }

            // Printable capture (section 13): a single printable character
            // typed while the field is unfocused focuses the field and
            // redispatches the original event to its editor exactly once.
            // The redispatch runs only on a VERIFIED responder -
            // makeFirstResponder's Bool alone is not proof in this
            // non-activating panel (measured: it returns true with the
            // editor installed while the responder never moves) - so an
            // unverified transition passes the key through instead of
            // swallowing it (finding 1).
            if
                !self.redispatchingFieldEvent,
                let field = self.root?.answerField,
                !field.isFocused(in: panel),
                Self.isPrintableKey(event)
            {
                self.redispatchingFieldEvent = true
                if !panel.isKeyWindow {
                    panel.makeKey()
                }
                field.focus(in: panel)
                if field.isFocused(in: panel) {
                    NSApp.sendEvent(event)
                    self.redispatchingFieldEvent = false
                    return nil
                }
                self.redispatchingFieldEvent = false
            }
            return event
        }

        self.panel = panel
    }

    /// The Tab cycle as an ordered array: field, answer buttons in reading
    /// order, Close (section 13).
    private func tabCycleViews() -> [NSView] {
        var cycle: [NSView] = []
        if let fieldView = root?.answerField?.textField {
            cycle.append(fieldView)
        }
        cycle.append(contentsOf: root?.buttons ?? [])
        if let close = root?.closeButton {
            cycle.append(close)
        }
        return cycle
    }

    /// Command, option, or control: the carrying modifiers disqualify a key
    /// from Return routing and from printable capture alike.
    private static func modifiersCarry(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !mods.intersection([.command, .option, .control]).isEmpty
    }

    /// A single printable character with no command, option, or control
    /// modifier (Shift allowed): not Return, Tab, or Escape, no function or
    /// navigation keys, no control characters.
    static func isPrintableKey(_ event: NSEvent) -> Bool {
        guard !modifiersCarry(event) else { return false }
        guard let characters = event.characters, characters.count == 1 else { return false }
        guard let scalar = characters.unicodeScalars.first else { return false }
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        // Function and navigation keys report private-use glyphs; the
        // MacRoman command range is excluded for safety.
        if (0xF700...0xF8FF).contains(scalar.value) { return false }
        if (0xF000...0xF0FF).contains(scalar.value) { return false }
        switch event.keyCode {
        case 36, 48, 53: return false
        default: return true
        }
    }

    /// Make one step's ChamferButtons (section 5 kinds and targets).
    private func makeButtons(for question: Question) -> [ChamferButton] {
        question.buttons.enumerated().map { index, title in
            let button = ChamferButton(
                title: title,
                kind: index == question.defaultIndex ? .defaultFilled : .ghost
            )
            button.target = self
            button.action = #selector(buttonClicked(_:))
            return button
        }
    }

    /// Return plumbing (section 10) and Tab cycling (sections 5 and 13),
    /// reassigned at every step swap so Return and VoiceOver share one
    /// source of truth (section 12). The initial responder is pinned to the
    /// default button - never the field (section 10) - and the Tab cycle
    /// runs field, buttons in reading order, Close, field.
    private func applyStepChrome(to panel: AskPanel, buttons: [ChamferButton], question: Question) {
        let defaultButton = buttons[question.defaultIndex]
        panel.defaultButtonCell = defaultButton.cell as? NSButtonCell
        panel.initialFirstResponder = defaultButton
        initialDefaultButton = defaultButton
        currentDefaultButton = defaultButton
        freshTabPending = true
        if let field = root?.answerField {
            field.textField.nextKeyView = buttons.first
        }
        for (button, next) in zip(buttons, buttons.dropFirst()) {
            button.nextKeyView = next
        }
        buttons.last?.nextKeyView = root?.closeButton
        root?.closeButton?.nextKeyView = root?.answerField?.textField
    }

    // MARK: Step content (section 12)

    private func loadStep(_ index: Int) {
        currentStep = index
        let step = steps[index]
        panel?.title = step.question.title

        model.stepIndex = index + 1
        model.stepCount = steps.count
        // A single-question file renders no indicator (section 12).
        model.indicator = isBatch && steps.count > 1 ? "\(index + 1)/\(steps.count)" : nil

        root?.bodyDocument?.rootView = BodyDocumentView(blocks: step.blocks, width: bodyWidth)
        root?.bodyDocument?.frame = NSRect(
            origin: .zero,
            size: CGSize(width: bodyWidth, height: max(step.naturalHeight, 1))
        )
        root?.metadataHost?.rootView = MetadataContentView(title: step.question.title, model: model)
        root?.updateLinkCursor(blocks: step.blocks, width: bodyWidth, viewHeight: max(step.naturalHeight, 1))

        let buttons = makeButtons(for: step.question)
        root?.swapButtons(buttons, rows: buttonRows[index])
        if let panel {
            applyStepChrome(to: panel, buttons: buttons, question: step.question)
            // Enter the step unfocused, exactly like a fresh panel: the new
            // default button holds the responder before any key arrives.
            panel.makeFirstResponder(buttons[step.question.defaultIndex])
            root?.answerField?.refreshFocusState(panel: panel)
        }
        startTiming()
    }

    /// §12 step transition: snapshot the outgoing content, swap the live
    /// content to the next question, fade the snapshot while the incoming
    /// content rises 2pt into place (180ms main curve; opacity-only 100ms
    /// under Reduce Motion). Chamfer, border, glow, and drain line persist.
    private func transition(to index: Int) {
        guard let root, let contentLayer = root.contentContainer?.layer else { return }
        // Snapshot the outgoing content (typed field included), then end
        // editing without submitting and clear editor plus backing text
        // before the swap completes (sections 10 and 13).
        let snapshot = root.snapshotContent()
        root.answerField?.resetForStep(panel: panel)

        loadStep(index)

        if let snapshot {
            contentLayer.addSublayer(snapshot)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = reduceMotion ? Theme.stepReduceMotionDuration : Theme.stepTransitionDuration
        let riseTransform = CATransform3DMakeTranslation(0, -Theme.stepRise, 0)

        // Model values hold the FINAL state; the animations only supply the
        // presentation fromValues, so nothing snaps back when they end. The
        // snapshot fades OUT, so its model opacity is 0: when Core Animation
        // drops the fade at animation end the presentation lands on 0 instead
        // of snapping to an implicit 1 for a frame (the full-opacity blink of
        // the outgoing content, frame-verified). Same D23 pattern as the
        // incoming stack below, on the outgoing side.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let snapshot {
            snapshot.opacity = 0
        }
        if let stackLayer = root.contentStack?.layer {
            stackLayer.opacity = 1
            stackLayer.transform = CATransform3DIdentity
        }
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            snapshot?.removeFromSuperlayer()
        }
        if let snapshot {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = Theme.mainCurve
            fade.fillMode = .forwards
            snapshot.add(fade, forKey: "step.fade")
        }
        if let stackLayer = root.contentStack?.layer {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = duration
            appear.timingFunction = Theme.mainCurve
            stackLayer.add(appear, forKey: "step.appear")
            if !reduceMotion {
                let rise = CABasicAnimation(keyPath: "transform")
                rise.fromValue = riseTransform
                rise.toValue = CATransform3DIdentity
                rise.duration = duration
                rise.timingFunction = Theme.mainCurve
                stackLayer.add(rise, forKey: "step.rise")
            }
        }
        CATransaction.commit()
    }

    /// VoiceOver announcement for a step change (sections 8 and 12): one per
    /// change, "Question k of n: <title>. <plain body>" (markdown stripped),
    /// posted when the new content lands. Countdown silence applies.
    private func announceStep(_ index: Int) {
        let step = steps[index]
        let text = "Question \(index + 1) of \(steps.count): \(step.question.title). "
            + BodyBlocks.plainText(of: step.blocks)
        guard let panel else { return }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high]
        )
    }

    // MARK: Show and animate

    private func showAndAnimate() {
        guard let panel, let layer = root?.layer else { return }
        panel.orderFront(nil)
        panel.makeKey()
        // makeKey can hand initial focus to the field through the key-view
        // loop even with initialFirstResponder pinned to the default button
        // (reproduced bare), and the same steal can land a turn later when
        // the window actually becomes key. The correction is deterministic,
        // not timed: the pin is re-asserted here, on the next main-queue
        // turn, on every windowDidBecomeKey, and ahead of every key event
        // (see enforceInitialFocusPin) - and it never touches focus the
        // user deliberately acquired (the field's userFocusAcquired flag,
        // set only by real user input).
        enforceInitialFocusPin()
        DispatchQueue.main.async { [weak self] in
            self?.enforceInitialFocusPin()
        }
        animateEntrance(layer: layer)
    }

    /// Re-assert the pinned initial responder (sections 10 and 13: initial
    /// focus is never the field). Runs only when the field's editor holds
    /// the responder WITHOUT user-initiated focus - the flag is set solely
    /// by real user input (a key or mouse event driving editing), so no
    /// correction can remove deliberately acquired focus, and a deferred
    /// click transition is applied instead of overridden.
    private func enforceInitialFocusPin() {
        guard !finished, !interactionsStarted, let panel, let field = root?.answerField else { return }
        if field.applyPendingBecomeKeyFocus(in: panel) { return }
        guard field.isFocused(in: panel), !field.userFocusAcquired else { return }
        let pinned = initialDefaultButton ?? currentDefaultButton
        if let pinned {
            panel.makeFirstResponder(pinned)
            field.refreshFocusState(panel: panel)
        }
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

    // MARK: Countdown (sections 6 and 12)

    /// Restart the per-question bound: the drain line resets to full width
    /// and accent instantly at the step start (a width crossfade would
    /// misread as progress); a step without a bound hides the line and
    /// countdown exactly like a no-bound single invocation.
    private func startTiming() {
        let bound = steps[currentStep].question.giveUpAfter
        if let bound {
            boundSeconds = bound
            deadline = Date().addingTimeInterval(bound)
            if ticker == nil {
                let ticker = DrainTicker { [weak self] in self?.tick() }
                ticker.start()
                self.ticker = ticker
            }
            updateCountdown(remaining: bound)
        } else {
            deadline = nil
            countdown.secondsLeft = nil
            countdown.color = Theme.accentSwiftUI
            if let drainLayer = root?.drainLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                drainLayer.path = CGPath(rect: .zero, transform: nil)
                CATransaction.commit()
            }
        }
    }

    private func tick() {
        guard !finished, let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            updateCountdown(remaining: 0)
            ticker?.stop()
            ticker = nil
            gaveUpAtCurrentStep()
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
        // The visual panel width is the window minus the transparent margin
        // on both sides; the line spans that width minus the bottom cut.
        let visualWidth = panelSize.width
        let width = (visualWidth - Theme.panelCut) * CGFloat(fraction)
        // The ramp is already interpolated per tick. Assign its shared color
        // directly so the line cannot lag behind the seconds text.
        // The line sits just inside the border stroke (section 6): y 1..3.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drainLayer.path = CGPath(
            rect: CGRect(x: 0, y: 1, width: width, height: Theme.drainLineHeight),
            transform: nil
        )
        drainLayer.fillColor = color.cgColor
        CATransaction.commit()
    }

    // MARK: Outcomes

    @objc private func closeClicked(_ sender: ChamferButton) {
        guard !finished else { return }
        if isBatch {
            stopSequence(status: "closed", exitCode: 4)
        } else {
            finish(.closed)
        }
    }

    /// A typed answer (section 13): the live editor string, verbatim, no
    /// trim - whitespace-only strings are non-empty, and typed Cancel,
    /// CANCELED, CLOSED, and GAVE-UP remain answered strings with exit 0.
    /// One announcement carries the string before the exit fade or the step
    /// transition starts.
    private func typedAnswerCommitted(_ text: String) {
        if let panel {
            NSAccessibility.post(
                element: panel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "custom answer sent: \(text)",
                    .priority: NSAccessibilityPriorityLevel.high,
                ]
            )
        }
        if isBatch {
            recordAnswered(text)
        } else {
            finish(.answered(text))
        }
    }

    @objc private func buttonClicked(_ sender: ChamferButton) {
        guard !finished else { return }
        if isBatch {
            // A button labeled "Cancel" answers only its own question and
            // the sequence continues; canceling the whole sequence is
            // Escape's job (section 12).
            recordAnswered(sender.buttonTitle)
        } else if sender.buttonTitle == "Cancel" {
            // Single-question legacy contract: a clicked Cancel is CANCELED.
            finish(.canceled)
        } else {
            finish(.answered(sender.buttonTitle))
        }
    }

    private func escapePressed() {
        if isBatch {
            stopSequence(status: "canceled", exitCode: 2)
        } else {
            finish(.canceled)
        }
    }

    private func gaveUpAtCurrentStep() {
        if isBatch {
            stopSequence(status: "gave-up", exitCode: 3)
        } else {
            finish(.gaveUp)
        }
    }

    private func recordAnswered(_ answer: String) {
        results.append(StepResult(index: currentStep, status: "answered", answer: answer))
        if currentStep + 1 < steps.count {
            transition(to: currentStep + 1)
            announceStep(currentStep)
        } else {
            stopSequence(status: nil, exitCode: 0)
        }
    }

    /// End the sequence: the stop entry (canceled/gave-up) joins the
    /// collected answers, and one line of JSON carries the whole outcome.
    /// Partial answers survive a mid-sequence stop. stopped_at is the 0-based
    /// index of the stopped step when stopped early, questions.count when
    /// every question was answered (section 12 invariants).
    private func stopSequence(status: String?, exitCode: Int32) {
        if let status {
            results.append(StepResult(index: currentStep, status: status, answer: nil))
        }
        let stoppedAt = status != nil ? currentStep : steps.count
        finishRaw(output: Self.batchJSON(results: results, stoppedAt: stoppedAt), exit: exitCode)
    }

    /// Compact batch JSON: {"results":[{"index":0,"status":"answered",
    /// "answer":"Deploy"},...],"stopped_at":N} - one line, UTF-8, newline.
    static func batchJSON(results: [StepResult], stoppedAt: Int) -> String {
        let entries = results.map { result in
            var entry = "{\"index\":\(result.index),\"status\":\"\(result.status)\""
            if let answer = result.answer {
                entry += ",\"answer\":\"\(Self.jsonEscaped(answer))\""
            }
            return entry + "}"
        }
        return "{\"results\":[\(entries.joined(separator: ","))],\"stopped_at\":\(stoppedAt)}"
    }

    private static func jsonEscaped(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Single-question exit: the outcome's own stdout line.
    private func finish(_ outcome: Outcome) {
        finishRaw(output: outcome.stdout, exit: outcome.exitCode)
    }

    /// Never returns: prints, releases the cascade slot, animates the exit,
    /// and exits with the contract code.
    private func finishRaw(output: String, exit code: Int32) {
        guard !finished else { return }
        finished = true

        print(output)
        fflush(stdout)
        Cascade.release(screenID: screenID)
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        ticker?.stop()
        ticker = nil
        attentionController?.stop()
        attentionController = nil

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
            exit(code)
        }
    }
}
