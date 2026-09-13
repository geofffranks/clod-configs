#!/usr/bin/env bash
# Shared policy core for the notify diagnostic adapter. Pure functions:
# clock and state are injected; no I/O beyond the caller-provided state dir.
set -u

# Strict RFC3339 wire grammar only (T separator, timezone required, bounded
# fractional seconds). Anything else — including ISO forms Python would accept,
# such as a space separator — must fail so callers diagnostic-skip.
policy_epoch(){ python3 - "$1" <<'PY'
import datetime,re,sys
s=sys.argv[1]
if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})', s):
    sys.exit(1)
try:
    d=datetime.datetime.fromisoformat(s.replace('Z','+00:00'))
    if d.tzinfo is None: raise ValueError()
    print(int(d.timestamp()))
except Exception:
    sys.exit(1)
PY
}

policy_age_decision(){ local now="$1" emitted_at="$2" ts; ts="$(policy_epoch "$emitted_at")" || { printf 'diagnostic-skip\n'; return 2; }; local age=$((now-ts)); if [ "$age" -gt 120 ]; then echo stale; elif [ "$age" -lt -5 ]; then echo future; else echo ok; fi; }

# Declares a clock discontinuity when the local clock moves backward beyond
# tolerance. Persists last-observed-clock; never modifies the watermark (the
# watermark belongs to decided events only).
policy_discontinuity(){ local now="$1" dir="$2" old; mkdir -p "$dir"; old="$(cat "$dir/last-observed-clock" 2>/dev/null || true)"; printf '%s\n' "$now" > "$dir/last-observed-clock"; if [[ "$old" =~ ^[0-9]+$ ]] && [ "$((old-now))" -gt 5 ]; then printf 'declare\n'; return 2; fi; printf 'ok\n'; }

# Episode keys per event family. Only string scalar IDs qualify; anything
# missing, non-scalar, or ambiguous maps to a diagnostic key (never a claim).
policy_episode_key(){ local j="$1"; jq -r '
  def scalar($x): ($x | type == "string" and length > 0 and length <= 128);
  if (.event.transition? == "cleared") then "diagnostic:cleared"
  elif scalar(.event.interrogative_id?) then "interrogative:\(.event.interrogative_id)"
  elif scalar(.event.prompt_id?) then "prompt:\(.event.prompt_id)"
  elif scalar(.event.goal.id?) then "goal:\(.event.goal.id):\(.event.transition // "")"
  else "diagnostic:missing-id" end' <<<"$j" 2>/dev/null; }

# Atomic episode claim. Exactly one concurrent caller wins.
policy_claim(){ local dir="$1" key="$2"; mkdir -p "$dir/claims"; ( set -C; : > "$dir/claims/$key" ) 2>/dev/null && return 0; return 1; }

# Cancellation episodes may proceed only with verified evidence that they are
# not part of an intentional shutdown. Absent evidence suppresses.
policy_shutdown_gate(){ [ "${1:-}" = verified-non-shutdown ] && return 0; printf 'suppressed\n'; return 1; }
