import AppKit
import CoreGraphics
import Darwin

/// Failure-wrapped detection probes (design.md section 14, plan section 3).
/// Every read returns a typed result or an explicit failure; a failed read
/// is never an empty successful inventory. No probe reads `kCGWindowName`
/// (the only Screen-Recording-gated field); owner pid, bounds, and layer
/// are ungated. No application-name allowlist, bundle-ID matching, or
/// `TERM_PROGRAM` consultation exists here: identification is structural.
enum AttentionProbe {

    // MARK: Process reads

    /// One process row: pid, parent pid, and controlling-terminal device.
    struct ProcessRecord: Equatable, Sendable {
        let pid: Int32
        let ppid: Int32
        /// `kp_eproc.e_tdev` (dev_t); -1 (NODEV) when the process has no
        /// controlling terminal.
        let ttyDevice: dev_t
    }

    /// sysctl KERN_PROC_PID for one process, or nil on failure.
    static func readProcess(pid: Int32) -> ProcessRecord? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride else {
            return nil
        }
        return ProcessRecord(pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid, ttyDevice: info.kp_eproc.e_tdev)
    }

    /// The full process snapshot via KERN_PROC_ALL, or nil on failure.
    /// Used for descendant membership and client-tty resolution.
    static func readAllProcesses() -> [ProcessRecord]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let stride = MemoryLayout<kinfo_proc>.stride
        var records: [ProcessRecord] = []
        records.reserveCapacity(size / stride)
        for offset in Swift.stride(from: 0, to: size, by: stride) {
            let info = buffer.withUnsafeBytes { raw -> kinfo_proc in
                raw.loadUnaligned(fromByteOffset: offset, as: kinfo_proc.self)
            }
            records.append(ProcessRecord(pid: info.kp_proc.p_pid, ppid: info.kp_eproc.e_ppid, ttyDevice: info.kp_eproc.e_tdev))
        }
        return records
    }

    /// The controlling-terminal device number of a `/dev/ttysNNN` path, via
    /// stat - never by opening the device. nil when the tty does not exist.
    static func ttyDeviceNumber(forTTY path: String) -> dev_t? {
        guard path.hasPrefix("/dev/") else { return nil }
        var st = stat()
        let rc: Int32 = path.withCString { cpath -> Int32 in
            withUnsafeMutablePointer(to: &st) { stp -> Int32 in
                stat(cpath, stp)
            }
        }
        return rc == 0 ? st.st_rdev : nil
    }

    // MARK: Application and window reads

    /// Structural application metadata for one pid.
    struct RunningAppRecord: Equatable, Sendable {
        let exists: Bool
        let policy: Int

        var qualifiesKind: Bool { exists && policy == NSApplication.ActivationPolicy.regular.rawValue }
    }

    /// NSRunningApplication resolution plus activation policy. A nil record
    /// (no running application) is a successful "not an app" read.
    static func readRunningApplication(pid: Int32) -> RunningAppRecord {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return RunningAppRecord(exists: false, policy: -1)
        }
        return RunningAppRecord(exists: true, policy: app.activationPolicy.rawValue)
    }

    /// One window row; names are never read.
    struct WindowRecord: Equatable, Sendable {
        let ownerPID: Int32
        let layer: Int
        let bounds: CGRect
        let windowNumber: Int
    }

    enum WindowScope {
        /// Full inventory (any Space, minimized included): host qualification.
        case full
        /// On-screen only, desktop elements excluded: visibility.
        case onScreen
    }

    /// CGWindowListCopyWindowInfo as typed records, or nil on a failed
    /// read. Row parsing lives in `parseWindowEntries`.
    static func readWindows(scope: WindowScope) -> [WindowRecord]? {
        let options: CGWindowListOption = scope == .full
            ? []
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return parseWindowEntries(list)
    }

    /// Raw window-list rows into typed records. One malformed row
    /// invalidates the whole inventory (nil): a row missing its owner pid,
    /// layer, window number, or complete numeric bounds is
    /// indistinguishable from the hosting app's own row, and silently
    /// dropping or zero-defaulting it could turn an unreadable host into a
    /// successful zero-window observation (review finding 9). nil is no
    /// signal, so the failure direction is safe: it can only suppress
    /// escalation, never cause it.
    static func parseWindowEntries(_ list: [[String: Any]]) -> [WindowRecord]? {
        var records: [WindowRecord] = []
        records.reserveCapacity(list.count)
        for entry in list {
            guard
                let owner = entry[kCGWindowOwnerPID as String] as? Int,
                let layer = entry[kCGWindowLayer as String] as? Int,
                let number = entry[kCGWindowNumber as String] as? Int,
                let raw = entry[kCGWindowBounds as String] as? [String: Any],
                let x = raw["X"] as? Double,
                let y = raw["Y"] as? Double,
                let width = raw["Width"] as? Double,
                let height = raw["Height"] as? Double
            else { return nil }
            records.append(WindowRecord(
                ownerPID: Int32(owner),
                layer: layer,
                bounds: CGRect(x: x, y: y, width: width, height: height),
                windowNumber: number
            ))
        }
        return records
    }

    // MARK: Structural GUI-host walk

    /// Reader bundles so synthetic ancestries can drive the same walk the
    /// production engine uses.
    struct WalkReaders: Sendable {
        let process: @Sendable (Int32) -> ProcessRecord?
        let application: @Sendable (Int32) -> RunningAppRecord
        let fullWindows: @Sendable () -> [WindowRecord]?
    }

    /// The live reader bundle: sysctl, NSRunningApplication, and the full
    /// window inventory. Shared by the direct walk and client walks.
    static let liveReaders = WalkReaders(
        process: { pid in AttentionProbe.readProcess(pid: pid) },
        application: { pid in AttentionProbe.readRunningApplication(pid: pid) },
        fullWindows: { AttentionProbe.readWindows(scope: .full) }
    )

    /// Walk from `startPID` toward its ancestors, capped at
    /// MAX_ANCESTOR_HOPS, and return the nearest ancestor that is a GUI
    /// application: NSRunningApplication resolves, activation policy is
    /// `.regular`, and a successful full window inventory contains at least
    /// one owner-matching layer-0 entry. Stops safely at PID 1/0, a failed
    /// process read, a self-parent, a repeated pid, or cap exhaustion;
    /// returns nil (unidentified) in all of those cases without a host.
    @discardableResult
    static func walkGUIHost(startPID: Int32, readers: WalkReaders) -> Int32? {
        var pid = startPID
        var visited: Set<Int32> = []
        var hops = 0
        while pid > 1, hops < AttentionConstants.maxAncestorHops {
            // The walk runs inside a cancellable task; stop between hops.
            if Task.isCancelled { return nil }
            hops += 1
            if !visited.insert(pid).inserted { return nil }
            if let host = qualifyingHost(pid: pid, readers: readers) {
                return host
            }
            guard let record = readers.process(pid), record.ppid != pid else { return nil }
            pid = record.ppid
        }
        return nil
    }

    /// The three-part structural test for one candidate pid.
    static func qualifyingHost(pid: Int32, readers: WalkReaders) -> Int32? {
        guard readers.application(pid).qualifiesKind else { return nil }
        guard let windows = readers.fullWindows() else { return nil }
        let ownsNormalWindow = windows.contains { record in
            record.ownerPID == pid && record.layer == AttentionConstants.hostingWindowLayer
        }
        return ownsNormalWindow ? pid : nil
    }

    /// Apply the same structural walk to resolved client pids; every
    /// qualifying host joins the set (multiple clients on one session).
    static func resolveClientHosts(clientPIDs: [Int32], readers: WalkReaders) -> [Int32] {
        var hosts: [Int32] = []
        for pid in clientPIDs where !hosts.contains(pid) {
            if let host = walkGUIHost(startPID: pid, readers: readers) {
                if !hosts.contains(host) { hosts.append(host) }
            }
        }
        return hosts
    }

    // MARK: Helper ownership

    /// Host pids plus their proven descendants, excluding ask-away itself
    /// and ask-away's descendants: the panel's own window must never keep
    /// its host "visible". Requires a fresh process snapshot; nil snapshot
    /// yields nil (unusable ownership read).
    static func hostingOwnerPIDs(hosts: [Int32], snapshot: [ProcessRecord]?, ownPID: Int32) -> [Int32]? {
        guard let snapshot else { return nil }
        var children: [Int32: [Int32]] = [:]
        for record in snapshot where record.ppid > 0 {
            children[record.ppid, default: []].append(record.pid)
        }
        var excluded: Set<Int32> = [ownPID]
        var frontier = [ownPID]
        while let pid = frontier.popLast() {
            for child in children[pid] ?? [] where !excluded.contains(child) {
                excluded.insert(child)
                frontier.append(child)
            }
        }
        var owners: Set<Int32> = []
        var queue = hosts
        while let pid = queue.popLast() {
            guard owners.insert(pid).inserted else { continue }
            for child in children[pid] ?? [] where !excluded.contains(child) {
                queue.append(child)
            }
        }
        return Array(owners)
    }

    // MARK: Visibility and hard absence

    /// Count owner-matching on-screen windows: layer 0, width and height
    /// each at least MIN_ONSCREEN_WINDOW_DIMENSION_PTS. A successful zero
    /// differs from a failed inventory or an empty ownership read.
    static func readHostingVisibility(ownerPIDs: [Int32]?) -> VisibilityReading {
        guard let ownerPIDs, !ownerPIDs.isEmpty else { return .noSignal }
        guard let windows = readWindows(scope: .onScreen) else { return .noSignal }
        return .count(qualifyingOnScreenCount(windows: windows, ownerPIDs: ownerPIDs))
    }

    /// The production on-screen predicate, shared by the live read and the
    /// synthetic tests: no test re-implements the filter (finding 9).
    static func qualifyingOnScreenCount(windows: [WindowRecord], ownerPIDs: [Int32]) -> Int {
        let minimum = AttentionConstants.minOnscreenWindowDimensionPoints
        return windows.filter { record in
            ownerPIDs.contains(record.ownerPID)
                && record.layer == AttentionConstants.hostingWindowLayer
                && record.bounds.width >= minimum
                && record.bounds.height >= minimum
        }.count
    }

    /// Display asleep or screensaver running. Failed reads default awake
    /// (the safe direction: no escalation).
    static func readHardAbsence() -> HardAbsenceReading {
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        guard !asleep else { return .absent(displayAsleep: true, screensaver: false) }
        let screensaver = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.apple.screensaver"
        }
        return screensaver
            ? .absent(displayAsleep: false, screensaver: true)
            : .awake
    }
}
