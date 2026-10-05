import Foundation

/// Multiplexer context parsing and bounded tmux client resolution
/// (design.md section 14, plan section 3). The tmux subprocess runs off the
/// main actor with a hard MULTIPLEXER_PROBE_TIMEOUT_SECONDS budget: only
/// the owned child is terminated, pipes drain without blocking, and a
/// timeout or nonzero exit is no signal - never "detached".
enum MultiplexerProbe {

    // MARK: Context

    /// Which multiplexer environment marks the ancestry, and the tmux
    /// socket/session identity when it is tmux. Only the selected keys are
    /// read; environment values are never dumped.
    enum Context: Equatable, Sendable {
        case none
        case tmux(socket: String, sessionTarget: String)
        case herdr
        case zellij
        case screen
    }

    /// Parse the multiplexer identity from selected environment keys.
    /// `TMUX` carries `<socket-path>,<server-pid>,<session>`; the session
    /// field passes through as the `-t` target unchanged.
    static func parseMultiplexerContext(environment: [String: String]) -> Context {
        if let value = environment["TMUX"], !value.isEmpty {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return .none }
            return .tmux(socket: fields[0], sessionTarget: fields[2])
        }
        if let value = environment["HERDR_ENV"], !value.isEmpty { return .herdr }
        if let value = environment["ZELLIJ"], !value.isEmpty { return .zellij }
        if let value = environment["STY"], !value.isEmpty { return .screen }
        return .none
    }

    /// The live context from this process's environment.
    static func currentEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var selected: [String: String] = [:]
        for key in ["TMUX", "HERDR_ENV", "ZELLIJ", "STY"] {
            if let value = environment[key] { selected[key] = value }
        }
        return selected
    }

    // MARK: Bounded subprocess

    struct SubprocessResult: Sendable {
        /// nil when the launch failed or the timeout killed the child.
        let exitStatus: Int32?
        /// nil when the bytes were not valid UTF-8: a decode failure is no
        /// signal, never an empty string that would parse as detached
        /// (review finding 6). Nonempty malformed-but-decodable output is
        /// still no signal at the parse layer.
        let stdout: String?
    }

    /// Resolve the tmux executable without a shell: PATH entries plus the
    /// standard Homebrew prefixes, first executable file named tmux.
    static func tmuxExecutable() -> String? {
        var candidates: [String] = []
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            candidates.append("\(directory)/tmux")
        }
        candidates.append("/opt/homebrew/bin/tmux")
        candidates.append("/usr/local/bin/tmux")
        candidates.append("/usr/bin/tmux")
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// Run `tmux -S <socket> list-clients -t <session>` with the inherited
    /// environment, off the caller's context, under the
    /// MULTIPLEXER_PROBE_TIMEOUT_SECONDS budget. Arguments are argv entries;
    /// no shell interpolation exists here. On timeout the owned child is
    /// terminated and reaped, and the result carries no exit status.
    static func runTmuxClients(
        socket: String,
        sessionTarget: String,
        timeout: Double = AttentionConstants.multiplexerProbeTimeoutSeconds,
        executable: String? = nil
    ) async -> SubprocessResult {
        guard let executable = executable ?? tmuxExecutable() else {
            return SubprocessResult(exitStatus: nil, stdout: "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-S", socket, "list-clients", "-t", sessionTarget]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return SubprocessResult(exitStatus: nil, stdout: "")
        }

        let runner = SubprocessRunner(process: process, pipe: pipe)
        let result: SubprocessResult = await withCheckedContinuation { continuation in
            runner.start(continuation: continuation, timeout: timeout)
        }
        return result
    }

    /// One owned child run: drains stdout through a readability handler
    /// (never a blocking read on a cooperative thread), reaps through the
    /// termination handler, and enforces the timeout by completing as no
    /// signal IMMEDIATELY when the budget expires, then terminating only
    /// this owned child (TERM, KILL after a grace period). A child that
    /// ignores SIGTERM, or an inherited pipe held open past the child's
    /// exit, cannot keep the await pending past its budget (review
    /// finding 7). First completer wins; later callbacks are no-ops.
    private final class SubprocessRunner: @unchecked Sendable {
        /// TERM-to-KILL grace for the owned child after a timeout.
        private static let killGraceSeconds: TimeInterval = 0.5
        /// Bounded drain window after the child exits: if EOF has not
        /// arrived by then (a grandchild holds the write end), the result
        /// is whatever was drained.
        private static let drainDeadlineSeconds: TimeInterval = 0.25

        private let process: Process
        private let pipe: Pipe
        private let lock = NSLock()
        private var stdoutData = Data()
        private var drained = false
        private var terminated = false
        private var completed = false
        private var continuation: CheckedContinuation<SubprocessResult, Never>?
        private var timeoutWork: DispatchWorkItem?
        private var drainDeadlineWork: DispatchWorkItem?

        init(process: Process, pipe: Pipe) {
            self.process = process
            self.pipe = pipe
        }

        func start(continuation: CheckedContinuation<SubprocessResult, Never>, timeout: Double) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF: the child has exited and the pipe is drained.
                    handle.readabilityHandler = nil
                    self.markDrained()
                } else {
                    self.append(chunk)
                }
            }
            process.terminationHandler = { [weak self] _ in
                self?.markTerminated()
            }

            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.completeAsNoSignal()
            }
            timeoutWork = work
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }

        private func append(_ data: Data) {
            lock.lock()
            stdoutData.append(data)
            lock.unlock()
        }

        private func markDrained() {
            lock.lock()
            drained = true
            let ready = drained && terminated && !completed
            lock.unlock()
            if ready { complete() }
        }

        private func markTerminated() {
            lock.lock()
            terminated = true
            let ready = drained && !completed
            let needsDrainDeadline = !drained && !completed
            lock.unlock()
            if ready {
                complete()
            } else if needsDrainDeadline {
                // The child exited but EOF has not arrived: an inherited
                // write descriptor (a grandchild) can hold the pipe open
                // indefinitely. Bound the drain instead of waiting. The
                // evidence is incomplete - whatever bytes arrived are not
                // a usable reading, so complete as no signal (never as a
                // zero-byte success, which would parse as detached).
                let work = DispatchWorkItem { [weak self] in self?.completeAsNoSignal() }
                lock.lock()
                drainDeadlineWork = work
                lock.unlock()
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + Self.drainDeadlineSeconds,
                    execute: work
                )
            }
        }

        /// The budget expired: complete the evidence request as no signal
        /// NOW, within the budget, then tear down the owned child. The
        /// continuation is released before any teardown so a stubborn
        /// child cannot stall the caller.
        private func completeAsNoSignal() {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            pipe.fileHandleForReading.readabilityHandler = nil
            timeoutWork?.cancel()
            timeoutWork = nil
            drainDeadlineWork?.cancel()
            drainDeadlineWork = nil
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            let child = process
            if child.isRunning {
                child.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGraceSeconds) {
                    if child.isRunning {
                        kill(child.processIdentifier, SIGKILL)
                    }
                }
            }
            continuation?.resume(returning: SubprocessResult(exitStatus: nil, stdout: nil))
        }

        private func complete() {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            pipe.fileHandleForReading.readabilityHandler = nil
            timeoutWork?.cancel()
            timeoutWork = nil
            drainDeadlineWork?.cancel()
            drainDeadlineWork = nil
            let status = process.isRunning ? nil : process.terminationStatus
            let text = String(data: stdoutData, encoding: .utf8)
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: SubprocessResult(exitStatus: status, stdout: text))
        }
    }

    // MARK: Parsing

    /// Exit-qualified `list-clients` parse:
    /// exit 0 + empty stdout = detached; exit 0 + valid client lines =
    /// attached (tty list extracted); nonzero, launch failure, timeout,
    /// undecodable output, or nonempty malformed output = no signal.
    static func parseTmuxClients(exitStatus: Int32?, stdout: String?) -> AttachmentReading {
        guard let status = exitStatus, status == 0 else { return .noSignal }
        guard let output = stdout else { return .noSignal }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .detached }
        var ttys: [String] = []
        for line in trimmed.split(separator: "\n") {
            guard let tty = Self.clientTTY(fromLine: String(line)) else { return .noSignal }
            ttys.append(tty)
        }
        return ttys.isEmpty ? .noSignal : .attached(ttys: ttys)
    }

    /// The leading `/dev/ttysNNN` field of a `list-clients` line, before
    /// the colon. The server's pane tty never appears here.
    static func clientTTY(fromLine line: String) -> String? {
        let head = line.split(separator: ":", maxSplits: 1).first.map(String.init) ?? line
        let trimmed = head.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/dev/ttys") else { return nil }
        let digits = trimmed.dropFirst("/dev/ttys".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }

    /// Compatibility/probe parse for `display -p '#{client_attached}'`:
    /// exit 0 plus empty or whitespace-only output means detached; exit 0
    /// plus a valid positive attachment value means attached; failure,
    /// malformed output, and unqualified emptiness mean no signal. Never
    /// `output != "1"` as absence (tmux prints an empty value for a detached
    /// pane, never 0). Not the primary detector.
    static func parseClientAttached(exitStatus: Int32?, stdout: String?) -> AttachmentReading {
        guard let status = exitStatus, status == 0 else { return .noSignal }
        guard let output = stdout else { return .noSignal }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .detached }
        guard let value = Int(trimmed), value > 0 else { return .noSignal }
        return .attached(ttys: [])
    }

    // MARK: Client resolution

    /// Resolve the client processes for a list of attached tty paths by
    /// matching each tty's device number against the process snapshot's
    /// controlling-terminal devices. Pane processes never carry a client's
    /// tty; no name search happens here.
    static func clientPIDs(forTTYs ttys: [String], snapshot: [AttentionProbe.ProcessRecord]?) -> [Int32] {
        guard let snapshot else { return [] }
        var devices: [dev_t] = []
        for tty in ttys {
            if let device = AttentionProbe.ttyDeviceNumber(forTTY: tty) {
                devices.append(device)
            }
        }
        guard !devices.isEmpty else { return [] }
        return snapshot.filter { record in
            record.ttyDevice != -1 && devices.contains(record.ttyDevice)
        }.map(\.pid)
    }
}
