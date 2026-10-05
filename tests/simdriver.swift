import AppKit

// Test driver for ask-away: same app setup and run flow as src/main.swift,
// but it schedules event injection from the ASKAWAY_SIM / ASKAWAY_SIM_SCRIPT
// env vars before the app loop starts. The injections go through the real
// in-app dispatch pipeline (NSApp.postEvent -> run loop -> hit test /
// performKeyEquivalent / local keyDown monitor) without any TCC-gated
// synthetic-event posting to another session - safe on CI runners with no
// Accessibility grant.
//
// ASKAWAY_SIM is a comma-separated action list, one action per step (or
// fewer; later steps wait):
//   answer      - click the current step's default (filled) button
//   click:N     - click the Nth button in reading order (wrapped rows count)
//   close       - click the Close control
//   escape      - post Escape
//   return      - post Return (the default button)
//   stop        - ignore the rest
//
// ASKAWAY_SIM_SCRIPT is a JSON alternative with timestamps:
//   {"actions":[{"at":0.7,"action":"answer"},{"at":3.2,"action":"escape"}]}
// Times are seconds from panel start; both variables may be set.
//
// Attention injection seam (plan section 4; test builds only - the shipped
// binary never reads these):
//   ASKAWAY_ATTENTION_SCRIPT - timestamped probe snapshots (see below)
//   ASKAWAY_ATTENTION_TRACE  - JSONL state/effect evidence output path
// When set, the scripted engine replaces the live probe, effects are
// observed and traced instead of performed (no real activation during
// suites), and the trace file records evaluations, first evaluation,
// escalation effects, beeps, and stop. With --no-attention the scripted
// engine is still constructed here, but the panel must never call it; any
// call writes a poison marker line into the trace.
//
// Build: swiftc (src/*.swift minus main.swift) + tests/simdriver.swift.

@main
struct SimDriverMain {
    static func main() {
        Simulator.run()
    }
}

@MainActor
private enum Simulator {

    private struct Scheduled {
        let at: Double
        let action: String
    }

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let parsed = try? Question.parseInvocation(arguments) else {
            FileHandle.standardError.write(Data("simdriver: bad arguments\n".utf8))
            exit(1)
        }
        let (questions, batch): ([Question], Bool)
        switch parsed.content {
        case let .single(question): (questions, batch) = ([question], false)
        case let .batch(parsedQuestions): (questions, batch) = (parsedQuestions, true)
        }

        var dependencies: AttentionDependencies?
        if
            let scriptPath = ProcessInfo.processInfo.environment["ASKAWAY_ATTENTION_SCRIPT"],
            let tracePath = ProcessInfo.processInfo.environment["ASKAWAY_ATTENTION_TRACE"]
        {
            dependencies = makeAttentionSeam(
                scriptPath: scriptPath,
                tracePath: tracePath,
                poison: !parsed.attention.enabled
            )
        } else if
            let tmuxExecutable = ProcessInfo.processInfo.environment["ASKAWAY_TMUX_EXECUTABLE"],
            let tmuxContext = ProcessInfo.processInfo.environment["ASKAWAY_TMUX_CONTEXT"],
            let tracePath = ProcessInfo.processInfo.environment["ASKAWAY_ATTENTION_TRACE"]
        {
            // Live-engine path with an injected tmux executable: exercises
            // the real subprocess budget and first-evaluation deadline.
            var environment = MultiplexerProbe.currentEnvironment()
            environment["TMUX"] = tmuxContext
            let writer = TraceWriter(path: tracePath)
            dependencies = AttentionDependencies(
                probe: LiveAttentionEngine(environment: environment, tmuxExecutable: tmuxExecutable),
                effects: RecordingAttentionEffects(trace: { line in writer.append(line) }),
                clock: .live,
                trace: { line in writer.append(line) }
            )
        } else if let liveTracePath = ProcessInfo.processInfo.environment["ASKAWAY_ATTENTION_LIVE_TRACE"] {
            // Real live engine with observed effects and a trace: the
            // harness records actual host resolution, states, and effects
            // without performing real activation.
            let writer = TraceWriter(path: liveTracePath)
            dependencies = AttentionDependencies(
                probe: LiveAttentionEngine(),
                effects: RecordingAttentionEffects(trace: { line in writer.append(line) }),
                clock: .live,
                trace: { line in writer.append(line) }
            )
        }

        let scheduled = scheduledActions()
        // The panel's run() never returns; actions are armed before it.
        for event in scheduled {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, event.at)) {
                if event.action == "stop" { return }
                perform(event.action)
            }
        }

        PanelController(questions: questions, batch: batch, attention: parsed.attention, dependencies: dependencies).run()
    }

    // MARK: Attention injection seam

    private static func makeAttentionSeam(scriptPath: String, tracePath: String, poison: Bool) -> AttentionDependencies {
        let writer = TraceWriter(path: tracePath)
        let engine = ScriptedAttentionEngine(scriptPath: scriptPath, poison: poison, trace: { line in
            writer.append(line)
        })
        let effects = RecordingAttentionEffects(trace: { line in
            writer.append(line)
        })
        return AttentionDependencies(
            probe: engine,
            effects: effects,
            clock: .live,
            trace: { line in writer.append(line) }
        )
    }

    /// Sequential appends on the main actor only; created empty so a
    /// crashed run still leaves whatever evidence it had written.
    @MainActor
    private final class TraceWriter {
        private let handle: FileHandle

        init(path: String) {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path) ?? FileHandle.nullDevice
            _ = handle.seekToEndOfFile()
        }

        func append(_ line: String) {
            handle.write(Data((line + "\n").utf8))
        }
    }

    /// Probe-input scripts, not precomputed states: samples carry host,
    /// visibility, attachment, and hard-absence readings with timestamps;
    /// the latest sample at or before now is held until replaced.
    @MainActor
    private final class ScriptedAttentionEngine: AttentionProbeSource {
        private struct Sample {
            let at: Double
            let host: String
            let visibility: Int?
            let attachment: String
            let displayAsleep: Bool
            let screensaver: Bool
        }

        private let samples: [Sample]
        private let base = ProcessInfo.processInfo.systemUptime
        private let poisonMode: Bool
        private let trace: ((String) -> Void)?

        init(scriptPath: String, poison: Bool, trace: ((String) -> Void)?) {
            self.poisonMode = poison
            self.trace = trace
            var loaded: [Sample] = []
            if
                let data = FileManager.default.contents(atPath: scriptPath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawSamples = json["samples"] as? [[String: Any]]
            {
                for raw in rawSamples {
                    loaded.append(Sample(
                        at: raw["at"] as? Double ?? 0,
                        host: raw["host"] as? String ?? "unidentified",
                        visibility: raw["visibility"] as? Int,
                        attachment: raw["attachment"] as? String ?? "nosignal",
                        displayAsleep: raw["displayAsleep"] as? Bool ?? false,
                        screensaver: raw["screensaver"] as? Bool ?? false
                    ))
                }
            } else {
                FileHandle.standardError.write(Data("simdriver: unreadable attention script\n".utf8))
            }
            samples = loaded.sorted { $0.at < $1.at }
        }

        func beginDiscovery() {
            poison()
        }

        func refreshTransient() {
            poison()
        }

        func readSnapshot(now: Double) -> AttentionSnapshot {
            poison()
            let relative = now - base
            let current = samples.last { $0.at <= relative } ?? samples.first
            let hosting: HostingReading
            switch current?.host {
            case "identified": hosting = .identified(hostPIDs: [4242])
            case "pending", nil: hosting = .pending
            default: hosting = .unidentified
            }
            let visibility: VisibilityReading
            if let count = current?.visibility {
                visibility = .count(count)
            } else {
                visibility = .noSignal
            }
            let attachment: AttachmentReading
            switch current?.attachment {
            case "attached": attachment = .attached(ttys: [])
            case "detached": attachment = .detached
            default: attachment = .noSignal
            }
            let hard: HardAbsenceReading
            if current?.displayAsleep == true {
                hard = .absent(displayAsleep: true, screensaver: false)
            } else if current?.screensaver == true {
                hard = .absent(displayAsleep: false, screensaver: true)
            } else {
                hard = .awake
            }
            return AttentionSnapshot(now: now, hosting: hosting, visibility: visibility, attachment: attachment, hardAbsence: hard)
        }

        /// Under --no-attention the panel must never call the probe: a call
        /// writes the poison line and fails the suite.
        private func poison() {
            guard poisonMode else { return }
            trace?("{\"event\":\"POISON\",\"detail\":\"probe called under no-attention\"}")
        }
    }

    /// Observes escalation effects instead of performing them: no real
    /// activation, no real sound during suites. Every call is traced.
    @MainActor
    private final class RecordingAttentionEffects: AttentionEffectsObserver {
        private let trace: ((String) -> Void)?
        private(set) var activations = 0
        private(set) var orderFronts = 0
        private(set) var levelRaises = 0
        private(set) var beeps = 0

        init(trace: ((String) -> Void)?) {
            self.trace = trace
        }

        func activateApplication() {
            activations += 1
            trace?("{\"t\":\(stamp()),\"event\":\"observedActivate\"}")
        }

        func makeKeyAndOrderFront() {
            orderFronts += 1
            trace?("{\"t\":\(stamp()),\"event\":\"observedMakeKeyAndOrderFront\"}")
        }

        func raiseLevelToScreenSaver() {
            levelRaises += 1
            trace?("{\"t\":\(stamp()),\"event\":\"observedRaiseLevel\"}")
        }

        func playEscalationBeep(index: Int) {
            beeps += 1
        }

        func playAppearBeep() {
            beeps += 1
        }

        private func stamp() -> String {
            String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        }
    }

    // MARK: Event scheduling

    private static func scheduledActions() -> [Scheduled] {
        var events: [Scheduled] = []
        if let scriptPath = ProcessInfo.processInfo.environment["ASKAWAY_SIM_SCRIPT"] {
            if
                let data = FileManager.default.contents(atPath: scriptPath),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let actions = json["actions"] as? [[String: Any]]
            {
                for action in actions {
                    events.append(Scheduled(
                        at: action["at"] as? Double ?? 0,
                        action: action["action"] as? String ?? "stop"
                    ))
                }
            } else {
                FileHandle.standardError.write(Data("simdriver: unreadable sim script\n".utf8))
            }
        }
        let legacy = (ProcessInfo.processInfo.environment["ASKAWAY_SIM"] ?? "")
            .split(separator: ",")
            .map(String.init)
        for (index, action) in legacy.enumerated() {
            events.append(Scheduled(at: 0.7 + Double(index) * 0.9, action: action))
        }
        return events.sorted { $0.at < $1.at }
    }

    private static func currentPanel() -> NSPanel? {
        NSApp.windows.compactMap { $0 as? NSPanel }.first
    }

    /// The live ChamferButtons of the current step, in reading order (top row
    /// first, then left to right).
    private static func currentButtons() -> [ChamferButton] {
        guard let panel = currentPanel(), let contentView = panel.contentView else { return [] }
        var found: [ChamferButton] = []
        func walk(_ view: NSView) {
            if let button = view as? ChamferButton, button !== (contentView as? PanelRootView)?.closeButton {
                found.append(button)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(contentView)
        return found.sorted {
            if $0.frame.maxY != $1.frame.maxY { return $0.frame.maxY > $1.frame.maxY }
            return $0.frame.minX < $1.frame.minX
        }
    }

    private static func postKey(_ keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) {
        guard let panel = currentPanel() else {
            FileHandle.standardError.write(Data("simdriver: no panel for key\n".utf8))
            exit(1)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            FileHandle.standardError.write(Data("simdriver: key event creation failed\n".utf8))
            exit(1)
        }
        NSApp.postEvent(event, atStart: false)
    }

    /// A click on an arbitrary view (buttons and the answer field alike).
    private static func click(view: NSView) {
        guard let panel = currentPanel() else {
            FileHandle.standardError.write(Data("simdriver: no panel for click\n".utf8))
            exit(1)
        }
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let mouse = NSEvent.mouseEvent(
                with: type,
                location: center,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                FileHandle.standardError.write(Data("simdriver: mouse event creation failed\n".utf8))
                exit(1)
            }
            NSApp.postEvent(mouse, atStart: false)
        }
    }

    /// A quiet point on the panel background: the left padding gutter at
    /// mid height (panel-local x=10), the point the v0.1.1 drag driver
    /// measured as the plain drag surface.
    private static func quietPoint() -> CGPoint? {
        guard let panel = currentPanel(), let root = panel.contentView else { return nil }
        return CGPoint(x: Theme.windowMargin + 10, y: root.bounds.height / 2)
    }

    private static func postMouseEvent(_ type: NSEvent.EventType, at location: CGPoint) {
        guard let panel = currentPanel() else { return }
        guard let mouse = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        NSApp.postEvent(mouse, atStart: false)
    }

    /// Write the live field/keyboard state to a file for suite assertions:
    /// first responder kind, field focus, live field value, editor presence.
    /// The answer field's center and a quiet panel-background point, in
    /// screen coordinates, for HID click tests.
    private static func writeFieldRect(to path: String) {
        guard
            let panel = currentPanel(),
            let root = panel.contentView as? PanelRootView,
            let field = root.answerField
        else {
            try? "{\"error\":\"no panel\"}".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let center = field.convert(CGPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let screen = panel.convertToScreen(NSRect(origin: center, size: .zero)).origin
        let quietLocal = CGPoint(x: Theme.windowMargin + 10, y: root.bounds.height / 2)
        let quiet = panel.convertToScreen(NSRect(origin: quietLocal, size: .zero)).origin
        let payload: [String: Any] = [
            "fieldCenterX": screen.x,
            "fieldCenterY": screen.y,
            "quietX": quiet.x,
            "quietY": quiet.y,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8)
        {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func writeProbe(to path: String) {
        guard let panel = currentPanel(), let root = panel.contentView as? PanelRootView else {
            try? "{\"error\":\"no panel\"}".write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let responderTitle = (panel.firstResponder as? NSButton)?.title ?? ""
        let field = root.answerField
        let payload: [String: Any] = [
            "isKeyWindow": panel.isKeyWindow,
            "firstResponder": responder,
            "responderTitle": responderTitle,
            "fieldFocused": field?.isFocused(in: panel) ?? false,
            "fieldValue": field?.liveStringValue ?? "",
            "hasEditor": field?.textField.currentEditor() != nil,
            "isEditorFocused": field.map { $0.isFocused(in: panel) } ?? false,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8)
        {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func click(_ button: ChamferButton) {
        guard let panel = currentPanel() else {
            FileHandle.standardError.write(Data("simdriver: no panel for click\n".utf8))
            exit(1)
        }
        // Button frames live in the content stack; convert to window
        // coordinates through the view chain (the window carries a 28pt
        // transparent margin around the visual panel).
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let mouse = NSEvent.mouseEvent(
                with: type,
                location: center,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                FileHandle.standardError.write(Data("simdriver: mouse event creation failed\n".utf8))
                exit(1)
            }
            NSApp.postEvent(mouse, atStart: false)
        }
    }

    private static func perform(_ action: String) {
        switch action {
        case _ where action.hasPrefix("probe:"):
            writeProbe(to: String(action.dropFirst("probe:".count)))
        case "field":
            if let root = currentPanel()?.contentView as? PanelRootView, let field = root.answerField {
                click(view: field)
            } else {
                FileHandle.standardError.write(Data("simdriver: no answer field\n".utf8))
                exit(1)
            }
        case "tab":
            postKey(48, characters: "\t")
        case "shifttab":
            postKey(48, characters: "\t", modifiers: .shift)
        case "clickbg":
            if let point = quietPoint() {
                postMouseEvent(.leftMouseDown, at: point)
                postMouseEvent(.leftMouseUp, at: point)
            }
        case "drag":
            if let point = quietPoint() {
                postMouseEvent(.leftMouseDown, at: point)
                postMouseEvent(.leftMouseDragged, at: CGPoint(x: point.x + 40, y: point.y - 30))
                postMouseEvent(.leftMouseUp, at: CGPoint(x: point.x + 40, y: point.y - 30))
            }
        case _ where action.hasPrefix("type:"):
            let text = String(action.dropFirst("type:".count))
            for character in text {
                postKey(0, characters: String(character))
            }
        case _ where action.hasPrefix("paste:"):
            // Drive the editor's real paste: method (pasteboard read plus
            // the single-line rejection path). Posted command-modified key
            // events do not route to field-editor bindings (measured), so
            // the HID path is exercised separately by the real-event driver.
            let text = String(action.dropFirst("paste:".count))
                .replacingOccurrences(of: "\\n", with: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if let root = currentPanel()?.contentView as? PanelRootView,
               let editor = root.answerField?.textField.currentEditor() as? NSTextView {
                editor.paste(nil)
            }
        case _ where action.hasPrefix("select:"):
            // Set the live editor's selection: "select:1-3" selects the
            // substring [1,3); "select:2-2" places the caret at index 2.
            // Drives the paste-position cases through the real editor.
            let parts = String(action.dropFirst("select:".count)).split(separator: "-")
            guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start <= end else {
                FileHandle.standardError.write(Data("simdriver: bad select range\n".utf8))
                exit(1)
            }
            if let root = currentPanel()?.contentView as? PanelRootView,
               let editor = root.answerField?.textField.currentEditor() as? NSTextView {
                editor.selectedRange = NSRange(location: start, length: end - start)
            }
        case _ where action.hasPrefix("fieldrect:"):
            // The answer field's center in screen coordinates plus a quiet
            // background point, for HID-driven click tests: the shell
            // drives real CGEventPost input at these coordinates.
            writeFieldRect(to: String(action.dropFirst("fieldrect:".count)))
        case "modkeyc":
            postKey(8, characters: "c", modifiers: .command)
        case "modkeyo":
            postKey(31, characters: "o", modifiers: .option)
        case "modkeyctrl":
            postKey(8, characters: "c", modifiers: .control)
        case "close":
            if let root = currentPanel()?.contentView as? PanelRootView, let button = root.closeButton {
                click(button)
            } else {
                FileHandle.standardError.write(Data("simdriver: no close button\n".utf8))
                exit(1)
            }
        case "escape":
            postKey(53, characters: "\u{1B}")
        case "return":
            postKey(36, characters: "\r")
        case "answer":
            if let defaultButton = currentButtons().first(where: { $0.kind == .defaultFilled }) {
                click(defaultButton)
            } else {
                FileHandle.standardError.write(Data("simdriver: no default button\n".utf8))
                exit(1)
            }
        case "stop":
            break
        default:
            if action.hasPrefix("click:") {
                let n = Int(action.dropFirst("click:".count)) ?? 0
                let buttons = currentButtons()
                guard n >= 1, n <= buttons.count else {
                    FileHandle.standardError.write(Data("simdriver: no button \(n) (have \(buttons.count))\n".utf8))
                    exit(1)
                }
                click(buttons[n - 1])
            }
            // Unknown actions are ignored: a driver must not fake an outcome.
        }
    }
}
