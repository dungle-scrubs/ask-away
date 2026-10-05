import AppKit

/// The field's own text control. The stock NSTextField refuses the
/// responder transition in this non-activating panel whenever the panel is
/// not key - an active user session keeps key elsewhere, and AppKit then
/// installs the editor, returns true from makeFirstResponder, and never
/// moves the responder (measured). Taking key synchronously before the
/// stock mouseDown makes the transition real; accepting first mouse lets
/// the very first click reach the control at all instead of being consumed
/// by window ordering.
@MainActor
class AnswerTextField: NSTextField {
    weak var fieldOwner: AnswerField?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? NSPanel, !panel.isKeyWindow {
            panel.makeKey()
        }
        super.mouseDown(with: event)
        if let panel = window as? NSPanel {
            // A click asked for focus; if the transition is still deferred
            // (AppKit can hold it until the window becomes key), mark it so
            // windowDidBecomeKey applies it exactly once.
            fieldOwner?.noteClickFocusOutcome(in: panel)
        }
    }
}

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

    /// True once the user deliberately focused this field - a real key or
    /// mouse event drove editing (Tab routing, printable capture, or a
    /// click). Programmatic or AppKit key-view-loop focus (the makeKey
    /// steal) never sets it. The panel's focus pin consults this flag so
    /// no correction can remove deliberately acquired focus (section 13).
    private(set) var userFocusAcquired = false
    /// A click asked for focus while the responder transition was deferred
    /// until the window becomes key; applied once on windowDidBecomeKey.
    private(set) var pendingBecomeKeyFocus = false

    override init(frame frameRect: NSRect) {
        let field = AnswerTextField()
        textField = field
        super.init(frame: frameRect)
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
                .kern: Theme.fieldKerning,
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
        field.fieldOwner = self
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
    /// submitting, clear editor plus backing text, unfocused, with the
    /// user-focus and pending-transition markers cleared for the new step.
    func resetForStep(panel: NSPanel?) {
        userFocusAcquired = false
        pendingBecomeKeyFocus = false
        endEditing(in: panel, discard: true)
    }

    /// Record whether a click's focus request verified immediately or is
    /// deferred to the moment the window becomes key (called from the text
    /// field's own mouseDown, after the stock handling ran).
    func noteClickFocusOutcome(in panel: NSPanel) {
        pendingBecomeKeyFocus = !isFocused(in: panel)
    }

    /// Apply a deferred click-focus transition. A real click asked for
    /// this focus, so acquiring it counts as user-initiated. Returns true
    /// when a pending transition existed (applied or not, it is consumed).
    @discardableResult
    func applyPendingBecomeKeyFocus(in panel: NSPanel) -> Bool {
        guard pendingBecomeKeyFocus else { return false }
        pendingBecomeKeyFocus = false
        if !isFocused(in: panel) {
            focus(in: panel)
        }
        if isFocused(in: panel) {
            userFocusAcquired = true
        }
        return true
    }

    // MARK: Editor styling

    private func editingBegan() {
        focused = true
        // User-initiated focus means a real input event drove editing: a
        // key (Tab routing, printable capture, direct typing) or a mouse
        // click. The AppKit key-view-loop steal carries no user event, so
        // it never sets the flag and the pin may undo it.
        if let event = NSApp.currentEvent {
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
                userFocusAcquired = true
                pendingBecomeKeyFocus = false
            default:
                break
            }
        }
        onFocusChange?()
        guard let editor = textField.currentEditor() as? NSTextView else { return }
        editor.insertionPointColor = Theme.accent
        editor.selectedTextAttributes = [
            .backgroundColor: Theme.accent.withAlphaComponent(0.35),
        ]
        editor.typingAttributes = [
            .font: Theme.fieldFont,
            .foregroundColor: Theme.textBody,
            .kern: Theme.fieldKerning,
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
        // The painted shape carries the state (section 2): the fill is the
        // chamfered path's fillColor - idle white 2%, focused accent 8% -
        // never a background color, which the path would leave visible
        // outside its geometry.
        fillLayer.fillColor = (focused
            ? Theme.accent.withAlphaComponent(0.08)
            : NSColor.white.withAlphaComponent(0.02)).cgColor
        borderLayer.strokeColor = (focused
            ? Theme.accent.withAlphaComponent(0.65)
            : NSColor.white.withAlphaComponent(0.18)).cgColor
        CATransaction.commit()
        textField.textColor = Theme.textBody
    }

    /// Set the frame and build the chamfer geometry immediately: the
    /// layout pass can arrive after first render in this non-activating
    /// panel, and a nil-path layer mask hides the whole subtree (measured:
    /// band, hairline, and placeholder all absent from the capture).
    func place(in rect: NSRect) {
        frame = rect
        rebuildGeometry()
    }

    private func rebuildGeometry() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = Chamfer.path(cut: Theme.fieldCut, in: bounds)
        (layer?.mask as? CAShapeLayer)?.path = path
        fillLayer.path = path
        borderLayer.path = Chamfer.borderPath(cut: Theme.fieldCut, in: bounds)
        // The inner text field is framed eagerly too: this panel's first
        // render can precede any layout pass, and constraints alone would
        // leave it at zero size (measured: placeholder absent).
        textField.frame = NSRect(
            x: Theme.fieldHorizontalInset,
            y: (bounds.height - Theme.fieldLineHeight) / 2,
            width: bounds.width - 2 * Theme.fieldHorizontalInset,
            height: Theme.fieldLineHeight
        )
        CATransaction.commit()
    }

    /// The whole 28pt band focuses the field, corners included: it is one
    /// text field, not a hit rectangle with dead margins.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return textField.hitTest(convert(point, to: textField)) ?? textField
    }

    override func layout() {
        super.layout()
        rebuildGeometry()
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
        // Insert at the editor's live selection, not a zero range at
        // location 0: a caret mid-text pastes there, and a selected
        // substring is replaced by the paste (finding 11).
        insertText(Self.rejectingLineBreaks(contents) ?? "", replacementRange: selectedRange())
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

/// Panel delegate answering only the field-editor question (plus the
/// become-key focus hook); every other window delegate method keeps
/// AppKit's default.
@MainActor
final class AnswerFieldEditorProvider: NSObject, NSWindowDelegate {
    weak var answerField: AnswerField?
    /// Fired on windowDidBecomeKey: the panel re-asserts its focus pin at
    /// the exact event where the key-view-loop steal lands.
    var onPanelBecameKey: (() -> Void)?

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

    func windowDidBecomeKey(_ notification: Notification) {
        onPanelBecameKey?()
    }
}
