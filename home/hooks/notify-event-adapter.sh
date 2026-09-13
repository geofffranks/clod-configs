#!/usr/bin/env bash
# Diagnostic-only SSE adapter. It deliberately has no sender code path: every
# outcome is a bounded log record, so nothing here can notify anyone.
set -u
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"; . "$_LIB_DIR/notify-policy.sh"; unset _LIB_DIR
LOG_DIR="${AGENT_NOTIFY_ADAPTER_LOG_DIR:-${AGENT_NOTIFY_STATE_DIR:-$HOME/.local/share/polytoken/logs}/notify-adapter}"; LOG="$LOG_DIR/notify.log"; LOCK="$LOG_DIR/adapter.lock"; MAX="${AGENT_NOTIFY_LOG_MAX_BYTES:-8192}"
log(){ mkdir -p "$LOG_DIR" 2>/dev/null || return; chmod 700 "$LOG_DIR" 2>/dev/null || true; printf '%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG" 2>/dev/null || true; chmod 600 "$LOG" 2>/dev/null || true; if [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$MAX" ]; then tail -c "$MAX" "$LOG" > "$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"; fi; }
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0
mkdir "$LOCK" 2>/dev/null || { log "decision=would-suppress reason=claim-exists"; exit 0; }; trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
startup="${1:-${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}/startup.json}"; port="$(jq -r '.port // empty' "$startup" 2>/dev/null || true)"; cred="$(jq -r '.credential_file_path // empty' "$startup" 2>/dev/null || true)"; sid="$(jq -r '.session_id // empty' "$startup" 2>/dev/null || true)"
[ -n "$port" ] && [ -n "$sid" ] || { log "decision=diagnostic-skip reason=missing-session-or-port"; exit 0; }
# Clock is injectable for tests (file may be rewritten between frames).
clock_read(){ if [ -n "${AGENT_NOTIFY_TEST_CLOCK_FILE:-}" ] && [ -f "$AGENT_NOTIFY_TEST_CLOCK_FILE" ]; then cat "$AGENT_NOTIFY_TEST_CLOCK_FILE" 2>/dev/null; elif [ -n "${AGENT_NOTIFY_TEST_NOW:-}" ]; then printf '%s\n' "$AGENT_NOTIFY_TEST_NOW"; else date +%s; fi; }
tolerance=5; maxage=120; base="${AGENT_NOTIFY_ADAPTER_URL:-http://127.0.0.1:$port/events}"; state_dir="${AGENT_NOTIFY_ADAPTER_STATE_DIR:-${AGENT_NOTIFY_STATE_DIR:-$HOME/.local/share/polytoken/notify-state}/$sid}"; mkdir -p "$state_dir"
# Baseline is per-connection. The watermark is decided-event state: it is only
# created when absent and never lowered by a restart or a clock jump.
clock="$(clock_read)"
if [ "${AGENT_NOTIFY_PRESERVE_STATE:-}" != 1 ]; then printf '%s\n' "$clock" > "$state_dir/connect-clock"; fi
[[ "$(cat "$state_dir/watermark" 2>/dev/null || true)" =~ ^[0-9]+$ ]] || printf '%s\n' "$clock" > "$state_dir/watermark"
# Scalar string extraction; non-string, oversized, or absent -> empty.
jstr(){ printf '%s' "$line" | jq -r "if (.event.$1? | type == \"string\" and length > 0 and length <= 128) then .event.$1 else empty end" 2>/dev/null || true; }
process(){
  local line="$1" emitted emitted_epoch eff pid iid typ interrogative_type trans reason key decision envelope now baseline watermark
  now="$(clock_read)"
  if ! policy_discontinuity "$now" "$state_dir" >/dev/null 2>&1; then
    # Declared jump: every persisted unclaimed candidate is pre-jump evidence.
    for c in "$state_dir"/candidate-*; do
      [ -f "$c" ] || continue
      log "decision=would-suppress reason=discontinuity-stale candidate=${c##*/candidate-}"
      rm -f "$c"
    done
    printf '%s\n' "$now" > "$state_dir/discontinuity-marker"
    log "decision=would-suppress reason=clock-discontinuity buffered-unclaimed=true watermark-rebaselined=decided-only"
    return
  fi
  envelope="$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null || true)"
  [ "$envelope" = "$sid" ] || { log "decision=diagnostic-skip reason=envelope-session-mismatch"; return; }
  emitted="$(printf '%s' "$line" | jq -r '.emitted_at // empty' 2>/dev/null || true)"
  typ="$(jstr type)"; iid="$(jstr interrogative_id)"; pid="$(jstr prompt_id)"
  interrogative_type="$(jstr interrogative_type)"; trans="$(jstr transition)"; reason="$(jstr reason)"
  # Family-required ID validation: each family must present its own required
  # ID as a string scalar. Falling back to another family's ID is forbidden;
  # when both are present the prompt_id is the verified cross-family alias.
  case "$typ" in
    turn_cancelled|model_error) id="$pid" ;;
    ask_user_question|interrogative) id="$iid" ;;
    goal_driver_update) log "decision=silent reason=non-attention-transition family=$typ"; return;;
    *) log "decision=silent reason=unsupported-event family=$typ"; return;;
  esac
  [ -n "$id" ] || { log "decision=diagnostic-skip reason=missing-or-invalid-event-id family=$typ"; return; }
  case "$typ" in
    interrogative) case "$interrogative_type" in plan_handoff|goal_proposal) ;; *) log "decision=silent reason=unsupported-event family=$typ interrogative_type=$interrogative_type"; return;; esac ;;
  esac
  emitted_epoch="$(policy_epoch "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=unparseable-emitted_at family=$typ id=$id"; return; }
  # Discontinuity boundary: pending stream evidence emitted before the declare
  # marker is pre-jump and suppressed. The marker is NOT cleared here — it is
  # cleared only after a frame passes every validation (verified resync).
  if [ -f "$state_dir/discontinuity-marker" ]; then
    marker="$(cat "$state_dir/discontinuity-marker" 2>/dev/null || echo 0)"
    if [ "$emitted_epoch" -lt "$marker" ]; then log "decision=would-suppress reason=discontinuity-stale family=$typ id=$id"; return; fi
  fi
  baseline="$(cat "$state_dir/connect-clock" 2>/dev/null || true)"; watermark="$(cat "$state_dir/watermark" 2>/dev/null || true)"
  key="$(policy_episode_key "$line")"
  if [ "$trans" = cleared ]; then log "decision=diagnostic-keyed reason=cleared-transition family=$typ id=$id"; return; fi
  if [ "${AGENT_NOTIFY_TWO_PHASE:-}" = decide ]; then
    # Decide the persisted candidate: the incoming frame's timestamps are not
    # the episode's evidence and must not validate in its place.
    emitted="$(cat "$state_dir/candidate-$key" 2>/dev/null || true)"; [ -n "$emitted" ] || { log "decision=diagnostic-skip reason=missing-candidate family=$typ id=$id"; return; }
    emitted_epoch="$(policy_epoch "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=unparseable-candidate family=$typ id=$id"; return; }
  fi
  [[ "$baseline" =~ ^[0-9]+$ ]] && [ "$emitted_epoch" -le "$baseline" ] && { log "decision=diagnostic-skip reason=pre-connect-baseline family=$typ id=$id"; return; }
  [[ "$watermark" =~ ^[0-9]+$ ]] && [ "$emitted_epoch" -lt "$watermark" ] && { log "decision=diagnostic-skip reason=stale-watermark family=$typ id=$id"; return; }
  if [ "${AGENT_NOTIFY_TWO_PHASE:-}" != decide ]; then
    # Processing-time freshness gate (decide mode already gated at staging).
    decision="$(policy_age_decision "$now" "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=age-decision-failed family=$typ id=$id"; return; }
    case "$decision" in
      stale) log "decision=would-suppress reason=stale-processing family=$typ id=$id"; return;;
      future) log "decision=would-suppress reason=future-emitted_at family=$typ id=$id"; return;;
      ok) ;;
      *) log "decision=diagnostic-skip reason=age-decision-unknown family=$typ id=$id"; return;;
    esac
  fi
  if [ "${AGENT_NOTIFY_TWO_PHASE:-}" = process ]; then printf '%s\n' "$emitted" > "$state_dir/candidate-$key"; log "decision=claim-candidate age-at-process=$((now-emitted_epoch)) family=$typ id=$id"; return; fi
  # Send-time freshness recheck on every path: fresh clock read at the
  # decision point, applied to the timestamp actually being decided.
  now="$(clock_read)"
  if [ -n "${AGENT_NOTIFY_TEST_FINAL_NOW:-}" ]; then now="$AGENT_NOTIFY_TEST_FINAL_NOW"; fi
  decision="$(policy_age_decision "$now" "$emitted" 2>/dev/null)" || { log "decision=diagnostic-skip reason=age-decision-failed family=$typ id=$id"; return; }
  case "$decision" in
    stale) log "decision=stale-at-send family=$typ id=$id"; rm -f "$state_dir/candidate-$key" 2>/dev/null || true; return;;
    future) log "decision=would-suppress reason=future-emitted_at family=$typ id=$id"; return;;
    ok) ;;
    *) log "decision=diagnostic-skip reason=age-decision-unknown family=$typ id=$id"; return;;
  esac
  # Backward movement between clock observations is a discontinuity at the
  # decision point too: suppress rather than trust the apparent age.
  if ! policy_discontinuity "$now" "$state_dir" >/dev/null 2>&1; then
    log "decision=would-suppress reason=clock-discontinuity-final family=$typ id=$id"
    return
  fi
  rm -f "$state_dir/discontinuity-marker"
  # Cancellation episodes are gated on verified non-shutdown evidence at the
  # shared decision boundary; without it they are suppressed, never sent.
  if [ "$typ" = turn_cancelled ]; then
    if [ "$reason" != user_cancelled ]; then log "decision=silent reason=shutdown-or-hook-blocked family=$typ id=$id"; return; fi
    if ! policy_shutdown_gate "${AGENT_NOTIFY_CANCELLATION_EVIDENCE:-absent}" >/dev/null 2>&1; then log "decision=would-suppress reason=shutdown-gate family=$typ id=$id"; return; fi
  fi
  if ! [[ "$watermark" =~ ^[0-9]+$ ]] || [ "$emitted_epoch" -gt "$watermark" ]; then printf '%s\n' "$emitted_epoch" > "$state_dir/watermark"; fi
  policy_claim "$state_dir" "$key" || { log "decision=would-suppress reason=claim-loser family=$typ id=$id"; return; }
  log "decision=would-send reason=diagnostic-only family=$typ id=$id"
}
[ -f "$cred" ] && bearer="$(jq -r '.token // .credential // empty' "$cred" 2>/dev/null || true)" || bearer=""; args=(-sS -N --max-time 10); [ -n "$bearer" ] && args+=(-H "Authorization: Bearer $bearer"); curl "${args[@]}" "$base" 2>/dev/null | while IFS= read -r line; do case "$line" in data:*) process "${line#data: }";; esac; done
