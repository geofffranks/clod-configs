#!/usr/bin/env bash
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -r "$T"' EXIT
P=0; F=0; ok(){ echo "ok: $1"; P=$((P+1)); }; no(){ echo "FAIL: $1"; F=$((F+1)); }; eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got=$1 want=$2"; no "$3"; }; }
source "$R/home/lib/notify-policy.sh"
ADAPTER="$R/home/hooks/notify-event-adapter.sh"
run_adapter(){ local dir="$1" now="$2" frame="$3"; mkdir -p "$dir"; printf '%s' '{"port":1,"session_id":"sid","credential_file_path":""}' > "$dir/startup.json"; printf '#!/usr/bin/env bash\nprintf '\''%%s\\n'\'' %q\n' "$frame" > "$dir/curl"; chmod +x "$dir/curl"; PATH="$dir:$PATH" AGENT_NOTIFY_ADAPTER_LOG_DIR="$dir/logs" AGENT_NOTIFY_ADAPTER_STATE_DIR="$dir/state" AGENT_NOTIFY_TEST_NOW="$now" bash "$ADAPTER" "$dir/startup.json" >/dev/null 2>&1; }
run_adapter "$T/integration" 1704067200 'data: {"session_id":"wrong","emitted_at":"2024-01-01T00:00:00Z","event":{"type":"unknown","prompt_id":"p"}}'; grep -q 'envelope-session-mismatch' "$T/integration/logs/notify.log" && ok 'adapter envelope session mismatch' || no 'adapter envelope session mismatch'
run_adapter "$T/unsupported" 1704067200 'data: {"session_id":"sid","emitted_at":"2024-01-01T00:00:00Z","event":{"type":"retry_wait","prompt_id":"p"}}'; ! grep -q 'would-send' "$T/unsupported/logs/notify.log" && ok 'adapter unsupported silence' || no 'adapter unsupported silence'
run_adapter "$T/permission" 1704067200 'data: {"session_id":"sid","emitted_at":"2024-01-01T00:00:00Z","event":{"type":"interrogative","interrogative_type":"permission","interrogative_id":"i"}}'; grep -q 'decision=silent' "$T/permission/logs/notify.log" && ! grep -q 'would-send' "$T/permission/logs/notify.log" && ok 'permission interrogative silent' || no 'permission interrogative silent'
run_adapter "$T/handoff" 1704067200 'data: {"session_id":"sid","emitted_at":"2024-01-01T00:00:00Z","event":{"type":"interrogative","interrogative_type":"plan_handoff","interrogative_id":"i"}}'; grep -q 'would-send' "$T/handoff/logs/notify.log" && ok 'plan handoff would-send' || no 'plan handoff would-send'
S="$T/state"; mkdir -p "$S"
eq "$(policy_epoch 2024-01-01T00:00:00Z)" 1704067200 'RFC3339 Z epoch'
eq "$(policy_epoch 2024-01-01T00:00:00.9+00:00)" 1704067200 'RFC3339 fractional truncates'
eq "$(policy_age_decision 1704067200 2023-12-31T23:57:59Z)" stale 'stale age'
eq "$(policy_age_decision 1704067200 2024-01-01T00:00:06Z)" future 'future age'
eq "$(policy_age_decision 1704067200 1704067000)" diagnostic-skip 'epoch mismatch must diagnostic-skip'
eq "$(policy_age_decision 1704067200 bad)" diagnostic-skip 'bad timestamp diagnostic'
policy_discontinuity 1704067200 "$S" >/dev/null; eq "$(policy_discontinuity 1704067180 "$S")" declare 'backward clock declares'
[ -f "$S/last-observed-clock" ] && ok 'clock persisted/rebaselined' || no 'clock persisted/rebaselined'
eq "$(policy_episode_key '{"event":{"type":"turn","prompt_id":"p"}}')" prompt:p 'prompt family key'
eq "$(policy_episode_key '{"event":{"type":"provider","prompt_id":"p"}}')" prompt:p 'cross-family prompt correlation'
eq "$(policy_episode_key '{"event":{"type":"turn","prompt_id":"q"}}')" prompt:q 'different prompt independent'
eq "$(policy_episode_key '{"event":{"type":"goal","transition":"cleared","goal":{"id":"g"}}}')" diagnostic:cleared 'cleared diagnostic key'
eq "$(policy_episode_key '{"event":{"type":"turn"}}')" diagnostic:missing-id 'missing id diagnostic key'
rm -f "$S/claims/race"; (policy_claim "$S" race; echo $? > "$T/a") & pa=$!; (policy_claim "$S" race; echo $? > "$T/b") & pb=$!; wait "$pa" "$pb"; wins=0; [ "$(cat "$T/a")" = 0 ] && wins=$((wins+1)); [ "$(cat "$T/b")" = 0 ] && wins=$((wins+1)); [ "$wins" = 1 ] && ok 'exclusive concurrent claim' || no 'exclusive concurrent claim'
policy_shutdown_gate verified-non-shutdown >/dev/null && ok 'shutdown verified allows' || no 'shutdown verified allows'; ! policy_shutdown_gate absent >/dev/null && ok 'shutdown absent suppresses' || no 'shutdown absent suppresses'
[ "$P" -gt 0 ] && [ "$F" -eq 0 ] && echo "PASS: $P" || echo "FAILURES: $F/$((P+F))"; exit "$F"
