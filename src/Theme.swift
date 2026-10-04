import AppKit
import SwiftUI

/// Design tokens from docs/design.md section 0. Single source of truth:
/// every color, font, and dimension the panel uses comes from here.
/// MainActor: every reader builds UI on the main actor.
@MainActor
enum Theme {
    // MARK: Colors (section 0)

    static let accent = NSColor(srgbRed: 0x00 / 255.0, green: 0xE5 / 255.0, blue: 0xFF / 255.0, alpha: 1)
    static let accentHover = NSColor(srgbRed: 0x4D / 255.0, green: 0xEC / 255.0, blue: 0xFF / 255.0, alpha: 1)
    static let accentPressed = NSColor(srgbRed: 0x00 / 255.0, green: 0xC2 / 255.0, blue: 0xDE / 255.0, alpha: 1)
    /// #0B0F16, the panel base color. The scrim draws it at 90% alpha over vibrancy.
    static let panelBase = NSColor(srgbRed: 0x0B / 255.0, green: 0x0F / 255.0, blue: 0x16 / 255.0, alpha: 1)
    static let textBody = NSColor(srgbRed: 0xF2 / 255.0, green: 0xF7 / 255.0, blue: 0xFB / 255.0, alpha: 1)
    static let textCode = NSColor(srgbRed: 0xCF / 255.0, green: 0xE9 / 255.0, blue: 0xF2 / 255.0, alpha: 1)
    /// Reserved token (section 0); defined so the table has one owner.
    static let textSecondary = NSColor(srgbRed: 0x9F / 255.0, green: 0xB4 / 255.0, blue: 0xC1 / 255.0, alpha: 1)
    static let buttonDarkLabel = NSColor(srgbRed: 0x06 / 255.0, green: 0x21 / 255.0, blue: 0x26 / 255.0, alpha: 1)
    static let buttonDarkLabelDisabled = NSColor(srgbRed: 0x66 / 255.0, green: 0x90 / 255.0, blue: 0x99 / 255.0, alpha: 1)
    static let rampAmber = NSColor(srgbRed: 0xFF / 255.0, green: 0xB0 / 255.0, blue: 0x20 / 255.0, alpha: 1)
    static let rampRed = NSColor(srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
    /// Desaturated ice midpoint of the countdown ramp (section 2), required at the 35% mark.
    static let rampIce = NSColor(srgbRed: 0xA8 / 255.0, green: 0xE6 / 255.0, blue: 0xEE / 255.0, alpha: 1)

    static let accentSwiftUI = Color(nsColor: accent)
    static let textBodySwiftUI = Color(nsColor: textBody)
    static let textCodeSwiftUI = Color(nsColor: textCode)
    static let buttonDarkLabelSwiftUI = Color(nsColor: buttonDarkLabel)
    static let chipFillSwiftUI = Color.white.opacity(0.05)

    // MARK: Typography (section 3)

    static let metadataFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let metadataKerning: CGFloat = 0.3
    static let bodyFont = NSFont.systemFont(ofSize: 15, weight: .regular)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let bodyLineHeight: CGFloat = 21
    static let bodyKerning: CGFloat = -0.1
    static let buttonGhostFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let buttonDefaultFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let buttonKerning: CGFloat = 0.1

    static let metadataSwiftUIFont = Font(metadataFont)
    static let bodySwiftUIFont = Font(bodyFont)
    static let codeSwiftUIFont = Font(codeFont)

    // MARK: Layout (sections 1, 4, 5, 6)

    static let panelCut: CGFloat = 14
    static let buttonCut: CGFloat = 7
    static let horizontalPadding: CGFloat = 20
    static let topPadding: CGFloat = 18
    static let metadataHeight: CGFloat = 14
    static let metadataToBody: CGFloat = 10
    static let bodyToButtons: CGFloat = 18
    static let buttonRowHeight: CGFloat = 30
    static let bottomPadding: CGFloat = 20
    static let buttonGap: CGFloat = 8
    static let buttonMinWidth: CGFloat = 64
    static let buttonHPadding: CGFloat = 16
    static let drainLineHeight: CGFloat = 2
    static let maxBodyLines = 4
    /// Drain line spans the full inner width: panel width minus the bottom-right cut.
    static var drainLineWidth: CGFloat { panelCut }
    /// Transparent margin between the window edge and the visual panel rect:
    /// room for the outer glow (r12), the ambient shadow (r20 + 4pt offset),
    /// and clear of the system's rounded-window edge treatment.
    static let windowMargin: CGFloat = 28

    // MARK: Width rule (section 1)

    static let widthCandidates: [CGFloat] = [340, 420, 520]
    static let twoLineBudget: CGFloat = 2 * bodyLineHeight

    // MARK: Elevation (section 4)

    static let glowRadius: CGFloat = 12
    static let glowOpacity: Float = 0.38
    static let defaultGlowRadius: CGFloat = 8
    static let defaultGlowOpacity: Float = 0.35
    static let ambientRadius: CGFloat = 20
    static let ambientOpacity: Float = 0.35
    static let ambientOffset = CGSize(width: 0, height: 4)

    // MARK: Motion (section 7)

    static let entranceDuration: TimeInterval = 0.18
    static let exitDuration: TimeInterval = 0.14
    static let reduceMotionEntranceDuration: TimeInterval = 0.10
    static let reduceMotionExitDuration: TimeInterval = 0.10
    static let hoverCrossfade: TimeInterval = 0.12
    static let drainCrossfade: TimeInterval = 0.30
    /// CubicBezier(0.2, 0.8, 0.2, 1), the entrance and exit curve.
    static let mainCurve = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)

    // MARK: Countdown ramp (section 2)

    /// Piecewise ramp as a function of the remaining fraction:
    /// 100-50% accent held; 50-20% cyan to amber through the ice midpoint at 35%;
    /// 20-0% amber to red.
    static func rampColor(remainingFraction fraction: Double) -> NSColor {
        let f = min(max(fraction, 0), 1)
        if f >= 0.5 { return accent }
        if f >= 0.35 { return blend(accent, rampIce, from: 0.5, to: 0.35, at: f) }
        if f >= 0.2 { return blend(rampIce, rampAmber, from: 0.35, to: 0.2, at: f) }
        return blend(rampAmber, rampRed, from: 0.2, to: 0, at: f)
    }

    private static func blend(_ start: NSColor, _ end: NSColor, from hi: Double, to lo: Double, at f: Double) -> NSColor {
        let t = CGFloat((hi - f) / (hi - lo))
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        start.usingColorSpace(.sRGB)?.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        end.usingColorSpace(.sRGB)?.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return NSColor(
            srgbRed: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t
        )
    }
}
