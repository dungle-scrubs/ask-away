import Foundation

/// The §12 questions file: Codable schema, loading ('-' reads stdin to EOF),
/// and whole-document validation before anything renders - a batch never
/// shows step 1 and then fails. Unknown fields are ignored (forward
/// compatibility); the document is capped at 256KiB.
enum SequenceFile {

    static let maxBytes = 256 * 1024

    struct Document: Codable {
        var questions: [QuestionSpec]
    }

    struct QuestionSpec: Codable {
        var title: String
        var text: String
        var buttons: [String]
        var `default`: Int?
        var give_up_after: Double?
        var no_beep: Bool?
    }

    /// Load and validate a questions file at `path`, or from stdin when path
    /// is "-". Throws LoadError; main prints it and exits 1.
    static func load(_ path: String) throws -> [Question] {
        let data = try read(path)
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw LoadError.notValidJSON(reason: Self.decodeReason(error))
        }
        return try validate(document)
    }

    // MARK: Reading

    private static func read(_ path: String) throws -> Data {
        let fd: Int32
        if path == "-" {
            fd = 0 // stdin
        } else {
            fd = open(path, O_RDONLY)
            guard fd >= 0 else { throw LoadError.unreadable(path: path) }
        }
        defer {
            if fd != 0 { close(fd) }
        }
        // Read in chunks, stopping one byte past the cap: a longer document
        // is rejected, not truncated. stdin reads to EOF (section 10).
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw LoadError.unreadable(path: path == "-" ? "<stdin>" : path)
            }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if data.count > maxBytes {
                throw LoadError.tooLarge
            }
        }
        return data
    }

    // MARK: Validation (section 12: JSON-path style messages, 0-based index)

    private static func validate(_ document: Document) throws -> [Question] {
        guard (1...10).contains(document.questions.count) else {
            throw LoadError.invalid(
                "questions must contain 1..10 entries, got \(document.questions.count)"
            )
        }
        return try document.questions.enumerated().map { index, spec in
            guard !spec.title.isEmpty else {
                throw LoadError.invalid("questions[\(index)].title must be non-empty")
            }
            guard !spec.text.isEmpty else {
                throw LoadError.invalid("questions[\(index)].text must be non-empty")
            }
            guard (2...4).contains(spec.buttons.count) else {
                throw LoadError.invalid(
                    "questions[\(index)].buttons must contain 2..4 entries, got \(spec.buttons.count)"
                )
            }
            for (buttonIndex, button) in spec.buttons.enumerated() where button.isEmpty {
                throw LoadError.invalid("questions[\(index)].buttons[\(buttonIndex)] must be non-empty")
            }
            // Default: 1-based, defaults to the last button, must be in range.
            let defaultOneBased = spec.default ?? spec.buttons.count
            guard (1...spec.buttons.count).contains(defaultOneBased) else {
                throw LoadError.invalid(
                    "questions[\(index)].default must be 1..\(spec.buttons.count), got \(defaultOneBased)"
                )
            }
            if let bound = spec.give_up_after, bound < 0 {
                throw LoadError.invalid(
                    "questions[\(index)].give_up_after must be >= 0, got \(bound)"
                )
            }
            return Question(
                title: spec.title,
                text: spec.text,
                buttons: spec.buttons,
                defaultIndex: defaultOneBased - 1,
                giveUpAfter: spec.give_up_after,
                beep: !(spec.no_beep ?? false)
            )
        }
    }

    // MARK: Errors (all exit 1, nothing on stdout)

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(path: String)
        case tooLarge
        case notValidJSON(reason: String)
        case invalid(String)

        var description: String {
            switch self {
            case let .unreadable(path):
                return "cannot read questions file \(path)"
            case .tooLarge:
                return "questions file exceeds the 256KiB cap"
            case let .notValidJSON(reason):
                return "questions file is not valid JSON: \(reason)"
            case let .invalid(message):
                return message
            }
        }
    }

    /// A one-line reason from a DecodingError.
    private static func decodeReason(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func pathText(_ path: [CodingKey]) -> String {
            path.map { key in
                if let index = key.intValue { return "[\(index)]" }
                return key.stringValue.count > 0 ? ".\(key.stringValue)" : ""
            }.joined().dropFirst().description
        }
        switch decoding {
        case let .keyNotFound(key, context):
            let at = pathText(context.codingPath)
            return "missing key \(at.isEmpty ? "" : at + ".")\(key.stringValue)"
        case let .typeMismatch(_, context):
            let at = pathText(context.codingPath)
            return "wrong type at \(at.isEmpty ? "document root" : at): \(context.debugDescription)"
        case let .valueNotFound(_, context):
            let at = pathText(context.codingPath)
            return "unexpected null at \(at.isEmpty ? "document root" : at)"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return decoding.localizedDescription
        }
    }
}
