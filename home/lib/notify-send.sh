#!/usr/bin/env bash
# Fail-open, one-shot Pushover sender. Credentials are environment-only.
set -u

LOG_DIR="${AGENT_NOTIFY_LOG_DIR:-${AGENT_NOTIFY_STATE_DIR:-$HOME/.local/share/polytoken/logs}/notify}"
LOG_FILE="$LOG_DIR/notify.log"
LOG_MAX="${AGENT_NOTIFY_LOG_MAX_BYTES:-8192}"
LOG_ROTATE="${AGENT_NOTIFY_LOG_ROTATIONS:-2}"
notify_diag() {
  local result="$1" status="${2:-}" line
  mkdir -p "$LOG_DIR" 2>/dev/null || return 0
  chmod 700 "$LOG_DIR" 2>/dev/null || true
  local source event session
  source="${notify_source:-unknown}"; event="${notify_event:-unknown}"; session="${notify_session:-unknown}"
  source="${source:0:128}"; event="${event:0:128}"; session="${session:0:128}"
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)|$source|$event|$session|$result"
  [ -n "$status" ] && line="$line|http_status=${status:0:32}"
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE" 2>/dev/null || printf 0)" -ge "$LOG_MAX" ]; then
    local i
    i="$LOG_ROTATE"
    while [ "$i" -gt 0 ]; do
      if [ "$i" -eq 1 ]; then mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true; else mv -f "$LOG_FILE.$((i-1))" "$LOG_FILE.$i" 2>/dev/null || true; fi
      i=$((i-1))
    done
  fi
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}
notify_send() {
  [ -n "${PUSHOVER_APP_TOKEN:-}" ] && [ -n "${PUSHOVER_USER_KEY:-}" ] || return 0
  local url="${AGENT_NOTIFY_PUSHOVER_URL:-https://api.pushover.net/1/messages.json}"
  (
    local status_file="${TMPDIR:-/tmp}/notify-status.$$.tmp"
    curl -sS --fail --max-time 10 -o /dev/null -w '%{http_code}' -X POST "$url" \
      --data-urlencode "token=$PUSHOVER_APP_TOKEN" --data-urlencode "user=$PUSHOVER_USER_KEY" \
      --data-urlencode "title=${notify_title:-}" --data-urlencode "message=${notify_body:-}" >"$status_file" 2>/dev/null
    local rc=$? status="$(cat "$status_file" 2>/dev/null || true)"; rm -f "$status_file"
    [ "$rc" -eq 0 ] && notify_diag sent "$status" || notify_diag rejected "${status:-unknown}"
  ) </dev/null >/dev/null 2>&1 &
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then notify_send; exit 0; fi
