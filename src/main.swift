import AppKit

// ask-away: one process, one question, one answer on stdout.
// Exit codes: 0 clicked | 2 canceled | 3 gave up | 1 usage error.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: .darkAqua)

let arguments = Array(CommandLine.arguments.dropFirst())

if let first = arguments.first, first == "--help" || first == "-h" {
    print(Question.usage)
    exit(0)
}

let question: Question
do {
    question = try Question.parse(arguments)
} catch {
    FileHandle.standardError.write(Data("ask-away: \(error)\n".utf8))
    FileHandle.standardError.write(Data("run `ask-away --help` for the flag surface\n".utf8))
    exit(1)
}

PanelController(question: question).run()
