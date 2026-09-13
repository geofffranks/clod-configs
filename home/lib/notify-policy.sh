#!/usr/bin/env bash
set -u
policy_epoch(){ python3 - "$1" <<'PY'
import datetime,sys
try:
 s=sys.argv[1].replace('Z','+00:00'); d=datetime.datetime.fromisoformat(s)
 if d.tzinfo is None: raise ValueError()
 print(int(d.timestamp()))
except Exception: sys.exit(1)
PY
}
policy_age_decision(){ local now="$1" ts; ts="$(policy_epoch "$2")" || { printf 'diagnostic-skip\n'; return 2; }; local age=$((now-ts)); if [ "$age" -gt 120 ]; then echo stale; elif [ "$age" -lt -5 ]; then echo future; else echo ok; fi; }
policy_discontinuity(){ local now="$1" dir="$2" old; mkdir -p "$dir"; old="$(cat "$dir/last-observed-clock" 2>/dev/null || true)"; printf '%s\n' "$now" > "$dir/last-observed-clock"; if [[ "$old" =~ ^[0-9]+$ ]] && [ "$((old-now))" -gt 5 ]; then printf '%s\n' declare; return 2; fi; printf '%s\n' ok; }
policy_episode_key(){ local j="$1"; jq -r 'if (.event.transition? == "cleared") then "diagnostic:cleared" elif (.event.prompt_id? // empty) != "" then "prompt:\(.event.prompt_id)" elif (.event.goal.id? // empty) != "" then "goal:\(.event.goal.id):\(.event.transition // "")" elif (.event.interrogative_id? // empty) != "" then "interrogative:\(.event.interrogative_id)" else "diagnostic:missing-id" end // "diagnostic:missing-id"' <<<"$j" 2>/dev/null; }
policy_claim(){ local dir="$1" key="$2"; mkdir -p "$dir/claims"; ( set -C; : > "$dir/claims/$key" ) 2>/dev/null && return 0; return 1; }
policy_shutdown_gate(){ [ "${1:-}" = verified-non-shutdown ] && return 0; printf 'suppressed\n'; return 1; }
