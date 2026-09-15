#!/usr/bin/env bash
# Lifecycle shipper (plan r3.6 freeze, r3.7 closed-world rule and common-cause
# collapse, r3.8 fidelity gate; operator "Choice C" dispatch). Called by both
# producers (native wrapper and container run.sh trap) immediately after the
# exit record is emitted.
#
# Contract:
#   - Only exit_status 137 with signal KILL ships tui_abnormal_exit. 0,
#     1/empty-signal, 129/130/143 (and anything else) suppress with a bounded
#     diagnostic entry and never send (native terminal closure is silent by
#     construction: the wrapper has no trap).
#   - A record whose timestamps degraded (ts_fidelity:"degraded", set by the
#     emitter) is suppressed: the fidelity-conditional identity window and the
#     claim-key math must never run on substituted emission times.
#   - No real correlated session_id means diagnostic-skip, never a synthetic
#     identity.
#   - Common-cause collapse: an exclusive-create claim on the batch key
#     tui-abnormal-batch-<ended_at floored to 15s> in <exit-dir>/claims makes
#     simultaneous deaths yield exactly ONE send; claim losers are
#     diagnostic-logged and suppress.
#   - The winner counts fidelity-clean 137/KILL records whose ended_at falls
#     inside its 15s window (read from notify-exit.log, bounded) and names the
#     affected-session count in the body.
#   - Title via notify_identity_title: repo/branch (session_id), no fallbacks;
#     a title failure suppresses.
#   - Fail-open: never changes the launcher exit status; the shared sender
#     (local macOS Notification Center + optional Pushover) is an immediate
#     detached attempt bounded by the sender's own timeouts.
# Portable bash 3.2+, jq-free; safe under `set -euo pipefail` callers.
set -u

_NOTIFY_SHIPPER_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v notify_exit_dir >/dev/null 2>&1 || . "$_NOTIFY_SHIPPER_LIB/notify-exit-record.sh"
command -v notify_claim_acquire >/dev/null 2>&1 || . "$_NOTIFY_SHIPPER_LIB/notify-claim.sh"
command -v notify_send >/dev/null 2>&1 || . "$_NOTIFY_SHIPPER_LIB/notify-send.sh"
command -v notify_identity_title >/dev/null 2>&1 || . "$_NOTIFY_SHIPPER_LIB/notify-identity.sh"
unset _NOTIFY_SHIPPER_LIB

# days_from_civil (Hinnant): days since 1970-01-01 for a UTC civil date.
_notify_shipper_days_from_civil(){
  local y=$((10#$1)) m=$((10#$2)) d=$((10#$3)) era yoe mp doy doe
  if [ "$m" -le 2 ]; then y=$((y-1)); m=$((m+12)); fi
  if [ "$y" -ge 0 ]; then era=$((y/400)); else era=$(( (y-399)/400 )); fi
  yoe=$((y - era*400))
  mp=$(( (m + 9) % 12 ))
  doy=$(( (153*mp + 2) / 5 + d - 1 ))
  doe=$(( yoe*365 + yoe/4 - yoe/100 + doy ))
  printf '%s\n' $(( era*146097 + doe - 719468 ))
}

# Strict emitter-grammar RFC3339 UTC -> epoch; anything else fails so the
# caller can skip the record.
_notify_shipper_iso_epoch(){
  local s="$1" days
  case "$s" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  days="$(_notify_shipper_days_from_civil "${s:0:4}" "${s:5:2}" "${s:8:2}")" || return 1
  printf '%s\n' $(( days*86400 + 10#${s:11:2}*3600 + 10#${s:14:2}*60 + 10#${s:17:2} ))
  return 0
}

# Count fidelity-clean 137/KILL records with ended_at in [batch, batch+15).
# Best effort and bounded: the emitter rotation already caps the log
# (POLY_NOTIFY_EXIT_LOG_MAX_BYTES, default 64KiB) and this scan stops after
# 400 lines. Only complete v1 records (leading {"v":1,) count, so rotation
# head fragments are never miscounted.
_notify_shipper_count_batch(){
  local log="$1" batch="$2" n=0 lines=0 line e epoch
  [ -f "$log" ] || { printf '0\n'; return 0; }
  while IFS= read -r line; do
    lines=$((lines+1))
    [ "$lines" -gt 400 ] && break
    case "$line" in
      '{"v":1,'*'"exit_status":137,'*'"signal":"KILL"'*) ;;
      *) continue ;;
    esac
    case "$line" in *'"ts_fidelity":"degraded"'*) continue ;; esac
    case "$line" in *'"ended_at":"'*) ;; *) continue ;; esac
    e="${line#*\"ended_at\":\"}"
    e="${e%%\"*}"
    epoch="$(_notify_shipper_iso_epoch "$e")" || continue
    if [ "$epoch" -ge "$batch" ] && [ "$epoch" -lt "$((batch + 15))" ]; then
      n=$((n+1))
    fi
  done < "$log"
  printf '%s\n' "$n"
  return 0
}

# notify_exit_ship <launcher> <session_id|''> <status> <started> <ended> <repo|''> <branch|''> <title|''>
# Reads NOTIFY_EXIT_TS_FIDELITY as set by the just-completed notify_exit_emit.
notify_exit_ship(){
  local launcher="${1:-}" session_id="${2:-}" status="${3:-}" started="${4:-}" ended="${5:-}"
  local repo="${6:-}" branch="${7:-}" title="${8:-}"
  local fidelity="${NOTIFY_EXIT_TS_FIDELITY:-}" signal dir claims batch count
  local ship_title="" ship_body=""
  signal="$(_notify_exit_signal "$status")"
  dir="$(notify_exit_dir)"
  claims="$dir/claims"
  notify_source="$launcher"
  notify_session="${session_id:-unknown}"
  # Closed-world status rule (r3.7): only 137/KILL ships.
  if [ "$status" != "137" ] || [ "$signal" != "KILL" ]; then
    notify_event="suppress"
    notify_diag "suppressed:status=$status,signal=$signal" || true
    return 0
  fi
  # r3.8 fidelity gate: substituted emission times never ship and never
  # correlate; this is the fail-closed void the marker exists to expose.
  if [ "$fidelity" = "degraded" ]; then
    notify_event="suppress"
    notify_diag "suppressed:ts_fidelity=degraded" || true
    return 0
  fi
  if [ -z "$session_id" ]; then
    notify_event="suppress"
    notify_diag "suppressed:no-session" || true
    return 0
  fi
  batch=$(( ended / 15 * 15 ))
  if ! notify_claim_acquire "$claims" "tui-abnormal-batch-$batch"; then
    notify_event="suppress"
    notify_diag "suppressed:claim-loser:batch=$batch" || true
    return 0
  fi
  count="$(_notify_shipper_count_batch "$dir/notify-exit.log" "$batch")"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -ge 1 ] || count=1
  if ! ship_title="$(notify_identity_title "$session_id" "$repo" "$branch" "$title")"; then
    notify_event="suppress"
    notify_diag "suppressed:title-unavailable" || true
    return 0
  fi
  ship_body="$(notify_identity_body "TUI terminated abnormally" "signal KILL" "$count session(s) affected")"
  notify_event="tui_abnormal_exit"
  notify_title="$ship_title"
  notify_body="$ship_body"
  notify_send
  return 0
}
