import AppKit

/// The chamfered native single-line answer field (design.md section 13).
///
/// A plain `NSTextField` (borderless, no background, no focus ring) inside a
/// chamfer-masked container whose layers paint the section 2 states: idle
/// white 2% / white 18%, focused accent 8% / accent 65%, the section 7
/// 120ms crossfade. The field is single-line on every insertion path,
/// including paste: line breaks are rejected at insertion, not trimmed from
/// an accepted answer. The caret and selection live in the field editor,
/// inside the masked content tree - no external caret overlay exists.
@MainActor
final class AnswerField: NSView {

    let textField: NSTextField
    /// The dedicated single-line editor, installed through the panel
    /// delegate's field-editor hook; AppKit's shared editor is never used
    /// for this field.
    var fieldEditor: SingleLineFieldEditor?
    private let fillLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// The notification token in a Sendable box: deinit must be nonisolated
    /// under Swift 6, and the box is only ever touched on the main actor
    /// during life.
    private let observerBox = ObserverBox()
    private var focused = false { didSet { restyle() } }

    /// Focus notifications for keyboard routing (never for key capture -
    /// an unfocused field's delegate sees no keys).
    var onFocusChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let field = NSTextField()
        textField = field
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.font = Theme.fieldFont
        field.textColor = Theme.textBody
        field.placeholderAttributedString = NSAttributedString(
            string: Theme.answerFieldPlaceholder,
            attributes: [
                .font: Theme.fieldFont,
                .foregroundColor: Theme.textSecondary,
            ]
        )
        field.setAccessibilityLabel("custom answer")
        field.setAccessibilityRole(.textField)
        field.setAccessibilityHelp(Theme.answerFieldPlaceholder)
        field.alignment = .natural

        let mask = CAShapeLayer()
        layer?.mask = mask
        fillLayer.fillColor = NSColor.white.withAlphaComponent(0.02).cgColor
        layer?.addSublayer(fillLayer)
        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)

        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.fieldHorizontalInset),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.fieldHorizontalInset),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: Theme.fieldLineHeight),
        ])

        observerBox.token = NotificationCenter.default.addObserver(
            forName: NSControl.textDidBeginEditingNotification,
            object: field,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.editingBegan()
            }
        }
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AnswerField is created in code only")
    }

    deinit {
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: Focus and content access

    /// Focused means the field's active editor is the window's first
    /// responder (section 13 definition).
    func isFocused(in window: NSWindow?) -> Bool {
        guard let window, let editor = textField.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    /// The live editor content, checked before the backing value: the cell
    /// copy can lag the editor mid-edit.
    var liveStringValue: String {
        if let editor = textField.currentEditor() as? NSTextView {
            return editor.string
        }
        return textField.stringValue
    }

    @discardableResult
    func focus(in panel: NSPanel) -> Bool {
        panel.makeFirstResponder(textField)
    }

    /// End editing without submitting. With `discard`, the uncommitted
    /// text is dropped too (Escape, Close, give-up, step swap); without it,
    /// blur semantics keep the text while the field loses focus.
    func endEditing(in panel: NSPanel?, discard: Bool) {
        if discard {
            if let editor = textField.currentEditor() as? NSTextView {
                editor.string = ""
            }
            textField.stringValue = ""
        }
        if let panel, isFocused(in: panel) {
            panel.makeFirstResponder(nil)
        }
    }

    /// The per-step reset (section 13 batch): end editing without
    /// submitting and clear editor plus backing text, unfocused.
    func resetForStep(panel: NSPanel?) {
        endEditing(in: panel, discard: true)
    }

    // MARK: Editor styling

    private func editingBegan() {
        focused = true
        onFocusChange?()
        guard let editor = textField.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = Theme.accent
        editor.selectedTextAttributes = [
            .backgroundColor: Theme.accent.withAlphaComponent(0.35),
        ]
        editor.typingAttributes = [
            .font: Theme.fieldFont,
            .foregroundColor: Theme.textBody,
        ]
    }

    /// Refresh the visual focus state from the actual responder (called
    /// after blur paths that bypass the end-editing notification).
    func refreshFocusState(panel: NSPanel?) {
        let now = isFocused(in: panel)
        if now != focused {
            focused = now
            if !now { onFocusChange?() }
        }
    }

    // MARK: Visual states (section 2)

    private func restyle() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduceMotion ? 0 : Theme.hoverCrossfade)
        fillLayer.backgroundColor = (focused
            ? Theme.accent.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.02)).cgColor
        borderLayer.strokeColor = (focused
            ? Theme.accent.withAlphaComponent(0.65)
            : NSColor.white.withAlphaComponent(0.18)).cgColor
        CATransaction.commit()
        textField.textColor = Theme.textBody
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = Chamfer.path(cut: Theme.fieldCut, in: bounds)
        (layer?.mask as? CAShapeLayer)?.path = path
        fillLayer.path = path
        borderLayer.path = Chamfer.borderPath(cut: Theme.fieldCut, in: bounds)
        CATransaction.commit()
    }

    /// The whole 28pt band focuses the field, corners included: it is one
    /// text field, not a hit rectangle with dead margins.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return textField.hitTest(convert(point, to: textField)) ?? textField
    }
}

/// Carries the notification token across the isolation boundary in deinit.
private final class ObserverBox: @unchecked Sendable {
    var token: NSObjectProtocol?
}

/// The single-line field editor (section 13: Return never inserts a
/// newline; paste never becomes multiline). Returned by the panel's window
/// delegate for the answer field only; every other control keeps AppKit's
/// shared editor.
@MainActor
final class SingleLineFieldEditor: NSTextView {

    override func insertNewline(_ sender: Any?) {
        // Swallowed, never inserted: Return is the commit gesture, routed by
        // the panel's key monitor before the editor ever sees it.
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String {
            guard let sanitized = Self.rejectingLineBreaks(text) else { return }
            super.insertText(sanitized, replacementRange: replacementRange)
        } else if let attributed = string as? NSAttributedString {
            guard let sanitized = Self.rejectingLineBreaks(attributed.string) else { return }
            super.insertText(
                NSAttributedString(string: sanitized, attributes: attributed.attributes(at: 0, effectiveRange: nil)),
                replacementRange: replacementRange
            )
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    override func paste(_ sender: Any?) {
        guard let contents = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(Self.rejectingLineBreaks(contents) ?? "", replacementRange: NSRange())
    }

    /// Reject the line-break insertion itself: any newline, carriage
    /// return, or Unicode line/paragraph separator is removed from the
    /// inserted run. The accepted answer text is never edited.
    private static func rejectingLineBreaks(_ text: String) -> String? {
        guard text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
            return text
        }
        var result = String()
        result.reserveCapacity(text.count)
        for character in text
        where character != "\n" && character != "\r" && character != "\u{2028}" && character != "\u{2029}" {
            result.append(character)
        }
        return result
    }
}

/// Panel delegate answering only the field-editor question; every other
/// window delegate method keeps AppKit's default.
@MainActor
final class AnswerFieldEditorProvider: NSObject, NSWindowDelegate {
    weak var answerField: AnswerField?

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let answerField, let control = client as? NSControl, control === answerField.textField else {
            return nil
        }
        if let editor = answerField.fieldEditor {
            return editor
        }
        let editor = SingleLineFieldEditor()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = false
        editor.setAccessibilityLabel("custom answer")
        answerField.fieldEditor = editor
        return editor
    }
}
