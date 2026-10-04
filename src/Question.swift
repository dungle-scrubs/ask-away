import Foundation

/// The parsed invocation: one single question from flags, or a sequence of
/// questions from a §12 questions file.
///
/// Flag surface for single questions is identical to the predecessor
/// renderer (ask-on-screen/scripts/ask.sh): --title, --text, --buttons
/// B1 [B2] [B3], --default N (1-based, default = last button),
/// --give-up-after SECONDS, --no-beep. Any parse failure is a usage error:
/// message on stderr, exit 1.
///
/// `--questions-file PATH` ('-' reads stdin) is mutually exclusive with every
/// single-question flag; any co-presence is a usage error naming the
/// conflict, never silent precedence (decision D12).
enum Invocation {
    case single(Question)
    case batch([Question])
}

/// Everything parseInvocation produced: the content invocation plus the
/// invocation-level attention configuration. Attention settings belong to
/// the invocation, never to a Question.
struct ParsedInvocation {
    let content: Invocation
    let attention: AttentionConfig
}

/// One question: single mode parses it from flags; batch mode builds it
/// from a validated questions-file entry. Both draw identically.
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
        case badInterruptAfter(String)
        case badAbsentAfter(String)
        case conflict(with: String, flag: String)
        /// A questions-file load or validation failure; the message is the
        /// SequenceFile error text (spec section 12 wording).
        case documentError(String)

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
            case let .badInterruptAfter(value):
                return "--interrupt-after must be a whole number of seconds >= 0, got \(value)"
            case let .badAbsentAfter(value):
                return "--absent-after must be a whole number of seconds >= 0, got \(value)"
            case let .conflict(with, flag):
                return "\(with) cannot be combined with \(flag)"
            case let .documentError(message):
                return message
            }
        }
    }

    static let usage = """
    ask-away - put a decision on the user's screen, get the answer back on stdout.

    Usage:
      ask-away --title TITLE --text TEXT --buttons B1 [B2] [B3]
               [--default N] [--give-up-after SECONDS] [--no-beep]
               [--interrupt-after SECONDS] [--absent-after SECONDS]
               [--no-attention]
      ask-away --questions-file PATH [--interrupt-after SECONDS]
               [--absent-after SECONDS] [--no-attention]

    Single-question flags:
      --title TITLE          One line: "repo-name: what this decides".
      --text TEXT            Body text, block markup per the design spec:
                             paragraphs, fenced code blocks, lists,
                             blockquotes, links, `code`, **strong**, *em*.
      --buttons B1 [B2] [B3] Two or three buttons, left to right in the order
                             given. The rightmost is the recommended answer.
      --default N            1-based default button (Return). Defaults to the
                             LAST button. Position never changes; the fill
                             marks the recommendation.
      --give-up-after S      Close unanswered after S seconds and print
                             GAVE-UP. The panel shows a draining countdown.
      --no-beep              Suppress the single beep at appearance.

    Attention (works with both modes; escalation only when the hosting
    runtime's window is provably out of view):
      --interrupt-after S    Seconds of confirmed absence before escalation
                             fires mid-flight; 0 (default) escalates on the
                             first confirmed absence. Whole seconds >= 0.
      --absent-after S       Seconds of zero on-screen hosting windows before
                             that counts as absence (the gesture filter);
                             default 20. Whole seconds >= 0.
      --no-attention         No detection, no escalation: the panel behaves
                             exactly as before for attention. Conflicts with
                             --interrupt-after and --absent-after.

    Batch mode (section 12):
      --questions-file PATH  A JSON document of 1-10 questions, each with
                             title, text, 2-4 buttons, optional default
                             (1-based), give_up_after (seconds), no_beep.
                             PATH may be "-" to read stdin to EOF. Walks all
                             questions in one panel. Mutually exclusive with
                             every single-question flag.
                             Output: one line of JSON
                             {"results":[{"index":0,"status":"answered","answer":"..."},...],
                             "stopped_at":N} on stdout.

    Single-question output (stdout): the clicked button's text, or CANCELED,
    GAVE-UP, or CLOSED.
    Exit codes (both modes): 0 answered (batch: every question) | 2 canceled
    (Escape or single-question Cancel; batch: sequence stopped on Escape) |
    3 gave up (batch: a step's bound
    expired) | 4 closed (Close; batch: sequence stopped) | 1 usage, parse,
    or validation error.

    Close is the top-right X. Closing supplies no approval or default answer;
    re-ask in the session UI. Batch Close preserves earlier answers, appends
    a status "closed" entry, and sets stopped_at to that step's 0-based index.
    A batch button labeled "Cancel" answers its step; Escape stops the batch.
    The step indicator is k/n at the upper right; seconds sit at the lower
    left above the drain origin.

    A panel appears over the current app, on the screen holding the pointer,
    and never activates or steals focus. Parallel invocations cascade.
    """

    /// Parse argv into an invocation plus attention configuration. Sequence
    /// files load here too, so every error - usage or document - takes the
    /// single exit-1 path in main.
    static func parseInvocation(_ arguments: [String]) throws(ParseError) -> ParsedInvocation {
        var questionsFilePath: String?
        var singleFlagsUsed: [String] = []
        var attentionFlagsUsed: [String] = []

        func noteSingle(_ flag: String) throws(Question.ParseError) {
            singleFlagsUsed.append(flag)
            if questionsFilePath != nil {
                throw .conflict(with: "--questions-file", flag: flag)
            }
        }

        func wholeSeconds(_ flag: String, _ raw: String) throws(ParseError) -> Int {
            guard let value = Int(raw), value >= 0 else {
                throw flag == "--interrupt-after"
                    ? .badInterruptAfter(raw)
                    : .badAbsentAfter(raw)
            }
            return value
        }

        var title: String?
        var text: String?
        var buttons: [String] = []
        var defaultOneBased: Int?
        var giveUpAfter: TimeInterval?
        var beep = true
        var interruptAfter = AttentionConstants.interruptAfterDefaultSeconds
        var absentAfter = AttentionConstants.absentAfterDefaultSeconds
        var attentionDisabled = false

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--title", "--text":
                try noteSingle(arg)
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                if arg == "--title" { title = arguments[i + 1] } else { text = arguments[i + 1] }
                i += 2
            case "--buttons":
                try noteSingle(arg)
                i += 1
                while i < arguments.count, !arguments[i].hasPrefix("--") {
                    buttons.append(arguments[i])
                    i += 1
                }
            case "--default":
                try noteSingle(arg)
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                guard let n = Int(arguments[i + 1]) else {
                    throw .badDefault(arguments[i + 1], count: 0)
                }
                defaultOneBased = n
                i += 2
            case "--give-up-after":
                try noteSingle(arg)
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                guard let s = Double(arguments[i + 1]), s >= 0 else {
                    throw .badGiveUpAfter(arguments[i + 1])
                }
                giveUpAfter = s
                i += 2
            case "--no-beep":
                try noteSingle(arg)
                beep = false
                i += 1
            case "--interrupt-after":
                attentionFlagsUsed.append(arg)
                if attentionDisabled {
                    throw .conflict(with: "--no-attention", flag: arg)
                }
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                interruptAfter = Double(try wholeSeconds(arg, arguments[i + 1]))
                i += 2
            case "--absent-after":
                attentionFlagsUsed.append(arg)
                if attentionDisabled {
                    throw .conflict(with: "--no-attention", flag: arg)
                }
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                absentAfter = Double(try wholeSeconds(arg, arguments[i + 1]))
                i += 2
            case "--no-attention":
                if let first = attentionFlagsUsed.first {
                    throw .conflict(with: arg, flag: first)
                }
                attentionDisabled = true
                i += 1
            case "--questions-file":
                guard i + 1 < arguments.count else { throw .missingValueFor(arg) }
                if let first = singleFlagsUsed.first {
                    throw .conflict(with: arg, flag: first)
                }
                if questionsFilePath != nil {
                    throw .conflict(with: arg, flag: arg)
                }
                questionsFilePath = arguments[i + 1]
                i += 2
            case "--help", "-h":
                // Handled before parse in main(); reaching here is a bug.
                throw .unknownArgument(arg)
            default:
                throw .unknownArgument(arg)
            }
        }

        if let path = questionsFilePath {
            do {
                let questions = try SequenceFile.load(path)
                return ParsedInvocation(
                    content: .batch(questions),
                    attention: attentionDisabled
                        ? .disabled
                        : AttentionConfig(enabled: true, absentAfter: absentAfter, interruptAfter: interruptAfter)
                )
            } catch {
                throw .documentError(String(describing: error))
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
        let content = Invocation.single(Question(
            title: title,
            text: text,
            buttons: buttons,
            defaultIndex: defaultIndex,
            giveUpAfter: giveUpAfter,
            beep: beep
        ))
        return ParsedInvocation(
            content: content,
            attention: attentionDisabled
                ? .disabled
                : AttentionConfig(enabled: true, absentAfter: absentAfter, interruptAfter: interruptAfter)
        )
    }
}
