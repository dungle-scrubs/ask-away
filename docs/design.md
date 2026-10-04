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
| `text-secondary` | `#9FB4C1` (list markers, §11) |
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
|  metadata row                       2/3 [ X ]    |  18pt top pad
|  body text, 1-2 sentences,                       |
|  wraps, block markup (§11)                       |  10pt above, 18pt below
|  42s         [ ghost ] [ ghost ] [ FILLED ]      |  row right-aligned
| [ Type your own answer - Return sends it      ]  |  answer field, full width (§13)
| ▓▓▓▓▓▓▓▓▓▓▓▓▓▓__________ drain line (2pt)        |
|                              (bottom-right cut)  |
+--------------------------------------------------+
```

- Base grid: 4pt. Horizontal padding 20pt. Top padding 18pt. Bottom padding
  20pt (measured to the drain line, not the panel edge).
- Metadata row: title left, step indicator `k/n` right in a sequence (§12),
  baseline-aligned, one line, tail-truncated with ellipsis. Reserve space
  at the top right for the Close control: subtract an additional **32pt**
  from the metadata row's available width.
- Countdown: lower left, above the drain line's left origin; separate from
  metadata and answer buttons. A step without a bound hides it.
- Body block: full width minus padding, rendered as block markup per §11;
  height caps at **36% of the screen's visible frame height**, beyond which
  the body scrolls internally (no ellipsis).
- Button row: right-aligned, 8pt gaps between buttons.
- Answer field (§13): one single-line text input on **every** panel, single
  question and batch step alike, under the button row. Full inner width,
  **28pt** tall, the buttons' 7pt chamfers; **8pt** below the button row, and
  the §1 bottom padding leaves **20pt** between the field and the drain
  line. §13 owns the full contract.
- Drain line: 2pt, along the bottom edge, full inner width (see §6).

**Sizing** (amended by §11-§13). Width is fixed per invocation: default
**420pt**, clamped to [**340pt, 520pt**]. Pick the smallest of
340 / 420 / 520 at which the body fits in 2 lines (measure the rendered
block stack at the body style, using **panel width minus 40pt** for both
width selection and natural stack height, exactly as the body renders);
body that still exceeds 2 lines grows the
height instead, capped at the body maximum, then scrolls internally -
tail-truncation with ellipsis is retired. 1-2 sentence bodies land at 420pt.
Body maximum: **36% of the target screen's `visibleFrame.height`**, measured
at show time. Height is intrinsic: 18 + 14 (metadata) + 10 + body + 18 +
30 (buttons) + 8 + 28 (answer field, §13) + 20, i.e. roughly **184-268pt**;
a wrapped second button row (§12) adds 38pt. Panel hard cap: **52% of the
target screen's `visibleFrame.height`**. Fixed chrome is **146pt** (one
button row) to **184pt** (wrapped); when 36% + chrome would exceed the cap
(visible frames under ~1150pt with a wrapped row), the panel cap is the
binding constraint and the body region shrinks to the remainder and scrolls
- the body region is the only elastic element; nothing ever truncates with
ellipsis. Example, 900pt visible frame: body cap 324pt, panel cap 468pt; a
500pt body renders as a 322pt scrolling region (panel 468pt).

**Placement.** On the screen containing the pointer
(`NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }`),
horizontally centered, top edge at **42% of screen height** (slightly above
center). Never reposition automatically after appearing; background dragging
(§10) moves the panel only in response to the human.

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
| Code block chip | `white 6%` fill, r6, full body width (§11) | - | - | - |
| Code block text | `#CFE9F2` on the chip | - | - | - |
| Code block label | `accent`, metadata style (§3) | - | - | - |
| Blockquote stripe | `accent` @ 100%, 2pt (§11) | - | - | - |
| List markers | `#9FB4C1` (§11) | - | - | - |
| Body links | `accent` + underline (§11) | - | - | - |
| Ghost button label | `#F2F7FB` | `#FFFFFF` | `#FFFFFF` | `white 42%` |
| Ghost button border | `white 18%` | `accent 65%` | `accent 100%` | `white 10%` |
| Ghost button fill | `white 2%` | `accent 8%` | `accent 16%` | `white 0%` |
| Default button fill | `accent` | `accent-hover` | `accent-pressed` | `accent 28%` |
| Default button label | `#062126` | `#062126` | `#062126` | `#669099` |
| Default button glow | `accent`, r8, 35% | same | same | none |
| Answer field fill (§13) | `white 2%` | `accent 8%` (focused) | - | - |
| Answer field hairline (§13) | `white 18%` | `accent 65%` (focused) | - | - |
| Answer field text | `#F2F7FB` | - | - | - |
| Answer field placeholder | `#9FB4C1` (§13) | - | - | - |
| Answer field caret | `accent` | - | - | - |
| Answer field selection | `accent` @ 35% behind `#F2F7FB` text | - | - | - |

The answer field (§13) has no hover and no pressed state - it is a text
field, not a button. The Hover column of its rows carries its single
non-idle state, focus; the idle-to-focused crossfade uses the §7 button
timing (120ms).

**WCAG contrast**, computed against `#0B0F16` nominal and, in brackets,
against the worst case (scrim blended over pure white, effective `#23272D`):

| Pair | Ratio |
| --- | --- |
| Body `#F2F7FB` on panel | **17.8:1** [13.9:1] - AAA |
| Code span `#CFE9F2` on panel | **15.2:1** [11.9:1] - AAA |
| Code block text `#CFE9F2` on `white 6%` chip | **13.3:1** [9.9:1] - AAA |
| Code block label `accent` on `white 6%` chip | **11.0:1** [8.1:1] - AAA |
| Blockquote stripe `accent` (non-text, 2pt) | **12.5:1** [9.8:1] - clears the 3:1 floor |
| Body links `accent` on panel | **12.5:1** [9.8:1] - AAA; underline carries 1.4.1 |
| Accent metadata on panel | **12.5:1** [9.8:1] - AAA |
| Ghost label on idle / hover / pressed fills | **17.8 / 15.6 / 12.9:1** - AAA |
| Default label `#062126` on `accent` / hover / pressed fills | **10.9 / 11.8 / 7.8:1** - AAA |
| Secondary `#9FB4C1` on panel (list markers, §11) | **8.9:1** [7.0:1] - AAA |
| Ramp amber `#FFB020` on panel | **10.5:1** |
| Ramp red `#FF453A` on panel | **5.6:1** (non-text, needs 3:1) |
| Answer field placeholder `#9FB4C1` on its `white 2%` fill | **8.6:1** [6.6:1] - AA (hint text; both clear 4.5) |
| Answer field text on selection `accent` @ 35% | **7.3:1** [5.8:1] - AAA |
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
| Countdown seconds | SF Mono, lower left above drain origin | 11pt | 500 | 14pt | +0.3pt, tabular |
| Body | SF Pro Text | 15pt | 400 | 21pt (1.4) | -0.1pt |
| Body `**strong**` | SF Pro Text | 15pt | 600 | 21pt | -0.1pt |
| Body `*em*` | SF Pro Text | 15pt | 400, italic | 21pt | -0.1pt |
| Code span | SF Mono | 13.5pt (0.9x) | 400 | inherit | 0 |
| Body code block (§11) | SF Mono | 12.5pt | 400 | 16pt | 0 |
| Code block label (§11) | SF Mono, metadata style | 11pt | 500 | 14pt | +0.3pt |
| Step indicator (§12) | SF Mono, metadata style | 11pt | 500 | 14pt | +0.3pt, tabular |
| Button label (ghost) | SF Pro Text | 13pt | 500 | - | +0.1pt |
| Button label (default) | SF Pro Text | 13pt | 600 | - | +0.1pt |
| Answer field text + placeholder (§13) | SF Pro Text | 13pt | 400 | 17pt | -0.1pt |

Mono is used only where it means code or measurement (metadata, countdown,
code, step indicator) - never as decoration. Never uppercase agent-supplied
text: titles often contain case-sensitive repo names. Body markdown parses
per §11: full block syntax via `AttributedString` with
`interpretedSyntax: .full`, rendered as a stack of blocks; unsupported
constructs degrade to plain text.

## 4. Corner geometry

- Panel chamfer: **14pt 45-degree cuts on the top-left and bottom-right
  corners only**; the other two corners are square. The diagonal pair is the
  frame motif; all four cuts would eat body measure at the 340pt floor.
- Buttons: same diagonal orientation, **7pt cuts, top-left and bottom-right**.
  The filled default button keeps the cut - one cut language across the whole
  panel, no rectangular exceptions. The answer field (§13) carries the same
  7pt cuts.
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
  treatment (`accent 65%` border). Return triggers the default when the
  answer field (§13) is empty or unfocused; with the field focused and
  non-empty, Return sends the typed string instead. Escape sends `CANCELED`
  (exit 2). No other keys are bound; printable characters route to the
  answer field (§13).
- Batch mode (§12): up to 4 buttons per question; when the row exceeds the
  inner width it wraps to a second right-aligned row (§12 owns the rule).

### Close control (amended v0.2.0)

- A visible X at the top right uses the ghost-button colors and the same
  diagonal chamfers as the answer buttons. Its full hit target is
  **28 x 28pt**, inset **12pt** from the visual panel's top and right edges.
- VoiceOver exposes an `AXButton` labeled **"Close"**. The control consumes
  its own mouse down so pressing it never starts a background drag.
- Close dismisses a single ask with stdout `CLOSED`, exit **4**. Closing
  leaves the decision unanswered and supplies no approval. The caller takes
  no default or best-effort recommendation and re-asks in the session UI.
- Escape remains `CANCELED`, exit **2**. The AppleScript fallback cannot
  distinguish close from cancellation and keeps `CANCELED`, exit **2**.

## 6. Countdown drain line

- Geometry: **2pt tall**, along the bottom edge, spanning from the left edge
  to the start of the bottom-right chamfer (full inner width `W - 14pt`).
  Drawn just inside the border.
- Behavior: anchored at the left; the right endpoint retreats leftward.
  Width = `remaining fraction x (W - 14pt)`, recomputed continuously
  (display link, ~30Hz while visible). The same tick computes the shared
  line-and-text ramp color.
- Color: the §2 ramp as a function of remaining fraction; the "42s" seconds
  text at the lower left adopts the same color, so line and number always
  agree. In panel-local coordinates the countdown host is **x = 20pt,
  y = 4pt, height = 14pt**, with leading alignment, above the drain origin.
  Keep the §3 mono style. Seconds render as an integer, ceiling of remaining.
- The drain line is informational motion, not decoration: it survives
  Reduce Motion (§7).
- At 0 the panel fades out, stdout prints `GAVE-UP`, exit 3.
- Sequence steps (§12) restart the bound per question: the line snaps back
  to full width instantly at each step start (no crossfade on the reset);
  steps without a bound hide the line and countdown exactly like a no-bound
  single invocation.
- **Beep (amended §14):** audio only, unrelated to the drain line. With
  attention on (§14), the beep plays at the first attention evaluation -
  within **1s** of appear - as a single beep (PRESENT or UNKNOWN) or the
  escalation triple (ABSENT); `--no-beep` suppresses every pattern. With
  `--no-attention`, one `NSSound.beep()` at the moment the panel appears,
  exactly as v0.2.0. The line, ramp, and timing are identical either way. In
  a sequence (§12) the beep plays once at sequence start, never per step; it
  is suppressed when any question in the file sets `no_beep`.

## 7. Motion

One authored moment: the entrance. Nothing loops, nothing pulses, nothing
glitches.

- **Entrance:** opacity 0 -> 1 and scale 0.98 -> 1.0 (anchor: center),
  **180ms**, `CubicBezier(0.2, 0.8, 0.2, 1)` (fast ease-out). Runs once on
  orderFront.
- **Exit (answer, cancel, close, or give-up):** opacity -> 0 and scale -> 1.01,
  **140ms**, same curve, then close.
- **Hover / focus transitions:** border and fill colors crossfade over
  **120ms** ease-out.
- **Countdown ramp (amended v0.2.0):** continuously interpolate the §2 ramp
  at ~30Hz and apply the same target hue to line and seconds text on each
  tick. Set the line color without a separate Core Animation crossfade;
  both channels stay synchronized while the hue changes smoothly. The
  line's width moves continuously.
- **Step transition (§12):** the content region (metadata row, body, button
  row, answer field) crossfades over **180ms**, main curve, with the incoming
  content rising **2pt** into place. Chamfer, border, glow, and drain line persist
  untouched - only content fades; the window never closes or respawns.
- **Reduce Motion** (`NSWorkspace.accessibilityDisplayShouldReduceMotion`,
  observed live): entrance becomes opacity-only, **100ms**, no scale, no glow
  change; exit becomes opacity-only 100ms; hover crossfades drop to instant
  state changes; the step transition becomes opacity-only **100ms**, no
  slide. The drain line stays - it is a deadline indicator, and the
  seconds text already carries the same information for anyone who prefers
  to ignore the line.

## 8. Accessibility

- Contrast: every text pair in §2 is AAA against the panel, including the
  worst-case translucent backdrop; non-text indicators (border, drain ramp)
  exceed the 3:1 UI-component floor. Disabled states are exempt (inactive
  controls) but still legible.
- Hit targets: 30 x >=64pt for answers and at least 28 x 28pt for Close
  per §5, no missed-click tolerance games.
- VoiceOver:
  - Panel (`NSPanel`) exposes `role = .window`, label = the `--title` string,
    so the announcement is "askaway: deploy to prod?, window".
  - Body is a static text element carrying the **plain-text** rendering
    (markdown syntax stripped, emphasis preserved as traits).
  - Each answer button is an `AXButton` with its label as the title. Close
    is an `AXButton` labeled "Close".
  - The answer field (§13) is an `AXTextField` labeled **"custom answer"**
    with the placeholder string as its help; it follows the answer buttons in
    the AX element order. On commit, one announcement carries the typed
    string as the answer - posted before the exit fade starts.
  - The panel's `defaultButtonCell` is the default button, so VoiceOver and
    the key plumbing share one source of truth.
  - Countdown: a static text element ("42 seconds remaining"), `AXValue`
    updated every second but **never announced per tick** - no
    announcements, no `.updatesFrequently` interruptions. The hue ramp is
    decorative doubling; the number is the accessible channel.
  - Step indicator (§12): static text, AX label "question k of n".
  - Step changes (§12): one announcement, "Question k of n: <title>.
    <plain body>" (markdown stripped), posted when the new content lands.
    Countdown silence applies to every step.
- VoiceOver focus should land on the body text (the question) first.
- Pointer cursor: interactive elements show the pointing hand - chamfered
  buttons and body markdown links - and the arrow restores everywhere else.
  This panel never activates (§10), so the declarative AppKit cursor
  mechanisms (cursor rects, `cursorUpdate` tracking) do not engage reliably;
  the cursor is set explicitly from delivered mouse-moved events. SwiftUI
  `Text` link runs expose no per-link cursor geometry, so link rectangles
  derive from a parallel TextKit layout of the same attributed string (same
  fonts, kerning, and block offsets); an affordance rectangle a few points
  off never changes behavior - taps and URL opening stay SwiftUI's. The
  answer field (§13) shows the I-beam text cursor, set in the same explicit
  mouse-moved path.
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
- A sequence (§12) is one panel and therefore one cascade slot, however many
  questions it walks through.
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
- **Answer field first responder (§13).** The field never becomes the
  panel's initial first responder: set `panel.initialFirstResponder` to the
  default button before `makeKey()`. Leaving it nil is a trap - AppKit
  resolves the initial key view down the key-view loop, the field is first
  in the Tab chain, and Return-on-appear would land in the field instead of
  the default button. The field takes focus only by click, Tab, or
  printable-key capture, never at show time.
- **Printable-key capture (§13).** One mechanism, named: the same local
  `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` that owns Escape
  also routes printable characters. KeyDown with no command/option/control
  flags and a single printable `characters` string, while the field is not
  first responder: `makeFirstResponder(field)`, then re-dispatch the same
  event so the field editor inserts it. A field delegate cannot do this -
  it never sees keys while its field is unfocused - so the delegate is not
  the capture mechanism. Tab, Return, Escape, and modifiers-carrying
  keydowns are not captured; they keep their existing routes.
- **Answer field chrome (§13).** A single-line AppKit `NSTextField` wrapped
  in `NSViewRepresentable`, masked by its own 7pt chamfer path. `bordered =
  false`, `drawsBackground = false` - the layer fill paints the §2 states;
  the focus ring is never drawn (the hairline is the focus state). Caret:
  the field editor's `insertionPointColor` set to `accent` when editing
  begins; selection: the editor's `selectedTextAttributes` background
  `accent` @ 35%. The caret lives inside the masked content tree - the §4
  chamfer mask already clips it; never build a caret overlay outside the
  mask.
- **AppleScript fallback parity (§13).** The skill's `display dialog`
  fallback passes `default answer ""` and maps: `text returned` non-empty +
  a button click → stdout the typed string, exit 0; `text returned` empty +
  a button click → stdout `button returned`, exit 0. Escape cancels
  (`CANCELED`, exit 2) even with text typed; a bound expiry prints
  `GAVE-UP` (exit 3) and discards the text. Same stdout contract, no new
  exit codes.
- **Block body rendering (§11).** Parse once with `interpretedSyntax: .full`
  and split blocks by grouping consecutive runs with equal
  `PresentationIntent`. Newline scanning cannot find block boundaries:
  verified on the build toolchain, soft breaks inside a paragraph arrive as
  space runs, hard breaks as `\n` runs, and adjacent blocks abut with no
  separator in the character stream. Code block runs carry content verbatim
  (indent, blank lines, trailing newline) - render as-is; `fenceInfo`
  carries the whole info string, so take the first whitespace-separated
  token for the label. Paragraphs render as plain `Text`, but list rows and
  the blockquote stripe are hand-built (`HStack`: marker column + item
  `Text`); don't lean on SwiftUI's automatic list markers - their color and
  indent are not stylable.
- **Body scroll (§11).** The cap comes from the target screen's
  `visibleFrame` and must be known before the window is built (it sizes the
  hosting frame). Wrap the block stack in a scroll view; overlay-style
  scrollers only, never a reserved gutter.
- **Step transitions (§12).** Never fade the container holding vibrancy +
  scrim - a 180ms scrim fade flashes the desktop through the panel. Fade a
  body container above the scrim (hosting view + buttons only). Crossfade
  via snapshot: render the outgoing content into one layer, swap the live
  content to the next question, fade the snapshot 180ms, remove it - no
  second live view tree, no duplicate AX elements. Reassign
  `panel.defaultButtonCell` and rebuild the Tab chain at each swap (the
  chain includes the answer field, §13); the swap clears the field and
  releases its focus; the Escape/printable-key monitor and the drain layer
  stay put.
- **Sequence startup (§12).** Read stdin to EOF for `-`, cap the document at
  256KiB, decode with `Codable` (unknown fields ignored), validate every
  question, and only then build the first panel - a batch must not show
  step 1 and fail at step 3.
- **One window per invocation.** No singleton, no window reuse, no queue.
  Timers/display link invalidated on close; the cascade registry entry
  removed on every exit path (answer, cancel, close, give-up, crash-safe via pid
  staleness).
- **Movable by its background (amended v0.2.0).** The panel drags by any
  non-interactive surface: body text, metadata row, quiet bands, and
  padding. Answer buttons, Close, and links consume their own clicks. The
  transparent margin around the visual panel (the elevation room described
  in §4) is not draggable; clicks there fall through. The root view starts
  a local AppKit `NSWindow.trackEvents` session for unconsumed mouse downs.
  Track left-dragged and left-mouse-up events, consuming scroll events
  during the drag. Each drag event calls `setFrameOrigin` from the original
  window origin plus displacement from the original pointer anchor; stop
  on mouse up. Use no global monitor or event tap. A plain click still
  makes key.
- **Per-tick isolation (amended v0.1.1).** The countdown seconds text and
  its ramp color live in their own observable: a drain tick re-renders only
  the seconds text - never the title, the step indicator, or the body - so
  §12's step transition fires exactly once per step change regardless of a
  running bound.
- **Attention probes (§14).** Identification reads the own-process
  environment (the panel inherits the asking agent's env), so an
  SSH-launched panel usually carries no `TERM_PROGRAM` and its ancestor walk
  dead-ends at `sshd`: attention runs in the UNKNOWN rows and the panel
  behaves exactly as v0.2.0. A CI session has no GUI at all - same UNKNOWN
  result, and **no crash**: every probe is failure-wrapped. A nil
  `frontmostApplication` reads as not frontmost; a failed idle read skips
  the tick; a failed display read reads awake; a failed or timed-out probe
  yields no signal. Probes never block the main thread on I/O: the tmux
  probe spawns a subprocess off-main with a **2s** kill budget; the rest are
  in-process calls.
- **Attention permissions.** `CGEventSource.secondsSinceLastEventType` reads
  system idle time; it is not an event tap and needs no Accessibility or
  Input Monitoring permission. `NSWorkspace.frontmostApplication` likewise.
  (The posted-event test driver's Accessibility grant belongs to the calling
  terminal, unchanged.)
- **Attention activation.** Escalation is the only activation: the process
  keeps `.accessory` + `.nonactivatingPanel` (§10) for its whole life, and
  `NSApp.activate(ignoringOtherApps: true)` runs only in the §14 escalation
  sequence, before `makeKeyAndOrderFront`. It makes ask-away the active
  application (the host app deactivates); when the panel closes, the process
  exits and the system restores focus on its own - no restore dance, no
  re-activation of ask-away. On the macOS 13 floor
  `activate(ignoringOtherApps:)` is the floor-legal spelling; the macOS 14+
  deprecation warning is expected and must not be "upgraded" past the floor.
- **Attention cadence.** One **1 Hz** `Timer` on the main RunLoop drives
  detection. It shares nothing with the drain display link (§6) and does no
  display-link work; a tick's cost is a few in-process calls plus at most
  one spawned probe. State changes apply on the main thread only.
- **Attention first evaluation.** Detection never delays the panel: layout,
  placement, and key status are unchanged at show time. The first state
  evaluation is scheduled async at show time and must complete within **1s**;
  the appear beep waits for it (§6, §14).
- **Assumption:** macOS 13+ floor (SwiftUI-in-NSPanel, `AttributedString`
  markdown parsing). Confirm the minimum OS before implementation; nothing
  in this spec needs newer APIs except the display link (fall back to
  `CVDisplayLink` or a 30Hz `Timer` below macOS 14).

---

## 11. Block markup (amends §1 sizing, §2 tables, §3 parsing)

Body rendering upgrades from inline-only to block scope. Everything here is
body-region only; chrome (metadata row, buttons, drain line, §1 geometry)
is unchanged.

**Parsing.** Parse `--text` (and each `text` in a sequence file) with
`AttributedString(markdown:, options: .init(interpretedSyntax: .full))` -
`.inlineOnlyPreservingWhitespace` is retired for body parsing. On parse
failure, degrade to plain `AttributedString(raw)` (unchanged). Supported
blocks: paragraphs, fenced code blocks, unordered and ordered lists (one
nesting level), blockquotes, hard line breaks. Inline is unchanged: strong,
em, code spans, links. Everything else degrades to plain text: headings
render as ordinary paragraphs (no size or weight change), tables and
thematic breaks render their text as plain paragraphs. Whitespace follows
CommonMark: soft line breaks collapse to spaces inside a paragraph; hard
breaks (`\` at end of line, or two trailing spaces) render as line breaks;
code block content is verbatim - monospaced, newline-preserving. Blocks
stack top-down with **10pt** between blocks (the `metadataToBody` gap).

**Code blocks.** A full-width inset chip on the panel:

- Fill `white 6%`, corner radius **6pt**, spanning the full body width.
- Text: SF Mono **12.5pt / 16pt line height**, `text-code`, content verbatim
  (indentation and blank lines preserved).
- Inner padding **12pt** on all sides.
- Info string: if present, its first whitespace-separated token renders as a
  label on its own row above the code - metadata style (SF Mono 11/500,
  +0.3pt tracking) in `accent`, **4pt** between label row and first code
  line. No info string, no label; the rest of the info string is not
  rendered.
- Height: capped at **25% of the screen's `visibleFrame.height`**; longer
  blocks scroll internally. Scrollbar: overlay style, system-managed (it
  appears on scroll and when the pointer rests on the chip); a legacy
  always-visible scroller bar is wrong.
- **No syntax highlighting in v1** - the build stays zero-dependency.
  Token-color highlighting is a possible later addition; do not stub for it.

**Lists.** One nesting level; deeper items flatten into their parent item's
text (space-joined).

- Rows: marker column **14pt** wide, item text hanging at **16pt** from the
  region's left edge, so wrapped lines align under the first text glyph,
  not the marker.
- Unordered marker: `•` in `#9FB4C1` at body size. Ordered marker: the
  item's number plus `.` (`3.`, `4.` - the author's start number is
  preserved), same color and geometry.
- Spacing: **4pt** between items; **10pt** between the list and adjacent
  blocks (paragraph spacing applies).
- Item text renders inline spans per §3.

**Blockquotes.** An accent hairline: **2pt** wide, `accent` @ 100%, the full
height of the quoted block. Quoted text indents **12pt** right of the
stripe and renders in body style (`text-body`), no fill; inline spans
allowed. Multiple lines inside one quote render as one flowing block (soft
breaks collapse).

**Links.** `.link` runs tint `accent` with a single underline - the
non-color cue required by WCAG 1.4.1 - and stay tappable in SwiftUI `Text`:
the standard open-URL path hands the URL to the default browser; the panel
never activates its own app.

**Body region.** §1's 4-line cap is gone. The body region caps at **36% of
the target screen's `visibleFrame.height`** (measured at show time, before
the window is built); content beyond it scrolls internally. The panel hard
cap (**52% of `visibleFrame.height`**, §1) then bounds the whole panel; at
the cap the body region yields and scrolls. Ellipsis truncation no longer
exists anywhere in the body.

## 12. Question sequences (batch mode)

One invocation walks the human through several questions in one panel. The
single-question contract is untouched: flags, output, exit codes, and panel
behavior are byte-identical when `--questions-file` is absent.

**Invocation contract (normative).**

- New flag `--questions-file PATH`; `PATH` may be `-` to read the document
  from stdin (read to EOF - a caller that never closes stdin blocks the
  panel from ever appearing).
- `--questions-file` is **mutually exclusive** with every single-question
  flag: `--title`, `--text`, `--buttons`, `--default`, `--give-up-after`,
  `--no-beep`. Any co-presence is a usage error (exit 1, conflict named on
  stderr). Decided: an error, not silent precedence - precedence would hide
  a broken caller.
- A missing or unreadable path is a usage error (exit 1, path named).
- `--help` documents the flag.

**Document format (normative).**

```json
{
  "questions": [
    {
      "title": "str, required, non-empty",
      "text": "str, required, non-empty; block markup per §11",
      "buttons": ["2-4 non-empty strings"],
      "default": 2,
      "give_up_after": 42,
      "no_beep": false
    }
  ]
}
```

- `questions`: **1-10** entries. The batch renders as one panel; the cap
  bounds how long one invocation can hold the screen.
- `buttons`: **2-4** strings. The CLI flag stays 2-3; only the file allows
  4.
- `default`: 1-based index into `buttons`, **defaults to the last button**,
  must be within range - same semantics as `--default`.
- `give_up_after`: seconds, `>= 0`, optional, per question. Absent = no
  bound for that step.
- `no_beep`: bool, optional, default `false`.
- UTF-8; unknown fields ignored (forward compatibility); document capped at
  **256KiB**.

**Validation (normative).** Parse and validate the whole document before
anything renders - a batch never shows step 1 and then fails. Violations
exit **1** with a JSON-path style message on stderr naming the offending
entry (0-based index in brackets):
`ask-away: questions[2].default must be 1..3, got 7`. Malformed JSON exits 1
the same way (`ask-away: questions file is not valid JSON: <reason>`).
Nothing prints on stdout in any error case.

**Output (normative).** At sequence end - and only then - stdout receives
one line of compact JSON, UTF-8, trailing newline:

```json
{"results": [{"index": 0, "status": "answered", "answer": "Deploy"}, {"index": 1, "status": "canceled"}], "stopped_at": 1}
```

- `results[i].index`: 0-based question index.
- `status`: `answered` | `canceled` | `closed` | `gave-up`. `answer` is
  present iff `answered`, and carries the answer string verbatim - the
  clicked button's text or the string typed into the answer field (§13);
  the two are shape-identical in the JSON (a button labeled `Cancel`
  answers `"Cancel"`, and so does typing `Cancel`).
- Invariants: entries appear in order for every question that was presented;
  entries before `stopped_at` are all `answered`; `results.count ==
  stopped_at + 1` when stopped early (the stopped entry included);
  `stopped_at == questions.count` when every question was answered.
- Exit codes: **0** all answered; **2** stopped on Escape; **3** stopped on
  gave-up; **4** stopped on Close; **1** usage/parse/validation error.
- Partial answers survive a mid-sequence stop: Escape, Close, or give-up at
  step k returns every answer collected before k. (A SIGKILL returns nothing - the
  process is gone; that is outside the contract.)

**Panel behavior.**

- **One panel, one frame.** The sequence is a single `NSPanel`: chamfer,
  border, glow, drain layer, and cascade slot (§9) persist across steps.
  The frame is computed once from all questions and never changes
  mid-sequence: width by the §1 rule requiring every question's body to fit
  2 lines (else 520pt); height = the maximum per-question height under §1's
  formula and caps. Content is top-anchored; the button row and the answer
  field are bottom-anchored, the field always the last row above the bottom
  padding (§13); a short question leaves quiet space rather than resizing
  the window.
- **Step indicator.** Metadata row right side: **`2/3`**, current step
  1-based, plain integers, always `accent`. The indicator contains only
  `k/n`; the countdown remains separate at the lower left above the drain
  origin (§6). A single-question file renders no indicator.
- **Transition.** Each step change crossfades the content region (metadata
  row, body, button row, answer field) per §7: **180ms**, main curve,
  incoming content rising **2pt**. No window close/respawn, no resize, no
  chrome animation. Reduce Motion: opacity-only **100ms**, no slide. The
  answer field clears at each step start and enters the step unfocused;
  typed text never carries across steps.
- **Drain line and countdown.** The bound is per question: each step's
  deadline restarts from that step's `give_up_after`. At a step start the
  line resets to full width and `accent` **instantly** (a width crossfade
  would misread as progress) and the seconds text restarts. A step without
  a bound hides the countdown text and the drain line exactly like a
  no-bound single invocation.
- **Beep.** One `NSSound.beep()` at sequence start (the moment the panel
  appears), never per step. Suppressed when **any** question sets
  `no_beep: true` - one objection silences the single beep.
- **Buttons.** Up to 4 per question, order as passed, rightmost =
  recommended, per-question `default` filled and Return-bound (§5 semantics
  per step). Row layout: if the total row width (sum of button widths + 8pt
  gaps) exceeds the inner width (panel width - 40pt), the row's tail wraps
  to a second row; both rows right-aligned (ragged edge on the left),
  **8pt** vertical gap between rows, reading order preserved across the
  wrap, and every button keeps its full 30 x >=64pt hit target - wrapping
  never shrinks buttons or padding.
- **Escape at step k** (0-based): the sequence stops at that step. `results`
  carries answers 0..k-1 plus entry `k` with `status: "canceled"`,
  `stopped_at = k`, exit **2**.
- **Close at step k** (0-based): the sequence stops at that step. `results`
  carries answers 0..k-1 plus entry `k` with `status: "closed"`,
  `stopped_at = k`, exit **4**. The stopped entry has no `answer`; earlier
  answers remain intact. The caller re-asks in the session UI per §5.
- **A button labeled `Cancel` answers only its own question** and the
  sequence continues. Escape and Close stop the whole sequence.
  Single-question mode keeps its legacy mapping: a clicked `Cancel` button
  is `CANCELED`, exit 2. The asymmetry is deliberate.
- **Give-up at step k**: entry `k` is `gave-up`, `stopped_at = k`, exit
  **3**; earlier answers are in `results`.
- **Attention (§14) is invocation-level.** The document schema gains no
  attention fields in v1 - attention is a setting about the human, not about
  a question. State is computed once at panel launch and re-evaluated on the
  running timer across steps; escalation targets the panel, never a step;
  answered, `canceled`, `closed`, and `gave-up` all end the detector. The
  appear beep evaluates once at sequence start under the §14 policy.

**Accessibility.** At each step change the panel posts one accessibility
announcement: **"Question k of n: <title>. <plain body>"** (markdown
stripped, per §8's plain-text rule), at the moment the new content lands.
The indicator is a static text element with AX label "question k of n"; the
countdown silence rules of §8 apply to every step. Buttons re-expose as
`AXButton`s for the current step; `defaultButtonCell` follows the step's
default, so Return and VoiceOver share one source of truth (§10). The panel
never activates, so step changes never disturb the host app's VoiceOver
cursor - the announcement carries the context instead.

---

## 13. Custom answer field (amends §1 sizing, §2 states, §3, §5, §7, §8, §10, §12)

Every panel carries one free-text answer field: a single-line input under
the button row, on single questions and on every batch step. Buttons stay
the primary channel; the field is the always-present second channel for
answers the button set cannot express. No new flags, no new exit codes.

**Geometry.** Height **28pt**, full inner width (panel width minus 40pt),
the buttons' **7pt** top-left/bottom-right chamfer cuts (§4). It sits
**8pt** below the button row; the §1 bottom padding leaves **20pt** between
the field and the drain line. §1's diagram and height formula include it;
the §12 fixed frame is computed from the same formula.

**Typography.** Text and placeholder in SF Pro Text 13pt / 400 / 17pt line
height / -0.1pt tracking (§3) - the body family, never mono: typed prose is
content, not measurement. Inner horizontal padding **10pt**, vertically
centered. Placeholder: **"Type your own answer - Return sends it"** in
`text-secondary`.

**States.** Per §2: idle fill `white 2%`, hairline `white 18%`; focused
fill `accent 8%`, hairline `accent 65%`; no hover and no pressed state - it
is a text field. Idle-to-focused crossfade: the §7 button timing,
**120ms** ease-out. Caret `accent`; selection `accent` @ 35% behind
`text-body` text. No dotted focus ring - the hairline is the focus state,
the same stance as the buttons.

**Commit semantics (normative).**

- Return with the field focused and non-empty: the typed string **is** the
  answer - verbatim, no trim - printed on stdout with a trailing newline,
  exit **0**; in a batch it is `{"status": "answered", "answer": "<the
  typed string>"}`. The string is a first-class answer: in single mode it
  never maps to `CANCELED`, even when it equals a button label (the legacy
  single-mode `Cancel`-button mapping applies to the button path only).
- Return with the field empty or unfocused: the default button fires
  (unchanged §5 behavior).
- Pointer clicks always answer with the clicked control; only the Return
  key consults the field. A button click never sends the typed string.
- Escape anywhere - including focused in the field - is `CANCELED`, exit
  **2**. Close is `CLOSED`, exit **4**. A bound expiry is `GAVE-UP`, exit
  **3**. In all three the uncommitted field text is discarded, never
  printed.
- The field is single-line: Return never inserts a newline into it, so
  stdout stays one line.

**Keyboard (normative).**

- Initial focus is never the field: on appear, Return hits the default
  button (§10 first-responder note).
- A printable character typed while the field is unfocused moves focus to
  the field and inserts it - the macOS search-field pattern, driven by the
  panel's local keyDown monitor (§10).
- Tab order: the field first, then the buttons in row order (a wrapped §12
  layout reads row by row), then Close; Shift-Tab walks it backwards. One
  Tab from a fresh panel reaches typing - the one action with no key of its
  own. In the VoiceOver element order the field follows the buttons (§8);
  the two orders disagree on purpose.
- Escape precedence: the keyDown monitor intercepts Escape before the field
  editor sees it, whatever the focus.
- Close while the field is focused works: the X consumes its own click
  (§5), the field editor deactivates without committing, exit **4**.
  Starting a background drag (§10) blurs the field the same way, without
  committing.

**Batch.** The field clears at each step start and enters the step
unfocused; typed text never carries across steps. A typed answer answers
only its own step, exactly like a button click. In the §12 step transition
the field is part of the fading content region.

**VoiceOver.** An `AXTextField` labeled **"custom answer"**; the
placeholder string is its help. It follows the answer buttons in the AX
element order; the Tab chain reaches it first (above). On commit the panel
posts one accessibility announcement carrying the typed string, before the
exit fade starts, so VoiceOver reads the answer being sent. Pointer cursor
over the field: the I-beam, set in §8's explicit mouse-moved path.

**AppleScript fallback parity.** The skill's `display dialog` fallback
renders the field natively via `default answer ""`: `text returned`
non-empty + a button click → stdout the typed string, exit **0**; empty →
stdout `button returned`, exit **0**. Escape cancels (`CANCELED`, exit
**2**) even with text typed; a bound expiry prints `GAVE-UP` (exit **3**)
and discards the text. Same stdout contract, no new exit codes.

---

## 14. Attention-aware escalation (amends §6 beep, §10 notes, §12 batch)

The panel escalates only when the evidence says the human is not looking.
One unforgivable failure: stealing focus on a wrong guess. UNKNOWN therefore
never escalates, escalation requires the ABSENT state - a truth-table row at
a tick, never a judgment call - and every threshold is a named constant.
Attention changes WHEN the human is pulled to the panel, never WHAT is
answered: no new exit codes, no new stdout, outcomes byte-identical.

**Identification.** Name the GUI terminal this session runs in, so
"frontmost" has a target. Read the own-process environment (the panel
inherits the asking agent's env): `TERM_PROGRAM` names the terminal,
`TMUX` / `ZELLIJ` / `STY` / `HERDR_ENV` mark a multiplexer. When the env
yields no terminal, walk the ancestor process chain (sysctl
`KERN_PROC_PID` ppid walk from `getpid()`): resolve each pid's bundle id via
`NSRunningApplication(processIdentifier:)`; the first pid whose bundle id is
in the known-terminal table wins - the innermost terminal hosts the pane.
Non-GUI ancestors resolve nil and the walk continues. **Env wins:** when
both sources answer, the env claim is used and the walk is not run; the
walk only fills gaps. Unknown terminals are legal: no claim and no known
ancestor leaves the panel unidentified - it renders and answers normally,
and attention falls back to the UNKNOWN rows.

| `TERM_PROGRAM` | Bundle id (named table `TERMINALS`) |
| --- | --- |
| `Apple_Terminal` | `com.apple.Terminal` |
| `iTerm.app` | `com.googlecode.iterm2` |
| `ghostty` | `com.mitchellh.ghostty` |
| `WezTerm` | `com.github.wez.wezterm` |
| `vscode` | `com.microsoft.VSCode` |

**Multiplexer attach.**

- **tmux** (`TMUX` set): run `tmux display -p '#{client_attached}'` with the
  inherited env, no `-t`. Parse qualified by exit status: exit 0 + stdout
  `1` = attached; exit 0 + **empty stdout = detached**; any other output,
  non-zero exit, or spawn failure = no signal. The empty-means-detached rule
  is measured (tmux 3.7 prints an empty value for a detached pane, never
  `0`) - a naive `!= 1` parse would misread probe failure as absence.
- **Herdr** (`HERDR_ENV` set): no attach probe in v1 - the CLI exposes pane
  focus but no client-attach state. Herdr behaves like a non-multiplexer:
  the env only marks identification.
- **zellij / screen** (`ZELLIJ` / `STY`): detection only, no attach probe in
  v1 - identified-but-unknown attach; rules fall through to focus + idle.

**Signals.** All local, all permissionless:

| # | Signal | Mechanism | On failure |
| --- | --- | --- | --- |
| 1 | Terminal identification | env table + `KERN_PROC_PID` walk above | unidentified |
| 2 | Multiplexer attach | tmux probe above (only when `TMUX` set) | no signal |
| 3 | Focus | `NSWorkspace.shared.frontmostApplication?.bundleIdentifier ==` identified bundle id | not frontmost |
| 4 | Presence | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)` - system-wide input idle seconds | skip the tick |
| 5 | Hard absence | `CGDisplayIsAsleep(CGMainDisplayID()) != 0`, or `NSWorkspace.shared.runningApplications` contains bundle id `com.apple.screensaver` | reads awake |

Signal 4 measures physical input across the whole login session. A busy
agent injects no HID events, so agent work cannot fake presence (measured:
9.2s idle reported mid-agent-work). Signal 5 needs no other input: display
asleep or screensaver running is absence, full stop.

**States (truth table, precedence-ordered).** Evaluate top to bottom each
tick; the first matching row is the state.

| Row | Asleep / screensaver | Attach probe | Frontmost = identified | Input idle | State |
| --- | --- | --- | --- | --- | --- |
| 1 | true | any | any | any | **ABSENT** |
| 2 | false | detached | any | any | **ABSENT** |
| 3 | false | attached / unknown | yes | any | **PRESENT** |
| 4 | false | any | any | < 3s | **PRESENT** |
| 5 | false | attached / unknown | no | >= absent-after | **ABSENT** |
| 6 | every remaining combination | | | | **UNKNOWN** |

- Row 2 outranks row 3 by decision: a detached tmux client means the asking
  agent's own surface is not being watched, even if the physical terminal is
  frontmost; the human re-attaches to answer.
- Row 4 is the reflex catch: input anywhere in the last 3 seconds means
  hands on the machine, whatever is frontmost.
- Row 6 collects every ambiguous remainder: unidentified terminal (SSH
  launch, CI, unknown app), not-frontmost with idle between the constants,
  a failed focus read. **UNKNOWN is treated as PRESENT for escalation** -
  it never activates, never raises the level, never triple-beeps.

**Escalation.** The one place the non-activating design (§10) is ever
overridden. Preconditions: state ABSENT - never UNKNOWN. Sequence, in order,
on the main thread:

1. `NSApp.activate(ignoringOtherApps: true)`
2. `panel.makeKeyAndOrderFront(nil)`
3. `panel.level = .screenSaver` - stays for the invocation's lifetime,
   never downgraded
4. Triple beep: three `NSSound.beep()` calls 0.25s apart

Fires once per invocation and **stays fired**: a later PRESENT re-attaches
no cancel, replays no beep, and never hands key or level back - the panel is
already in the human's face; answer or close it. Parallel invocations (§9)
each run the detector; concurrent escalations stack at the raised level and
the most recent holds key.

**Timing.**

- Panel appear is never delayed (§10). The first evaluation lands within
  **1s** of appear and carries the appear beep (§6).
- ABSENT at the first evaluation escalates **immediately**;
  `--interrupt-after` does not delay the launch case - the absence predates
  the question. A caller who wants that case deferred raises
  `--absent-after` instead (a higher threshold keeps the launch state in
  row 4/6 until the idle truly accumulates).
- Mid-flight: re-evaluate every **1s**. ABSENT must hold on consecutive
  ticks for `--interrupt-after` seconds (default 0: the first ABSENT tick
  escalates; N = N consecutive ABSENT ticks). Any non-ABSENT tick cancels
  the pending hold. Fire on the tick that completes the hold.
- Escalation never touches the give-up bound: `--give-up-after` keeps
  draining; a panel whose human never returns still gives up (§6) and
  prints `GAVE-UP`.

**Beep policy.**

| State at first evaluation | Beep |
| --- | --- |
| PRESENT | single, as today |
| UNKNOWN | single |
| ABSENT | triple, as part of the escalation |

`--no-beep` silences all of it; the escalation's other three steps still
run. In a sequence the policy is evaluated once at sequence start, never per
step (§12).

**CLI (additive).**

| Flag | Default | Meaning |
| --- | --- | --- |
| - | on | Detection + escalation run unless disabled |
| `--interrupt-after SECONDS` | 0 | Mid-flight ABSENT hold before escalation; 0 = immediately on ABSENT |
| `--absent-after SECONDS` | 20 | Idle-seconds threshold for truth-table row 5 |
| `--no-attention` | off | No detection, no escalation: panel behaves exactly as v0.2.0 |

- `SECONDS` takes non-negative integers; violations are usage errors (exit
  1, flag named on stderr, nothing on stdout). `--help` documents all three.
- `--no-attention` **conflicts** with `--interrupt-after` and
  `--absent-after` (exit 1, conflict named) - §12's rule: silent precedence
  hides a broken caller. `--no-attention` and `--no-beep` are orthogonal:
  one kills the brain, the other the sound.
- **No per-question attention fields in v1.** The batch schema (§12) gains
  nothing: attention is a human-level setting, not a question-level one.
- **AppleScript fallback:** `ask.sh` forwards the flags and the fallback
  accepts them as inert - `display dialog` has no attention model and
  behaves exactly as today. Same documented-renderer-limitation pattern as
  `--questions-file` there.

**Named constants.**

| Constant | Value | Role |
| --- | --- | --- |
| `PRESENT_IDLE_MAX_SECONDS` | 3 | Row 4 fresh-input window |
| `ABSENT_AFTER_DEFAULT_SECONDS` | 20 | Row 5 idle threshold (flag default) |
| `INTERRUPT_AFTER_DEFAULT_SECONDS` | 0 | Mid-flight ABSENT hold (flag default) |
| `ATTENTION_TICK_SECONDS` | 1 | Detection cadence |
| `FIRST_EVALUATION_DEADLINE_SECONDS` | 1 | First evaluation after appear |
| `BEEP_GAP_SECONDS` | 0.25 | Triple-beep spacing |
| `MAX_ANCESTOR_HOPS` | 32 | Identification walk cap |
| `TMUX_PROBE_TIMEOUT_SECONDS` | 2 | Attach probe subprocess budget |

**What the implementer cannot verify headlessly.** The implementation is
delegated to a worker with no screen. The worker CAN verify offline: flag
parsing, defaults, and conflicts (exit 1 cases); `--help` text;
`--no-attention` equivalence to v0.2.0 through the existing behavioral and
posted-event suites; the tmux probe's parse against a scripted detached
session; and that all probes return rather than crash without a GUI
session. The worker CANNOT verify live focus, real idle, or sleep state -
these need a human at the display:

1. **Present:** with the terminal frontmost, ask and keep working - single
   beep, no activation, host app keeps focus.
2. **Absent:** switch to another app, hands off (`--absent-after 5` to
   shorten) - panel activates, sits above everything, triple-beeps; answer
   it while escalated.
3. **Stays fired:** after escalation, click back to the terminal - the
   panel keeps its level and key status and still answers normally.
4. **Hold then cancel:** `--interrupt-after 10 --absent-after 5` - go away
   ~6s, return before 10s - no activation happened.
5. **Detach:** inside tmux, ask, detach (prefix `d`), `--absent-after 5` -
   escalation follows within ~1.5s of the detach even with the terminal
   frontmost; reattach and answer.
6. **Hard absence:** start the screensaver (or let the display sleep) with
   a panel open - escalation; on wake the panel is frontmost at the raised
   level. This run also confirms the `com.apple.screensaver` process check
   on this macOS.
7. **Unknown shape:** run the panel from an IDE task runner or remote shell
   with no GUI terminal ancestor - panel appears, single beep, never
   escalates for the whole bound (leave the machine idle past
   `--absent-after`).
8. **`--no-attention`:** repeat scenario 2 - single beep, no activation,
   v0.2.0 behavior.

---

Design provenance: spec authored by design-agent under the impeccable
workflow; decisions and machine-made calls are recorded in `ledger.tsv`
(git-ignored). Proportion check artifact: `.scratch/ask-away-design/mock2.png`
(git-ignored, throwaway). Block-markup and question-sequence amendments
(§11-§12) authored 2026-10-04 by design-agent; machine-made calls in ledger
rows D12-D18, Foundation `.full` parsing probe in
`.scratch/ask-away-amend/`. The v0.1.1 amendments (§8 pointer cursor,
§10 background dragging and per-tick isolation) were authored against
real-use defect reports; evidence and machine-made calls in
`.scratch/ask-away-v011/ledger.tsv` (git-ignored). The custom-answer-field
amendment (§13) was authored 2026-10-04 by design-agent against a fixed
caller brief; machine-made calls in ledger rows D25-D27, contrast
arithmetic in `.scratch/ask-away-fieldamend/contrast.py` (git-ignored). The
attention-aware-escalation amendment (§14) was authored 2026-10-04 by
design-agent against a fixed caller brief; machine-made calls in ledger rows
D28-D30, signal probes in `.scratch/ask-away-attention/` (git-ignored).
