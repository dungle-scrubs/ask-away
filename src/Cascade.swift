import AppKit

/// Lock-protected cascade registry (design.md section 9).
///
/// Every invocation is its own process, so the cascade index comes from a
/// per-screen directory of pid-named entries under the app-support directory:
/// lock the lock file, prune entries whose pid is dead, count the rest, write
/// own entry, unlock. Each process removes its entry on every exit path;
/// a crashed process leaves a stale entry that the next show prunes.
enum Cascade {

    /// Index of this invocation: how many live ask-away panels are already
    /// visible on the screen, 0-based. Claims one entry; pair with `release`.
    static func claimIndex(screenID: String) -> Int {
        let dir = Self.registryDirectory(screenID: screenID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lockPath = dir.appendingPathComponent("lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return 0 }
        defer { flock(fd, LOCK_UN) }

        var live = 0
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for entry in entries where entry != "lock" {
            guard let pid = pid_t(entry) else {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(entry).path)
                continue
            }
            if isAlive(pid) {
                live += 1
            } else {
                try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(entry).path)
            }
        }
        let own = String(ProcessInfo.processInfo.processIdentifier)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent(own).path,
            contents: Data()
        )
        return live
    }

    /// Remove this process's entry. Safe to call twice.
    static func release(screenID: String) {
        let dir = Self.registryDirectory(screenID: screenID)
        let own = String(ProcessInfo.processInfo.processIdentifier)
        try? FileManager.default.removeItem(atPath: dir.appendingPathComponent(own).path)
    }

    private static func registryDirectory(screenID: String) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("ask-away", isDirectory: true)
            .appendingPathComponent("cascade", isDirectory: true)
            .appendingPathComponent(sanitized(screenID), isDirectory: true)
    }

    private static func sanitized(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }
}
