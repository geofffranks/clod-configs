#!/bin/bash
# Fetch monthly usage-credit spend from Anthropic and cache it for statusline.sh.
#
# The statusline stdin payload carries no plan/billing data at all (rate_limits is
# null on enterprise / API-provider sessions), so the monthly credit figure shown
# by /usage has to be fetched from the API ourselves. This script does that
# out-of-band and writes a tiny cache file; statusline.sh only ever reads the
# cache, so rendering stays instant and never touches the network.
#
# Cache: $CLAUDE_CONFIG_DIR/.usage-cache.json
#   { "used": 131.24, "limit": 200, "currency": "USD",
#     "percent": 66, "fetched_at": 1788458328 }
# On failure the previous cache is left untouched (stale data beats no data) and
# a non-zero exit is returned.
#
# Auth: OAuth access token from the macOS Keychain item "Claude Code-credentials"
# (the same credential Claude Code itself uses). The token is held in a variable
# for the length of one curl call and is never written to disk.

set -uo pipefail

CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE="$CFG/.usage-cache.json"
LOCK="$CFG/.usage-cache.lock"
LOCK_STALE_SECS=60

command -v jq >/dev/null 2>&1 || exit 1
command -v curl >/dev/null 2>&1 || exit 1
command -v security >/dev/null 2>&1 || exit 1

# ---- single-flight ----
# statusline.sh runs once a second in every open session, so without a lock one
# stale cache would fire a burst of concurrent fetches. mkdir is atomic; a lock
# older than LOCK_STALE_SECS is assumed orphaned and reclaimed.
if ! mkdir "$LOCK" 2>/dev/null; then
  MT=$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)
  case "$MT" in
    ''|*[!0-9]*) exit 0 ;;
    *)
      [ $(( $(date +%s) - MT )) -lt "$LOCK_STALE_SECS" ] && exit 0
      rmdir "$LOCK" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null || exit 0
      ;;
  esac
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ---- credentials ----
CREDS=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || exit 1
TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$CREDS" 2>/dev/null)
[ -z "$TOKEN" ] && exit 1

# expiresAt is epoch milliseconds. An expired token would just 401, so bail early
# rather than letting a logged-out machine poll the endpoint every few minutes.
EXP=$(jq -r '.claudeAiOauth.expiresAt // empty' <<<"$CREDS" 2>/dev/null)
case "$EXP" in
  ''|*[!0-9]*) ;;
  *) [ $(( EXP / 1000 )) -le "$(date +%s)" ] && exit 1 ;;
esac

# ---- fetch ----
BODY=$(curl -sf --max-time 10 \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "anthropic-beta: oauth-2025-04-20" \
  https://api.anthropic.com/api/oauth/usage) || exit 1

# Prefer .spend (minor units with an explicit exponent); fall back to
# .extra_usage, whose used_credits/monthly_limit are minor units scaled by
# .decimal_places. Emit nothing if neither block carries a limit.
OUT=$(jq -c --argjson now "$(date +%s)" '
  def money($minor; $exp): if $minor == null then null else $minor / pow(10; $exp) end;

  (if (.spend.limit.amount_minor // null) != null then
     { used:     money(.spend.used.amount_minor;  (.spend.used.exponent  // 2)),
       limit:    money(.spend.limit.amount_minor; (.spend.limit.exponent // 2)),
       currency: (.spend.used.currency // .spend.limit.currency // "USD"),
       percent:  .spend.percent }
   elif (.extra_usage.monthly_limit // null) != null then
     { used:     money(.extra_usage.used_credits;  (.extra_usage.decimal_places // 2)),
       limit:    money(.extra_usage.monthly_limit; (.extra_usage.decimal_places // 2)),
       currency: (.extra_usage.currency // "USD"),
       percent:  .extra_usage.utilization }
   else null end)
  | if . == null or .used == null or .limit == null then empty else
      .percent = (if .percent != null then (.percent | round)
                  elif .limit > 0 then (.used / .limit * 100 | round)
                  else 0 end)
      | .fetched_at = $now
    end
' <<<"$BODY" 2>/dev/null)

[ -z "$OUT" ] && exit 1

# atomic replace, so a concurrent statusline read never sees a partial file
TMP=$(mktemp "$CACHE.XXXXXX") || exit 1
if printf '%s\n' "$OUT" > "$TMP"; then
  mv -f "$TMP" "$CACHE" || { rm -f "$TMP"; exit 1; }
else
  rm -f "$TMP"
  exit 1
fi
