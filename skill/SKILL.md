---
name: ask-away
description:
  "Put a decision, authorization, or attention request on the user's screen
  as a native macOS dialog and get the clicked button back, when the human
  may be in any app rather than watching the agent's terminal. Use when a
  decision cannot wait silently, when the session owner asked for on-screen
  interaction, or when a terminal-blocking question tool would go unseen.
  Answers arrive as the button text, CANCELED, or GAVE-UP once a bound
  expires. Not for opening URLs (open-in-browser) or driving windows that
  already exist (peekaboo)."
---

# Ask away

Render the decision where the human is, not where the agent is. One panel,
one clicked button, one bound.

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

## Output

**Artifact:** none; this skill writes no file. **Where:** `ask.sh` prints
the clicked button's text, `CANCELED`, or `GAVE-UP` on stdout (exit 0, 2, or
3), and the agent reports that answer in chat. **Contains:** the human's
choice only; details and tables stay in the agent's chat reply, never in the
dialog. **Not:** an authorization the caller did not already hold; an
unanswered ask stays unanswered (the gave-up handoff below states the rule).

## The gave-up handoff (rung 3)

The bound turns an unanswered ask into rung 3 of the ladder. Take the
recommendation, record it as machine-made where decisions live (ledger, map,
commit), and continue. Taking the recommendation never supplies an
approval the caller lacks: a request to authorize something stays
unanswered and is reported as unanswered. A decision on a shared or outward
surface never takes the best-effort path - re-ask with a longer bound, or
wait in prose.

Size the bound from how long the work can wait: minutes for an
authorization, tens of seconds for a mid-task preference.

## The renderer

`ask.sh` drives the native `ask-away` binary when one is installed: a
non-activating dark panel with a neon edge that appears over the current
app, takes Return and Escape without stealing focus from the host app, and
cascades for parallel invocations. Inline `code`, **strong**, and *em*
spans render in the body; newlines become paragraph breaks.

When no binary is on PATH (next to the script either), `ask.sh` falls back
to the same flags through AppleScript `display dialog`, which needs no
install and no extra permission. The stdout, exit codes, and flag surface
are identical in both paths; the native binary is faster to appear and
visually distinct from a system dialog.

## Not this

<!-- skill-graph: mentions - each is named to route the reader away from
     this skill; none is loaded here -->

- [peekaboo](../peekaboo/SKILL.md) drives windows that already
  exist and cannot create one. This skill creates the dialog; peekaboo is
  not involved.
- [open-in-browser](../open-in-browser/SKILL.md) is for URLs.
- A terminal question tool blocks inside the harness UI. Reach for it when
  the human is watching the terminal; reach for this skill when they may not
  be.

## Measured

On the reference machine (Apple Silicon MacBook Pro, macOS 26), for the
native binary: process launch to window visible measured 135-214 ms warm
and 385 ms cold (first launch after build; 2-3 ms poll granularity). A 2 s
bound printed `GAVE-UP` on stdout with exit 3 at 2.25-2.29 s wall time
(deadline + one display-link tick + the 140 ms exit fade + process
teardown). Live-window captures, pixel-sampled against the design tokens:
1 px cyan border at full alpha, 90% `#0B0F16` scrim, `white 2%` ghost
fills, solid accent default fill with dark label, and a 2 pt drain line
whose color matched the countdown text through the cyan-amber-red ramp.
Bodies with quotes, backslashes, and real newlines rendered correctly,
including `code`, **strong**, and *em* spans. Real synthetic input
(CGEventPost, the Accessibility permission belonging to the calling
terminal, none to the dialog) clicked both button kinds and delivered
Return and Escape: all five scenarios matched the contract table above.
The AppleScript fallback was measured earlier as the `ask-on-screen`
renderer: no extra permission, correct quoting, one reflex-speed human
click, Escape to `CANCELED` exit 2, and a 5 s bound giving up at 5.1 s.
