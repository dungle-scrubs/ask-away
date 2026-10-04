---
name: ask-away
description:
  "Put a decision, authorization, or attention request on the user's screen
  as a native macOS dialog and get the clicked button back, when the human
  may be in any app rather than watching the agent's terminal. Use when a
  decision cannot wait silently, when the session owner asked for on-screen
  interaction, or when a terminal-blocking question tool would go unseen.
  Not for opening URLs (open-in-browser) or driving windows that
  already exist (peekaboo)."
---

# Ask away

Render the decision where the human is, not where the agent is. One panel,
one clicked button, one bound. For a chain of related decisions, one panel
can walk them in sequence.

## When

This is rung 2 of the library's human-in-the-loop ladder - **human
reachable** - for which `AGENTS.md` reserves a slot until an elevation
mechanism exists. This skill is that mechanism.

Ask only for decisions no experiment settles: preference calls, product
calls, authorizations. If running something cheaper would show the answer,
run it instead (the ladder's test, `AGENTS.md`).

State the ask as decision + recommendation + reversibility, never a bare
question. The recommended answer is the dialog's default button.

## The ask

```sh
<skill-dir>/scripts/ask.sh \
  --title "repo-name: what this decides" \
  --text "One or two short sentences. Details and tables: your terminal." \
  --buttons "Cancel" "Option A" "Option A + B" \
  --give-up-after 300
```

- Two or three buttons, decision verbs for labels. Rightmost is the
  recommended one and takes Return unless `--default N` moves it.
- The dialog carries the question; the agent's reply carries the details.
  When details exist, the dialog text says where to find them.
- A beep sounds before the dialog unless `--no-beep`.

## Reading the answer

| stdout | exit | meaning | then |
|---|---|---|---|
| button text | 0 | the human chose | act on it |
| `CANCELED` | 2 | the human declined the framing | stop, or re-ask in prose |
| `GAVE-UP` | 3 | the bound expired unanswered | rung 3, below |
| `CLOSED` | 4 | the human dismissed the native panel | re-ask in the session UI |

Closing leaves the decision unanswered and supplies no approval. Take no
default or best-effort recommendation after `CLOSED`; re-ask in the session
UI. Keep answers already collected in a batch.

## Body text scope (markdown)

`--text` renders block markup, not just one paragraph: paragraphs, fenced
code blocks (info string's first token becomes the label; content verbatim,
internally scrollable), one nesting level of unordered and ordered lists,
blockquotes, and hard line breaks. Inline: `code`, **strong**, *em*, and
accent-underlined links. Headings, tables, and thematic breaks degrade to
plain paragraphs - do not rely on them for structure. The body scrolls
after a screen-height-proportional cap; nothing is ever truncated with an
ellipsis. Keep asks short anyway: the dialog is a decision surface, and the
chat reply carries the details.

## Batch mode (--questions-file)

One invocation can walk up to 10 questions in one panel:

```sh
<skill-dir>/scripts/ask.sh --questions-file questions.json
printf '%s' "$doc" | <skill-dir>/scripts/ask.sh --questions-file -
```

- The document is JSON: `{"questions": [...]}`, 1-10 entries, each with
  required `title` and `text`, `buttons` (2-4 strings), optional `default`
  (1-based, defaults to the last button), `give_up_after` (seconds, absent =
  unbounded), `no_beep` (bool). Unknown fields are ignored; the document is
  capped at 256KiB.
- `--questions-file` is mutually exclusive with every single-question flag;
  any co-presence exits 1 without showing a panel.
- Validation failures exit 1 before any panel appears and name the entry:
  `ask-away: questions[2].default must be 1..3, got 7`.
- stdout at sequence end is one line of JSON:
  `{"results":[{"index":0,"status":"answered","answer":"Deploy"},{"index":1,"status":"canceled"}],"stopped_at":1}`.
  `status` is `answered` (with `answer`) | `canceled` | `closed` | `gave-up`;
  `stopped_at` is the 0-based stop step, or the question count when every
  question was answered. Exit codes: 0 all answered, 2 stopped on
  Escape, 3 stopped on a step's bound, 4 stopped on Close, 1 usage or
  validation. Close at step k appends `{"index":k,"status":"closed"}` and
  sets `stopped_at` to k.
- Partial answers survive a mid-sequence stop: answers collected before the
  stopped step are in `results`.
- The upper-right step indicator reads `k/n`; the lower-left countdown
  reads `42s` above the drain origin. The countdown and bound restart per
  question; the beep plays once per sequence and any question's `no_beep`
  silences it.
- A button labeled `Cancel` answers only its own step and the sequence
  continues. Escape or Close stops the whole sequence.

**stdin pitfall:** with `--questions-file -` the document is read to EOF
before the panel appears - a caller that never closes stdin blocks the ask
forever. Build the document, close the pipe, then wait.

## Output

**Artifact:** none; this skill writes no file. **Where:** `ask.sh` prints
the clicked button's text, `CANCELED`, `GAVE-UP`, or `CLOSED` on stdout
(exit 0, 2, 3, or 4) - or the batch JSON above - and the agent reports that
answer in chat.
**Contains:** the human's choice only; details and tables stay in the
agent's chat reply, never in the dialog. **Not:** an authorization the
caller did not already hold; an unanswered ask stays unanswered (the
gave-up handoff below states the rule).

## The gave-up handoff (rung 3)

The bound turns an unanswered ask into rung 3 of the ladder. Take the
recommendation, record it as machine-made where decisions live (ledger, map,
commit), and continue. Taking the recommendation never supplies an
approval the caller lacks: a request to authorize something stays
unanswered and is reported as unanswered. A decision on a shared or outward
surface never takes the best-effort path - re-ask with a longer bound, or
wait in prose.

Size the bound from how long the work can wait: minutes for an
authorization, tens of seconds for a mid-task preference. In a batch, size
each step's `give_up_after` the same way; the sequence stops at the first
step whose bound expires.

## The renderer

`ask.sh` drives the native `ask-away` binary when one is installed: a
non-activating dark panel with a neon edge that appears over the current
app, takes Return and Escape without stealing focus from the host app, and
cascades for parallel invocations. The body renders the block markup
described above; a batch is one fixed-frame panel whose content crossfades
between steps and holds one cascade slot.

When no binary is on PATH (next to the script either), `ask.sh` falls back
to the same flags through AppleScript `display dialog`, which needs no
install and no extra permission. The single-question flags are the same,
but closing the AppleScript fallback returns `CANCELED` (exit 2): that
renderer cannot distinguish close from cancellation. The fallback cannot
walk a questions file (`--questions-file` there exits 1 with a message), and it
renders plain text only. The native binary is faster to appear and visually
distinct from a system dialog.

## Not this

<!-- skill-graph: mentions - each is named to route the reader away from
     this skill; none is loaded here -->

- `peekaboo` drives windows that already exist and cannot create one. This
  skill creates the dialog; peekaboo is not involved.
- `open-in-browser` is for URLs.
- A terminal question tool blocks inside the harness UI. Reach for it when
  the human is watching the terminal; reach for this skill when they may not
  be.

## Measured

On the reference machine (Apple Silicon MacBook Pro, macOS 26), for the
native binary: process launch to window visible measured 135-214 ms warm
and 385 ms cold (first launch after build; 2-3 ms poll granularity). A 2 s
bound printed `GAVE-UP` on stdout with exit 3 at 2.25-2.37 s wall time
(deadline + one display-link tick + the 140 ms exit fade + process
teardown). Live-window captures, pixel-sampled against the design tokens:
1 px cyan border at full alpha, `white 6%` code-chip fill over the scrim
(exact measured RGB vs the derived blend), accent info-string label, 2 pt
accent blockquote stripe bounded to the quoted line's 21 pt, list markers
in the 14 pt marker column with text hanging at 16 pt, and a 2 pt drain
line whose color matched the countdown text through the cyan-amber-red
ramp. A 24-paragraph body capped the body region at exactly 36% of the
screen's visible frame (518.4 pt of 1440) inside a panel well under the 52%
panel cap, and scrolled live (4.6% of pixels changed under a synthetic
scroll, all inside the body region); a 40-line code block's chip capped at
exactly 25% of the visible frame (360.0 pt) and scrolled internally with
the surrounding content static. Real synthetic input (CGEventPost, the
Accessibility permission belonging to the calling terminal, none to the
dialog) drove a full 3-question sequence (exit 0, all answered), Escape at
step 2 (results[0] answered, stopped_at=1, exit 2), a step-2 bound expiry
(exit 3), and clicks on both rows of a wrapped 4-button layout including
the second-row button; the same scenarios pass through the in-app posted-
event driver with exact batch-JSON equality. The AppleScript fallback was
measured earlier as the `ask-on-screen` renderer: no extra permission,
correct quoting, one reflex-speed human click, Escape to `CANCELED` exit 2,
and a 5 s bound giving up at 5.1 s.
