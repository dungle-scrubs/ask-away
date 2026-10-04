import AppKit

// ask-away: one process, one question (or a §12 sequence), one outcome on
// stdout.
// Exit codes: 0 answered | 2 canceled | 3 gave up | 1 usage, parse, or
// validation error.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first == "--help" || first == "-h" {
    print(Question.usage)
    exit(0)
}

do {
    let parsed = try Question.parseInvocation(arguments)
    switch parsed.content {
    case let .single(question):
        PanelController(questions: [question], batch: false, attention: parsed.attention).run()
    case let .batch(questions):
        PanelController(questions: questions, batch: true, attention: parsed.attention).run()
    }
} catch {
    FileHandle.standardError.write(Data("ask-away: \(error)\n".utf8))
    FileHandle.standardError.write(Data("run `ask-away --help` for the flag surface\n".utf8))
    exit(1)
}
