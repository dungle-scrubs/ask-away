import Foundation

// Deterministic attention-policy checks: the reducer under fake time. No
// AppKit, no GUI, no real clock - every timeline is scripted by hand and the
// two clocks (visibility hold, interrupt hold) are checked separately.
//
// Build: swiftc -swift-version 6 src/AttentionPolicy.swift tests/attention-policy.swift -o attention-policy

@main
enum AttentionPolicyTests {
    static func main() {
        var pass = 0
        var fail = 0

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("PASS  \(name)")
                pass += 1
            } else {
                print("FAIL  \(name)  \(detail())")
                fail += 1
            }
        }

        func sample(_ now: Double, host: HostingReading = .identified(hostPIDs: [739]), visibility: VisibilityReading = .count(1), attachment: AttachmentReading = .noSignal, hard: HardAbsenceReading = .awake) -> AttentionSnapshot {
            AttentionSnapshot(now: now, hosting: host, visibility: visibility, attachment: attachment, hardAbsence: hard)
        }

        // MARK: Truth table precedence

        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, visibility: .count(5), hard: .absent(displayAsleep: true, screensaver: false)))
            check("hard absence beats visible host", d.state == .absent(.hardAbsence(displayAsleep: true, screensaver: false)) && d.escalate, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, visibility: .count(5), attachment: .detached))
            check("detached beats visible host", d.state == .absent(.detached) && d.escalate, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, host: .unidentified, visibility: .noSignal, hard: .absent(displayAsleep: false, screensaver: true)))
            check("hard absence with unreadable visibility is still ABSENT", d.state == .absent(.hardAbsence(displayAsleep: false, screensaver: true)) && d.escalate, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, host: .unidentified, visibility: .noSignal, attachment: .detached))
            check("detached with no host identity is ABSENT", d.state == .absent(.detached) && d.escalate, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0))
            check("identified host with positive count is VISIBLE", d.state == .visible && !d.escalate && d.beep == .single, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            var d = r.evaluate(sample(0, host: .unidentified, visibility: .noSignal))
            check("unidentified host is UNKNOWN on first evaluation", d.state == .unknown(.unidentified) && !d.escalate && d.beep == .single, "\(d)")
            d = r.evaluate(sample(100, host: .unidentified, visibility: .noSignal))
            check("unidentified host stays UNKNOWN forever", d.state == .unknown(.unidentified) && !d.escalate, "\(d)")
        }

        // MARK: Visibility gesture filter (row 4 hold)

        do {
            var r = AttentionReducer(config: .standard)
            var d = r.evaluate(sample(0))
            d = r.evaluate(sample(1, visibility: .count(0)))
            check("zero below threshold starts the hold and reads UNKNOWN", d.state.isHoldAccruing && d.holdStarted && !d.escalate, "\(d)")
            d = r.evaluate(sample(2, visibility: .count(0)))
            d = r.evaluate(sample(5, visibility: .count(0)))
            check("accruing UNKNOWN preserves the hold (row 4 reachable)", d.state.isHoldAccruing && !d.escalate, "\(d)")
            d = r.evaluate(sample(21, visibility: .count(0)))
            check("hold completes at absentAfter from first zero observation", d.state.isZeroWindowsHeld && d.escalate, "\(d)")
        }
        do {
            // Zero observed at t=1; threshold 20 reached at t=21, not at 20:
            // the accrual starts at the first observation.
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(1, visibility: .count(0)))
            let at20 = r.evaluate(sample(20, visibility: .count(0)))
            let at21 = r.evaluate(sample(21, visibility: .count(0)))
            check("threshold measured from first zero observation", at20.state.isHoldAccruing && at21.state.isZeroWindowsHeld, "\(at20) \(at21)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(1, visibility: .count(0)))
            _ = r.evaluate(sample(5, visibility: .count(0)))
            let d = r.evaluate(sample(6, visibility: .count(1)))
            check("positive observation resets the hold", d.state == .visible && d.holdReset, "\(d)")
            let d2 = r.evaluate(sample(30, visibility: .count(0)))
            check("hold restarts after a gesture", d2.state.isHoldAccruing && d2.holdStarted, "\(d2)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(1, visibility: .count(0)))
            let d = r.evaluate(sample(2, visibility: .noSignal))
            check("failed visibility read resets the hold", d.state == .unknown(.visibilityNoSignal) && d.holdReset, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(1, visibility: .count(0)))
            let d = r.evaluate(sample(2, host: .unidentified, visibility: .noSignal))
            check("lost hosting identity resets the hold", d.state == .unknown(.unidentified) && d.holdReset, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(1, visibility: .count(0)))
            _ = r.evaluate(sample(2, host: .pending, visibility: .noSignal))
            let d = r.evaluate(sample(3, host: .pending, visibility: .noSignal))
            check("pending discovery breaks hold continuity", d.state == .unknown(.discoveryPending) && !d.escalate, "\(d)")
        }
        do {
            // absentAfter 0: first zero starts accrual; a SUBSEQUENT
            // evaluation qualifies (section 14 launch rule).
            var r = AttentionReducer(config: AttentionConfig(enabled: true, absentAfter: 0, interruptAfter: 30))
            var d = r.evaluate(sample(0))
            check("absentAfter 0: first zero at first evaluation is not ABSENT", d.state == .visible, "\(d)")
            d = r.evaluate(sample(1, visibility: .count(0)))
            check("absentAfter 0: first zero observation still UNKNOWN", d.state.isHoldAccruing && !d.escalate, "\(d)")
            d = r.evaluate(sample(2, visibility: .count(0)))
            check("absentAfter 0: second zero observation qualifies", d.state.isZeroWindowsHeld, "\(d)")
        }

        // MARK: Interrupt hold (later evaluations)

        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0))
            let d = r.evaluate(sample(1, attachment: .detached))
            check("interruptAfter 0 escalates on first ABSENT tick", d.escalate, "\(d)")
        }
        do {
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 3)
            var r = AttentionReducer(config: config)
            _ = r.evaluate(sample(10))
            var d = r.evaluate(sample(10.5, attachment: .detached))
            check("interrupt hold starts on first ABSENT", d.absentHoldStarted && !d.escalate, "\(d)")
            d = r.evaluate(sample(11.5, attachment: .detached))
            check("elapsed 1.0 of 3: no fire", !d.escalate, "\(d)")
            d = r.evaluate(sample(12.5, attachment: .detached))
            check("elapsed 2.0 of 3: no fire", !d.escalate, "\(d)")
            d = r.evaluate(sample(13.5, attachment: .detached))
            check("elapsed 3.0 of 3: fires exactly at the bound", d.escalate, "\(d)")
        }
        do {
            // The plan's timeline: observations at 10, 11, 12, 13 - fire at 13.
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 3)
            var r = AttentionReducer(config: config)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(10, attachment: .detached))
            _ = r.evaluate(sample(11, attachment: .detached))
            let at12 = r.evaluate(sample(12, attachment: .detached))
            let at13 = r.evaluate(sample(13, attachment: .detached))
            check("integer timeline fires at 13, never 12", !at12.escalate && at13.escalate, "\(at12) \(at13)")
        }
        do {
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 3)
            var r = AttentionReducer(config: config)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(10, attachment: .detached))
            var d = r.evaluate(sample(11, attachment: .attached(ttys: ["/dev/ttys042"])))
            check("UNKNOWN/VISIBLE clears the interrupt hold", d.state == .visible && d.absentHoldReset && !d.escalate, "\(d)")
            d = r.evaluate(sample(12, attachment: .detached))
            check("hold starts again from scratch after an interruption", d.absentHoldStarted && !d.escalate, "\(d)")
            d = r.evaluate(sample(15, attachment: .detached))
            check("restarted hold needs the full span again", d.escalate, "\(d)")
        }
        do {
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 3)
            var r = AttentionReducer(config: config)
            _ = r.evaluate(sample(0))
            _ = r.evaluate(sample(10, attachment: .detached))
            _ = r.evaluate(sample(11, host: .unidentified, visibility: .noSignal, attachment: .noSignal))
            check("missing evidence cannot bridge the interrupt hold", r.evaluate(sample(12, attachment: .detached)).absentHoldStarted, "expected restart")
        }
        do {
            // First-evaluation ABSENT ignores interruptAfter.
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 30)
            var r = AttentionReducer(config: config)
            let d = r.evaluate(sample(0, hard: .absent(displayAsleep: true, screensaver: false)))
            check("first-evaluation ABSENT escalates despite interruptAfter 30", d.escalate && d.beep == .triple, "\(d)")
        }
        do {
            let config = AttentionConfig(enabled: true, absentAfter: 20, interruptAfter: 30)
            var r = AttentionReducer(config: config)
            let d = r.evaluate(sample(0, attachment: .detached))
            check("first-evaluation detached escalates despite interruptAfter 30", d.escalate, "\(d)")
        }

        // MARK: Exactly once, latch, beep policy

        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0, attachment: .detached))
            var d = r.evaluate(sample(1, visibility: .count(3)))
            check("escalation stays fired across VISIBLE", d.state == .visible && !d.escalate, "\(d)")
            d = r.evaluate(sample(2, attachment: .detached))
            check("no replay of escalation", !d.escalate, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard, beepAllowed: false)
            let d = r.evaluate(sample(0, attachment: .detached))
            check("no-beep suppresses the triple but escalation still qualifies", d.escalate && d.beep == .none, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, host: .unidentified, visibility: .noSignal))
            check("first evaluation UNKNOWN beeps single", d.beep == .single, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            _ = r.evaluate(sample(0, attachment: .detached))
            let d = r.evaluate(sample(1, attachment: .detached))
            check("beep policy applies once: later evaluations carry none", d.beep == .none, "\(d)")
        }

        // MARK: Client-host combinations

        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, host: .identified(hostPIDs: [900, 901]), visibility: .count(1)))
            check("one visible host among several resolved clients is VISIBLE", d.state == .visible, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            var d = r.evaluate(sample(0, host: .identified(hostPIDs: [900, 901]), visibility: .count(0)))
            d = r.evaluate(sample(30, host: .identified(hostPIDs: [900, 901]), visibility: .count(0)))
            check("all client hosts gone for the hold is ABSENT", d.state.isZeroWindowsHeld, "\(d)")
        }
        do {
            var r = AttentionReducer(config: .standard)
            let d = r.evaluate(sample(0, host: .unidentified, attachment: .attached(ttys: ["/dev/ttys042"])))
            check("attached but unresolved client stays UNKNOWN", d.state == .unknown(.unidentified) && !d.escalate, "\(d)")
        }

        print("attention-policy total: \(pass) passed, \(fail) failed")
        exit(fail > 0 ? 1 : 0)
    }
}

extension AttentionState {
    var isHoldAccruing: Bool {
        if case .unknown(.holdAccruing) = self { return true }
        return false
    }

    var isZeroWindowsHeld: Bool {
        if case .absent(.zeroWindowsHeld) = self { return true }
        return false
    }
}
