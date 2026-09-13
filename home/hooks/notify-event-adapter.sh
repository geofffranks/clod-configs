#!/usr/bin/env bash
# Diagnostic-only SSE adapter. It deliberately has no sender code path.
set -u
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"; . "$_LIB_DIR/notify-policy.sh"; unset _LIB_DIR
LOG_DIR="${AGENT_NOTIFY_ADAPTER_LOG_DIR:-${AGENT_NOTIFY_STATE_DIR:-$HOME/.local/share/polytoken/logs}/notify-adapter}"; LOG="$LOG_DIR/notify.log"; LOCK="$LOG_DIR/adapter.lock"; MAX="${AGENT_NOTIFY_LOG_MAX_BYTES:-8192}"
log(){ mkdir -p "$LOG_DIR" 2>/dev/null || return; chmod 700 "$LOG_DIR" 2>/dev/null || true; printf '%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; chmod 600 "$LOG" 2>/dev/null || true; if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$MAX" ]; then tail -c "$MAX" "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; fi; }
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
mkdir "$LOCK" 2>/dev/null || { log "decision=would-suppress reason=claim-exists"; exit 0; }; trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
startup="${1:-${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/startup.json}"; port="$(jq -r '.port // empty' "$startup" 2>/dev/null || true)"; cred="$(jq -r '.credential_file_path // empty' "$startup" 2>/dev/null || true)"; sid="$(jq -r '.session_id // empty' "$startup" 2>/dev/null || true)"
[ -n "$port" ] && [ -n "$sid" ] || { log "decision=diagnostic-skip reason=missing-session-or-port"; exit 0; }
clock="${AGENT_NOTIFY_TEST_NOW:-$(date +%s)}"; tolerance=5; maxage=120; base="${AGENT_NOTIFY_ADAPTER_URL:-http://127.0.0.1:$port/events}"; state_dir="${AGENT_NOTIFY_ADAPTER_STATE_DIR:-${AGENT_NOTIFY_STATE_DIR:-$HOME/.local/share/polytoken/notify-state}/$sid}"; mkdir -p "$state_dir"; printf '%s\n' "$clock" > "$state_dir/connect-clock"; printf '%s\n' "$clock" > "$state_dir/watermark"
process(){
  local line="$1" emitted emitted_epoch id typ interrogative_type trans reason key decision envelope
  clock="${AGENT_NOTIFY_TEST_NOW:-$(date +%s)}"
  if ! policy_discontinuity "$clock" "$state_dir" >/dev/null 2>&1; then
    log "decision=would-suppress reason=clock-discontinuity buffered-unclaimed=true watermark-rebaselined=true"
    printf '%s\n' "$clock" > "$state_dir/watermark"
    return
  fi
  envelope="$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null || true)"
  [ "$envelope" = "$sid" ] || { log "decision=diagnostic-skip reason=envelope-session-mismatch"; return; }
  emitted="$(printf '%s' "$line" | jq -r '.emitted_at // empty' 2>/dev/null || true)"
  id="$(printf '%s' "$line" | jq -r '.event.interrogative_id // .event.prompt_id // .event.goal.id // empty' 2>/dev/null || true)"
  typ="$(printf '%s' "$line" | jq -r '.event.type // .event.kind // "unknown"' 2>/dev/null || echo unknown)"
  interrogative_type="$(printf '%s' "$line" | jq -r '.event.interrogative_type // empty' 2>/dev/null || true)"
  trans="$(printf '%s' "$line" | jq -r '.event.transition // empty' 2>/dev/null || true)"
  reason="$(printf '%s' "$line" | jq -r '.event.reason // empty' 2>/dev/null || true)"
  [ -n "$id" ] || { log "decision=diagnostic-skip reason=missing-event-id family=$typ"; return; }
  case "$typ" in
    turn|provider|ask_user_question) ;;
    interrogative) case "$interrogative_type" in plan_handoff|goal_proposal) ;; *) log "decision=silent reason=unsupported-event family=$typ interrogative_type=$interrogative_type"; return;; esac ;;
    *) log "decision=silent reason=unsupported-event family=$typ"; return;;
  esac
  emitted_epoch="$(policy_epoch "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=unparseable-emitted_at family=$typ id=$id"; return; }
  decision="$(policy_age_decision "$clock" "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=age-decision-failed family=$typ id=$id"; return; }
  case "$decision" in stale) log "decision=would-suppress reason=stale-processing family=$typ id=$id"; return;; future) log "decision=would-suppress reason=future-emitted_at family=$typ id=$id"; return;; ok) ;; *) log "decision=diagnostic-skip reason=age-decision-unknown family=$typ id=$id"; return;; esac
  key="$(policy_episode_key "$line")"; if [ "$trans" = cleared ]; then log "decision=diagnostic-keyed reason=cleared-transition family=$typ id=$id"; return; fi
  if [ "$typ" = turn_cancelled ] || [ "$typ" = cancellation ] || [ "$reason" = user_cancelled ]; then log "decision=would-suppress reason=shutdown-evidence-unverified family=$typ id=$id"; return; fi
  printf '%s\n' "$emitted_epoch" > "$state_dir/watermark"
  policy_claim "$state_dir" "$key" || { log "decision=would-suppress reason=claim-loser family=$typ id=$id"; return; }
  log "decision=would-send reason=diagnostic-only family=$typ id=$id"
}
[ -f "$cred" ] && bearer="$(jq -r '.token // .credential // empty' "$cred" 2>/dev/null || true)" || bearer=""; args=(-sS -N --max-time 10); [ -n "$bearer" ] && args+=(-H "Authorization: Bearer $bearer"); curl "${args[@]}" "$base" 2>/dev/null | while IFS= read -r line; do case "$line" in data:*) process "${line#data: }";; esac; done
