#!/bin/bash
SKILL_ONCE_SESSION_HASH=
SKILL_ONCE_CONFIG_DIR=
SKILL_ONCE_CACHE_DIR=
SKILL_ONCE_CACHE_FILE=
SKILL_ONCE_SESSION_LOCK=
SKILL_ONCE_CLEANUP_LOCK=
SKILL_ONCE_CLEANUP_MARKER=
SKILL_ONCE_SESSION_LOCK_OWNED=0
SKILL_ONCE_CLEANUP_LOCK_OWNED=0
SKILL_ONCE_TMP_FILE=
SKILL_ONCE_TRACE_ACTIVE=0
SKILL_ONCE_TRACE_OP_ID=
SKILL_ONCE_TRACE_DIR=

skill_once_test_fail_point() {
  local label=${1-}
  [ "$SKILL_ONCE_TRACE_ACTIVE" -eq 1 ] || return 1
  [ "${SKILL_ONCE_TEST_FAIL_POINT-}" = "$label" ] || return 1
  case "$label" in
    append) return 0 ;;
    *) return 1 ;;
  esac
}

skill_once_init() {
  local session_id=${1-} cmd
  SKILL_ONCE_SESSION_HASH=; SKILL_ONCE_CONFIG_DIR=; SKILL_ONCE_CACHE_DIR=
  SKILL_ONCE_CACHE_FILE=; SKILL_ONCE_SESSION_LOCK=; SKILL_ONCE_CLEANUP_LOCK=
  SKILL_ONCE_CLEANUP_MARKER=; SKILL_ONCE_SESSION_LOCK_OWNED=0
  SKILL_ONCE_CLEANUP_LOCK_OWNED=0; SKILL_ONCE_TMP_FILE=
  SKILL_ONCE_TRACE_ACTIVE=0; SKILL_ONCE_TRACE_OP_ID=; SKILL_ONCE_TRACE_DIR=
  [ -n "$session_id" ] || return 1
  for cmd in cat cut find grep jq mkdir mktemp mv rm rmdir seq sleep tail; do command -v "$cmd" >/dev/null 2>&1 || return 1; done
  if command -v sha256sum >/dev/null 2>&1; then
    SKILL_ONCE_SESSION_HASH=$(printf '%s' "$session_id" | sha256sum 2>/dev/null | cut -c1-16) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    SKILL_ONCE_SESSION_HASH=$(printf '%s' "$session_id" | shasum -a 256 2>/dev/null | cut -c1-16) || return 1
  else return 1; fi
  [ "${#SKILL_ONCE_SESSION_HASH}" -eq 16 ] || return 1
  SKILL_ONCE_CONFIG_DIR="${AGENT_CONFIG_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
  SKILL_ONCE_CACHE_DIR="$SKILL_ONCE_CONFIG_DIR/skill-once"
  mkdir -p "$SKILL_ONCE_CACHE_DIR" 2>/dev/null || return 1
  SKILL_ONCE_CACHE_FILE="$SKILL_ONCE_CACHE_DIR/session-$SKILL_ONCE_SESSION_HASH.jsonl"
  SKILL_ONCE_SESSION_LOCK="$SKILL_ONCE_CACHE_DIR/.session-$SKILL_ONCE_SESSION_HASH.lock"
  SKILL_ONCE_CLEANUP_LOCK="$SKILL_ONCE_CACHE_DIR/.cleanup.lock"
  SKILL_ONCE_CLEANUP_MARKER="$SKILL_ONCE_CACHE_DIR/.last-cleanup"
}

skill_once_trace_acquired() {
  local id=${1-} dir=${SKILL_ONCE_TEST_TRACE_DIR-}
  if [ -d "$dir" ] && [ -n "${SKILL_ONCE_TEST_OP_ID-}" ] && [ "$id" = "$SKILL_ONCE_TEST_OP_ID" ] && [[ "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    SKILL_ONCE_TRACE_ACTIVE=1; SKILL_ONCE_TRACE_OP_ID=$id; SKILL_ONCE_TRACE_DIR=$dir
    : > "$dir/$id.acquired" 2>/dev/null || { SKILL_ONCE_TRACE_ACTIVE=0; return 0; }
    local i
    for i in $(seq 1 500); do [ ! -e "$dir/$id.hold" ] && return 0; sleep 0.01; done
    skill_once_unlock; return 1
  fi
  SKILL_ONCE_TRACE_ACTIVE=0; SKILL_ONCE_TRACE_OP_ID=; SKILL_ONCE_TRACE_DIR=
}

skill_once_lock() {
  local op=${1-} i
  for i in $(seq 1 50); do
    if mkdir "$SKILL_ONCE_SESSION_LOCK" 2>/dev/null; then
      SKILL_ONCE_SESSION_LOCK_OWNED=1
      skill_once_trace_acquired "$op" || return 1
      return 0
    fi
    [ "$i" -eq 50 ] || sleep 0.01
  done
  return 1
}
skill_once_unlock() {
  if [ "$SKILL_ONCE_SESSION_LOCK_OWNED" -eq 1 ]; then
    rmdir "$SKILL_ONCE_SESSION_LOCK" 2>/dev/null || true
    SKILL_ONCE_SESSION_LOCK_OWNED=0
  fi
  if [ "$SKILL_ONCE_TRACE_ACTIVE" -eq 1 ]; then
    rm -f "$SKILL_ONCE_TRACE_DIR/$SKILL_ONCE_TRACE_OP_ID.acquired" 2>/dev/null || true
    : > "$SKILL_ONCE_TRACE_DIR/$SKILL_ONCE_TRACE_OP_ID.released" 2>/dev/null || true
    SKILL_ONCE_TRACE_ACTIVE=0
  fi
}
skill_once_append() { [ "$SKILL_ONCE_SESSION_LOCK_OWNED" -eq 1 ] || return 1; skill_once_test_fail_point append && return 1; printf '%s\n' "$1" 2>/dev/null >>"$SKILL_ONCE_CACHE_FILE"; }
skill_once_remove() {
  local skill=$1 agent=$2
  [ "$SKILL_ONCE_SESSION_LOCK_OWNED" -eq 1 ] || return 1; [ -f "$SKILL_ONCE_CACHE_FILE" ] || return 0
  SKILL_ONCE_TMP_FILE=$(mktemp "$SKILL_ONCE_CACHE_DIR/.force.XXXXXX") || return 1
  if ! jq -c --arg s "$skill" --arg a "$agent" 'select(.skill != $s or .agent != $a)' "$SKILL_ONCE_CACHE_FILE" >"$SKILL_ONCE_TMP_FILE" 2>/dev/null; then rm -f "$SKILL_ONCE_TMP_FILE" 2>/dev/null || true; SKILL_ONCE_TMP_FILE=; return 1; fi
  if ! mv -f "$SKILL_ONCE_TMP_FILE" "$SKILL_ONCE_CACHE_FILE" 2>/dev/null; then rm -f "$SKILL_ONCE_TMP_FILE" 2>/dev/null || true; SKILL_ONCE_TMP_FILE=; return 1; fi
  SKILL_ONCE_TMP_FILE=
}
skill_once_clear() { [ "$SKILL_ONCE_SESSION_LOCK_OWNED" -eq 1 ] || return 1; [ ! -e "$SKILL_ONCE_CACHE_FILE" ] || rm -f "$SKILL_ONCE_CACHE_FILE" 2>/dev/null; }
skill_once_cleanup_stale() {
  local now=${1-} last=0 f hash i
  [ "$SKILL_ONCE_CLEANUP_LOCK_OWNED" -eq 0 ] || return 1
  for i in $(seq 1 50); do if mkdir "$SKILL_ONCE_CLEANUP_LOCK" 2>/dev/null; then SKILL_ONCE_CLEANUP_LOCK_OWNED=1; break; fi; [ "$i" -eq 50 ] || sleep 0.01; done
  [ "$SKILL_ONCE_CLEANUP_LOCK_OWNED" -eq 1 ] || return 1
  last=$(cat "$SKILL_ONCE_CLEANUP_MARKER" 2>/dev/null || echo 0); [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if [ $((now-last)) -gt 3600 ]; then
    for f in "$SKILL_ONCE_CACHE_DIR"/session-*.jsonl; do [ -f "$f" ] || continue; [ "$(find "$f" -mtime +1 -print -quit 2>/dev/null)" ] || continue
      hash=${f##*/session-}; hash=${hash%.jsonl}; mkdir "$SKILL_ONCE_CACHE_DIR/.session-$hash.lock" 2>/dev/null || continue; rm -f "$f" 2>/dev/null || { rmdir "$SKILL_ONCE_CACHE_DIR/.session-$hash.lock" 2>/dev/null || true; return 1; }; rmdir "$SKILL_ONCE_CACHE_DIR/.session-$hash.lock" 2>/dev/null || return 1
    done
    printf '%s\n' "$now" > "$SKILL_ONCE_CLEANUP_MARKER" 2>/dev/null || return 1
  fi
  rmdir "$SKILL_ONCE_CLEANUP_LOCK" 2>/dev/null || return 1; SKILL_ONCE_CLEANUP_LOCK_OWNED=0
}
skill_once_exit_cleanup() { [ -z "$SKILL_ONCE_TMP_FILE" ] || rm -f "$SKILL_ONCE_TMP_FILE" 2>/dev/null || true; skill_once_unlock; if [ "$SKILL_ONCE_CLEANUP_LOCK_OWNED" -eq 1 ]; then rmdir "$SKILL_ONCE_CLEANUP_LOCK" 2>/dev/null || true; SKILL_ONCE_CLEANUP_LOCK_OWNED=0; fi; }
