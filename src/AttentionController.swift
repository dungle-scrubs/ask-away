import AppKit

/// Constructor-injected dependencies for the attention lifecycle. The
/// production set is live; the simulator substitutes a scripted probe, a
/// recording effects observer, and a trace sink. None of these seams are
/// reachable from the shipped binary's environment.
@MainActor
struct AttentionDependencies {
    let probe: AttentionProbeSource
    let effects: AttentionEffectsObserver
    let clock: MonotonicClock
    /// Trace writer (JSONL line, no newline included). nil in production:
    /// attention diagnostics never touch stdout.
    let trace: ((String) -> Void)?
}

/// The live evidence engine: caches the invocation's direct ancestry walk,
/// refreshes visibility and multiplexer attachment per tick, and keeps at
/// most one tmux subprocess in flight. All state is main-actor; the only
/// off-main work is the bounded subprocess itself.
@MainActor
final class LiveAttentionEngine: AttentionProbeSource {

    private let environment: [String: String]
    private let tmuxExecutable: String?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let context: MultiplexerProbe.Context

    private var discoveryDone = false
    private var directHost: Int32?
    private var attachment: AttachmentReading = .noSignal
    private var attachmentInFlight = false
    /// Attached-client tty list of the last completed probe: the cache key
    /// for resolved client ancestries. A changed list invalidates them.
    private var attachedTTYs: [String] = []
    private var clientHosts: [Int32] = []
    private var clientResolutionPending = false

    /// Production engine: multiplexer context from this process's own
    /// environment, tmux resolved from PATH.
    convenience init() {
        self.init(environment: MultiplexerProbe.currentEnvironment(), tmuxExecutable: nil)
    }

    init(environment: [String: String], tmuxExecutable: String?) {
        self.environment = environment
        self.tmuxExecutable = tmuxExecutable
        self.context = MultiplexerProbe.parseMultiplexerContext(environment: environment)
    }

    // MARK: Discovery

    func beginDiscovery() {
        guard !discoveryDone, !discoveryStarted else { return }
        discoveryStarted = true
        // The walk is a handful of sysctls and one window-list read - a few
        // milliseconds at most - dispatched after the panel is already on
        // screen so appearance is never delayed.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.directHost = AttentionProbe.walkGUIHost(startPID: self.ownPID, readers: AttentionProbe.liveReaders)
            self.discoveryDone = true
            // Attachment is probed whenever TMUX is set, even when the
            // direct walk found a host: detached precedence must hold.
            if case .tmux = self.context {
                self.refreshTransient()
            }
        }
    }

    private var discoveryStarted = false

    // MARK: Snapshot

    func readSnapshot(now: Double) -> AttentionSnapshot {
        let hard = AttentionProbe.readHardAbsence()
        var hosting: HostingReading = .pending
        var visibility: VisibilityReading = .noSignal
        if discoveryDone {
            var hosts: [Int32] = []
            if let directHost {
                hosts = [directHost]
            } else {
                hosts = clientHosts
            }
            if hosts.isEmpty {
                // An attached-but-unresolved client set stays pending while
                // resolution runs; once every probe has answered, it is
                // unidentified (UNKNOWN, never escalation).
                hosting = clientResolutionPending ? .pending : .unidentified
            } else {
                let owners = AttentionProbe.hostingOwnerPIDs(hosts: hosts, snapshot: AttentionProbe.readAllProcesses(), ownPID: ownPID)
                if let owners, !owners.isEmpty {
                    hosting = .identified(hostPIDs: owners)
                    visibility = AttentionProbe.readHostingVisibility(ownerPIDs: owners)
                } else {
                    hosting = .unidentified
                }
            }
        }
        return AttentionSnapshot(
            now: now,
            hosting: hosting,
            visibility: visibility,
            attachment: attachment,
            hardAbsence: hard
        )
    }

    // MARK: Transient refresh

    func refreshTransient() {
        guard case let .tmux(socket, session) = context else { return }
        guard !attachmentInFlight else { return }
        attachmentInFlight = true
        let executable = tmuxExecutable
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await MultiplexerProbe.runTmuxClients(
                socket: socket,
                sessionTarget: session,
                executable: executable
            )
            guard !Task.isCancelled else { return }
            self.attachmentInFlight = false
            let reading = MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout)
            self.attachment = reading
            switch reading {
            case let .attached(ttys):
                if ttys != self.attachedTTYs {
                    self.attachedTTYs = ttys
                    self.invalidateClientMembership()
                }
                // Resolve client hosts only when the direct walk found no
                // host of its own.
                if self.directHost == nil, !ttys.isEmpty, self.discoveryDone {
                    self.resolveClients(ttys: ttys)
                } else if self.directHost == nil, self.discoveryDone {
                    self.clientResolutionPending = false
                }
            case .detached, .noSignal:
                // No usable client identity; membership from an earlier
                // probe must not linger.
                if !self.attachedTTYs.isEmpty {
                    self.attachedTTYs = []
                    self.invalidateClientMembership()
                }
                if self.directHost == nil {
                    self.clientResolutionPending = false
                }
            }
        }
    }

    /// Client-tty resolution: the client processes owning each attached
    /// tty, then the same structural walk from each, cached by identity.
    private func resolveClients(ttys: [String]) {
        clientResolutionPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = AttentionProbe.readAllProcesses()
            let pids = MultiplexerProbe.clientPIDs(forTTYs: ttys, snapshot: snapshot)
            let hosts = pids.isEmpty ? [] : AttentionProbe.resolveClientHosts(clientPIDs: pids, readers: AttentionProbe.liveReaders)
            // Apply only if the membership is still current.
            if self.attachedTTYs == ttys {
                self.clientHosts = hosts
                self.clientResolutionPending = false
            }
        }
    }

    private func invalidateClientMembership() {
        clientHosts = []
        clientResolutionPending = false
    }
}

/// Production escalation effects against the live panel, in the section 14
/// order. The activation spelling is the macOS 13 floor-legal one; the
/// macOS 14 deprecation is expected and must not be upgraded past the
/// floor.
@MainActor
final class PanelAttentionEffects: AttentionEffectsObserver {
    private weak var panel: AskPanel?

    init(panel: AskPanel) {
        self.panel = panel
    }

    func activateApplication() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func makeKeyAndOrderFront() {
        panel?.makeKeyAndOrderFront(nil)
    }

    func raiseLevelToScreenSaver() {
        panel?.level = .screenSaver
    }

    func playEscalationBeep(index: Int) {
        NSSound.beep()
    }

    func playAppearBeep() {
        NSSound.beep()
    }
}

/// Invocation-level attention lifecycle: first evaluation on the next
/// main-loop turn, a 1 Hz common-mode timer independent of the drain
/// display link, exactly-once escalation with latched effects in the
/// section 14 order, beep scheduling, and cancellation on finish.
@MainActor
final class AttentionController {

    private let config: AttentionConfig
    private var reducer: AttentionReducer
    private let clock: MonotonicClock
    private let effects: AttentionEffectsObserver
    private let probe: AttentionProbeSource
    private let trace: ((String) -> Void)?

    private var timer: Timer?
    private var finished = false
    private var appearTime: Double = 0
    private var escalated = false
    private var pendingBeeps: [DispatchWorkItem] = []

    init(config: AttentionConfig, beepAllowed: Bool, dependencies: AttentionDependencies) {
        self.config = config
        self.reducer = AttentionReducer(config: config, beepAllowed: beepAllowed)
        self.clock = dependencies.clock
        self.effects = dependencies.effects
        self.probe = dependencies.probe
        self.trace = dependencies.trace
    }

    /// Called once, after the panel is ordered front and has taken key.
    /// Appearance is already complete: nothing here can delay it.
    func start() {
        appearTime = clock.now()
        probe.beginDiscovery()
        // First evaluation lands on the next main-loop turn, using only the
        // evidence already available; it never waits for the subprocess
        // budget.
        DispatchQueue.main.async { [weak self] in
            self?.evaluate()
        }
        let timer = Timer(timeInterval: AttentionConstants.attentionTickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard !finished else { return }
        probe.refreshTransient()
        evaluate()
    }

    private func evaluate() {
        guard !finished else { return }
        let now = clock.now()
        let snapshot = probe.readSnapshot(now: now)
        let decision = reducer.evaluate(snapshot)
        if let trace {
            Self.writeEvaluationTrace(trace, now: now, decision: decision, appearTime: appearTime)
        }
        switch decision.beep {
        case .single:
            effects.playAppearBeep()
            if let trace { trace(Self.line(now, event: "beep", extra: "\"kind\":\"appear\"")) }
        case .triple:
            break
        case .none:
            break
        }
        if decision.escalate {
            performEscalation(decision: decision, now: now)
        }
    }

    /// The escalation sequence, effects in the section 14 order, latched by
    /// the reducer before any effect runs. The level stays raised for the
    /// invocation's lifetime; later VISIBLE readings cancel nothing.
    private func performEscalation(decision: AttentionDecision, now: Double) {
        guard !escalated else { return }
        escalated = true
        effects.activateApplication()
        if let trace { trace(Self.line(now, event: "activate")) }
        effects.makeKeyAndOrderFront()
        if let trace { trace(Self.line(now, event: "makeKeyAndOrderFront")) }
        effects.raiseLevelToScreenSaver()
        if let trace { trace(Self.line(now, event: "raiseLevel")) }
        // Step 4 of the escalation sequence, part of every escalation
        // (first-evaluation or mid-flight) unless beep policy suppressed it.
        guard reducer.beepAllowed else { return }
        for index in 0...2 {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    self.effects.playEscalationBeep(index: index)
                    if let trace = self.trace {
                        trace(Self.line(self.clock.now(), event: "beep", extra: "\"kind\":\"escalation\",\"index\":\(index)"))
                    }
                }
            }
            pendingBeeps.append(work)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Double(index) * AttentionConstants.beepGapSeconds,
                execute: work
            )
        }
    }

    /// Finish: cancel remaining beeps, the timer, and late callbacks. The
    /// give-up deadline is untouched by everything here.
    func stop() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        for work in pendingBeeps {
            work.cancel()
        }
        pendingBeeps.removeAll()
        if let trace { trace(Self.line(clock.now(), event: "stop")) }
    }

    // MARK: Trace

    private static func line(_ now: Double, event: String, extra: String = "") -> String {
        let seconds = String(format: "%.3f", now)
        return extra.isEmpty
            ? "{\"t\":\(seconds),\"event\":\"\(event)\"}"
            : "{\"t\":\(seconds),\"event\":\"\(event)\",\(extra)}"
    }

    private static func writeEvaluationTrace(
        _ trace: (String) -> Void,
        now: Double,
        decision: AttentionDecision,
        appearTime: Double
    ) {
        let reason: String
        switch decision.state {
        case .visible: reason = "visible"
        case let .absent(why): reason = why.traceLabel
        case let .unknown(why): reason = why.traceLabel
        }
        trace(Self.line(now, event: "evaluation", extra: String(
            format: "\"state\":\"%@\",\"reason\":\"%@\",\"first\":%@,\"holdStarted\":%@,\"holdReset\":%@,\"absentHoldStarted\":%@,\"absentHoldReset\":%@",
            decision.state.traceLabel,
            reason,
            decision.firstEvaluation ? "true" : "false",
            decision.holdStarted ? "true" : "false",
            decision.holdReset ? "true" : "false",
            decision.absentHoldStarted ? "true" : "false",
            decision.absentHoldReset ? "true" : "false"
        )))
        if decision.firstEvaluation {
            trace(Self.line(now, event: "firstEvaluationDone", extra: String(format: "\"withinDeadline\":%@", (now - appearTime) <= AttentionConstants.firstEvaluationDeadlineSeconds ? "true" : "false")))
        }
    }
}
