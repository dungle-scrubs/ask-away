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
        buttons: [ChamferButton]
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
        contentContainer = content

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

        // The step-swappable container (sections 7 and 12): metadata row,
        // body scroll, buttons. Never the vibrancy or scrim - a scrim fade
        // would flash the desktop through the panel.
        let stack = NSView(frame: panelBounds)
        stack.wantsLayer = true
        content.addSubview(stack)
        contentStack = stack

        // Metadata row hosting: fixed 14pt band at the top (section 1).
        let metadataFrame = NSRect(
            x: Theme.horizontalPadding,
            y: panelRect.height - Theme.topPadding - Theme.metadataHeight,
            width: panelRect.width - 2 * Theme.horizontalPadding,
            height: Theme.metadataHeight
        )
        let metadata = NSHostingView(
            rootView: MetadataContentView(title: title, model: model, countdown: countdown)
        )
        metadata.frame = metadataFrame
        stack.addSubview(metadata)
        metadataHost = metadata

        // Body region: the only elastic element (section 1). An explicit
        // NSScrollView so scroller style is forced overlay regardless of the
        // system's scroll-bar setting - never a reserved gutter (section 10).
        let bodyFrame = NSRect(
            x: Theme.horizontalPadding,
            y: Theme.bottomPadding + buttonBlockHeight(rows: buttonRows) + Theme.bodyToButtons,
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

    /// Movable by its background (v0.1.1 amendment, section 10). Borderless
    /// panels are not draggable by default, and AppKit's
    /// isMovableByWindowBackground engages only erratically on this shaped,
    /// clear window (it worked near the window edges and dead-ended over
    /// content - frame-verified), so the panel drags explicitly: this root
    /// view sees a mouseDown only when no interactive control consumed it
    /// (buttons track their own clicks; a plain click still makes key), and
    /// `performDrag` runs the window-move loop until mouseUp.
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
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
        let overButton = buttons.contains { button in
            window.convertToScreen(button.convert(button.bounds, to: nil)).contains(global)
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
    /// targets (section 12).
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
            let y = Theme.bottomPadding
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

    /// - Parameters:
    ///   - questions: one question, or a validated §12 sequence in file order.
    ///   - batch: true when the invocation came through --questions-file;
    ///     batch output is the JSON contract even for a single-question file.
    init(questions: [Question], batch: Bool) {
        self.steps = questions.map { PreparedStep(question: $0, blocks: BodyBlocks($0.text).blocks) }
        self.isBatch = batch
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

        // One beep per invocation (sections 6 and 12): the moment the panel
        // appears; in a sequence one objection (any no_beep) silences it.
        if steps.allSatisfy({ $0.question.beep }) {
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
                BodyMeasurer.stackHeight(step.blocks, width: candidate, chipCap: chipCap)
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
            let natural = BodyMeasurer.stackHeight(prepared[index].blocks, width: width, chipCap: chipCap)
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
            buttons: buttons
        )
        panel.contentView = root

        applyStepChrome(to: panel, buttons: buttons, question: steps[0].question)

        // Escape is not free in a borderless panel: bind it via a local
        // keyDown monitor (section 10). The monitor stays put across steps.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.finished, event.keyCode == 53 else { return event }
            self.escapePressed()
            return nil
        }

        self.panel = panel
        self.root = root
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

    /// Return plumbing (section 10) and Tab cycling (section 5), reassigned
    /// at every step swap so Return and VoiceOver share one source of truth
    /// (section 12).
    private func applyStepChrome(to panel: AskPanel, buttons: [ChamferButton], question: Question) {
        panel.defaultButtonCell = buttons[question.defaultIndex].cell as? NSButtonCell
        for (button, next) in zip(buttons, buttons.dropFirst()) {
            button.nextKeyView = next
        }
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
        root?.metadataHost?.rootView = MetadataContentView(title: step.question.title, model: model, countdown: countdown)
        root?.updateLinkCursor(blocks: step.blocks, width: bodyWidth, viewHeight: max(step.naturalHeight, 1))

        let buttons = makeButtons(for: step.question)
        root?.swapButtons(buttons, rows: buttonRows[index])
        if let panel {
            applyStepChrome(to: panel, buttons: buttons, question: step.question)
        }
        startTiming()
    }

    /// §12 step transition: snapshot the outgoing content, swap the live
    /// content to the next question, fade the snapshot while the incoming
    /// content rises 2pt into place (180ms main curve; opacity-only 100ms
    /// under Reduce Motion). Chamfer, border, glow, and drain line persist.
    private func transition(to index: Int) {
        guard let root, let contentLayer = root.contentContainer?.layer else { return }
        let snapshot = root.snapshotContent()

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
            exit(code)
        }
    }
}
