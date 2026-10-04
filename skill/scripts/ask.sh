#!/bin/bash
# ask.sh - put a decision on the user's screen, get the clicked button back.
#
# Usage:
#   ask.sh --title TITLE --text TEXT --buttons B1 [B2] [B3]
#          [--default N] [--give-up-after SECONDS] [--no-beep]
#
# Output (stdout): the clicked button's text, or CANCELED, or GAVE-UP.
# Exit codes: 0 clicked | 2 canceled | 3 gave up | 1 usage or osascript error.
#
# --default N is 1-based and defaults to the LAST button, so the recommended
# answer is the rightmost unless the caller says otherwise. A button named
# "Cancel" is macOS's cancel button and maps to CANCELED.
#
# Renderer: if an ask-away binary is on PATH, or sits at ../bin/ask-away
# relative to this script, it drives the native panel. Otherwise this script
# falls back to AppleScript display dialog - same flags, same stdout and
# exit contract, no install needed.

set -euo pipefail

# --- renderer probe -------------------------------------------------------
native=""
if command -v ask-away >/dev/null 2>&1; then
  native="$(command -v ask-away)"
elif [[ -x "${BASH_SOURCE[0]%/*}/../bin/ask-away" ]]; then
  native="${BASH_SOURCE[0]%/*}/../bin/ask-away"
fi

if [[ -n "$native" ]]; then
  exec "$native" "$@"
fi

# --- AppleScript fallback (identical flag surface and output contract) ----

title="" text="" default="" give_up="" beep="yes"
buttons=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --text) text="$2"; shift 2 ;;
    --buttons) shift; while [[ $# -gt 0 && "$1" != --* ]]; do buttons+=("$1"); shift; done ;;
    --default) default="$2"; shift 2 ;;
    --give-up-after) give_up="$2"; shift 2 ;;
    --no-beep) beep="no"; shift ;;
    *) echo "ask.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$title" || -z "$text" || ${#buttons[@]} -lt 2 || ${#buttons[@]} -gt 3 ]]; then
  echo "ask.sh: needs --title, --text, and 2 or 3 --buttons" >&2
  exit 1
fi

# Escape for an AppleScript double-quoted literal. Real newlines become
# " & linefeed & " splices, the one form osascript renders as a line break.
esc() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\" & linefeed & \"}"
  printf '%s' "$s"
}

default_clause="default button ${default:-${#buttons[@]}}"
give_up_clause=""
[[ -n "$give_up" ]] && give_up_clause=" giving up after $give_up"
beep_line=""
[[ "$beep" == "yes" ]] && beep_line=$'beep 2\n'

button_list=""
for b in "${buttons[@]}"; do
  button_list+="\"$(esc "$b")\","
done
button_list="${button_list%,}"

script="${beep_line}display dialog \"$(esc "$text")\" with title \"$(esc "$title")\" buttons {$button_list} $default_clause$give_up_clause with icon note"

err_file="$(mktemp)"
trap 'rm -f "$err_file"' EXIT

out="$(osascript -e "$script" -e 'button returned of result as text' 2>"$err_file" || true)"
err="$(cat "$err_file")"

# A clicked button makes out non-empty. A gave-up dialog exits 0 with an
# empty button and no error. A cancel exits 1 with -128 in the error.
if [[ -n "$out" ]]; then
  printf '%s\n' "$out"; exit 0
fi
if [[ "$err" == *"User canceled"* || "$err" == *"-128"* ]]; then
  echo "CANCELED"; exit 2
fi
if [[ -z "$err" ]]; then
  echo "GAVE-UP"; exit 3
fi
echo "ask.sh: osascript error: $err" >&2
exit 1
