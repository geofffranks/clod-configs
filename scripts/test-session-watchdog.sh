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
# Recording osascript + Darwin uname stubs (AC6): the default-on mac lane must
# never pop a real Notification Center alert during tests; the Darwin uname
# stub keeps credential-free mac assertions working on Linux CI too.
OSA="$TMP/osacalls"; : > "$OSA"; export OSA_LOG="$OSA"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${2:-}|${3:-}" >> "${OSA_LOG:-/dev/null}"\n' > "$TMP/osascript-rec"; chmod +x "$TMP/osascript-rec"
ln -sf "$TMP/osascript-rec" "$TMP/osascript"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$TMP/uname"; chmod +x "$TMP/uname"
# Failing osascript stub isolates mac-lane failure from Pushover retry state.
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/osascript-fail"; chmod +x "$TMP/osascript-fail"
osacount(){ wc -l < "$OSA" | tr -d ' '; }
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
  printf '%s\n' '{"type":"user","content":"hi"}' >> "$TMP/sess/$1/log.jsonl"
  if [ "$2" = idle ]; then touch -t 200001010000 "$TMP/sess/$1/log.jsonl"; fi
}
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

run(){
  : > "$LOG"; : > "$OSA"
  local purge="${1:-0}"   # 0=disabled (existing tests), N=threshold, "default"=omit env (pins built-in default)
  if [ "$purge" = "default" ]; then
    WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
    WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 \
    PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
    bash "$HOOK"
  else
    WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
    WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 WATCHDOG_PURGE_OLD_DAYS="$purge" \
    PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
    bash "$HOOK"
  fi
}
# Credential-free mac-only runner: no Pushover creds anywhere (env vars empty
# AND the real host watchdog.env is pinned away, so pushover_ok=0 by
# construction), so only the mac lane can send. Does NOT truncate $OSA:
# cross-scan mac-send counts are asserted directly.
run_nocreds(){
  : > "$LOG"
  WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 WATCHDOG_PURGE_OLD_DAYS=0 \
  WATCHDOG_ENV_FILE="$TMP/none.env" \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" OSA_LOG="$OSA" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= \
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
# The mac lane fires for the same death with the SAME title/body (AC2).
grep -Fq 'fix the flux capacitor Agent Died|projx: fix the flux capacitor (last activity 0m ago)' "$OSA" \
  && ok "death mac-sends with the same title/body" || no "death mac-sends with the same title/body"

run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessC" ] && [ "$(osacount)" = 0 ] && ok "death episode pings only once" || no "death episode pings only once"

mkdaemon c2 sessC fresh
run
[ ! -f "$TMP/state/tomb-sessC" ] && [ "$(count)" = 0 ] && ok "fresh daemon clears death tombstone" || no "fresh daemon clears death tombstone"
mkdaemon c2b sessC fresh
rm -f "$TMP/logs/c2.liveness.jsonl"   # c2 goes away entirely; only c2b remains
touch -t 200001010000 "$TMP/logs/c2b.liveness.jsonl"
run
[ "$(count)" = 1 ] && ok "new death episode pings again" || no "new death episode pings again"

# T1/AC-2.1 (the flood): a session alive via ANY fresh journal must not be
# re-armed by a stale leftover sibling. fresh+stale for one session => 0
# pings; the stale journal alone would look like a death, but the fresh
# sibling keeps the session alive. (Fails pre-fix: the stale sibling re-pings.)
newworld
mkdaemon f1 sessF1 fresh; mksession sessF1 active
run                                     # bootstrap this fresh daemon (boot grace)
mkdaemon f2 sessF1 stale                # a stale leftover sibling appears
run
[ "$(count)" = 0 ] && ok "fresh+stale sibling for one session pings 0 (flood fixed)" \
  || no "fresh+stale sibling for one session pings 0 (calls=$(count))"

# T2/AC-3.1a: a stale dead-session journal older than the threshold is purged
# on run, together with its paired .log. Runs with the env var OMITTED so this
# also pins the shipped default (WATCHDOG_PURGE_OLD_DAYS=7).
newworld
mkdaemon q1 sessQ1 stale; mksession sessQ1 idle
run default
[ ! -f "$TMP/logs/q1.liveness.jsonl" ] && [ ! -f "$TMP/logs/q1.log" ] \
  && ok "stale dead-session journal + .log purged (default threshold 7d)" \
  || no "stale dead-session journal + .log purged (default threshold 7d)"

# T2/AC-3.1b: a fresh journal for a live session is never removed even when
# dead-session journals are purged in the same scan.
newworld
mkdaemon live1 sessLive1 fresh; mkdaemon dead2 sessDead2 stale; mkdaemon dead3 sessDead3 stale
mksession sessLive1 active; mksession sessDead2 idle; mksession sessDead3 idle
run 7
[ -f "$TMP/logs/live1.liveness.jsonl" ] \
  && [ ! -f "$TMP/logs/dead2.liveness.jsonl" ] && [ ! -f "$TMP/logs/dead2.log" ] \
  && [ ! -f "$TMP/logs/dead3.liveness.jsonl" ] \
  && ok "live fresh journal kept while dead-session journals purged" \
  || no "live fresh journal kept while dead-session journals purged"

# T2/AC-3.1c: a stale journal whose session still has a fresh sibling is NOT
# removed (the live-session-never-affected guard).
newworld
mkdaemon s1 sessS1 fresh; mkdaemon s2 sessS1 stale; mksession sessS1 active
run 7
[ -f "$TMP/logs/s2.liveness.jsonl" ] && [ -f "$TMP/logs/s2.log" ] \
  && ok "stale journal with a fresh sibling is NOT purged (live-session guard)" \
  || no "stale journal with a fresh sibling is NOT purged"

# T1/AC-2.3: a session with only fresh journal(s) pings 0 (no regression), even
# with a second fresh daemon for the same session after the bootstrap scan.
newworld
mkdaemon g1 sessG2 fresh; mksession sessG2 active
run                                     # bootstrap (boot grace)
mkdaemon g2 sessG2 fresh                # a second fresh daemon for the session
run
[ "$(count)" = 0 ] && [ ! -f "$TMP/state/tomb-sessG2" ] \
  && ok "only-fresh session pings 0 and never tombstones (AC-2.3)" \
  || no "only-fresh session pings 0 (calls=$(count))"

# T2: WATCHDOG_PURGE_OLD_DAYS=0 (the harness default) disables purge: an old
# stale journal for a dead session survives a scan with its .log untouched.
newworld
mkdaemon z1 sessZ1 stale; mksession sessZ1 idle
run
[ -f "$TMP/logs/z1.liveness.jsonl" ] && [ -f "$TMP/logs/z1.log" ] \
  && ok "purge disabled (0) keeps old stale journal + .log" \
  || no "purge disabled (0) keeps old stale journal + .log"

# T2: an old anonymous journal (no paired .log session id) is purged as hygiene
# once older than the threshold — it can name no live session.
newworld
: > "$TMP/logs/anon2.log"; : > "$TMP/logs/anon2.liveness.jsonl"; touch -t 200001010000 "$TMP/logs/anon2.liveness.jsonl"
run default
[ ! -f "$TMP/logs/anon2.liveness.jsonl" ] && [ ! -f "$TMP/logs/anon2.log" ] \
  && ok "old anonymous journal + .log purged as hygiene" \
  || no "old anonymous journal + .log purged as hygiene"

# 5. Daemon death while the session is long idle is silent.
newworld
mkdaemon e1 sessE stale; mksession sessE idle
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessE" ] && [ "$(osacount)" = 0 ] && ok "idle death never pings" || no "idle death never pings"

# 6. Mass deaths (>= WATCHDOG_MASS in one scan) are treated as one host event.
newworld
mkdaemon m1 s1 stale; mkdaemon m2 s2 stale; mkdaemon m3 s3 stale
mksession s1 active; mksession s2 active; mksession s3 active
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-s1" ] && [ -f "$TMP/state/tomb-s3" ] && [ "$(osacount)" = 0 ] && ok "mass death suppression" || no "mass death suppression"

# 7. A liveness file whose daemon log names no session is skipped safely.
newworld
: > "$TMP/logs/anon.log"; : > "$TMP/logs/anon.liveness.jsonl"; touch -t 200001010000 "$TMP/logs/anon.liveness.jsonl"
run && [ "$(count)" = 0 ] && ok "anonymous daemon log skipped safely" || no "anonymous daemon log skipped safely"

# 8. No destination at all (non-mac uname): fail open before any state or
#    network work — today's fail-open behavior.
NONMAC="$TMP/nonmac"; mkdir -p "$NONMAC"; printf '#!/usr/bin/env bash\necho Linux\n' > "$NONMAC/uname"; chmod +x "$NONMAC/uname"
newworld
out="$(WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/nocreds" \
  WATCHDOG_ENV_FILE="$TMP/none.env" \
  PATH="$NONMAC:/usr/bin:/bin" PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= bash "$HOOK")"
[ -z "$out" ] && [ ! -d "$TMP/nocreds" ] && ok "non-mac missing credentials fail open" || no "non-mac missing credentials fail open"

# 8b. Credential-free mac-only scan (Darwin uname stub keeps this portable to
#     Linux CI): death and TUI-crash alerts mac-send with ZERO curl, and the
#     episode is claimed without any Pushover retry state (AC2/AC5).
newworld
mkdaemon mc1 sessMC fresh; mksession sessMC active "mac only death"
run_nocreds                                  # boot grace: records, sends nothing
[ "$(osacount)" = 0 ] && [ "$(count)" = 0 ] && ok "credential-free boot scan stays silent" || no "credential-free boot scan stays silent"
touch -t 200001010000 "$TMP/logs/mc1.liveness.jsonl"
mkcrash mccrash sessMC fresh "mac only crash message"
run_nocreds
grep -Fq 'mac only death Agent Died|projx: mac only death (last activity 0m ago)' "$OSA" \
  && grep -Fq 'mac only death TUI Crashed|projx: mac only crash message (last activity 0m ago)' "$OSA" \
  && [ "$(osacount)" = 2 ] && [ "$(count)" = 0 ] \
  && ok "credential-free death+crash mac-send with zero curl" || no "credential-free death+crash mac-send with zero curl"
[ -f "$TMP/state/tomb-sessMC" ] && [ ! -e "$TMP/state/att-sessMC" ] \
  && [ -f "$TMP/state/crash-mccrash-tui.crash" ] \
  && ok "mac-only episodes claimed without Pushover retry state" || no "mac-only episodes claimed without Pushover retry state"

# 8c. A mac-lane failure must not release the tombstone or create att: the
#     episode sends exactly once (no mac retry), Pushover state untouched.
newworld
mkdaemon mf1 sessMF fresh; mksession sessMF active "mac fail death"
run_nocreds                                  # boot grace
touch -t 200001010000 "$TMP/logs/mf1.liveness.jsonl"
: > "$OSA"
ln -sf "$TMP/osascript-fail" "$TMP/osascript"
run_nocreds                                  # mac send fails (swallowed, fail-open)
ln -sf "$TMP/osascript-rec" "$TMP/osascript"
[ "$(count)" = 0 ] && [ ! -e "$TMP/state/att-sessMF" ] && [ -f "$TMP/state/tomb-sessMF" ] \
  && ok "mac failure never touches att or releases the tombstone" || no "mac failure never touches att or releases the tombstone"
run_nocreds                                  # episode already claimed: no second attempt
[ "$(count)" = 0 ] && [ "$(osacount)" = 0 ] \
  && ok "mac-only episode sends exactly once despite failure" || no "mac-only episode sends exactly once despite failure"

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
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 WATCHDOG_PURGE_OLD_DAYS=0 \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
  bash "$HOOK"
done
# The mock log is append-only across scans: exactly three failing attempts,
# then the cap tombstones the episode and the fourth scan sends nothing.
[ "$(count)" = 3 ] && [ -f "$TMP/state/tomb-sessR" ] && ok "failed sends retry 3 times then tombstone" || no "failed sends retry 3 times then tombstone (calls=$(count) tomb=$([ -f "$TMP/state/tomb-sessR" ] && echo y || echo n))"

# 10. A fresh TUI crash in an active session pings once, enriched like a death.
newworld
mksession sessK active "chasing the tui panic"
mkcrash 2026-09-13T15-27-09Z sessK fresh "panicked at rs/tui.rs:706: index out of bounds"
run
[ "$(count)" = 1 ] && grep -q -- '--data-urlencode title=chasing the tui panic TUI Crashed' "$LOG" \
  && grep -q -- '--data-urlencode message=projx: panicked at rs/tui.rs:706: index out of bounds (last activity 0m ago)' "$LOG" \
  && ok "fresh TUI crash pings once, enriched" || no "fresh TUI crash pings once, enriched"
grep -Fq 'chasing the tui panic TUI Crashed|projx: panicked at rs/tui.rs:706: index out of bounds (last activity 0m ago)' "$OSA" \
  && ok "crash mac-sends with the same title/body" || no "crash mac-sends with the same title/body"
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/crash-2026-09-13T15-27-09Z-tui.crash" ] && [ "$(osacount)" = 0 ] && ok "crash pings only once per crash log" || no "crash pings only once per crash log"

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
  WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 WATCHDOG_PURGE_OLD_DAYS=0 \
  PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user \
  bash "$HOOK"
done
[ "$(count)" = 3 ] && [ -f "$TMP/state/crash-2026-09-13T16-00-00Z-tui.crash" ] && ok "crash send failures retry 3 then tombstone" || no "crash send failures retry 3 then tombstone (calls=$(count))"

# A send claims the episode (tombstone) BEFORE delivering: concurrent
# scanners sharing this state must not double-ping the same death.
newworld
mkdaemon c9 sessC9 fresh; mksession sessC9 active "claim check"
touch -t 200001010000 "$TMP/logs/c9.liveness.jsonl"
cat > "$TMP/claimcurl" <<'EOF'
#!/usr/bin/env bash
if [ -f "$WATCHDOG_STATE_DIR/tomb-sessC9" ]; then
  printf '%s\n' 'CLAIMED-DURING-SEND' >> "${MOCK_LOG:?}"
fi
EOF
chmod +x "$TMP/claimcurl"; ln -sf "$TMP/claimcurl" "$TMP/curl"
run
grep -q 'CLAIMED-DURING-SEND' "$LOG" && ok "send claims the episode before delivering" || no "send claims the episode before delivering"
ln -sf "$TMP/curl-good" "$TMP/curl"

# 13. A daemon that disarmed cleanly (TUI closed, session replaced) ended on
# purpose: nobody died. Only a journal that stops mid-stream is a death.
newworld
mkdaemon d1 sessD1 fresh; mksession sessD1 active "still alive"
printf '{"type":"disarmed","reason":"serve_exited"}\n' >> "$TMP/logs/d1.liveness.jsonl"
touch -t 200001010000 "$TMP/logs/d1.liveness.jsonl"
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessD1" ] && ok "clean disarm is not a death" || no "clean disarm is not a death"

# 14. Explicit process env credentials beat watchdog.env: a seeded file must
# never leak real credentials into a context that passed its own.
newworld
mkdir -p "$TMP/envf"; printf 'PUSHOVER_APP_TOKEN=FILETOKEN\nPUSHOVER_USER_KEY=FILEUSER\n' > "$TMP/envf/wd.env"
mkdaemon f1 sessF fresh; mksession sessF active "env wins"
touch -t 200001010000 "$TMP/logs/f1.liveness.jsonl"
ln -sf "$TMP/curl-good" "$TMP/curl"
WATCHDOG_LOG_DIR="$TMP/logs" WATCHDOG_SESSIONS_DIR="$TMP/sess" WATCHDOG_STATE_DIR="$TMP/state" \
WATCHDOG_ENV_FILE="$TMP/envf/wd.env" WATCHDOG_LIVENESS_STALE=30 WATCHDOG_IDLE_LIMIT=300 WATCHDOG_MASS=3 \
PATH="$TMP:$PATH" MOCK_LOG="$LOG" PUSHOVER_APP_TOKEN=envtoken PUSHOVER_USER_KEY=envuser \
bash "$HOOK"
grep -q 'token=envtoken' "$LOG" && ! grep -q 'FILETOKEN' "$LOG" && ok "env credentials beat watchdog.env" || no "env credentials beat watchdog.env"

# 15. A session that never received a prompt has nothing to wait for: any
# daemon exit, however abrupt, is tombstoned silently.
newworld
mkdaemon n1 sessN1 stale; mksession sessN1 active
: > "$TMP/sess/sessN1/log.jsonl"
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/tomb-sessN1" ] && ok "never-prompted session never pings" || no "never-prompted session never pings"

# 16. A TUI crash in a never-prompted session stays silent too.
newworld
mksession sessN2 active; : > "$TMP/sess/sessN2/log.jsonl"
mkcrash 2026-09-13T17-00-00Z sessN2 fresh
run
[ "$(count)" = 0 ] && [ -f "$TMP/state/crash-2026-09-13T17-00-00Z-tui.crash" ] && ok "crash in never-prompted session stays silent" || no "crash in never-prompted session stays silent"

# 17. An empty title part does not duplicate "Agent": "Agent Died", once.
newworld
mkdaemon g1 sessG fresh
mkdir -p "$TMP/sess/sessG"; : > "$TMP/sess/sessG/log.jsonl"; printf '%s\n' '{"type":"user"}' >> "$TMP/sess/sessG/log.jsonl"
touch -t 200001010000 "$TMP/logs/g1.liveness.jsonl"
run
grep -q -- '--data-urlencode title=Agent Died ' "$LOG" && ! grep -q 'Agent Agent' "$LOG" && ok "empty title part does not duplicate Agent" || no "empty title part does not duplicate Agent"
[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
