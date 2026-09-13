#!/usr/bin/env bash
# Tests for home/session-watchdog.sh — see the header there for the design.
# Note: run() truncates the mock-curl log, so every count assertion is about
# the pings of THAT scan only; tombstone presence carries episode state.
# Tests 1-4 share one world (they exercise episode state across scans); the
# rest start from a fresh world so unrelated sessions cannot bleed in.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/home/session-watchdog.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CURL="$TMP/curl"; LOG="$TMP/calls"; : > "$LOG"
cat > "$CURL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
EOF
chmod +x "$CURL"
cp "$CURL" "$TMP/curl-good"   # restorable good mock: $TMP/curl gets relinked by retry tests
FAILCURL="$TMP/failcurl"
cat > "$FAILCURL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
exit 1
EOF
chmod +x "$FAILCURL"
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
count(){ wc -l < "$LOG" | tr -d ' '; }
newworld(){ mkdir -p "$TMP/logs" "$TMP/sess" "$TMP/state"; }

# mkdaemon <stem> <session> fresh|stale — a daemon log naming its session plus a liveness file
mkdaemon(){
  printf '{"level":"INFO","fields":{"message":"loaded history from disk","session_id":"%s"}}\n' "$2" > "$TMP/logs/$1.log"
  : > "$TMP/logs/$1.liveness.jsonl"
  if [ "$3" = stale ]; then touch -t 200001010000 "$TMP/logs/$1.liveness.jsonl"; fi
}
# mksession <session> active|idle [preview]
mksession(){
  mkdir -p "$TMP/sess/$1"
  printf '%s' "{\"project_path\":\"/Users/gfranks/workspace/projx\",\"last_user_message_preview\":\"${3:-do the thing}\"}" > "$TMP/sess/$1/session.json"
  : > "$TMP/sess/$1/log.jsonl"
  if [ "$2" = idle ]; then touch -t 200001010000 "$TMP/sess/$1/log.jsonl"; fi
}
run(){
  : > "$LOG"
  WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
  bash "$HOOK"
}

# 1-4. One world: boot grace, death+enrichment, dedup, resume-clears, re-death.
mkdir -p "$TMP/logs" "$TMP/sess" "$TMP/state"
mkdaemon a1 sessA fresh; mkdaemon b1 sessB stale
mksession sessA active; mksession sessB active
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessB" ] && ok "boot grace tombstones without pinging" || no "boot grace tombstones without pinging"

mkdaemon c1 sessC fresh; mksession sessC active "fix the flux capacitor"
run                                   # bootstrap c1's freshness
touch -t 200001010000 "$TMP/logs/c1.liveness.jsonl"
run
[ "$(count)" = 1 ] && grep -q -- '--data-urlencode title=fix the flux capacitor Agent Died' "$LOG" \
  && grep -q -- '--data-urlencode message=projx: fix the flux capacitor' "$LOG" \
  && grep -q 'last activity 0m ago' "$LOG" && ok "death while active pings once, enriched" || no "death while active pings once, enriched"

run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessC" ] && ok "death episode pings only once" || no "death episode pings only once"

mkdaemon c2 sessC fresh
run
[ ! -f "$TMP/state/tomb-sessC" ] && [ "$(count)" = 0 ] && ok "fresh daemon clears death tombstone" || no "fresh daemon clears death tombstone"
mkdaemon c2b sessC fresh
rm -f "$TMP/logs/c2.liveness.jsonl"   # c2 goes away entirely; only c2b remains
touch -t 200001010000 "$TMP/logs/c2b.liveness.jsonl"
run
[ "$(count)" = 1 ] && ok "new death episode pings again" || no "new death episode pings again"

# 5. Daemon death while the session is long idle is silent.
newworld
mkdaemon e1 sessE stale; mksession sessE idle
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessE" ] && ok "idle death never pings" || no "idle death never pings"

# 6. Mass deaths (>= WATCHDOG_MASS in one scan) are treated as one host event.
newworld
mkdaemon m1 s1 stale; mkdaemon m2 s2 stale; mkdaemon m3 s3 stale
mksession s1 active; mksession s2 active; mksession s3 active
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-s1" ] && [ -f "$TMP/state/tomb-s3" ] && ok "mass death suppression" || no "mass death suppression"

# 7. A liveness file whose daemon log names no session is skipped safely.
newworld
: > "$TMP/logs/anon.log"; : > "$TMP/logs/anon.liveness.jsonl"; touch -t 200001010000 "$TMP/logs/anon.liveness.jsonl"
run && [ "$(count)" = 0 ] && ok "anonymous daemon log skipped safely" || no "anonymous daemon log skipped safely"

# 8. Missing credentials fail open before any state or network work.
newworld
out="$(WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/nocreds" \
  PATH="$TMP:/usr/bin:/bin" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= bash "$HOOK")"
[ -z "$out" ] && [ ! -d "$TMP/nocreds" ] && ok "missing credentials fail open" || no "missing credentials fail open"

# 9. Send failures retry up to 3 attempts, then tombstone. Per-scan ping
#    counts: 1, 1, 1 failing attempts, then the 4th scan tombstones silently.
newworld
mkdaemon r1 sessR fresh; mksession sessR active "retry me"
run
touch -t 200001010000 "$TMP/logs/r1.liveness.jsonl"
total=0; last=0
# The mock is relinked per scan; the cap scan needs no send, but the good
# mock is restored so later tests deliver. (Never point $TMP/curl at $CURL —
# it IS $TMP/curl, and a self-referential link poisons later scans with ELOOP.)
for scan in 1 2 3 4; do
  if [ "$scan" -lt 4 ]; then ln -sf "$FAILCURL" "$TMP/curl"; else ln -sf "$TMP/curl-good" "$TMP/curl"; fi
  WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
  bash "$HOOK"
done
# The mock log is append-only across scans: exactly three failing attempts,
# then the cap tombstones the episode and the fourth scan sends nothing.
[ "$(count)" = 3 ] && [ -f "$TMP/state/tomb-sessR" ] && ok "failed sends retry 3 times then tombstone" || no "failed sends retry 3 times then tombstone (calls=$(count) tomb=$([ -f "$TMP/state/tomb-sessR" ] && echo y || echo n))"

# mkcrash <stem> <session> fresh|stale [message] — a TUI crash log naming its session
mkcrash(){
  local msg="${4:-panicked at rs/polytoken-cli/src/tui/reducer/mod.rs:706:55: index out of bounds}"
  {
    echo "polytoken TUI crash log"
    echo "======================="
    echo "Timestamp: x"
    echo "Session: $2"
    echo
    echo "Reason: panic"
    echo "Location: rs/polytoken-cli/src/tui/reducer/mod.rs:706:55"
    echo "Message: $msg"
  } > "$TMP/logs/$1-tui.crash.log"
  if [ "$3" = stale ]; then touch -t 200001010000 "$TMP/logs/$1-tui.crash.log"; fi
  return 0
}

# 10. A fresh TUI crash in an active session pings once, enriched like a death.
newworld
mksession sessK active "chasing the tui panic"
mkcrash 2026-09-13T15-27-09Z sessK fresh "panicked at rs/tui.rs:706: index out of bounds"
run
[ "$(count)" = 1 ] && grep -q -- '--data-urlencode title=chasing the tui panic TUI Crashed' "$LOG" \
  && grep -q -- '--data-urlencode message=projx: panicked at rs/tui.rs:706: index out of bounds (last activity 0m ago)' "$LOG" \
  && ok "fresh TUI crash pings once, enriched" || no "fresh TUI crash pings once, enriched"
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/crash-2026-09-13T15-27-09Z-tui.crash" ] && ok "crash pings only once per crash log" || no "crash pings only once per crash log"

# 11. A crash log older than the idle limit is tombstoned silently.
newworld
mksession sessL active
mkcrash 2026-08-01T00-00-00Z sessL stale
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/crash-2026-08-01T00-00-00Z-tui.crash" ] && ok "stale crash tombstoned silently" || no "stale crash tombstoned silently"

# 12. Crash send failures retry up to 3 attempts, then tombstone silently.
newworld
mksession sessM active "crash retry"
mkcrash 2026-09-13T16-00-00Z sessM fresh
for scan in 1 2 3 4; do
  if [ "$scan" -lt 4 ]; then ln -sf "$FAILCURL" "$TMP/curl"; else ln -sf "$TMP/curl-good" "$TMP/curl"; fi
  WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
  bash "$HOOK"
done
[ "$(count)" = 3 ] && [ -f "$TMP/state/crash-2026-09-13T16-00-00Z-tui.crash" ] && ok "crash send failures retry 3 then tombstone" || no "crash send failures retry 3 then tombstone (calls=$(count))"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
