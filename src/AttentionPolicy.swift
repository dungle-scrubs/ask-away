import Foundation

/// Named constants for attention-aware escalation (design.md section 14).
/// Every threshold the subsystem uses is here; no policy decision is spelled
/// as a bare literal at a call site. Accessible to parsing and tests without
/// the UI actor.
enum AttentionConstants {
    /// Row 4 visibility-absent hold; the `--absent-after` default.
    static let absentAfterDefaultSeconds: Double = 20
    /// Mid-flight ABSENT hold before escalation; the `--interrupt-after`
    /// default. 0 escalates on the first confirmed ABSENT observation.
    static let interruptAfterDefaultSeconds: Double = 0
    /// Detection cadence.
    static let attentionTickSeconds: Double = 1
    /// The first evaluation must complete within this window of appear.
    static let firstEvaluationDeadlineSeconds: Double = 1
    /// Triple-beep spacing.
    static let beepGapSeconds: Double = 0.25
    /// Identification walk cap.
    static let maxAncestorHops: Int = 32
    /// tmux client-probe subprocess budget. Supersedes the retired
    /// tmux-specific spelling; broader scope, same value.
    static let multiplexerProbeTimeoutSeconds: Double = 2
    /// The window layer that counts as a normal window.
    static let hostingWindowLayer: Int = 0
    /// Minimum width and height of a counting window.
    static let minOnscreenWindowDimensionPoints: Double = 1
}

/// Invocation-level attention configuration (section 14 CLI table). Lives on
/// the invocation, never on a `Question`: attention is a human-level
/// setting, not a question-level one.
struct AttentionConfig: Equatable {
    var enabled: Bool
    var absentAfter: Double
    var interruptAfter: Double

    static let standard = AttentionConfig(
        enabled: true,
        absentAfter: AttentionConstants.absentAfterDefaultSeconds,
        interruptAfter: AttentionConstants.interruptAfterDefaultSeconds
    )

    /// `--no-attention`: no detection, no escalation; the panel behaves
    /// exactly as v0.2.0 for attention while still rendering the field.
    static let disabled = AttentionConfig(enabled: false, absentAfter: 0, interruptAfter: 0)
}

// MARK: - Readings

/// Readings carry explicit no-signal cases: a failed read is never
/// represented as an empty successful inventory (plan section 3).
enum AttachmentReading: Equatable {
    /// A qualified attached-client list; the tty device paths resolve hosts.
    case attached(ttys: [String])
    /// Exit-0, empty `list-clients` output. High-confidence absence.
    case detached
    /// Failed, timed-out, malformed, or still-pending probe.
    case noSignal
}

/// Hosting identity state for one evaluation.
enum HostingReading: Equatable {
    /// Resolved GUI host pids (direct ancestor, or every attached client's
    /// resolved host combined when the direct walk found none).
    case identified(hostPIDs: [Int32])
    /// No usable host: walk found no GUI ancestor and no client host resolved.
    case unidentified
    /// Discovery has not finished yet.
    case pending
}

enum VisibilityReading: Equatable {
    /// A successful owner-matching on-screen count. Zero is a successful
    /// observation, not a failure.
    case count(Int)
    /// Failed inventory read or unusable host ownership read.
    case noSignal
}

enum HardAbsenceReading: Equatable {
    case absent(displayAsleep: Bool, screensaver: Bool)
    case awake
}

// MARK: - State

enum AttentionState: Equatable {
    case visible
    case absent(AbsentReason)
    case unknown(UnknownReason)

    var traceLabel: String {
        switch self {
        case .visible: return "VISIBLE"
        case .absent: return "ABSENT"
        case .unknown: return "UNKNOWN"
        }
    }
}

enum AbsentReason: Equatable {
    /// Truth-table row 1: display asleep or screensaver running.
    case hardAbsence(displayAsleep: Bool, screensaver: Bool)
    /// Truth-table row 2: qualified tmux detached result.
    case detached
    /// Truth-table row 4: zero on-screen windows held for `--absent-after`.
    case zeroWindowsHeld(seconds: Double)

    var traceLabel: String {
        switch self {
        case let .hardAbsence(displayAsleep, screensaver):
            return "hardAbsence(asleep:\(displayAsleep),screensaver:\(screensaver))"
        case .detached: return "detached"
        case let .zeroWindowsHeld(seconds): return "zeroWindowsHeld(\(seconds)s)"
        }
    }
}

enum UnknownReason: Equatable {
    /// Row 5: row 4's hold is still accruing; `zeroWindowsSince` survives.
    case holdAccruing(seconds: Double)
    /// Failed visibility read with an identified host.
    case visibilityNoSignal
    /// Discovery pending.
    case discoveryPending
    /// No GUI ancestor, attached-but-unresolved client, zellij, screen,
    /// headless Herdr, or any other identity miss.
    case unidentified

    var traceLabel: String {
        switch self {
        case let .holdAccruing(seconds): return "holdAccruing(\(seconds)s)"
        case .visibilityNoSignal: return "visibilityNoSignal"
        case .discoveryPending: return "discoveryPending"
        case .unidentified: return "unidentified"
        }
    }
}

// MARK: - Snapshot and decision

/// One evaluation's complete input. `now` is monotonic seconds from the
/// injected clock; holds never use wall-clock time.
struct AttentionSnapshot: Equatable {
    var now: Double
    var hosting: HostingReading
    var visibility: VisibilityReading
    var attachment: AttachmentReading
    var hardAbsence: HardAbsenceReading

    static let pending = AttentionSnapshot(
        now: 0,
        hosting: .pending,
        visibility: .noSignal,
        attachment: .noSignal,
        hardAbsence: .awake
    )
}

enum BeepPattern: Equatable {
    case none
    case single
    case triple
}

/// The reducer's verdict for one evaluation. Effects (activation, level,
/// beeps) are the controller's to perform; this only decides.
struct AttentionDecision: Equatable {
    let state: AttentionState
    let firstEvaluation: Bool
    /// Escalation qualified this evaluation. Fires at most once per
    /// invocation: the reducer latches before reporting.
    let escalate: Bool
    /// Beep for this evaluation: the first evaluation's appear beep under
    /// section 6's amended policy; `.none` on later evaluations.
    let beep: BeepPattern
    /// Trace flags: the visibility hold started or reset on this evaluation.
    let holdStarted: Bool
    let holdReset: Bool
    /// Trace flags: the interrupt hold started or was cleared.
    let absentHoldStarted: Bool
    let absentHoldReset: Bool
}

// MARK: - Reducer

/// Pure timestamp-driven state reducer for the section 14 truth table.
/// Holds are elapsed-time comparisons against monotonic timestamps, never
/// tick counters: with `interruptAfter == 3` and observations at 10, 11, 12,
/// and 13 seconds, escalation qualifies at 13, never at 12.
///
/// The two clocks stay separate:
/// - `zeroWindowsSince` is the row 4 gesture filter. It survives UNKNOWN
///   ticks caused solely by the accruing hold (otherwise row 4 would be
///   unreachable) and resets on a positive observation, a failed visibility
///   read, or loss of a usable hosting identity.
/// - `absentSince` is the interrupt hold. Any VISIBLE or UNKNOWN evaluation
///   clears it; missing or failed evidence cannot bridge it.
struct AttentionReducer {

    private(set) var zeroWindowsSince: Double?
    private(set) var absentSince: Double?
    private(set) var firstEvaluationDone = false
    private(set) var didEscalate = false

    let config: AttentionConfig
    /// Section 6 beep policy, evaluated once per invocation: `--no-beep`,
    /// or any batch question setting `no_beep`, suppresses every pattern.
    let beepAllowed: Bool

    init(config: AttentionConfig, beepAllowed: Bool = true) {
        self.config = config
        self.beepAllowed = beepAllowed
    }

    /// Evaluate one snapshot. Idempotent per tick; call at most once per
    /// ATTENTION_TICK_SECONDS plus once for the first evaluation.
    mutating func evaluate(_ snapshot: AttentionSnapshot) -> AttentionDecision {
        let first = !firstEvaluationDone
        firstEvaluationDone = true

        var holdStarted = false
        var holdReset = false
        var visibilityAbsenceQualified = false

        // Row 3/4 bookkeeping runs whenever a usable hosting identity and a
        // visibility signal exist, so the gesture filter tracks real window
        // evidence even while precedence rows 1 and 2 decide the state.
        if case let .identified(hosts) = snapshot.hosting, !hosts.isEmpty {
            switch snapshot.visibility {
            case .count(let count) where count > 0:
                if zeroWindowsSince != nil { holdReset = true }
                zeroWindowsSince = nil
            case .count:
                if let since = zeroWindowsSince {
                    let elapsed = snapshot.now - since
                    if elapsed >= config.absentAfter {
                        visibilityAbsenceQualified = true
                    }
                } else {
                    // The first zero-window observation starts the accrual;
                    // qualification needs a subsequent evaluation, including
                    // with `--absent-after 0` (section 14's launch rule).
                    zeroWindowsSince = snapshot.now
                    holdStarted = true
                }
            case .noSignal:
                if zeroWindowsSince != nil { holdReset = true }
                zeroWindowsSince = nil
            }
        } else {
            // Pending or lost identity: uncertainty other than the accruing
            // hold breaks continuity.
            if zeroWindowsSince != nil { holdReset = true }
            zeroWindowsSince = nil
        }

        // Truth table, precedence order.
        let state: AttentionState
        if case let .absent(displayAsleep, screensaver) = snapshot.hardAbsence {
            state = .absent(.hardAbsence(displayAsleep: displayAsleep, screensaver: screensaver))
        } else if snapshot.attachment == .detached {
            state = .absent(.detached)
        } else if visibilityAbsenceQualified, let since = zeroWindowsSince {
            state = .absent(.zeroWindowsHeld(seconds: snapshot.now - since))
        } else if case .identified = snapshot.hosting, case .count(let count) = snapshot.visibility, count > 0 {
            state = .visible
        } else if case .identified = snapshot.hosting {
            switch snapshot.visibility {
            case .count: state = .unknown(.holdAccruing(seconds: snapshot.now - (zeroWindowsSince ?? snapshot.now)))
            case .noSignal: state = .unknown(.visibilityNoSignal)
            }
        } else if case .pending = snapshot.hosting {
            state = .unknown(.discoveryPending)
        } else {
            state = .unknown(.unidentified)
        }

        // Interrupt hold.
        var absentHoldStarted = false
        var absentHoldReset = false
        var escalate = false
        switch state {
        case .absent:
            if absentSince == nil {
                absentSince = snapshot.now
                absentHoldStarted = true
            }
            if !didEscalate {
                let held = snapshot.now - (absentSince ?? snapshot.now)
                if first || config.interruptAfter == 0 || held >= config.interruptAfter {
                    // Latch before reporting: exactly once per invocation.
                    didEscalate = true
                    escalate = true
                }
            }
        case .visible, .unknown:
            if absentSince != nil {
                absentHoldReset = true
                absentSince = nil
            }
        }

        let beep: BeepPattern
        if first {
            switch state {
            case .visible, .unknown: beep = beepAllowed ? .single : .none
            case .absent: beep = beepAllowed ? .triple : .none
            }
        } else {
            beep = .none
        }

        return AttentionDecision(
            state: state,
            firstEvaluation: first,
            escalate: escalate,
            beep: beep,
            holdStarted: holdStarted,
            holdReset: holdReset,
            absentHoldStarted: absentHoldStarted,
            absentHoldReset: absentHoldReset
        )
    }
}

// MARK: - Injection boundary

/// Monotonic clock for hold arithmetic. Wall-clock time never feeds a hold:
/// a wall-clock jump could manufacture or destroy elapsed evidence.
struct MonotonicClock: Sendable {
    let now: @Sendable () -> Double

    /// Process uptime: monotonic, sleep-inclusive, always available.
    static let live = MonotonicClock { ProcessInfo.processInfo.systemUptime }
}

/// Escalation effects, performed by the controller in the section 14 order.
/// Production runs the real AppKit calls; the simulator observes and traces.
@MainActor
protocol AttentionEffectsObserver: AnyObject {
    func activateApplication()
    func makeKeyAndOrderFront()
    func raiseLevelToScreenSaver()
    /// One beep of the escalation triple; `index` is 0, 1, or 2. The appear
    /// beep (single) is played through `playAppearBeep`.
    func playEscalationBeep(index: Int)
    /// The section 6 appear beep: single (or the first note of the triple).
    func playAppearBeep()
}

/// Synchronous evidence source for one evaluation. Implementations never
/// block past the caller's budget: the first evaluation must complete within
/// FIRST_EVALUATION_DEADLINE_SECONDS of appear, so unfinished discovery,
/// in-flight subprocesses, and pending client resolution surface as
/// no-signal or pending readings, not as waits.
protocol AttentionProbeSource: AnyObject {
    /// Kick discovery (ancestry walk, multiplexer context) asynchronously.
    /// Called once after appear; never delays panel presentation.
    func beginDiscovery()

    /// Currently available readings combined into one snapshot. `now` is
    /// supplied by the controller's clock.
    func readSnapshot(now: Double) -> AttentionSnapshot

    /// Refresh time-varying evidence (visibility, multiplexer attachment)
    /// asynchronously. Called once per tick; at most one subprocess may be
    /// in flight per invocation.
    func refreshTransient()
}
