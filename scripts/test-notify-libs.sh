#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -r "$TMP"' EXIT
pass=0; fail=0
# Suite-wide stubs (AC6): the default-on mac Notification Center lane must never
# pop a real alert on a mac dev host, so osascript is replaced with a recorder and
# uname reports Darwin. The Darwin stub also lets the suite's credential-free
# assertions pass on Linux CI. These are installed before any sender runs here.
STUBS="$TMP/stubs"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${2:-}|${3:-}" >> "${OSA_LOG:-/dev/null}"\n' > "$STUBS/osascript"; chmod +x "$STUBS/osascript"
printf '#!/usr/bin/env bash\necho Darwin\n' > "$STUBS/uname"; chmod +x "$STUBS/uname"
export PATH="$STUBS:$PATH"
OSA="$TMP/osacalls"; : > "$OSA"; export OSA_LOG="$OSA"
osacount(){ wc -l < "$OSA" | tr -d ' '; }
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got: $1 expected: $2"; no "$3"; }; }
# Formatter API: notify_identity_title session repo branch title; body reason error question.
run_title(){ bash -c 'source "$1"; notify_identity_title "$2" "$3" "$4" "$5"' _ "$REPO/home/lib/notify-identity.sh" "$@"; }
assert_eq "$(run_title sid repo branch '')" "repo/branch (sid)" "base title"
G="$TMP/gitrepo"; git init -q -b main "$G"; git -C "$G" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; git -C "$G" worktree add -q -b feature "$G/wt" main
assert_eq "$(bash -c 'source "$1"; notify_identity_resolve sid "$2" ""' _ "$REPO/home/lib/notify-identity.sh" "$G/wt")" "gitrepo/feature (sid)" "real worktree branch resolution"
git -C "$G/wt" checkout -q --detach; assert_eq "$(bash -c 'source "$1"; notify_identity_resolve sid "$2" ""' _ "$REPO/home/lib/notify-identity.sh" "$G/wt")" "gitrepo (sid)" "detached head has no branch"
assert_eq "$(run_title sid '(sid)' '' '')" "(sid) (sid)" "resolved session suffix comparison"
assert_eq "$(run_title $'s\033\177' $'r\033\177' $'b\033\177' '')" 'r  /b   (s  )' "all controls sanitized"
assert_eq "$(run_title sid repo '' '')" "repo (sid)" "only repo"
assert_eq "$(run_title sid '' branch '')" "branch (sid)" "only branch"
assert_eq "$(run_title sid '' '' '')" "(sid)" "neither repo nor branch"
assert_eq "$(run_title sid 'r☃' 'feat/ü' 'Ship it')" "r☃/feat/ü (sid) - Ship it" "unicode and slash title"
assert_eq "$(run_title sid repo branch '')" "repo/branch (sid)" "empty title omitted"
if run_title '' repo branch '' >/dev/null 2>&1; then no "missing session id skips"; else ok "missing session id skips"; fi
assert_eq "$(run_title $'s\n\t' $'r\r' $'b\n' $'t\t')" $'r /b  (s  ) - t ' "controls sanitized only"
LONG=$(printf 'x%.0s' $(seq 1 2000)); if run_title sid repo branch "$LONG" >/dev/null 2>&1; then no "oversize skips"; else ok "oversize skips"; fi
# Resolver project-basename fallback: a non-git project dir still names its
# repo (git fails there); with no project dir at all the title is "(<sid>)".
NGPROJ="$TMP/nongit/projdir"; mkdir -p "$NGPROJ"
assert_eq "$(bash -c 'source "$1"; notify_identity_resolve sid "$2" ""' _ "$REPO/home/lib/notify-identity.sh" "$NGPROJ")" "projdir (sid)" "non-git project dir falls back to basename"
assert_eq "$(bash -c 'source "$1"; notify_identity_resolve sid "" ""' _ "$REPO/home/lib/notify-identity.sh")" "(sid)" "absent project dir falls back to sid only"
# Session-title enrichment helper: record.json .session_title beats
# session.json .inferred_title beats .last_user_message_preview; any failure
# yields empty; charset pinned to the hook set; bounded to 48 chars.
run_enrich(){ bash -c 'source "$1"; notify_identity_session_title "$2" "$3"' _ "$REPO/home/lib/notify-identity.sh" "$@"; }
SSDIR="$TMP/sessions"; mkdir -p "$SSDIR/enrA" "$SSDIR/enrB" "$SSDIR/enrC" "$SSDIR/enrE" "$SSDIR/enrF"
printf '%s' '{"session_title":"record title"}' > "$SSDIR/enrA/record.json"
printf '%s' '{"inferred_title":"inferred title","last_user_message_preview":"raw preview"}' > "$SSDIR/enrA/session.json"
assert_eq "$(run_enrich "$SSDIR" enrA)" "record title" "enrichment prefers record.json session_title"
printf '%s' '{"inferred_title":"inferred title","last_user_message_preview":"raw preview"}' > "$SSDIR/enrB/session.json"
assert_eq "$(run_enrich "$SSDIR" enrB)" "inferred title" "enrichment falls back to inferred_title"
printf '%s' '{"last_user_message_preview":"raw preview"}' > "$SSDIR/enrC/session.json"
assert_eq "$(run_enrich "$SSDIR" enrC)" "raw preview" "enrichment falls back to last_user_message_preview"
assert_eq "$(run_enrich "$SSDIR" missing)" "" "enrichment empty on missing session"
assert_eq "$(run_enrich "" enrA)" "" "enrichment empty without sessions dir"
printf '%s' '{"inferred_title":"t:i/tle@x-y_z.w/é"}' > "$SSDIR/enrE/session.json"
assert_eq "$(run_enrich "$SSDIR" enrE)" "t:i/tle@x-y_z.w/" "enrichment charset is alnum plus space . _ / @ : -"
printf '%s' "{\"inferred_title\":\"$(printf 'a%.0s' $(seq 1 60))\"}" > "$SSDIR/enrF/session.json"
assert_eq "$(run_enrich "$SSDIR" enrF)" "$(printf 'a%.0s' $(seq 1 48))" "enrichment bounded to 48 chars"
run_tag(){ bash -c 'source "$1"; notify_alert_tag "$2" "$3"' _ "$REPO/home/lib/notify-identity.sh" "$1" "$2"; }
assert_eq "$(run_tag hook needs_input)" "[hook:needs_input] " "tag hook:needs_input"
assert_eq "$(run_tag sse question_pending)" "[sse:question_pending] " "tag sse:question_pending"
assert_eq "$(run_tag sse approval_pending)" "[sse:approval_pending] " "tag sse:approval_pending"
assert_eq "$(run_tag sse goal_completed)" "[sse:goal_completed] " "tag sse:goal_completed"
assert_eq "$(run_tag watchdog agent_died)" "[watchdog:agent_died] " "tag watchdog:agent_died"
assert_eq "$(run_tag watchdog tui_crash)" "[watchdog:tui_crash] " "tag watchdog:tui_crash"
assert_eq "$(run_tag shipper tui_abnormal_exit)" "[shipper:tui_abnormal_exit] " "tag shipper:tui_abnormal_exit"
# Sender must use one curl, detached, bounded diagnostics, and env-only credentials.
CURL="$TMP/curl"; CALLS="$TMP/calls"; LOGDIR="$TMP/logs"; mkdir -p "$LOGDIR"
printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CALLS"\nexit 22\n' > "$CURL"; chmod +x "$CURL"
PATH="$TMP:$PATH" CALLS="$CALLS" OSA_LOG="$OSA" AGENT_NOTIFY_LOG_DIR="$LOGDIR" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_PUSHOVER_URL=http://127.0.0.1:9 notify_source=test notify_event=stop notify_session=sid notify_title=Title notify_body=Body bash "$REPO/home/lib/notify-send.sh"; sleep .1
for _ in 1 2 3 4 5; do [ -s "$CALLS" ] && break; sleep .05; done
assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" 1 "one failed curl attempt"
# With creds present the mac lane also fires once, with the SAME title/body the
# Pushover sender receives (AC1/AC2 parity through notify_send).
for _ in 1 2 3 4 5; do [ -s "$OSA" ] && break; sleep .05; done
assert_eq "$(osacount)" 1 "mac fires once with creds"
assert_eq "$(cat "$OSA" 2>/dev/null)" "Title|Body" "mac send same title/body as Pushover"
grep -Eq -- --max-time home/lib/notify-send.sh && grep -Eq -- '--max-time 10' home/lib/notify-send.sh && ok "curl timeout bounded" || no "curl timeout bounded"
if grep -Eq -- 'curl .*--fail' home/lib/notify-send.sh && grep -q 'notify_diag rejected' home/lib/notify-send.sh; then ok "HTTP failure flag and rejected result"; else no "HTTP failure flag and rejected result"; fi
AGENT_NOTIFY_LOG_DIR="$LOGDIR" source "$REPO/home/lib/notify-send.sh"
LOG_MAX=64
notify_source="$(printf 's%.0s' $(seq 1 300))" notify_event="$(printf 'e%.0s' $(seq 1 300))" notify_session="$(printf 'i%.0s' $(seq 1 300))" notify_diag failed 500
[ "$(wc -c < "$LOGDIR/notify.log")" -le 8192 ] && ok "caller metadata bounded" || no "caller metadata bounded"
ROT="$TMP/rotation"; mkdir -p "$ROT"; AGENT_NOTIFY_LOG_DIR="$ROT" bash -c 'source "$1"; LOG_MAX=64; for n in 1 2 3 4 5; do notify_source=source notify_event=event notify_session="session-$n-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" notify_diag failed 500; done; [ -f "$2/notify.log.1" ] && [ "$(wc -c < "$2/notify.log")" -le 128 ]' _ "$REPO/home/lib/notify-send.sh" "$ROT" && ok "rotation cap reached" || no "rotation cap reached"
[ -f "$LOGDIR/notify.log" ] && [ "$(stat -c %a "$LOGDIR" 2>/dev/null || stat -f %Lp "$LOGDIR")" = 700 ] && ok "diagnostic log and dir permissions" || no "diagnostic log and dir permissions"
[ -z "$(PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= AGENT_NOTIFY_LOG_DIR="$TMP/missing" bash "$REPO/home/lib/notify-send.sh" 2>&1)" ] && [ ! -e "$TMP/missing" ] && ok "missing credentials silent" || no "missing credentials silent"
[ "$(wc -c < "$LOGDIR/notify.log")" -lt 10000 ] && ok "diagnostic bounded" || no "diagnostic bounded"
# macOS Notification Center module (notify-mac.sh): availability predicate and
# send behavior under a controlled PATH (per-test gating toggles knob/uname/osa).
M="$REPO/home/lib/notify-mac.sh"
# (a) on Darwin with osascript present: exactly one invocation, SAME title/body.
: > "$OSA"
bash -c 'source "$1"; notify_mac_send "Title" "Body"' _ "$M" >/dev/null 2>&1
assert_eq "$(osacount)" 1 "mac send: exactly one invocation"
assert_eq "$(cat "$OSA" 2>/dev/null)" "Title|Body" "mac send: same title/body as Pushover args"
# (b) zero when AGENT_NOTIFY_MAC=0.
: > "$OSA"
AGENT_NOTIFY_MAC=0 bash -c 'source "$1"; notify_mac_send "T" "B"' _ "$M" >/dev/null 2>&1
[ ! -s "$OSA" ] && ok "mac send zero when AGENT_NOTIFY_MAC=0" || no "mac send zero when AGENT_NOTIFY_MAC=0"
# (b) zero when non-Darwin (uname stub reports Linux).
mkdir -p "$TMP/linuxver"; printf '#!/usr/bin/env bash\necho Linux\n' > "$TMP/linuxver/uname"; chmod +x "$TMP/linuxver/uname"
: > "$OSA"
PATH="$TMP/linuxver:$STUBS:$PATH" bash -c 'source "$1"; notify_mac_send "T" "B"' _ "$M" >/dev/null 2>&1
[ ! -s "$OSA" ] && ok "mac send zero on non-Darwin" || no "mac send zero on non-Darwin"
# (b) zero when osascript absent (uname says Darwin but no osascript reachable).
mkdir -p "$TMP/noosa"; printf '#!/usr/bin/env bash\necho Darwin\n' > "$TMP/noosa/uname"; chmod +x "$TMP/noosa/uname"
: > "$OSA"
PATH="$TMP/noosa:/bin" bash -c 'source "$1"; notify_mac_send "T" "B"' _ "$M" >/dev/null 2>&1
[ ! -s "$OSA" ] && ok "mac send zero when osascript absent" || no "mac send zero when osascript absent"
# (c) empty title/body -> zero invocation even when available.
: > "$OSA"
bash -c 'source "$1"; notify_mac_send "" ""' _ "$M" >/dev/null 2>&1
[ ! -s "$OSA" ] && ok "mac send zero on empty title/body" || no "mac send zero on empty title/body"
# (d) the perl alarm(5) backstop is in the module source...
grep -Eq 'alarm[[:space:]]+5' "$M" && ok "module has perl alarm 5 backstop" || no "module has perl alarm 5 backstop"
# (d) ...and a wedged osascript returns well under 5s (AC4).
mkdir -p "$TMP/slow"; printf '#!/usr/bin/env bash\nsleep 30\n' > "$TMP/slow/osascript"; chmod +x "$TMP/slow/osascript"
_s0="$(date +%s)"
PATH="$TMP/slow:$STUBS:$PATH" bash -c 'source "$1"; notify_mac_send "t" "b"' _ "$M" >/dev/null 2>&1
_s1="$(date +%s)"
[ "$((_s1 - _s0))" -lt 8 ] && ok "wedged osascript bounded (<8s)" || no "wedged osascript bounded (<8s)"
# Claim library (notify-claim.sh): atomic exclusive-create claims, restrictive
# perms, exactly one concurrent winner (r3.1/r3.7 claim-boundary contract).
CLAIMS="$TMP/claims"
if [ -f "$REPO/home/lib/notify-claim.sh" ]; then
  # shellcheck source=../home/lib/notify-claim.sh
  . "$REPO/home/lib/notify-claim.sh"
  notify_claim_acquire "$CLAIMS" "k1" && ok "claim acquire succeeds" || no "claim acquire succeeds"
  if notify_claim_acquire "$CLAIMS" "k1" 2>/dev/null; then no "double acquire fails"; else ok "double acquire fails"; fi
  notify_claim_release "$CLAIMS" "k1" && notify_claim_acquire "$CLAIMS" "k1" && ok "release then re-acquire succeeds" || no "release then re-acquire succeeds"
  notify_claim_release "$CLAIMS" "k1" >/dev/null 2>&1
  [ "$(stat -c %a "$CLAIMS" 2>/dev/null || stat -f %Lp "$CLAIMS")" = 700 ] && ok "claims dir 700" || no "claims dir 700"
  notify_claim_acquire "$CLAIMS" "permcheck"
  [ "$(stat -c %a "$CLAIMS/claim.permcheck" 2>/dev/null || stat -f %Lp "$CLAIMS/claim.permcheck")" = 600 ] && ok "claim file 600" || no "claim file 600"
  notify_claim_release "$CLAIMS" "permcheck"
  # Hostile keys cannot escape the claims dir.
  notify_claim_acquire "$CLAIMS" "../escape"
  [ ! -e "$TMP/claim.escape" ] && [ ! -e "$TMP/escape" ] && [ -f "$CLAIMS/claim..._escape" ] && ok "hostile key contained" || no "hostile key contained"
  notify_claim_release "$CLAIMS" "../escape"
  # Concurrent acquirers: N racers, exactly one winner.
  : > "$TMP/winners"
  for i in 1 2 3 4 5 6; do ( notify_claim_acquire "$CLAIMS" race && printf 'w\n' >> "$TMP/winners" ) & done
  wait
  [ "$(wc -l < "$TMP/winners" | tr -d ' ')" = 1 ] && ok "concurrent claim has exactly one winner" || no "concurrent claim has exactly one winner"
  notify_claim_release "$CLAIMS" race
  # Empty arguments are refused, not treated as the default claim.
  if notify_claim_acquire "$CLAIMS" "" 2>/dev/null; then no "empty key refused"; else ok "empty key refused"; fi
  if notify_claim_acquire "" "k" 2>/dev/null; then no "empty dir refused"; else ok "empty dir refused"; fi
else
  no "claim library exists"
fi
[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
