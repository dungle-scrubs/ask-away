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
- Drain line: 2pt, along the bottom edge, full inner width (see §6).

**Sizing** (amended by §11-§12). Width is fixed per invocation: default
**420pt**, clamped to [**340pt, 520pt**]. Pick the smallest of
340 / 420 / 520 at which the body fits in 2 lines (measure the rendered
block stack at the body style, using **panel width minus 40pt** for both
width selection and natural stack height, exactly as the body renders);
body that still exceeds 2 lines grows the
height instead, capped at the body maximum, then scrolls internally -
tail-truncation with ellipsis is retired. 1-2 sentence bodies land at 420pt.
Body maximum: **36% of the target screen's `visibleFrame.height`**, measured
at show time. Height is intrinsic: 18 + 14 (metadata) + 10 + body + 18 +
30 (buttons) + 20, i.e. roughly **148-232pt**; a wrapped second button row
(§12) adds 38pt. Panel hard cap: **52% of the target screen's
`visibleFrame.height`**. Fixed chrome is 110pt (one button row) to 148pt
(wrapped); when 36% + chrome would exceed the cap (visible frames under
~975pt with a wrapped row), the panel cap is the binding constraint and the
body region shrinks to the remainder and scrolls - the body region is the
only elastic element; nothing ever truncates with ellipsis. Example, 900pt
visible frame: body cap 324pt, panel cap 468pt; a 500pt body renders as a
324pt scrolling region (panel 434pt).

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
- **Beep:** audio only, unrelated to the drain line. One `NSSound.beep()` at
  the moment the panel appears; `--no-beep` suppresses it. The line, ramp,
  and timing are identical either way. In a sequence (§12) the beep plays
  once at sequence start, never per step; it is suppressed when any question
  in the file sets `no_beep`.

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
  row) crossfades over **180ms**, main curve, with the incoming content
  rising **2pt** into place. Chamfer, border, glow, and drain line persist
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
  off never changes behavior - taps and URL opening stay SwiftUI's.
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
  `panel.defaultButtonCell` and rebuild the Tab chain at each swap; the
  Escape monitor and the drain layer stay put.
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
  present iff `answered`, and carries the button text verbatim (a button labeled
  `Cancel` answers `"Cancel"`).
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
  formula and caps. Content is top-anchored, buttons bottom-anchored; a
  short question leaves quiet space rather than resizing the window.
- **Step indicator.** Metadata row right side: **`2/3`**, current step
  1-based, plain integers, always `accent`. The indicator contains only
  `k/n`; the countdown remains separate at the lower left above the drain
  origin (§6). A single-question file renders no indicator.
- **Transition.** Each step change crossfades the content region (metadata
  row, body, button row) per §7: **180ms**, main curve, incoming content
  rising **2pt**. No window close/respawn, no resize, no chrome animation.
  Reduce Motion: opacity-only **100ms**, no slide.
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

Design provenance: spec authored by design-agent under the impeccable
workflow; decisions and machine-made calls are recorded in `ledger.tsv`
(git-ignored). Proportion check artifact: `.scratch/ask-away-design/mock2.png`
(git-ignored, throwaway). Block-markup and question-sequence amendments
(§11-§12) authored 2026-10-04 by design-agent; machine-made calls in ledger
rows D12-D18, Foundation `.full` parsing probe in
`.scratch/ask-away-amend/`. The v0.1.1 amendments (§8 pointer cursor,
§10 background dragging and per-tick isolation) were authored against
real-use defect reports; evidence and machine-made calls in
`.scratch/ask-away-v011/ledger.tsv` (git-ignored).
