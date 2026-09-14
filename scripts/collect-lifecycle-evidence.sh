#!/usr/bin/env bash
# collect-lifecycle-evidence.sh — HOST-runnable (macOS bash 3.2+).
# Runs the Task 4 lifecycle scenario matrix through the instrumented launchers
# and collects every record/output into ONE evidence file you paste back.
# Inert: the launchers only write notify-exit-record/v1 files; nothing notifies.
set -u
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$R/.polytoken/lifecycle-evidence.txt"
EXITDIR_N="$HOME/.local/share/polytoken/notify-exit"
EXITDIR_C="$HOME/.local/share/polytoken-dev/notify-exit"
sec(){ echo; echo "===== $1 ====="; echo "===== $1 =====" >> "$OUT"; }
cap(){ echo "--- $1" >> "$OUT"; shift; "$@" >> "$OUT" 2>&1; }
latest(){ local d="$1"; [ -f "$d/notify-exit.log" ] && tail -1 "$d/notify-exit.log" || echo "(no record)"; }
ask(){ printf '\n>>> %s (press Enter when done) ' "$1"; read -r _; }

: > "$OUT"
echo "Lifecycle evidence collected $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$OUT"
cap "podman version" podman --version
cap "native polytoken" polytoken --version

echo "=========== NATIVE SCENARIOS ==========="
if command -v polytoken >/dev/null 2>&1; then
  sec "NATIVE 1: clean quit"
  echo "A TUI will start. Quit it NORMALLY (double Ctrl-C or /quit)." >&2
  ask "ready"
  bash "$R/home/bin/polytoken-notify-wrapper.sh" new
  echo "wrapper exit status: $?"
  echo "native-1 record: $(latest "$EXITDIR_N")" | tee -a "$OUT"

  sec "NATIVE 3: SIGKILL TUI (automated)"
  bash "$R/home/bin/polytoken-notify-wrapper.sh" new &
  wp=$!
  pid=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    pid=$(pgrep -n -f 'polytoken' 2>/dev/null || true)
    [ -n "$pid" ] && break
  done
  if [ -n "$pid" ]; then
    echo "killing native TUI pid: $pid" | tee -a "$OUT"
    kill -9 "$pid" 2>/dev/null || true
    wait "$wp"; echo "wrapper exit status: $?"
  else
    echo "could not find a polytoken process to kill" | tee -a "$OUT"
    kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  fi
  echo "native-3 record: $(latest "$EXITDIR_N")" | tee -a "$OUT"

  sec "NATIVE 4: detach, then reattach"
  echo "Start the TUI, DETACH normally (quit TUI, daemon stays), then reattach with: polytoken attach  — then quit again." >&2
  ask "start detach/reattach now"
  bash "$R/home/bin/polytoken-notify-wrapper.sh" new
  echo "wrapper exit status: $?"
  echo "native-4 record: $(latest "$EXITDIR_N")" | tee -a "$OUT"
else
  sec "NATIVE: SKIPPED (polytoken not on PATH)"
fi

echo "=========== CONTAINER SCENARIOS ==========="
if command -v podman >/dev/null 2>&1; then
  sec "CONTAINER 1: clean quit"
  echo "The container TUI will start. Quit it NORMALLY (double Ctrl-C or /quit)." >&2
  ask "ready"
  bash "$R/polytoken-container/run.sh"
  echo "run.sh exit status: $?"
  echo "container-1 record: $(latest "$EXITDIR_C")" | tee -a "$OUT"

  sec "CONTAINER 3: SIGKILL container (automated)"
  bash "$R/polytoken-container/run.sh" > "$T.$$" 2>&1 &
  rp=$!
  cid=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    sleep 2
    cid=$(podman ps --format '{{.ID}}' 2>/dev/null | head -1)
    [ -n "$cid" ] && break
  done
  if [ -n "$cid" ]; then
    echo "killing container: $cid" | tee -a "$OUT"
    podman kill --signal=SIGKILL "$cid" >> "$OUT" 2>&1
    wait "$rp"; echo "run.sh exit status: $?"
  else
    echo "could not find a running container to kill" | tee -a "$OUT"
    kill "$rp" 2>/dev/null; wait "$rp" 2>/dev/null
  fi
  echo "--- run.sh output during scenario:" >> "$OUT"; cat "$T.$$" >> "$OUT" 2>/dev/null; rm -f "$T.$$" 2>/dev/null || true
  echo "container-3 record: $(latest "$EXITDIR_C")" | tee -a "$OUT"
else
  sec "CONTAINER: SKIPPED (podman not on PATH)"
fi

echo
echo "COLLECTED. Evidence file: $OUT"
echo "Paste the file contents back to the assistant (or just say 'done' — it is readable in place)."
