#!/usr/bin/env bash
# Atomic exclusive-create claim helpers (plan r3.1 claim boundary, r3.7
# lifecycle claim contract). Portable bash 3.2+, jq-free.
#
#   notify_claim_acquire <claims_dir> <key>   0 if acquired, 1 if already claimed
#   notify_claim_release <claims_dir> <key>
#
# Acquisition is a single exclusive-create (`set -C` noclobber redirect,
# O_EXCL semantics): concurrent acquirers yield exactly one winner. Claims
# live in a 700 directory as 600 files.
set -u

# Keys are flattened into a single safe path component: anything outside
# [A-Za-z0-9._-] becomes '_', capped at 128 bytes, so no key can traverse
# out of the claims directory or collide with its "claim." prefix scheme.
_notify_claim_key(){
  LC_ALL=C printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128
}

notify_claim_acquire(){
  local dir="${1:-}" key file
  [ -n "$dir" ] && [ -n "${2:-}" ] || return 1
  key="$(_notify_claim_key "$2")"
  [ -n "$key" ] || return 1
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  file="$dir/claim.$key"
  ( set -C; : > "$file" ) 2>/dev/null || return 1
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

notify_claim_release(){
  local dir="${1:-}" key
  [ -n "$dir" ] && [ -n "${2:-}" ] || return 1
  key="$(_notify_claim_key "$2")"
  [ -n "$key" ] || return 1
  rm -f "$dir/claim.$key" 2>/dev/null || true
  return 0
}
