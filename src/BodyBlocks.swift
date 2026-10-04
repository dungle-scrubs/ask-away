import Foundation

/// The §11 body model: one parsed `--text` (or sequence-file `text`) as a
/// stack of blocks. Parse once with `AttributedString(interpretedSyntax:
/// .full)` and group consecutive runs with equal `PresentationIntent` -
/// verified on the build toolchain that adjacent same-kind blocks carry
/// distinct intents, soft breaks arrive as space runs, hard breaks as `\\n`
/// runs, and adjacent blocks abut with no separator in the character stream.
///
/// Block kinds (section 11): paragraphs, fenced code blocks, unordered and
/// ordered lists (one nesting level, deeper items flattened space-joined
/// into their parent item), blockquotes, hard line breaks. Headings, tables,
/// and thematic breaks degrade to plain paragraphs. Inline spans (strong,
/// em, code spans, links) are unchanged and styled in place.
struct BodyBlocks {

    enum Block {
        case paragraph(AttributedString)
        case quote(AttributedString)
        case list([Row])
        case code(CodeChip)

        /// Plain-text rendering for accessibility (section 8): markdown
        /// syntax stripped, code content verbatim.
        var plainText: String {
            switch self {
            case let .paragraph(attr): return String(attr.characters)
            case let .quote(attr): return String(attr.characters)
            case let .list(rows): return rows.map { "\($0.marker) \(String($0.text.characters))" }.joined(separator: " ")
            case let .code(chip): return chip.text
            }
        }
    }

    struct Row {
        /// Rendered marker: "•" or the item number plus ".".
        let marker: String
        /// The item's 1-based number within its own list, from the parser.
        let number: Int
        let ordered: Bool
        var text: AttributedString
    }

    struct CodeChip {
        /// Verbatim fenced content, trailing newline included.
        let text: String
        /// First whitespace-separated token of the fence info string, if any.
        let label: String?
        /// Rendered chip height including 12pt padding and the label row,
        /// capped at 25% of the target screen's visible frame. Filled in
        /// during sizing; 0 until then.
        var height: CGFloat = 0
    }

    /// One classified parser group, ready to place in the block stack.
    private enum Action {
        case code(CodeChip)
        case listItem(ordered: Bool, number: Int, depth: Int, text: AttributedString)
        case quote(AttributedString)
        /// `fromTable` marks text merged out of a degraded table run.
        case paragraph(AttributedString, fromTable: Bool)
    }

    private struct Group {
        let intent: PresentationIntent?
        var text: AttributedString
    }

    let blocks: [Block]

    /// All text as one plain string for the body's accessibility element.
    var plainText: String {
        blocks.map(\.plainText).joined(separator: " ")
    }

    // MARK: Parsing

    /// Parse markdown into blocks. Malformed markdown degrades to one plain
    /// paragraph (unchanged from the inline-only days).
    init(_ raw: String) {
        let parsed = (try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(raw)

        var blocks: [Block] = []
        var inTableRun = false
        for group in Self.groups(of: parsed) {
            switch Self.classify(group) {
            case .code(let chip):
                blocks.append(.code(chip))
                inTableRun = false

            case let .listItem(ordered, number, depth, text):
                inTableRun = false
                guard case .list(let rows) = blocks.last, let lastRow = rows.last else {
                    guard depth <= 1 else {
                        // Deeper item with no parent row to flatten into.
                        blocks.append(.paragraph(text))
                        continue
                    }
                    blocks.append(.list([Row(
                        marker: Self.marker(ordered: ordered, number: number),
                        number: number,
                        ordered: ordered,
                        text: text
                    )]))
                    continue
                }
                if depth > 1
                    || (lastRow.ordered == ordered && lastRow.number == number && depth == 1) {
                    // Flatten: a continuation paragraph of the same item, or
                    // deeper nesting, space-joins into the previous row.
                    var merged = lastRow
                    merged.text += AttributedString(" ")
                    merged.text += text
                    blocks[blocks.count - 1] = .list(Array(rows.dropLast()) + [merged])
                } else {
                    blocks[blocks.count - 1] = .list(rows + [Row(
                        marker: Self.marker(ordered: ordered, number: number),
                        number: number,
                        ordered: ordered,
                        text: text
                    )])
                }

            case .quote(let text):
                if case .quote(let existing) = blocks.last {
                    blocks[blocks.count - 1] = .quote(existing + AttributedString(" ") + text)
                } else {
                    blocks.append(.quote(text))
                }
                inTableRun = false

            case let .paragraph(text, fromTable):
                if fromTable, inTableRun, case .paragraph(let existing) = blocks.last {
                    blocks[blocks.count - 1] = .paragraph(existing + AttributedString(" ") + text)
                } else {
                    blocks.append(.paragraph(text))
                }
                inTableRun = fromTable
            }
        }
        self.blocks = blocks
    }

    private static func marker(ordered: Bool, number: Int) -> String {
        ordered ? "\(number)." : "\u{2022}"
    }

    // MARK: Grouping and classification

    /// Consecutive runs with equal PresentationIntent form one group. Runs
    /// with a nil intent cannot occur under `.full` parsing, but a nil-intent
    /// run starts its own group and degrades to a paragraph.
    private static func groups(of parsed: AttributedString) -> [Group] {
        var groups: [Group] = []
        for run in parsed.runs {
            let slice = stripIntent(source: parsed, range: run.range)
            if !groups.isEmpty, groups[groups.count - 1].intent == run.presentationIntent {
                groups[groups.count - 1].text += slice
            } else {
                groups.append(Group(intent: run.presentationIntent, text: slice))
            }
        }
        return groups
    }

    /// A run's characters carrying their inline attributes (strong, em, code,
    /// link) but stripped of the block PresentationIntent, so merged text
    /// stays clean.
    private static func stripIntent(source: AttributedString, range: Range<AttributedString.Index>) -> AttributedString {
        var slice = AttributedString(source[range])
        slice.presentationIntent = nil
        return slice
    }

    private static func classify(_ group: Group) -> Action {
        let components = group.intent?.components ?? []

        // Fenced code block: content verbatim, fenceInfo's first token labels
        // it (section 11). A fence inside a list item still becomes a chip -
        // verbatim code outranks the nesting model.
        for comp in components {
            if case let .codeBlock(fenceInfo) = comp.kind {
                let label = (fenceInfo ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .first
                    .map(String.init)
                // The content run carries the fence's trailing newline
                // verbatim; CommonMark makes that break part of the fence,
                // not the content, so one trailing \n is stripped.
                var content = String(group.text.characters)
                if content.hasSuffix("\n") { content.removeLast() }
                return .code(CodeChip(text: content, label: label))
            }
        }

        // List items. Nesting depth = number of listItem components; the
        // payload carries the item's 1-based number within its own list
        // (the author's start number preserved, per the probe).
        let listItems = components.filter {
            if case .listItem = $0.kind { return true }
            return false
        }
        if let first = listItems.first, case let .listItem(number) = first.kind {
            let ordered = components.contains {
                if case .orderedList = $0.kind { return true }
                return false
            }
            return .listItem(ordered: ordered, number: number, depth: listItems.count, text: group.text)
        }

        if components.contains(where: {
            if case .blockQuote = $0.kind { return true }
            return false
        }) {
            return .quote(group.text)
        }

        // Tables and thematic breaks degrade: table cell text joins into one
        // plain paragraph per table run; the break's "⸻" glyph degrades like
        // a paragraph (section 11).
        let isTableCell = components.contains { comp in
            switch comp.kind {
            case .table, .tableHeaderRow: return true
            default:
                if case .tableRow = comp.kind { return true }
                if case .tableCell = comp.kind { return true }
                return false
            }
        }
        if isTableCell {
            return .paragraph(group.text, fromTable: true)
        }
        return .paragraph(group.text, fromTable: false)
    }
}
