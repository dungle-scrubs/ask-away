# Product

<!-- impeccable:product-schema 1 -->

> Record inferred from the owner's explicit design brief (task order: autonomous
> completion, commit docs/design.md). No interview was conducted; every fact
> below traces to that brief. The single open decision it left - accent hue -
> was delegated to the designer with explicit criteria.

## Platform

macos

## Stack

Native macOS app, single CLI-invoked binary: Swift, AppKit `NSPanel` hosting
SwiftUI content. Pinned by the brief.

## Users

Developers running coding agents (CLI agents such as Claude Code, pi, Codex).
The human at the keyboard is the real user: an agent interrupts them mid-work
in any app, asks one bounded question, and the human answers it at a glance
without switching context.

## Product Purpose

`ask-away` shows a one-shot native macOS decision dialog on behalf of a coding
agent. The agent invokes it from a CLI with a title, 1-2 sentence body, 2-3
buttons, an optional default button, an optional timeout, and an optional beep
suppressor. The human's answer returns on stdout as the clicked button's text,
`CANCELED` (Escape), or `GAVE-UP` (timeout), with exit codes 0 / 2 / 3.
Success: the question is understood and answered in seconds, mid-work, with
zero focus theft and zero ambiguity about which button is recommended.

## Positioning

A agent-facing prompt that behaves like a piece of the agent harness, not a
user app: non-activating key window over the current app, cascading for
parallel agents, machine-readable stdout/exit contract, one-window-per-
invocation. A neighboring "notifications with buttons" product could not
truthfully copy the focus discipline, the stdout contract, or the
agent-cascade behavior.

## Operating Context

- Invoked from a terminal or agent process, one process per invocation.
- Appears over whatever the user is doing, on the screen containing the
  pointer, slightly above center; parallel invocations cascade with a small
  offset.
- Must take key focus for Return/Escape without activating (stealing focus
  from) the user's current app: `.nonactivatingPanel` + `.floating` level.
- Body text may contain inline markdown: emphasis and code spans.
- Optional countdown bound; optional audio beep at appearance.

## Capabilities and Constraints

- CLI contract: `--title`, `--text`, `--buttons` (2-3), `--default N`,
  `--give-up-after SECONDS`, `--no-beep`.
- stdout result contract: button text | `CANCELED` | `GAVE-UP`; exit 0/2/3.
- Panel geometry: chamfered corners (45-degree cuts, Cyberpunk 2077 style),
  1px neon edge with soft outer glow, near-black glass panel.
- Exactly ONE accent color (cyan or magenta; owner delegated the pick on
  readability and vibration-avoidance criteria).
- Monospace for metadata line and countdown; SF Pro for body; buttons bottom-
  right, rightmost = recommended = default (Return).
- Countdown drawn as a thin draining line on the panel's bottom edge, hue
  shifting accent -> amber -> red.
- Entrance: quick fade + ~2% scale-in (~150-200ms). No looping animation, no
  glitch effects, no scanlines. Reduce Motion respected.
- Panel is always dark regardless of system appearance.

## Brand Commitments

Binding visual direction from the owner, verbatim in spirit: "Cyberpunk
chrome, quiet content. The neon lives in the panel's border, metadata, and
buttons; the question body stays near-white, high-contrast, instantly
readable." Ghost buttons with neon hairlines; the recommended/default button
filled with the accent and dark text. No glitch, no scanlines, no loops - a
decision surface, not a screensaver.

## Evidence on Hand

Owner's design brief (this session's task order). No usage data, no
screenshots, no prior implementation. Nothing here may be fabricated later.

## Product Principles

1. Answerable at a glance: the question, the recommended answer, and the time
   left must be readable in under two seconds from across the room.
2. Never steal context: appear, take keys, and vanish without activating or
   rearranging the user's current app.
3. Neon on the chrome, quiet in the content: expression lives in the frame;
   the words stay calm and high-contrast.
4. One window, one decision: no flows, no nesting, no memory of past
   questions.

## Accessibility & Inclusion

- WCAG contrast required for body text and button labels against the panel
  (brief mandates reporting the ratios); target AA minimum, aim AAA on body.
- Minimum hit targets on buttons; full-button hit area.
- VoiceOver labels for panel and buttons; countdown must not spam
  announcements.
- Reduce Motion: entrance falls back to fade-only.
