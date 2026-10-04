# ask-away panel design spec

The visual contract for the decision dialog. A dev agent implements from this
file; every value here is a requirement, not a suggestion. Rationale appears
only where it prevents a wrong implementation.

Direction in one line: **cyberpunk chrome, quiet content** - the neon lives in
the border, metadata, and buttons; the body stays near-white and instantly
readable. No loops, no glitch, no scanlines: this is a decision surface, not a
screensaver.

---

## 0. Tokens (single source of truth)

| Token | Value |
| --- | --- |
| `accent` | `#00E5FF` |
| `accent-hover` | `#4DECFF` |
| `accent-pressed` | `#00C2DE` |
| `accent-dim` | accent @ 28% alpha (fills over panel base) |
| `panel-base` | `#0B0F16` @ 90% alpha over vibrancy |
| `text-body` | `#F2F7FB` |
| `text-code` | `#CFE9F2` |
| `text-secondary` (reserved) | `#9FB4C1` |
| `btn-dark-label` | `#062126` |
| `ramp-amber` | `#FFB020` |
| `ramp-red` | `#FF453A` |

One accent, cyan. Magenta was rejected on the owner's own two criteria: neon
magenta's dark-on-fill contrast is ~2.8:1 (fails), and a magenta accent would
pile a third hot hue next to the countdown's amber-red ramp. Cyan's luminance
(0.63) keeps every accent role readable on near-black.

**The panel is always dark, regardless of system appearance.** It appears
unannounced over arbitrary apps at any moment; glanceability and the neon
identity must never depend on what the user had open, so appearance is locked
(see §10).

## 1. Layout

```
+--------------------------------------------------+
| ▲14pt cut (top-left)                             |
|  metadata row                  countdown "42s"   |  18pt top pad
|  body text, 1-2 sentences,                       |
|  wraps, inline md spans                          |  10pt above, 18pt below
|              [ ghost ] [ ghost ] [ FILLED ]      |  row right-aligned
| ▓▓▓▓▓▓▓▓▓▓▓▓▓▓__________ drain line (2pt)        |
|                              (bottom-right cut)  |
+--------------------------------------------------+
```

- Base grid: 4pt. Horizontal padding 20pt. Top padding 18pt. Bottom padding
  20pt (measured to the drain line, not the panel edge).
- Metadata row: full width, title left, countdown right (when a bound is set),
  baseline-aligned, one line, tail-truncated with ellipsis.
- Body block: full width minus padding, 1-4 lines.
- Button row: right-aligned, 8pt gaps between buttons.
- Drain line: 2pt, along the bottom edge, full inner width (see §6).

**Sizing.** Width is fixed per invocation: default **420pt**, clamped to
[**340pt, 520pt**]. Pick the smallest of 340 / 420 / 520 at which the body
fits in 2 lines (measure `--text` rendered at the body style); body that
still exceeds 2 lines grows the height instead, capped at **4 lines (~84pt)**,
then tail-truncates with ellipsis. 1-2 sentence bodies land at 420pt. Height
is intrinsic: 18 + 14 (metadata) + 10 + body + 18 + 30 (buttons) + 20, i.e.
roughly **148-232pt**.

**Placement.** On the screen containing the pointer
(`NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }`),
horizontally centered, top edge at **42% of screen height** (slightly above
center). Never reposition after appearing.

## 2. Color

Panel stack, bottom to top: `NSVisualEffectView` (`.hudWindow` material,
`.active`, `.behindWindow`, dark appearance) -> scrim `#0B0F16` @ 90% ->
content. The scrim guarantees the ratios below over any backdrop; the vibrancy
only adds depth.

| Element | Idle | Hover | Pressed | Disabled |
| --- | --- | --- | --- | --- |
| Panel border | `accent` @ 100%, 1px | - | - | - |
| Outer glow | `accent`, r12, 38% | - | - | - |
| Panel scrim | `#0B0F16` @ 90% | - | - | - |
| Metadata + countdown text | `accent` | - | - | - |
| Body text | `#F2F7FB` | - | - | - |
| Code span | `#CFE9F2` text on `white 5%` chip, r3 | - | - | - |
| Ghost button label | `#F2F7FB` | `#FFFFFF` | `#FFFFFF` | `white 42%` |
| Ghost button border | `white 18%` | `accent 65%` | `accent 100%` | `white 10%` |
| Ghost button fill | `white 2%` | `accent 8%` | `accent 16%` | `white 0%` |
| Default button fill | `accent` | `accent-hover` | `accent-pressed` | `accent 28%` |
| Default button label | `#062126` | `#062126` | `#062126` | `#669099` |
| Default button glow | `accent`, r8, 35% | same | same | none |

**WCAG contrast**, computed against `#0B0F16` nominal and, in brackets,
against the worst case (scrim blended over pure white, effective `#23272D`):

| Pair | Ratio |
| --- | --- |
| Body `#F2F7FB` on panel | **17.8:1** [13.9:1] - AAA |
| Code span `#CFE9F2` on panel | **15.2:1** [11.9:1] - AAA |
| Accent metadata on panel | **12.5:1** [9.8:1] - AAA |
| Ghost label on idle / hover / pressed fills | **17.8 / 15.6 / 12.9:1** - AAA |
| Default label `#062126` on `accent` / hover / pressed fills | **10.9 / 11.8 / 7.8:1** - AAA |
| Secondary `#9FB4C1` on panel (reserved token) | **8.9:1** [7.0:1] - AAA |
| Ramp amber `#FFB020` on panel | **10.5:1** |
| Ramp red `#FF453A` on panel | **5.6:1** (non-text, needs 3:1) |
| Disabled labels (2.8:1 / 3.9:1) | exempt - WCAG 1.4.3 excludes inactive controls |

Countdown hue ramp (drain line and the seconds text share one color):

| Time remaining | Color |
| --- | --- |
| 100% - 50% | `accent` `#00E5FF`, held |
| 50% - 20% | hue swing cyan -> amber through a desaturated ice midpoint `#A8E6EE` at the 35% mark |
| 20% - 0% | `#FFB020` -> `#FF453A` |

The ice midpoint is required: naive RGB or HSL interpolation from cyan to
amber passes through saturated green, which reads "OK" at exactly the moment
time is running out.

## 3. Typography

| Role | Face | Size | Weight | Line height | Tracking |
| --- | --- | --- | --- | --- | --- |
| Metadata line | SF Mono (`NSFont.monospacedSystemFont`) | 11pt | 500 (medium) | 14pt | +0.3pt |
| Countdown seconds | SF Mono, same row, right | 11pt | 500 | 14pt | +0.3pt, tabular |
| Body | SF Pro Text | 15pt | 400 | 21pt (1.4) | -0.1pt |
| Body `**strong**` | SF Pro Text | 15pt | 600 | 21pt | -0.1pt |
| Body `*em*` | SF Pro Text | 15pt | 400, italic | 21pt | -0.1pt |
| Code span | SF Mono | 13.5pt (0.9x) | 400 | inherit | 0 |
| Button label (ghost) | SF Pro Text | 13pt | 500 | - | +0.1pt |
| Button label (default) | SF Pro Text | 13pt | 600 | - | +0.1pt |

Mono is used only where it means code or measurement (metadata, countdown,
code spans) - never as decoration. Never uppercase agent-supplied text:
titles often contain case-sensitive repo names. Render inline markdown with
`AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace)`;
only emphasis, strong, and code spans are supported, everything else renders
as plain text.

## 4. Corner geometry

- Panel chamfer: **14pt 45-degree cuts on the top-left and bottom-right
  corners only**; the other two corners are square. The diagonal pair is the
  frame motif; all four cuts would eat body measure at the 340pt floor.
- Buttons: same diagonal orientation, **7pt cuts, top-left and bottom-right**.
  The filled default button keeps the cut - one cut language across the whole
  panel, no rectangular exceptions.
- Border: **1px** (`lineWidth: 1`, pixel-aligned: offset the path by 0.5pt at
  1x) stroked in `accent` at 100%.
- Glow: `CALayer.shadowColor = accent`, `shadowRadius = 12`, `shadowOpacity =
  0.38`, `shadowOffset = .zero`, on the stroked border layer,
  `masksToBounds = false`. The default button carries its own smaller glow
  (r8, 35%).
- Separation from bright windows: one additional ambient shadow on the panel
  shape - black, `shadowRadius 20`, `shadowOpacity 0.35`, `shadowOffset
  (0, 4)`. Declare elevation with the glow, separate with the ambient shadow;
  never two colored halos.

The chamfer path is built once and used three times: content mask, border
stroke, shadow shape (see §10).

## 5. Button row

- Order: as passed on the CLI, left to right. The rightmost button is the
  recommended answer.
- Default (`--default N`, falling back to the last button): filled `accent`
  with dark label, Return-bound, own glow. Position never changes - the fill
  marks the recommendation, order stays the agent's.
- Sizing: height **30pt**, min-width **64pt**, horizontal padding 16pt, gap
  8pt. Hit target is the full button (30 x >=64pt), above the macOS 28pt
  floor; no invisible hit-area padding.
- **Keyboard stance:** the filled default is the standing, always-visible
  Return hint. There is no hidden-until-used hint and no NSButton focus ring
  - the dotted ring would fight the neon hairline. Full-keyboard-access users
  get Tab cycling, and a focused (or hovered) ghost button shows the hover
  treatment (`accent 65%` border). Return triggers the default; Escape sends
  `CANCELED` (exit 2). No other keys are bound.

## 6. Countdown drain line

- Geometry: **2pt tall**, along the bottom edge, spanning from the left edge
  to the start of the bottom-right chamfer (full inner width `W - 14pt`).
  Drawn just inside the border.
- Behavior: anchored at the left; the right endpoint retreats leftward.
  Width = `remaining fraction x (W - 14pt)`, recomputed continuously
  (display link, ~30Hz while visible; the line is the only per-frame work).
- Color: the §2 ramp as a function of remaining fraction; the "42s" seconds
  text in the metadata row adopts the same color, so line and number always
  agree. Seconds render as an integer, ceiling of remaining.
- The drain line is informational motion, not decoration: it survives
  Reduce Motion (§7).
- At 0 the panel fades out, stdout prints `GAVE-UP`, exit 3.
- **Beep:** audio only, unrelated to the drain line. One `NSSound.beep()` at
  the moment the panel appears; `--no-beep` suppresses it. The line, ramp,
  and timing are identical either way.

## 7. Motion

One authored moment: the entrance. Nothing loops, nothing pulses, nothing
glitches.

- **Entrance:** opacity 0 -> 1 and scale 0.98 -> 1.0 (anchor: center),
  **180ms**, `CubicBezier(0.2, 0.8, 0.2, 1)` (fast ease-out). Runs once on
  orderFront.
- **Exit (answer, cancel, or give-up):** opacity -> 0 and scale -> 1.01,
  **140ms**, same curve, then close.
- **Hover / focus transitions:** border and fill colors crossfade over
  **120ms** ease-out. The drain line's color steps crossfade over 300ms;
  its width moves continuously.
- **Reduce Motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion`,
  observed live): entrance becomes opacity-only, **100ms**, no scale, no glow
  change; exit becomes opacity-only 100ms; hover crossfades drop to instant
  state changes. The drain line stays - it is a deadline indicator, and the
  seconds text already carries the same information for anyone who prefers
  to ignore the line.

## 8. Accessibility

- Contrast: every text pair in §2 is AAA against the panel, including the
  worst-case translucent backdrop; non-text indicators (border, drain ramp)
  exceed the 3:1 UI-component floor. Disabled states are exempt (inactive
  controls) but still legible.
- Hit targets: 30 x >=64pt per §5, no missed-click tolerance games.
- VoiceOver:
  - Panel (`NSPanel`) exposes `role = .window`, label = the `--title` string,
    so the announcement is "askaway: deploy to prod?, window".
  - Body is a static text element carrying the **plain-text** rendering
    (markdown syntax stripped, emphasis preserved as traits).
  - Each button is an `AXButton` with its label as the title.
  - The panel's `defaultButtonCell` is the default button, so VoiceOver and
    the key plumbing share one source of truth.
  - Countdown: a static text element ("42 seconds remaining"), `AXValue`
    updated every second but **never announced per tick** - no
    announcements, no `.updatesFrequently` interruptions. The hue ramp is
    decorative doubling; the number is the accessible channel.
- VoiceOver focus should land on the body text (the question) first.
- Reduce Motion: §7.
- The panel never activates the app (§10), so it never disrupts the user's
  VoiceOver cursor or focus in the host app.

## 9. Cascade

Parallel invocations cascade down-right so stacked windows stay individually
readable:

- Offset per index: **+24pt x, +24pt y** (a 45-degree down-right diagonal).
- Index = number of ask-away panels already visible on that screen at show
  time.
- Wrap: modulo **6** - the seventh concurrent window returns to the base
  position rather than walking off-screen. Also clamp: if base + offset
  would leave the panel inside the screen's visible frame with less than
  24pt margin, wrap early.
- Later windows stack above earlier ones (natural orderFront order). No
  z-order gymnastics, no focus stealing between siblings.
- Cross-process coordination (each invocation is its own process): keep an
  atomic per-screen registry - lock-protected directory of `pid`-named
  entries under the app-support directory; on show, `index = count of live
  entries`, write own entry (with pid), remove on close, and treat entries
  whose pid is dead as stale during count.

## 10. Implementation notes (do not get these wrong)

- **Key focus without activation.** `NSPanel` subclass with `canBecomeKey ->
  true`, `styleMask = [.borderless, .nonactivatingPanel]`, `level =
  .floating`, `becomesKeyOnlyOnClick = false`. Show with `orderFront(nil)`
  then `makeKey()` - this takes key status for Return/Escape without calling
  `activate()` and without stealing the host app's focus. The CLI process
  runs with `NSApplication.activationPolicy = .accessory` (no Dock icon).
  `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` so the
  panel also appears over fullscreen terminals, which is where agents live.
- **Return / Escape plumbing.** Set `panel.defaultButtonCell` to the default
  button (this drives Return for the panel and VoiceOver alike). Escape is
  not free in a borderless panel: bind it via a local
  `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` on the panel that
  maps Escape -> cancel, or an `NSButton` with the Escape key equivalent.
  Do not rely on SwiftUI `keyboardShortcut(.escape)` alone inside
  `NSHostingView` - it is flaky in non-activating panels.
- **Chamfered shape.** One `CGPath`/`UIBezierPath` builder: move/line
  commands producing the 14pt top-left and bottom-right cuts. Use it as
  (1) `layer.mask` (`CAShapeLayer`) over a container layer holding the
  vibrancy view, scrim, and content; (2) a stroked `CAShapeLayer` (1px,
  `accent`) pinned to the same frame for the border; (3) the border layer's
  `shadowPath` for the glow - never let Core Animation compute the shadow
  from alpha (slow and wrong at the cuts). `layer.cornerRadius` cannot
  produce chamfers; don't reach for it.
- **Window shadow.** `panel.hasShadow = false` - the system shadow is
  rectangular and would betray the cut corners. The glow plus the ambient
  shadow in §4 are the elevation.
- **Vibrancy stance.** `NSVisualEffectView`, material `.hudWindow`,
  blending `.behindWindow`, state `.active` (an inactive-looking HUD behind
  a question is wrong), view + panel appearance locked to
  `NSAppearance(named: .darkAqua)`. The 90% `#0B0F16` scrim sits above it
  and is what the contrast math in §2 assumes - if the scrim alpha drops,
  the ratios are no longer guaranteed.
- **Dark-only enforcement.** Set `NSApp.appearance = NSAppearance(named:
  .darkAqua)` at launch and `panel.appearance` to the same; never consult
  `effectiveAppearance`. The panel appears unannounced over arbitrary apps
  at arbitrary moments; glanceability and the neon identity must not depend
  on the user's system theme, and a light variant would halve the accent's
  contrast for zero informational gain.
- **Buttons.** Each button is its own chamfer-masked view (7pt cuts) - a
  plain `NSButton`/SwiftUI `Button` styled with: ghost = `white 2%` fill +
  1px `white 18%` hairline; hover/pressed per §2 via pointer-enter/exit
  state. The default button's fill and dark label follow §2; its glow rides
  on the button's own layer `shadowPath`.
- **One window per invocation.** No singleton, no window reuse, no queue.
  Timers/display link invalidated on close; the cascade registry entry
  removed on every exit path (answer, cancel, give-up, crash-safe via pid
  staleness).
- **Assumption:** macOS 13+ floor (SwiftUI-in-NSPanel, `AttributedString`
  markdown parsing). Confirm the minimum OS before implementation; nothing
  in this spec needs newer APIs except the display link (fall back to
  `CVDisplayLink` or a 30Hz `Timer` below macOS 14).

---

Design provenance: spec authored by design-agent under the impeccable
workflow; decisions and machine-made calls are recorded in `ledger.tsv`
(git-ignored). Proportion check artifact: `.scratch/ask-away-design/mock2.png`
(git-ignored, throwaway).
