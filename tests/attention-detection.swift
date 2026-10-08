import AppKit
import CoreGraphics
import Foundation

// Synthetic detection checks: ancestry walk, helper ownership, window
// qualification, subprocess bounds, and tmux parsing against the measured
// output shapes from .scratch/ask-away-visibility/. Deterministic: every
// input is injected; no live GUI state feeds a pass/fail verdict except the
// clearly marked live smoke that only asserts the walk terminates.
//
// Build: swiftc -swift-version 6 src/AttentionPolicy.swift src/AttentionProbe.swift \
//   src/MultiplexerProbe.swift src/AttentionController.swift tests/attention-detection.swift -o attention-detection

@main
enum AttentionDetectionTests {
    static func main() async {
        setbuf(stdout, nil)
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

        // MARK: Multiplexer context parsing

        check(
            "TMUX context parses socket and session target",
            MultiplexerProbe.parseMultiplexerContext(environment: ["TMUX": "/tmp/tmux-501/default,3279,0"])
                == .tmux(socket: "/tmp/tmux-501/default", sessionTarget: "0")
        )
        check(
            "TMUX with too few fields is no context",
            MultiplexerProbe.parseMultiplexerContext(environment: ["TMUX": "/tmp/tmux-501/default"])
                == .none
        )
        check(
            "empty TMUX is no context",
            MultiplexerProbe.parseMultiplexerContext(environment: ["TMUX": ""]) == .none
        )
        check(
            "HERDR_ENV marks herdr",
            MultiplexerProbe.parseMultiplexerContext(environment: ["HERDR_ENV": "1"]) == .herdr
        )
        check(
            "ZELLIJ marks zellij",
            MultiplexerProbe.parseMultiplexerContext(environment: ["ZELLIJ": "0"]) == .zellij
        )
        check(
            "STY marks screen",
            MultiplexerProbe.parseMultiplexerContext(environment: ["STY": "main"]) == .screen
        )
        check(
            "unrelated keys are ignored",
            MultiplexerProbe.parseMultiplexerContext(environment: ["TERM_PROGRAM": "ghostty", "HOME": "/x"]) == .none
        )

        // MARK: list-clients parsing (measured shapes)

        let attachedOut = "/dev/ttys042: v03 [80x24 xterm-256color] (attached,focused,UTF-8)\n"
        check(
            "exit 0 with empty stdout is detached",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: "") == .detached
        )
        check(
            "exit 0 with whitespace-only stdout is detached",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: "  \n") == .detached
        )
        check(
            "exit 0 with a client line is attached with the tty",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: attachedOut)
                == .attached(ttys: ["/dev/ttys042"])
        )
        check(
            "two client lines resolve both ttys",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: attachedOut + "/dev/ttys007: v03 [120x30] (attached)\n")
                == .attached(ttys: ["/dev/ttys042", "/dev/ttys007"])
        )
        check(
            "nonzero exit is no signal",
            MultiplexerProbe.parseTmuxClients(exitStatus: 1, stdout: attachedOut) == .noSignal
        )
        check(
            "timeout (nil exit) is no signal",
            MultiplexerProbe.parseTmuxClients(exitStatus: nil, stdout: "") == .noSignal
        )
        check(
            "malformed nonempty output is no signal",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: "no session\n") == .noSignal
        )
        check(
            "a line without a tty field is no signal",
            MultiplexerProbe.parseTmuxClients(exitStatus: 0, stdout: attachedOut + "garbage line\n") == .noSignal
        )

        // MARK: client_attached compatibility parsing

        check(
            "client_attached: exit 0 empty is detached",
            MultiplexerProbe.parseClientAttached(exitStatus: 0, stdout: "\n") == .detached
        )
        check(
            "client_attached: exit 0 with 1 is attached",
            MultiplexerProbe.parseClientAttached(exitStatus: 0, stdout: "1\n") == .attached(ttys: [])
        )
        check(
            "client_attached: 0 is malformed no signal, never detached",
            MultiplexerProbe.parseClientAttached(exitStatus: 0, stdout: "0\n") == .noSignal
        )
        check(
            "client_attached: garbage is no signal",
            MultiplexerProbe.parseClientAttached(exitStatus: 0, stdout: "yes") == .noSignal
        )
        check(
            "client_attached: nonzero exit is no signal",
            MultiplexerProbe.parseClientAttached(exitStatus: 1, stdout: "") == .noSignal
        )

        // MARK: Structural walk (synthetic ancestry)

        func makeReaders(
            processes: [Int32: AttentionProbe.ProcessRecord],
            apps: [Int32: AttentionProbe.RunningAppRecord],
            windows: [AttentionProbe.WindowRecord]?
        ) -> AttentionProbe.WalkReaders {
            AttentionProbe.WalkReaders(
                process: { pid in processes[pid] },
                application: { pid in apps[pid] ?? RunningAppRecord(exists: false, policy: -1) },
                fullWindows: { windows }
            )
        }

        let regularApp = AttentionProbe.RunningAppRecord(exists: true, policy: 0)
        let accessoryApp = AttentionProbe.RunningAppRecord(exists: true, policy: 1)
        let prohibitedApp = AttentionProbe.RunningAppRecord(exists: true, policy: 2)
        let noApp = AttentionProbe.RunningAppRecord(exists: false, policy: -1)
        let hostWindow = AttentionProbe.WindowRecord(ownerPID: 100, layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 300), windowNumber: 5)

        do {
            // child(5) -> node(6) -> shell(7) -> GUI app(100): found at depth 4.
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                5: .init(pid: 5, ppid: 6, ttyDevice: 0),
                6: .init(pid: 6, ppid: 7, ttyDevice: 0),
                7: .init(pid: 7, ppid: 100, ttyDevice: 0),
                100: .init(pid: 100, ppid: 1, ttyDevice: 0),
            ]
            let readers = makeReaders(
                processes: processes,
                apps: [7: noApp, 100: regularApp],
                windows: [hostWindow]
            )
            check("walk finds the GUI ancestor", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == 100)
        }
        do {
            let readers = makeReaders(
                processes: [5: .init(pid: 5, ppid: 6, ttyDevice: 0), 6: .init(pid: 6, ppid: 1, ttyDevice: 0)],
                apps: [5: noApp, 6: noApp],
                windows: [hostWindow]
            )
            check("no GUI ancestor terminates unidentified", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // 6 <-> 7 parent cycle: repeated-pid guard ends the walk.
            let readers = makeReaders(
                processes: [5: .init(pid: 5, ppid: 6, ttyDevice: 0), 6: .init(pid: 6, ppid: 7, ttyDevice: 0), 7: .init(pid: 7, ppid: 6, ttyDevice: 0)],
                apps: [5: noApp, 6: noApp, 7: noApp],
                windows: [hostWindow]
            )
            check("parent cycle terminates safely", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // Self-parent.
            let readers = makeReaders(
                processes: [5: .init(pid: 5, ppid: 5, ttyDevice: 0)],
                apps: [5: noApp],
                windows: [hostWindow]
            )
            check("self-parent terminates safely", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // A chain of 40 nodes exhausts the 32-hop cap without a host.
            var processes: [Int32: AttentionProbe.ProcessRecord] = [:]
            var apps: [Int32: AttentionProbe.RunningAppRecord] = [:]
            for pid in Int32(5)...44 {
                processes[pid] = .init(pid: pid, ppid: pid + 1, ttyDevice: 0)
                apps[pid] = noApp
            }
            let readers = makeReaders(processes: processes, apps: apps, windows: [hostWindow])
            check("cap exhaustion terminates unidentified", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // A host beyond the cap is never reached.
            var processes: [Int32: AttentionProbe.ProcessRecord] = [:]
            var apps: [Int32: AttentionProbe.RunningAppRecord] = [:]
            for pid in Int32(1)...40 {
                processes[pid] = .init(pid: pid, ppid: pid + 1, ttyDevice: 0)
                apps[pid] = noApp
            }
            processes[45] = .init(pid: 45, ppid: 1, ttyDevice: 0)
            apps[45] = regularApp
            let readers = makeReaders(processes: processes, apps: apps, windows: [hostWindow])
            check("host beyond the cap is unreachable", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // Accessory app (LSUIElement) is walked past; the next regular
            // app with windows qualifies.
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                5: .init(pid: 5, ppid: 50, ttyDevice: 0),
                50: .init(pid: 50, ppid: 100, ttyDevice: 0),
                100: .init(pid: 100, ppid: 1, ttyDevice: 0),
            ]
            let readers = makeReaders(
                processes: processes,
                apps: [50: accessoryApp, 100: regularApp],
                windows: [hostWindow]
            )
            check("accessory app is skipped, not chosen", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == 100)
        }
        do {
            // Prohibited runtime processes are walked past.
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                5: .init(pid: 5, ppid: 60, ttyDevice: 0),
                60: .init(pid: 60, ppid: 100, ttyDevice: 0),
                100: .init(pid: 100, ppid: 1, ttyDevice: 0),
            ]
            let readers = makeReaders(
                processes: processes,
                apps: [60: prohibitedApp, 100: regularApp],
                windows: [hostWindow]
            )
            check("prohibited app is skipped, not chosen", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == 100)
        }
        do {
            // Regular app owning no layer-0 window does not qualify.
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                5: .init(pid: 5, ppid: 100, ttyDevice: 0),
                100: .init(pid: 100, ppid: 1, ttyDevice: 0),
            ]
            let readers = makeReaders(
                processes: processes,
                apps: [100: regularApp],
                windows: [AttentionProbe.WindowRecord(ownerPID: 100, layer: 25, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), windowNumber: 9)]
            )
            check("regular app with only higher-layer windows is skipped", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // Failed window inventory: no host claim from a failed read.
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                5: .init(pid: 5, ppid: 100, ttyDevice: 0),
                100: .init(pid: 100, ppid: 1, ttyDevice: 0),
            ]
            let readers = makeReaders(processes: processes, apps: [100: regularApp], windows: nil)
            check("failed window inventory yields no host", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // Failed process read mid-walk.
            let readers = makeReaders(
                processes: [5: .init(pid: 5, ppid: 6, ttyDevice: 0)],
                apps: [5: noApp],
                windows: [hostWindow]
            )
            check("failed process read terminates unidentified", AttentionProbe.walkGUIHost(startPID: 5, readers: readers) == nil)
        }
        do {
            // Client walks reuse the same rule: client(200) -> GUI(300).
            let processes: [Int32: AttentionProbe.ProcessRecord] = [
                200: .init(pid: 200, ppid: 300, ttyDevice: 42),
                300: .init(pid: 300, ppid: 1, ttyDevice: 0),
            ]
            let window = AttentionProbe.WindowRecord(ownerPID: 300, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), windowNumber: 7)
            let readers = makeReaders(processes: processes, apps: [200: noApp, 300: regularApp], windows: [window])
            check(
                "client ancestry resolves the client's GUI host",
                AttentionProbe.resolveClientHosts(clientPIDs: [200], readers: readers) == [300]
            )
            check(
                "unresolvable client contributes no host",
                AttentionProbe.resolveClientHosts(clientPIDs: [999], readers: readers) == []
            )
        }

        // MARK: Helper ownership

        do {
            // Host 100 with helper child 101; ask-away 500 with child 501.
            let snapshot: [AttentionProbe.ProcessRecord] = [
                .init(pid: 100, ppid: 1, ttyDevice: 0),
                .init(pid: 101, ppid: 100, ttyDevice: 0),
                .init(pid: 500, ppid: 100, ttyDevice: 0),
                .init(pid: 501, ppid: 500, ttyDevice: 0),
            ]
            let owners = AttentionProbe.hostingOwnerPIDs(hosts: [100], snapshot: snapshot, ownPID: 500)!
            check("helper child counts toward ownership", owners.contains(101))
            check("ask-away itself never counts", !owners.contains(500))
            check("ask-away child never counts", !owners.contains(501))
            check("host itself counts", owners.contains(100))
        }
        check(
            "nil snapshot is an unusable ownership read",
            AttentionProbe.hostingOwnerPIDs(hosts: [100], snapshot: nil, ownPID: 500) == nil
        )

        // MARK: Client tty matching

        do {
            // Use a real tty file for the device-number mapping; the
            // snapshot itself is synthetic.
            let ttys = (0...80).compactMap { n -> String? in
                let path = String(format: "/dev/ttys%03d", n)
                return AttentionProbe.ttyDeviceNumber(forTTY: path) != nil ? path : nil
            }
            guard let tty = ttys.first else {
                check("a real /dev/ttysNNN exists for device mapping", false, "no ttys found")
                return printSummary(pass: &pass, fail: &fail)
            }
            let device = AttentionProbe.ttyDeviceNumber(forTTY: tty)!
            let snapshot: [AttentionProbe.ProcessRecord] = [
                .init(pid: 710, ppid: 1, ttyDevice: device),
                .init(pid: 711, ppid: 1, ttyDevice: -1),
                .init(pid: 712, ppid: 1, ttyDevice: device ^ 1),
            ]
            let pids = MultiplexerProbe.clientPIDs(forTTYs: [tty], snapshot: snapshot)
            check("client tty matches exactly the controlling process", pids == [710])
            check("nonexistent tty resolves no client", MultiplexerProbe.clientPIDs(forTTYs: ["/dev/ttys9999"], snapshot: snapshot) == [])
        }

        // MARK: Window-row parsing (production parser, finding 9)

        do {
            let valid: [String: Any] = [
                kCGWindowOwnerPID as String: 100,
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: 5,
                kCGWindowBounds as String: ["X": 1.0, "Y": 2.0, "Width": 500.0, "Height": 300.0],
            ]
            let records = AttentionProbe.parseWindowEntries([valid])
            check(
                "valid window rows parse into typed records",
                records?.count == 1 && records?.first?.ownerPID == 100 && records?.first?.bounds.width == 500,
                "\(String(describing: records))"
            )
        }
        do {
            func row(_ mutate: (inout [String: Any]) -> Void) -> [[String: Any]] {
                var entry: [String: Any] = [
                    kCGWindowOwnerPID as String: 100,
                    kCGWindowLayer as String: 0,
                    kCGWindowNumber as String: 5,
                    kCGWindowBounds as String: ["X": 1.0, "Y": 2.0, "Width": 500.0, "Height": 300.0],
                ]
                mutate(&entry)
                return [entry]
            }
            check("row missing owner pid invalidates the inventory", AttentionProbe.parseWindowEntries(row { $0.removeValue(forKey: kCGWindowOwnerPID as String) }) == nil)
            check("row missing layer invalidates the inventory", AttentionProbe.parseWindowEntries(row { $0.removeValue(forKey: kCGWindowLayer as String) }) == nil)
            check("row missing window number invalidates the inventory", AttentionProbe.parseWindowEntries(row { $0.removeValue(forKey: kCGWindowNumber as String) }) == nil)
            check("row missing bounds invalidates the inventory", AttentionProbe.parseWindowEntries(row { $0.removeValue(forKey: kCGWindowBounds as String) }) == nil)
            check(
                "row with partial bounds invalidates the inventory",
                AttentionProbe.parseWindowEntries(row {
                    var bounds = ($0[kCGWindowBounds as String] as? [String: Any]) ?? [:]
                    bounds.removeValue(forKey: "Height")
                    $0[kCGWindowBounds as String] = bounds
                }) == nil
            )
            check(
                "one malformed row beside a valid one still invalidates",
                AttentionProbe.parseWindowEntries([
                    [
                        kCGWindowOwnerPID as String: 100,
                        kCGWindowLayer as String: 0,
                        kCGWindowNumber as String: 5,
                        kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 10.0, "Height": 10.0],
                    ],
                    [kCGWindowOwnerPID as String: 200, kCGWindowLayer as String: 0],
                ]) == nil
            )
        }

        // MARK: Visibility reading (production predicate, no mirror)

        do {
            func raw(_ owner: Int, _ layer: Int, _ w: Double, _ h: Double, _ number: Int) -> [String: Any] {
                [
                    kCGWindowOwnerPID as String: owner,
                    kCGWindowLayer as String: layer,
                    kCGWindowNumber as String: number,
                    kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": w, "Height": h],
                ]
            }
            let list = [
                raw(100, 0, 0, 10, 1),   // zero width: excluded
                raw(100, 0, 10, 0.5, 2), // flat: excluded
                raw(100, 0, 1, 1, 3),    // 1pt qualifies
                raw(100, 25, 50, 50, 4), // non-zero layer: excluded
                raw(999, 0, 50, 50, 5),  // other owner: excluded
            ]
            let parsed = AttentionProbe.parseWindowEntries(list)!
            let count = AttentionProbe.qualifyingOnScreenCount(windows: parsed, ownerPIDs: [100])
            check("production predicate counts exactly the qualifying windows", count == 1)
        }
        check(
            "live on-screen inventory read succeeds on this machine",
            AttentionProbe.readWindows(scope: .onScreen) != nil
        )
        check(
            "live visibility with no owners is no signal",
            AttentionProbe.readHostingVisibility(ownerPIDs: []) == .noSignal
        )
        check(
            "live visibility with nil owners is no signal",
            AttentionProbe.readHostingVisibility(ownerPIDs: nil) == .noSignal
        )

        // Live smoke: the walk from this test process must terminate (a
        // terminal-spawned process resolves a host; a daemon-spawned one
        // returns nil) without crashing. Informational only.
        let smokeHost = AttentionProbe.walkGUIHost(startPID: getpid(), readers: AttentionProbe.liveReaders)
        print("note  live smoke: walk from pid \(getpid()) resolved host pid \(smokeHost.map(String.init) ?? "nil")")

        // MARK: Bounded subprocess

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("askaway-detection-\(getpid())")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        func script(_ name: String, _ body: String) -> String {
            let url = scratch.appendingPathComponent(name)
            try? "#!/bin/sh\n\(body)".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        let attachedScript = script("attached.sh", "printf '/dev/ttys042: v03 [80x24 xterm-256color] (attached,focused,UTF-8)\\n'\nexit 0\n")
        let exitOneScript = script("exit1.sh", "echo 'error' >&2\nexit 1\n")
        let slowScript = script("slow.sh", "sleep 3\nexit 0\n")
        // Ignores SIGTERM: only the budget-bounded completion (and the
        // post-completion KILL) can end it (finding 7).
        let ignoreTermScript = script("ignore-term.sh", "trap '' TERM\nsleep 5\nexit 0\n")
        // Exits immediately while a grandchild inherits stdout and holds it
        // open: EOF never arrives on its own (finding 7).
        let lateEOFScript = script("late-eof.sh", "sh -c 'sleep 3' &\nprintf 'ok\\n'\nexit 0\n")
        // Exit 0 with undecodable bytes: decode failure must be no signal,
        // never an empty string that parses as detached (finding 6).
        let invalidUTF8Script = script("invalid-utf8.sh", "printf '\\xff\\xfe\\xc3\\x28\\n'\nexit 0\n")

        do {
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: attachedScript)
            check(
                "scripted attached subprocess parses attached",
                MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout) == .attached(ttys: ["/dev/ttys042"]),
                "\(result)"
            )
        }
        do {
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: exitOneScript)
            check(
                "nonzero subprocess exit is no signal",
                MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout) == .noSignal,
                "\(result)"
            )
        }
        do {
            let started = Date()
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 0.5, executable: slowScript)
            let elapsed = Date().timeIntervalSince(started)
            check(
                "timeout completes as no signal inside the budget",
                result.exitStatus == nil && result.stdout == nil && elapsed < 1.0,
                "elapsed \(elapsed)s result \(result)"
            )
        }
        do {
            let started = Date()
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 0.5, executable: ignoreTermScript)
            let elapsed = Date().timeIntervalSince(started)
            check(
                "termination-resistant child still completes within the budget",
                result.exitStatus == nil && result.stdout == nil && elapsed < 1.0,
                "elapsed \(elapsed)s result \(result)"
            )
        }
        do {
            let started = Date()
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: lateEOFScript)
            let elapsed = Date().timeIntervalSince(started)
            // Incomplete drainage is NO SIGNAL since the round-2 drain
            // fix (lead review, finding 7 residual): partial bytes from
            // a hung pipe are never a usable reading.
            check(
                "delayed EOF from a grandchild is bounded past the child exit and reads no signal",
                result.exitStatus == nil && result.stdout == nil && elapsed < 1.2
                    && MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout) == .noSignal,
                "elapsed \(elapsed)s result \(result)"
            )
        }
        do {
            // Empty partial output held past the drain deadline: the
            // specific detached-forgery shape from lead finding 7.
            let emptyLateEOFScript = script("empty-late-eof.sh", "sh -c 'sleep 3' &\nexit 0\n")
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: emptyLateEOFScript)
            check(
                "empty incomplete drain is no signal, never detached",
                result.exitStatus == nil && result.stdout == nil
                    && MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout) == .noSignal,
                "\(result)"
            )
        }
        do {
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: invalidUTF8Script)
            check(
                "exit 0 with invalid UTF-8 stdout is no signal, never detached",
                result.exitStatus == 0 && result.stdout == nil
                    && MultiplexerProbe.parseTmuxClients(exitStatus: result.exitStatus, stdout: result.stdout) == .noSignal,
                "\(result)"
            )
            check(
                "client_attached parse also treats undecodable output as no signal",
                MultiplexerProbe.parseClientAttached(exitStatus: 0, stdout: nil) == .noSignal
            )
        }
        do {
            let result = await MultiplexerProbe.runTmuxClients(socket: "/unused", sessionTarget: "0", timeout: 2, executable: "/nonexistent/executable")
            check("launch failure is no signal with zero bytes", result.exitStatus == nil && result.stdout == "")
        }

        // MARK: Live engine latency (finding 8: discovery off the main
        // actor, publication of completed evidence only, cancel on finish)

        for outcome in await engineLatencyChecks() {
            check(outcome.0, outcome.1, outcome.2)
        }

        printSummary(pass: &pass, fail: &fail)
    }

    /// Latency and lifecycle checks against LiveAttentionEngine with slow
    /// injected walk readers. The evaluation surface must never wait on
    // discovery: readSnapshot returns pending immediately while the walk
    /// is still running, publishes only when it completes, and cancel()
    /// stops publication outright.
    @MainActor
    private static func engineLatencyChecks() async -> [(String, Bool, String)] {
        var results: [(String, Bool, String)] = []
        func note(_ name: String, _ ok: Bool, _ detail: String = "") {
            results.append((name, ok, detail))
        }
        let realPID = ProcessInfo.processInfo.processIdentifier
        let hopDelay: TimeInterval = 0.3
        let chain: [Int32: AttentionProbe.ProcessRecord] = [
            realPID: .init(pid: realPID, ppid: 99001, ttyDevice: 0),
            99001: .init(pid: 99001, ppid: 99002, ttyDevice: 0),
            99002: .init(pid: 99002, ppid: 1, ttyDevice: 0),
        ]
        let slowReaders = AttentionProbe.WalkReaders(
            process: { pid in
                Thread.sleep(forTimeInterval: hopDelay)
                return chain[pid]
            },
            application: { pid in
                pid == 99002 ? AttentionProbe.RunningAppRecord(exists: true, policy: 0) : RunningAppRecord(exists: false, policy: -1)
            },
            fullWindows: {
                [AttentionProbe.WindowRecord(ownerPID: 99002, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), windowNumber: 77)]
            }
        )
        let engine = LiveAttentionEngine(environment: [:], tmuxExecutable: nil, readers: slowReaders)
        engine.beginDiscovery()
        // 0.9s+ of sysctl-walk delay: three hops at 0.3s each.
        do {
            let started = Date()
            let snapshot = engine.readSnapshot(now: 0)
            let elapsed = Date().timeIntervalSince(started)
            note(
                "readSnapshot never blocks behind slow discovery",
                snapshot.hosting == .pending && elapsed < 0.05,
                "elapsed \(elapsed)s hosting \(snapshot.hosting)"
            )
        }
        do {
            try? await Task.sleep(nanoseconds: 400_000_000)
            let snapshot = engine.readSnapshot(now: 0.4)
            note(
                "unfinished discovery surfaces as pending, not stale identity",
                snapshot.hosting == .pending,
                "\(snapshot.hosting)"
            )
        }
        do {
            var hosting: HostingReading = .pending
            var visibility: VisibilityReading = .noSignal
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                engine.refreshTransient()
                let snapshot = engine.readSnapshot(now: 1)
                hosting = snapshot.hosting
                visibility = snapshot.visibility
                if case .pending = hosting {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                break
            }
            // ~0.9s of injected walk delay: three hops at 0.3s. Publication
            // carries the completed walk (identified) and a completed
            // visibility count; the count's value follows the real on-screen
            // inventory for the synthetic pid, so only its case is asserted.
            var identified = false
            if case let .identified(pids) = hosting, pids.contains(99002) { identified = true }
            var counted = false
            if case .count = visibility { counted = true }
            note(
                "completed discovery publishes identified hosting with a completed count",
                identified && counted,
                "hosting \(hosting) visibility \(visibility)"
            )
        }
        do {
            let cancelled = LiveAttentionEngine(environment: [:], tmuxExecutable: nil, readers: slowReaders)
            cancelled.beginDiscovery()
            cancelled.cancel()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            let hosting = cancelled.readSnapshot(now: 0).hosting
            note(
                "cancel stops discovery publication",
                hosting == .pending,
                "\(hosting)"
            )
        }
        return results
    }

    private static func printSummary(pass: inout Int, fail: inout Int) {
        print("attention-detection total: \(pass) passed, \(fail) failed")
        exit(fail > 0 ? 1 : 0)
    }
}

private typealias RunningAppRecord = AttentionProbe.RunningAppRecord
