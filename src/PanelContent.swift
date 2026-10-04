import AppKit
import SwiftUI

/// Live countdown state for the metadata row. The drain line is a CALayer
/// driven by PanelController; this model carries only the seconds text and
/// its shared ramp color, so line and number always agree (design.md section 6).
@MainActor
final class CountdownModel: ObservableObject {
    /// nil when the invocation has no time bound: no countdown is rendered.
    @Published var secondsLeft: Int?
    @Published var color: Color = Theme.accentSwiftUI
}

/// The SwiftUI content hosted in the panel's NSHostingView: metadata row
/// (title left, countdown right) and the body block with inline markdown
/// (design.md sections 1 and 3).
struct PanelContentView: View {
    let title: String
    let bodyMarkdown: AttributedString
    let bodyWidth: CGFloat
    @ObservedObject var countdown: CountdownModel

    /// SF Pro Text 15pt renders on a 21pt line height (section 3). SwiftUI's
    /// lineSpacing adds to the renderer's own natural line height, which does
    /// not match NSLayoutManager's metric, so the delta is calibrated once
    /// from the real single-line render (see BodyMeasurer.calibrate).
    @MainActor static let bodyLineSpacing: CGFloat = BodyMeasurer.calibrateLineSpacing()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(Theme.metadataSwiftUIFont)
                    .kerning(Theme.metadataKerning)
                    .foregroundStyle(Theme.accentSwiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)
                if let seconds = countdown.secondsLeft {
                    Spacer(minLength: 12)
                    Text("\(seconds)s")
                        .font(Theme.metadataSwiftUIFont)
                        .kerning(Theme.metadataKerning)
                        .monospacedDigit()
                        .foregroundStyle(countdown.color)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityLabel("\(seconds) seconds remaining")
                }
            }
            .frame(height: Theme.metadataHeight, alignment: .center)
            Text(bodyMarkdown)
                .font(Theme.bodySwiftUIFont)
                .kerning(Theme.bodyKerning)
                .lineSpacing(Self.bodyLineSpacing)
                .foregroundStyle(Theme.textBodySwiftUI)
                .lineLimit(Theme.maxBodyLines)
                .truncationMode(.tail)
                .frame(width: bodyWidth, alignment: .topLeading)
                .padding(.top, Theme.metadataToBody)
                .accessibilitySortPriority(1)
        }
    }

    /// Parse `--text` as inline markdown (emphasis, strong, code spans only;
    /// section 3) and style code spans per section 2. Malformed markdown
    /// degrades to plain text rather than failing the invocation.
    static func prepareBody(_ raw: String) -> AttributedString {
        guard var parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return AttributedString(raw)
        }
        for run in parsed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            parsed[run.range].font = Theme.codeSwiftUIFont
            parsed[run.range].kern = 0
            parsed[run.range].foregroundColor = Theme.textCodeSwiftUI
            parsed[run.range].backgroundColor = Theme.chipFillSwiftUI
        }
        return parsed
    }
}

/// Unbounded measurement view for the width rule (section 1): the body laid
/// out at a candidate width, no line limit, so fittingSize.height reports
/// the wrapped height in the real SwiftUI renderer.
struct BodyMeasureView: View {
    let markdown: AttributedString
    let width: CGFloat
    var spacing: CGFloat = PanelContentView.bodyLineSpacing

    var body: some View {
        Text(markdown)
            .font(Theme.bodySwiftUIFont)
            .kerning(Theme.bodyKerning)
            .lineSpacing(spacing)
            .foregroundStyle(Theme.textBodySwiftUI)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .topLeading)
    }
}

@MainActor
enum BodyMeasurer {
    private static var calibratedSpacing: CGFloat?

    /// One-time calibration: render a single line with zero spacing, read the
    /// renderer's natural line height, and take the delta to the 21pt spec.
    static func calibrateLineSpacing() -> CGFloat {
        if let calibratedSpacing { return calibratedSpacing }
        let probe = BodyMeasureView(
            markdown: AttributedString("Hg"),
            width: Theme.widthCandidates[0],
            spacing: 0
        )
        let natural = NSHostingView(rootView: probe).fittingSize.height
        let spacing = max(0, Theme.bodyLineHeight - natural)
        calibratedSpacing = spacing
        return spacing
    }

    /// Wrapped body height at `width`, in points, with no line cap.
    static func height(markdown: AttributedString, width: CGFloat) -> CGFloat {
        let host = NSHostingView(rootView: BodyMeasureView(markdown: markdown, width: width))
        let height = host.fittingSize.height
        return height > 0 ? height : Theme.bodyLineHeight
    }
}
