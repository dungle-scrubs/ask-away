import Foundation

/// The parsed invocation: everything ask-away needs to draw one question.
///
/// Flag surface is identical to the predecessor renderer
/// (ask-on-screen/scripts/ask.sh): --title, --text, --buttons B1 [B2] [B3],
/// --default N (1-based, default = last button), --give-up-after SECONDS,
/// --no-beep. Any parse failure is a usage error: message on stderr, exit 1.
struct Question {
    let title: String
    let text: String
    let buttons: [String]
    /// 0-based index into `buttons` of the Return-bound default.
    let defaultIndex: Int
    /// nil means no bound: the panel waits forever.
    let giveUpAfter: TimeInterval?
    let beep: Bool

    var defaultButtonTitle: String { buttons[defaultIndex] }

    enum ParseError: Error, CustomStringConvertible {
        case missingValueFor(String)
        case unknownArgument(String)
        case missingRequired
        case badButtonCount(Int)
        case badDefault(String, count: Int)
        case badGiveUpAfter(String)

        var description: String {
            switch self {
            case let .missingValueFor(flag):
                return "missing value for \(flag)"
            case let .unknownArgument(arg):
                return "unknown argument: \(arg)"
            case .missingRequired:
                return "needs --title, --text, and 2 or 3 --buttons"
            case let .badButtonCount(count):
                return "needs 2 or 3 buttons, got \(count)"
            case let .badDefault(value, count):
                return "--default must be 1..\(count), got \(value)"
            case let .badGiveUpAfter(value):
                return "--give-up-after must be a number of seconds >= 0, got \(value)"
            }
        }
    }

    static let usage = """
    ask-away - put one decision on the user's screen, get the answer back on stdout.

    Usage:
      ask-away --title TITLE --text TEXT --buttons B1 [B2] [B3]
               [--default N] [--give-up-after SECONDS] [--no-beep]

    Flags:
      --title TITLE          One line: "repo-name: what this decides".
      --text TEXT            One or two sentences. Inline `code`, **strong**,
                             *em* spans render; everything else is plain text.
      --buttons B1 [B2] [B3] Two or three buttons, left to right in the order
                             given. The rightmost is the recommended answer.
      --default N            1-based default button (Return). Defaults to the
                             LAST button. Position never changes; the fill
                             marks the recommendation.
      --give-up-after S      Close unanswered after S seconds and print
                             GAVE-UP. The panel shows a draining countdown.
      --no-beep              Suppress the single beep at appearance.

    Output (stdout): the clicked button's text, or CANCELED, or GAVE-UP.
    Exit codes: 0 clicked | 2 canceled (Escape or a button named "Cancel")
    | 3 gave up | 1 usage error.

    A panel appears over the current app, on the screen holding the pointer,
    and never activates or steals focus. Parallel invocations cascade.
    """

    static func parse(_ arguments: [String]) throws(ParseError) -> Question {
        var title: String?
        var text: String?
        var buttons: [String] = []
        var defaultOneBased: Int?
        var giveUpAfter: TimeInterval?
        var beep = true

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--title", "--text":
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                if arg == "--title" { title = arguments[i + 1] } else { text = arguments[i + 1] }
                i += 2
            case "--buttons":
                i += 1
                while i < arguments.count, !arguments[i].hasPrefix("--") {
                    buttons.append(arguments[i])
                    i += 1
                }
            case "--default":
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                guard let n = Int(arguments[i + 1]) else {
                    throw .badDefault(arguments[i + 1], count: 0)
                }
                defaultOneBased = n
                i += 2
            case "--give-up-after":
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                guard let s = Double(arguments[i + 1]), s >= 0 else {
                    throw .badGiveUpAfter(arguments[i + 1])
                }
                giveUpAfter = s
                i += 2
            case "--no-beep":
                beep = false
                i += 1
            case "--help", "-h":
                // Handled before parse in main(); reaching here is a bug.
                throw .unknownArgument(arg)
            default:
                throw .unknownArgument(arg)
            }
        }

        guard let title, !title.isEmpty, let text, !text.isEmpty, !buttons.isEmpty else {
            throw .missingRequired
        }
        guard buttons.count >= 2, buttons.count <= 3 else {
            throw .badButtonCount(buttons.count)
        }
        let defaultIndex = defaultOneBased.map { $0 - 1 } ?? buttons.count - 1
        guard defaultIndex >= 0, defaultIndex < buttons.count else {
            throw .badDefault(String(defaultOneBased!), count: buttons.count)
        }
        return Question(
            title: title,
            text: text,
            buttons: buttons,
            defaultIndex: defaultIndex,
            giveUpAfter: giveUpAfter,
            beep: beep
        )
    }
}
