import AppKit
import CoreVideo

/// One tick source at ~30Hz while a time bound is set, feeding the drain
/// line, the ramp color, and the seconds text (design.md section 6).
///
/// CVDisplayLink is the primary driver; if it cannot be created or started,
/// a 30Hz Timer on the main run loop takes over (the section 10 fallback).
/// Either way the update runs on the main actor - the line is the only
/// per-frame work in the whole panel.
@MainActor
final class DrainTicker {

    private var displayLink: CVDisplayLink?
    private var timer: Timer?
    private let tick: () -> Void

    init(tick: @escaping () -> Void) {
        self.tick = tick
    }

    func start() {
        if startDisplayLink() { return }
        let fallback = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        timer = fallback
    }

    func stop() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
            Self.tickBox = nil
            self.displayLink = nil
        }
        timer?.invalidate()
        timer = nil
    }

    private func startDisplayLink() -> Bool {
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else {
            return false
        }
        // CVDisplayLink's output handler is a C function pointer: no context
        // capture. One process shows one panel, so a single process-wide box
        // carries the callback and lives until stop().
        let box = TickBox { [weak self] in
            Task { @MainActor in
                self?.tick()
            }
        }
        Self.tickBox = box
        CVDisplayLinkSetOutputHandler(link) { _, _, _, _, _ in
            DrainTicker.tickBox?.fire()
            return kCVReturnSuccess
        }
        guard CVDisplayLinkStart(link) == kCVReturnSuccess else {
            Self.tickBox = nil
            return false
        }
        displayLink = link
        return true
    }
}

/// @unchecked: the box only forwards to a handler; the handler hops to the
/// main actor before touching any UI state.
private final class TickBox: @unchecked Sendable {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler()
    }
}

extension DrainTicker {
    fileprivate nonisolated(unsafe) static var tickBox: TickBox?
}
