import AppKit

// Test driver for ask-away: same app setup and run flow as src/main.swift,
// but it schedules event injection from the ASKAWAY_SIM env var before the
// app loop starts. The injections go through the real in-app dispatch
// pipeline (NSApp.postEvent -> run loop -> hit test / performKeyEquivalent /
// local keyDown monitor) without any TCC-gated synthetic-event posting to
// another session - safe on CI runners with no Accessibility grant.
//
// ASKAWAY_SIM is a comma-separated action list, one action per step (or
// fewer; later steps wait):
//   answer      - click the current step's default (filled) button
//   click:N     - click the Nth button in reading order (wrapped rows count)
//   escape      - post Escape
//   return      - post Return (the default button)
//   stop        - ignore the rest
// Examples:
//   ASKAWAY_SIM="click-default"          (single question)
//   ASKAWAY_SIM="answer,escape"          (batch: answer step 1, Escape step 2)
//   ASKAWAY_SIM="answer,click:4,answer"  (batch with a wrapped 4-button row)
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

    private static let actions: [String] = (ProcessInfo.processInfo.environment["ASKAWAY_SIM"] ?? "")
        .split(separator: ",")
        .map(String.init)

    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)

        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let invocation = try? Question.parseInvocation(arguments) else {
            FileHandle.standardError.write(Data("simdriver: bad arguments\n".utf8))
            exit(1)
        }
        let (questions, batch): ([Question], Bool)
        switch invocation {
        case let .single(question): (questions, batch) = ([question], false)
        case let .batch(parsed): (questions, batch) = (parsed, true)
        }

        // Action i fires at 0.7s + i * 0.9s: past the 180ms entrance, past a
        // 180ms step crossfade, and comfortably inside any give-up bound the
        // fixture sets.
        for (index, action) in actions.enumerated() {
            let when = DispatchTime.now() + 0.7 + Double(index) * 0.9
            DispatchQueue.main.asyncAfter(deadline: when) {
                if action == "stop" { return }
                perform(action)
            }
        }

        PanelController(questions: questions, batch: batch).run()
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
            if let button = view as? ChamferButton { found.append(button) }
            for sub in view.subviews { walk(sub) }
        }
        walk(contentView)
        return found.sorted {
            if $0.frame.maxY != $1.frame.maxY { return $0.frame.maxY > $1.frame.maxY }
            return $0.frame.minX < $1.frame.minX
        }
    }

    private static func postKey(_ keyCode: UInt16, characters: String) {
        guard let panel = currentPanel() else {
            FileHandle.standardError.write(Data("simdriver: no panel for key\n".utf8))
            exit(1)
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
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
