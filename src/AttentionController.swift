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
/// most one tmux subprocess in flight. Discovery and inventory reads run
/// OFF the main actor and publish completed evidence; `readSnapshot`
/// returns only what has already been published, so an evaluation never
/// waits on - and the main actor never stalls behind - a slow walk,
/// process snapshot, window inventory, or subprocess (review finding 8).
/// Unfinished work surfaces as pending/no-signal readings, which the
/// reducer evaluates as UNKNOWN: the safe direction that never escalates.
@MainActor
final class LiveAttentionEngine: AttentionProbeSource {

    private let environment: [String: String]
    private let tmuxExecutable: String?
    private let readers: AttentionProbe.WalkReaders
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let context: MultiplexerProbe.Context

    // Published evidence (main actor).
    private var discoveryStarted = false
    private var discoveryDone = false
    private var directHost: Int32?
    private var attachment: AttachmentReading = .noSignal
    /// Attached-client tty list of the last completed probe: the cache key
    /// for resolved client ancestries. A changed list invalidates them.
    private var attachedTTYs: [String] = []
    private var clientHosts: [Int32] = []
    private var clientResolutionPending = false
    private var hostingReading: HostingReading = .pending
    private var visibilityReading: VisibilityReading = .noSignal
    /// Visibility freshness (lead review round 2, finding 8): an
    /// inventory refresh in flight holds the previous reading so
    /// accrual continues across the normal one-tick refresh, but past
    /// visibilityStaleSeconds the held reading is stale and reads as
    /// no signal (UNKNOWN) - a slow refresh can never let a stale
    /// zero escalate.
    private var inventoryInFlight = false
    private var inventoryStartedAt: Double?
    private var lastSnapshotNow: Double?
    /// Bumped whenever published identity state becomes stale; evidence
    /// publishes only when its captured generation still matches.
    private var evidenceGeneration = 0

    // Retained engine tasks, cancelled on finish.
    private var discoveryTask: Task<Void, Never>?
    private var attachmentTask: Task<Void, Never>?
    private var evidenceTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    /// The tty membership the current client-host cache was resolved
    /// against: unchanged membership reuses the cache (review finding 8).
    private var lastResolvedTTYs: [String]?

    /// Production engine: multiplexer context from this process's own
    /// environment, tmux resolved from PATH, live probe readers.
    convenience init() {
        self.init(environment: MultiplexerProbe.currentEnvironment(), tmuxExecutable: nil)
    }

    init(
        environment: [String: String],
        tmuxExecutable: String?,
        readers: AttentionProbe.WalkReaders = AttentionProbe.liveReaders
    ) {
        self.environment = environment
        self.tmuxExecutable = tmuxExecutable
        self.readers = readers
        self.context = MultiplexerProbe.parseMultiplexerContext(environment: environment)
    }

    // MARK: Discovery

    func beginDiscovery() {
        guard !discoveryStarted else { return }
        discoveryStarted = true
        // The walk is a handful of sysctls and one window-list read. It
        // runs detached from the main actor so panel appearance, the first
        // beep, UI processing, and deadline handling never queue behind it.
        let readers = self.readers
        let startPID = ownPID
        discoveryTask = Task.detached(priority: .utility) { [weak self] in
            let host = AttentionProbe.walkGUIHost(startPID: startPID, readers: readers)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.directHost = host
                self.discoveryDone = true
                // Attachment is probed whenever TMUX is set, even when the
                // direct walk found a host: detached precedence must hold.
                if case .tmux = self.context {
                    self.refreshTransient()
                }
            }
        }
    }

    // MARK: Snapshot

    /// Compose the published evidence. Unpublished discovery is `.pending`;
    /// an in-flight inventory keeps the previous reading. Hard absence is
    /// the one synchronous read left here: it is two cheap main-thread
    /// queries (CGDisplayIsAsleep plus a running-apps scan).
    func readSnapshot(now: Double) -> AttentionSnapshot {
        lastSnapshotNow = now
        var visibility = visibilityReading
        if inventoryInFlight {
            if let started = inventoryStartedAt {
                if now - started > AttentionConstants.visibilityStaleSeconds {
                    // The refresh is past the staleness bound: the held
                    // reading no longer establishes current visibility.
                    visibility = .noSignal
                }
            } else {
                inventoryStartedAt = now
            }
        }
        return AttentionSnapshot(
            now: now,
            hosting: hostingReading,
            visibility: visibility,
            attachment: attachment,
            hardAbsence: AttentionProbe.readHardAbsence()
        )
    }

    // MARK: Transient refresh

    func refreshTransient() {
        refreshAttachment()
        refreshHostingEvidence()
    }

    private func refreshAttachment() {
        guard case let .tmux(socket, session) = context else { return }
        guard attachmentTask == nil else { return }
        let executable = tmuxExecutable
        attachmentTask = Task { [weak self] in
            let result = await MultiplexerProbe.runTmuxClients(
                socket: socket,
                sessionTarget: session,
                executable: executable
            )
            guard !Task.isCancelled else { return }
            self?.publishAttachment(result)
        }
    }

    private func publishAttachment(_ result: MultiplexerProbe.SubprocessResult) {
        attachmentTask = nil
        let reading = MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout)
        attachment = reading
        switch reading {
        case let .attached(ttys):
            if ttys != attachedTTYs {
                attachedTTYs = ttys
                invalidateClientMembership()
            }
            // Resolve client hosts only when the direct walk found no
            // host of its own, and only when membership changed.
            if directHost == nil, discoveryDone, !ttys.isEmpty {
                resolveClients(ttys: ttys)
            } else if directHost == nil {
                clientResolutionPending = false
            }
        case .detached, .noSignal:
            // No usable client identity; membership from an earlier probe
            // must not linger.
            if !attachedTTYs.isEmpty {
                attachedTTYs = []
                invalidateClientMembership()
            }
            if directHost == nil {
                clientResolutionPending = false
            }
        }
    }

    /// Hosting identity plus visibility evidence, computed off the main
    /// actor from the identity state captured at generation `generation`
    /// and published only if that generation is still current.
    private func refreshHostingEvidence() {
        guard discoveryDone else { return }
        guard evidenceTask == nil else { return }
        inventoryInFlight = true
        if inventoryStartedAt == nil { inventoryStartedAt = lastSnapshotNow }
        let hosts: [Int32]
        if let directHost {
            hosts = [directHost]
        } else {
            hosts = clientHosts
        }
        if hosts.isEmpty {
            // Pure identity state, main-actor truth: an attached but
            // unresolved client set stays pending while resolution runs;
            // once every probe has answered it is unidentified (UNKNOWN,
            // never escalation).
            hostingReading = clientResolutionPending ? .pending : .unidentified
            visibilityReading = .noSignal
            inventoryInFlight = false
            inventoryStartedAt = nil
            return
        }
        let generation = evidenceGeneration
        let ownPID = self.ownPID
        evidenceTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = AttentionProbe.readAllProcesses()
            let owners = snapshot.flatMap { AttentionProbe.hostingOwnerPIDs(hosts: hosts, snapshot: $0, ownPID: ownPID) }
            let identified = owners != nil && !owners!.isEmpty
            let visibility = identified
                ? AttentionProbe.readHostingVisibility(ownerPIDs: owners)
                : .noSignal
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.evidenceTask = nil
                guard self.evidenceGeneration == generation else { return }
                self.inventoryInFlight = false
                self.inventoryStartedAt = nil
                if let owners, !owners.isEmpty {
                    self.hostingReading = .identified(hostPIDs: owners)
                    self.visibilityReading = visibility
                } else {
                    self.hostingReading = .unidentified
                    self.visibilityReading = .noSignal
                }
            }
        }
    }

    /// Client-tty resolution: the client processes owning each attached
    /// tty, then the same structural walk from each. Cached by tty
    /// membership: an unchanged attached list reuses the resolved hosts
    /// instead of re-walking every tick (review finding 8).
    private func resolveClients(ttys: [String]) {
        guard ttys != lastResolvedTTYs else { return }
        lastResolvedTTYs = ttys
        clientResolutionPending = true
        let readers = self.readers
        resolveTask?.cancel()
        resolveTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = AttentionProbe.readAllProcesses()
            let pids = MultiplexerProbe.clientPIDs(forTTYs: ttys, snapshot: snapshot)
            let hosts = pids.isEmpty ? [] : AttentionProbe.resolveClientHosts(clientPIDs: pids, readers: readers)
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                // Apply only if the membership is still current.
                guard self.attachedTTYs == ttys else { return }
                self.clientHosts = hosts
                self.clientResolutionPending = false
                self.refreshHostingEvidence()
            }
        }
    }

    private func invalidateClientMembership() {
        resolveTask?.cancel()
        clientHosts = []
        clientResolutionPending = false
        lastResolvedTTYs = nil
        // Membership changed: published visibility evidence is stale
        // immediately (lead review round 2, finding 8).
        visibilityReading = .noSignal
        inventoryInFlight = false
        inventoryStartedAt = nil
        evidenceGeneration += 1
    }

    // MARK: Shutdown

    /// Cancel outstanding discovery, subprocess, evidence, and resolution
    /// tasks. Called when the invocation finishes; late completions are
    /// ignored, so nothing publishes after finish (review finding 8).
    func cancel() {
        discoveryTask?.cancel()
        discoveryTask = nil
        attachmentTask?.cancel()
        attachmentTask = nil
        evidenceTask?.cancel()
        evidenceTask = nil
        resolveTask?.cancel()
        resolveTask = nil
    }
}

/// Invocation-level attention lifecycle: first evaluation on the next
/// main-loop turn, a 1 Hz common-mode timer independent of the drain
/// display link, exactly-once escalation with latched effects in the
/// section 14 order, beep scheduling, and cancellation on finish. Finishing
/// also cancels the engine's outstanding discovery and probe tasks.
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

    /// Finish: cancel remaining beeps, the timer, late callbacks, and the
    /// engine's outstanding discovery/probe tasks. The give-up deadline is
    /// untouched by everything here.
    func stop() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        for work in pendingBeeps {
            work.cancel()
        }
        pendingBeeps.removeAll()
        probe.cancel()
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
