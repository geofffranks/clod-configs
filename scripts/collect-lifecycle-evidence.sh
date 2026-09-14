#!/usr/bin/env bash
# collect-lifecycle-evidence.sh — HOST-runnable (macOS bash 3.2+).
# Task 4 lifecycle evidence through the instrumented launchers. Inert: the
# launchers only append notify-exit-record/v1 lines; nothing notifies.
#
# Kill safety — every SIGKILL is scoped to what THIS run started:
#   native:    guided — you run the wrapper with its env-gated kill timer in
#              a real terminal; it SIGKILLs only its own child. (A script(1)
#              PTY cannot answer the TUI's cursor-position query, so the
#              automated PTY variant cannot boot the native TUI.)
#   container: run.sh gets POLY_CONTAINER_NAME; only that named container is
#              killed. Never any other running container or process.
#
# Usage: bash scripts/collect-lifecycle-evidence.sh [all|kill]
#   all  (default) = every scenario (fresh evidence file)
#   kill           = native-3 (guided) + container-3 (automated); appends
set -u
MODE="${1:-all}"
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$R/.polytoken/lifecycle-evidence.txt"
EXITDIR_N="$HOME/.local/share/polytoken/notify-exit"
EXITDIR_C="$HOME/.local/share/polytoken-dev/notify-exit"
mkdir -p "$R/.polytoken"
sec(){ echo; echo "===== $1 ====="; echo "===== $1 =====" >> "$OUT"; }
cap(){ echo "--- $1" >> "$OUT"; shift; "$@" >> "$OUT" 2>&1; }
nl_count(){ local n=0; n="$(wc -l < "$1/notify-exit.log" 2>/dev/null || echo 0)"; echo "$n"; }
show_records(){ local d="$1" n="$2" label="$3" rec; rec="$(sed -n "$((n + 1)),\$p" "$d/notify-exit.log" 2>/dev/null)"; if [ -n "$rec" ]; then printf '%s record(s):\n%s\n' "$label" "$rec" | tee -a "$OUT"; else echo "$label record: (none written)" | tee -a "$OUT"; fi; }
ask(){ printf '\n>>> %s (press Enter when done) ' "$1"; read -r _; }

if [ "$MODE" = "kill" ]; then echo >> "$OUT"; else : > "$OUT"; fi
echo "Lifecycle evidence collected $(date -u +%Y-%m-%dT%H:%M:%SZ) mode=$MODE" >> "$OUT"
cap "podman version" podman --version
cap "native polytoken" polytoken --version

if [ "$MODE" != "kill" ]; then
  echo "=========== GUIDED SCENARIOS ==========="
  if command -v polytoken >/dev/null 2>&1; then
    sec "NATIVE 1: clean quit"
    echo "A TUI will start. Quit it NORMALLY (double Ctrl-C or /quit)." >&2
    ask "ready"
    n="$(nl_count "$EXITDIR_N")"
    bash "$R/home/bin/polytoken-notify-wrapper.sh" new
    echo "wrapper exit status: $?" | tee -a "$OUT"
    show_records "$EXITDIR_N" "$n" "native-1"

    sec "NATIVE 4: detach, then reattach"
    echo "Start the TUI, DETACH normally (quit TUI, daemon stays), then reattach: polytoken attach <id> — then quit again." >&2
    ask "start detach/reattach now"
    n="$(nl_count "$EXITDIR_N")"
    bash "$R/home/bin/polytoken-notify-wrapper.sh" new
    echo "wrapper exit status: $?" | tee -a "$OUT"
    show_records "$EXITDIR_N" "$n" "native-4"
  else
    sec "NATIVE: SKIPPED (polytoken not on PATH)"
  fi

  if command -v podman >/dev/null 2>&1; then
    sec "CONTAINER 1: clean quit"
    echo "The container TUI will start. Quit it NORMALLY (double Ctrl-C or /quit)." >&2
    ask "ready"
    n="$(nl_count "$EXITDIR_C")"
    bash "$R/polytoken-container/run.sh"
    echo "run.sh exit status: $?" | tee -a "$OUT"
    show_records "$EXITDIR_C" "$n" "container-1"
  else
    sec "CONTAINER 1: SKIPPED (podman not on PATH)"
  fi
fi

echo "=========== SIGKILL SCENARIOS ==========="

sec "NATIVE 3: SIGKILL TUI (guided: wrapper kill-timer in your terminal)"
n="$(nl_count "$EXITDIR_N")"
echo "In a SECOND terminal run exactly:" | tee -a "$OUT"
echo "  POLY_NOTIFY_KILL_AFTER=20 bash \"$R/home/bin/polytoken-notify-wrapper.sh\" new" | tee -a "$OUT"
echo "The TUI comes up; after ~20s the wrapper SIGKILLs its own child and returns" | tee -a "$OUT"
echo "(your shell reports exit 137). Then come back here." | tee -a "$OUT"
ask "press Enter once the second-terminal wrapper has returned"
show_records "$EXITDIR_N" "$n" "native-3"

if command -v podman >/dev/null 2>&1; then
  sec "CONTAINER 3: SIGKILL container (scoped by POLY_CONTAINER_NAME)"
  n="$(nl_count "$EXITDIR_C")"
  CNAME="pt-ev-$$"
  tmpout="$(mktemp 2>/dev/null)" || tmpout="$R/.polytoken/.c3-out.$$"
  echo "running before this scenario: [$(podman ps -q 2>/dev/null | tr '\n' ' ')] — only name=$CNAME is ours" | tee -a "$OUT"
  HAVE_PTY=0; command -v script >/dev/null 2>&1 && HAVE_PTY=1
  rp=""
  cid=""
  if [ "$HAVE_PTY" = 1 ]; then
    POLY_CONTAINER_NAME="$CNAME" script -q /dev/null bash "$R/polytoken-container/run.sh" > "$tmpout" 2>&1 &
    rp=$!
    i=0
    while [ "$i" -lt 20 ]; do
      sleep 2; i=$((i + 1))
      cid="$(podman ps -q --filter "name=^$CNAME\$" 2>/dev/null | head -1)"
      [ -n "$cid" ] && break
    done
    if [ -n "$cid" ]; then
      echo "killing container started by this scenario: $cid (name=$CNAME)" | tee -a "$OUT"
      podman kill --signal=SIGKILL "$cid" >> "$OUT" 2>&1
    else
      echo "no container named $CNAME appeared — killing nothing" | tee -a "$OUT"
      kill "$rp" 2>/dev/null
    fi
    wait "$rp" 2>/dev/null; echo "run.sh (via script) exit status: $?" | tee -a "$OUT"
  else
    echo "SKIP: no 'script' (PTY) — podman -it cannot attach without a TTY." | tee -a "$OUT"
  fi
  echo "--- run.sh output during scenario:" >> "$OUT"; cat "$tmpout" >> "$OUT" 2>/dev/null; rm -f "$tmpout" 2>/dev/null || true
  show_records "$EXITDIR_C" "$n" "container-3"
else
  sec "CONTAINER 3: SKIPPED (podman not on PATH)"
fi

echo
echo "COLLECTED. Evidence file: $OUT"
