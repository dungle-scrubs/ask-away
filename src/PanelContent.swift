import AppKit
import SwiftUI

/// Live state for the metadata row's step identity (design.md sections 1
/// and 12). Written once per step change - never per tick - so a countdown
/// tick cannot invalidate the title or the step indicator.
@MainActor
final class StepModel: ObservableObject {
    /// "k/n" while a sequence runs; nil in single-question mode and for a
    /// single-question file (section 12).
    @Published var indicator: String?
    /// Count of questions in a sequence, for the AX label.
    @Published var stepIndex: Int = 0
    @Published var stepCount: Int = 0
}

/// Live countdown state (sections 6 and 12): the seconds text and its shared
/// ramp color, so line and number always agree. Written per tick by the
/// drain ticker into its OWN observable: only the countdown text re-renders
/// per tick - the title, the indicator, and the body never do.
@MainActor
final class CountdownModel: ObservableObject {
    /// nil when the current question has no time bound: no countdown renders.
    @Published var secondsLeft: Int?
    @Published var color: Color = Theme.accentSwiftUI
}

/// Shared body styling and the calibrated line spacings (section 3). The
/// calibration follows decision D10: SwiftUI line spacing is measured from
/// the real renderer's natural single-line height, not font metrics.
@MainActor
enum BodyStyle {

    /// Style a parsed group's inline spans in place: code spans per section 2
    /// (SF Mono 13.5, text-code on white 5% chip) and links per section 11
    /// (accent + underline, the WCAG 1.4.1 non-color cue). Strong and em
    /// render from their inlinePresentationIntent traits untouched.
    static func styled(_ source: AttributedString) -> AttributedString {
        var attr = source
        for run in attr.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attr[range].font = Theme.codeSwiftUIFont
                attr[range].kern = 0
                attr[range].foregroundColor = Theme.textCodeSwiftUI
                attr[range].backgroundColor = Theme.chipFillSwiftUI
            }
            if run.link != nil {
                attr[range].foregroundColor = Theme.accentSwiftUI
                attr[range].underlineStyle = .single
            }
        }
        return attr
    }

    static let bodyLineSpacing: CGFloat = calibrate(target: Theme.bodyLineHeight, font: Theme.bodyFont, kern: Theme.bodyKerning)
    static let codeLineSpacing: CGFloat = calibrate(target: Theme.codeBlockLineHeight, font: Theme.codeBlockFont, kern: 0)

    /// One-time calibration: render a single line with zero spacing, read the
    /// renderer's natural line height, and take the delta to the spec target.
    private static func calibrate(target: CGFloat, font: NSFont, kern: CGFloat) -> CGFloat {
        var probe = AttributedString("Hg")
        probe.font = Font(font)
        probe.kern = kern
        let host = NSHostingView(rootView:
            Text(probe)
                .lineSpacing(0)
                .fixedSize(horizontal: false, vertical: true)
        )
        let natural = host.fittingSize.height
        return max(0, target - natural)
    }
}

/// The metadata row: title left; step indicator and countdown right
/// (sections 1 and 12). Baseline-aligned, one line, tail-truncated. The
/// countdown text observes CountdownModel alone, so the per-tick drain
/// updates never re-render the title or the indicator.
struct MetadataContentView: View {
    let title: String
    @ObservedObject var model: StepModel
    @ObservedObject var countdown: CountdownModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(Theme.metadataSwiftUIFont)
                .kerning(Theme.metadataKerning)
                .foregroundStyle(Theme.accentSwiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            Spacer(minLength: 12)
            if model.indicator != nil {
                indicatorView
                    .layoutPriority(1)
            } else if countdown.secondsLeft != nil {
                CountdownView(countdown: countdown)
                    .layoutPriority(1)
            }
        }
        .frame(height: Theme.metadataHeight, alignment: .center)
    }

    /// "2/3 · 42s": the k/n segment holds accent regardless of the ramp; only
    /// the seconds segment adopts the ramp color (section 12). No bound on
    /// the current step renders the indicator alone.
    private var indicatorView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(model.stepIndex)/\(model.stepCount)")
            Text(" \u{00B7} ")
            CountdownView(countdown: countdown)
        }
        .font(Theme.metadataSwiftUIFont)
        .kerning(Theme.metadataKerning)
        .monospacedDigit()
        .foregroundStyle(Theme.accentSwiftUI)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("question \(model.stepIndex) of \(model.stepCount)")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var value = "\(model.stepIndex)/\(model.stepCount)"
        if let seconds = countdown.secondsLeft {
            value += " \u{00B7} \(seconds)s"
        }
        return value
    }
}

/// The seconds text alone ("42s", ramp color per section 2). Isolated so the
/// per-tick writes re-render only this view; the AX label keeps the section 8
/// countdown rule (never announced per tick).
private struct CountdownView: View {
    @ObservedObject var countdown: CountdownModel

    var body: some View {
        Text("\(countdown.secondsLeft ?? 0)s")
            .foregroundStyle(countdown.color)
            .accessibilityLabel("\(countdown.secondsLeft ?? 0) seconds remaining")
    }
}

/// One body block as a SwiftUI view. Mirrors the measurement views in
/// BodyMeasurer exactly - the width rule (section 1) sizes the panel from
/// these heights, so measure and render must agree.
struct BodyDocumentView: View {
    let blocks: [BodyBlocks.Block]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(BodyBlocks.plainText(of: blocks))
    }

    @ViewBuilder
    private func blockView(_ block: BodyBlocks.Block) -> some View {
        switch block {
        case let .paragraph(attr):
            bodyText(BodyStyle.styled(attr))
        case let .quote(attr):
            // The stripe is the text's background, not a greedy sibling: it
            // spans exactly the quoted text's height (section 11).
            bodyText(BodyStyle.styled(attr))
                .padding(.leading, Theme.quoteIndent)
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.accentSwiftUI)
                        .frame(width: Theme.quoteStripeWidth)
                }
                .padding(.leading, Theme.quoteStripeWidth)
                .frame(width: width, alignment: .topLeading)
        case let .list(rows):
            VStack(alignment: .leading, spacing: Theme.listItemSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.listHang - Theme.listMarkerWidth) {
                        Text(row.marker)
                            .font(Theme.bodySwiftUIFont)
                            .foregroundStyle(Theme.textSecondarySwiftUI)
                            .frame(width: Theme.listMarkerWidth, alignment: .leading)
                        bodyText(BodyStyle.styled(row.text))
                            .frame(width: width - Theme.listHang, alignment: .topLeading)
                    }
                }
            }
        case let .code(chip):
            CodeChipView(chip: chip, width: width)
        }
    }

    private func bodyText(_ attr: AttributedString) -> some View {
        Text(attr)
            .font(Theme.bodySwiftUIFont)
            .kerning(Theme.bodyKerning)
            .lineSpacing(BodyStyle.bodyLineSpacing)
            .foregroundStyle(Theme.textBodySwiftUI)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A fenced code block as a full-width inset chip (section 11): white 6%
/// fill, 6pt radius, 12pt inner padding, optional info-string label in
/// accent metadata style 4pt above the code, and an overlay-scrolled inner
/// scroll view capped at 25% of the visible frame. No syntax highlighting
/// in v1.
struct CodeChipView: View {
    let chip: BodyBlocks.CodeChip
    let width: CGFloat

    private var hasLabel: Bool { chip.label != nil }
    /// The inner scroll area: chip height minus padding, minus the label row
    /// and the 4pt gap when a label renders.
    private var codeAreaHeight: CGFloat {
        chip.height - 2 * Theme.codeChipPadding
            - (hasLabel ? Theme.metadataLineHeight + Theme.codeChipLabelGap : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.codeChipLabelGap) {
            if let label = chip.label {
                Text(label)
                    .font(Theme.metadataSwiftUIFont)
                    .kerning(Theme.metadataKerning)
                    .foregroundStyle(Theme.accentSwiftUI)
                    .frame(height: Theme.metadataLineHeight, alignment: .center)
            }
            CodeChipScroller(text: chip.text)
                .frame(height: codeAreaHeight)
        }
        .padding(Theme.codeChipPadding)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.codeChipRadius)
                .fill(Theme.codeChipFillSwiftUI)
        )
    }
}

/// The chip's inner scroll view (section 11): overlay-style scrollers only,
/// never a reserved gutter, in both axes - code content renders verbatim and
/// never wraps.
private struct CodeChipScroller: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        let document = NSHostingView(rootView: CodeDocumentText(text: text))
        let natural = document.fittingSize
        document.frame = NSRect(origin: .zero, size: natural)
        scroll.documentView = document
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Verbatim code text: SF Mono 12.5/16, text-code, no wrap - the scroll view
/// owns overflow (section 11).
private struct CodeDocumentText: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.codeBlockSwiftUIFont)
            .lineSpacing(BodyStyle.codeLineSpacing)
            .foregroundStyle(Theme.textCodeSwiftUI)
            .fixedSize(horizontal: true, vertical: true)
    }
}

// MARK: Measurement

/// Unbounded measurement of the body block stack for the width rule and the
/// height caps (sections 1 and 11). Every function mirrors its render view
/// in BodyDocumentView exactly.
@MainActor
enum BodyMeasurer {

    /// Wrapped attributed text height at `width` in the real renderer.
    static func textHeight(_ attr: AttributedString, width: CGFloat, kern: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        let view = Text(attr)
            .font(Theme.bodySwiftUIFont)
            .kerning(kern)
            .lineSpacing(lineSpacing)
            .foregroundStyle(Theme.textBodySwiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
        let host = NSHostingView(rootView: view)
        let height = host.fittingSize.height
        return height > 0 ? height : Theme.bodyLineHeight
    }

    /// Natural (unwrapped) verbatim text height, for code chip content.
    static func verbatimHeight(_ text: String) -> CGFloat {
        let host = NSHostingView(rootView: CodeDocumentText(text: text))
        let height = host.fittingSize.height
        return height > 0 ? height : Theme.codeBlockLineHeight
    }

    /// A code chip's rendered height: content + 12pt padding + label row,
    /// capped at `cap` (25% of the visible frame, section 11).
    static func chipHeight(_ chip: BodyBlocks.CodeChip, cap: CGFloat) -> CGFloat {
        let labelExtra: CGFloat = chip.label != nil ? Theme.metadataLineHeight + Theme.codeChipLabelGap : 0
        let natural = verbatimHeight(chip.text) + 2 * Theme.codeChipPadding + labelExtra
        return min(natural, cap)
    }

    /// The whole block stack's natural height at `width`, with chip caps
    /// applied. `chipCap` comes from the target screen's visible frame.
    static func stackHeight(_ blocks: [BodyBlocks.Block], width: CGFloat, chipCap: CGFloat) -> CGFloat {
        guard !blocks.isEmpty else { return Theme.bodyLineHeight }
        var height: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { height += Theme.blockGap }
            switch block {
            case let .paragraph(attr):
                height += textHeight(attr, width: width, kern: Theme.bodyKerning, lineSpacing: BodyStyle.bodyLineSpacing)
            case let .quote(attr):
                height += textHeight(
                    attr,
                    width: width - Theme.quoteStripeWidth - Theme.quoteIndent,
                    kern: Theme.bodyKerning,
                    lineSpacing: BodyStyle.bodyLineSpacing
                )
            case let .list(rows):
                for (rowIndex, row) in rows.enumerated() {
                    if rowIndex > 0 { height += Theme.listItemSpacing }
                    height += textHeight(
                        row.text,
                        width: width - Theme.listHang,
                        kern: Theme.bodyKerning,
                        lineSpacing: BodyStyle.bodyLineSpacing
                    )
                }
            case let .code(chip):
                height += chipHeight(chip, cap: chipCap)
            }
        }
        return height
    }
}

extension BodyBlocks {
    /// Plain text across blocks without owning a BodyBlocks instance.
    static func plainText(of blocks: [Block]) -> String {
        blocks.map(\.plainText).joined(separator: " ")
    }
}

/// Cursor affordance for body links (v0.1.1 amendment, section 8).
/// SwiftUI Text link runs expose no per-link cursor rects and render no
/// pointer inside NSHostingView (measured: ARROW over a link line), and the
/// SDK's SwiftUI surface has no cursor API - so link rectangles come from a
/// parallel TextKit layout of the same attributed string at the same width
/// and block offsets. The rects only feed the panel's mouse-moved cursor
/// check (this panel never activates, so WindowServer-managed cursor rects
/// and cursorUpdate tracking do not engage); clicks and URL opening stay
/// SwiftUI's. A one-word line-break drift between renderers shifts an
/// affordance rectangle a few points: cosmetic, never behavioral.
@MainActor
enum LinkRects {

    /// Link rectangles in body-document view coordinates (bottom-left
    /// origin). Block offsets mirror BodyMeasurer.stackHeight exactly; within
    /// a paragraph, rects come from NSLayoutManager at the render width.
    static func inDocument(
        blocks: [BodyBlocks.Block], width: CGFloat, viewHeight: CGFloat, hostIsFlipped: Bool
    ) -> [NSRect] {
        let flipped = hostIsFlipped
        var rects: [NSRect] = []
        var top: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { top += Theme.blockGap }
            switch block {
            case let .paragraph(attr):
                rects += textKitRects(attr: attr, layoutWidth: width, x: 0, blockTop: top, viewHeight: viewHeight, flipped: flipped)
                top += BodyMeasurer.textHeight(attr, width: width, kern: Theme.bodyKerning, lineSpacing: BodyStyle.bodyLineSpacing)
            case let .quote(attr):
                let quoteWidth = width - Theme.quoteStripeWidth - Theme.quoteIndent
                rects += textKitRects(
                    attr: attr,
                    layoutWidth: quoteWidth,
                    x: Theme.quoteStripeWidth + Theme.quoteIndent,
                    blockTop: top,
                    viewHeight: viewHeight,
                    flipped: flipped
                )
                top += BodyMeasurer.textHeight(attr, width: quoteWidth, kern: Theme.bodyKerning, lineSpacing: BodyStyle.bodyLineSpacing)
            case let .list(rows):
                for (rowIndex, row) in rows.enumerated() {
                    if rowIndex > 0 { top += Theme.listItemSpacing }
                    let rowWidth = width - Theme.listHang
                    rects += textKitRects(attr: row.text, layoutWidth: rowWidth, x: Theme.listHang, blockTop: top, viewHeight: viewHeight, flipped: flipped)
                    top += BodyMeasurer.textHeight(row.text, width: rowWidth, kern: Theme.bodyKerning, lineSpacing: BodyStyle.bodyLineSpacing)
                }
            case let .code(chip):
                // Verbatim code carries no link runs; the pinned chip height
                // keeps the offset accumulation exact (section 11).
                top += chip.height
            }
        }
        return rects
    }

    /// Link rects for one flowing text block: TextKit layout at `layoutWidth`,
    /// offset `x` into the document, block top `blockTop` from the view's top.
    private static func textKitRects(
        attr: AttributedString, layoutWidth: CGFloat, x: CGFloat, blockTop: CGFloat, viewHeight: CGFloat,
        flipped: Bool
    ) -> [NSRect] {
        let storage = NSTextStorage(attributedString: NSAttributedString(attr))
        let full = NSRange(location: 0, length: storage.length)
        // The render view applies the body font and kerning as Text-level
        // modifiers; mirror them as base attributes for runs without their own.
        storage.addAttributes([
            .font: Theme.bodyFont,
            .kern: Theme.bodyKerning,
        ], range: full)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(containerSize: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        // Line height calibrated the same way the render target is: 21pt lines.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = max(0, Theme.bodyLineHeight - manager.defaultLineHeight(for: Theme.bodyFont))
        storage.addAttribute(.paragraphStyle, value: paragraph, range: full)
        manager.ensureLayout(for: container)

        var out: [NSRect] = []
        storage.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            // Walk the link's lines: one rect per line fragment, sized to the
            // glyphs the link owns on that line (a wrapped link yields one
            // rect per line, never the spanning union).
            var remaining = glyphRange
            while remaining.length > 0 {
                var lineGlyphRange = NSRange()
                _ = manager.lineFragmentRect(forGlyphAt: remaining.location, effectiveRange: &lineGlyphRange)
                let slice = NSIntersectionRange(lineGlyphRange, remaining)
                if slice.length > 0 {
                    let rect = manager.boundingRect(forGlyphRange: slice, in: container)
                    // Text container rects are top-left origin. NSHostingView
                    // is a flipped view (top-left origin too), so the rects
                    // carry over directly; a non-flipped host would need the
                    // bottom-left conversion instead.
                    out.append(NSRect(
                        x: x + rect.minX,
                        y: flipped ? blockTop + rect.minY : viewHeight - (blockTop + rect.maxY),
                        width: rect.width,
                        height: rect.height
                    ))
                }
                remaining = NSRange(
                    location: NSMaxRange(lineGlyphRange),
                    length: max(0, NSMaxRange(remaining) - NSMaxRange(lineGlyphRange))
                )
            }
        }
        return out
    }
}
