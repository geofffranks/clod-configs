#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -r "$TMP"' EXIT
pass=0; fail=0
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
# Sender must use one curl, detached, bounded diagnostics, and env-only credentials.
CURL="$TMP/curl"; CALLS="$TMP/calls"; LOGDIR="$TMP/logs"; mkdir -p "$LOGDIR"
printf '#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$CALLS"\nexit 22\n' > "$CURL"; chmod +x "$CURL"
PATH="$TMP:$PATH" CALLS="$CALLS" AGENT_NOTIFY_LOG_DIR="$LOGDIR" PUSHOVER_APP_TOKEN=app PUSHOVER_USER_KEY=user AGENT_NOTIFY_PUSHOVER_URL=http://127.0.0.1:9 notify_source=test notify_event=stop notify_session=sid notify_title=Title notify_body=Body bash "$REPO/home/lib/notify-send.sh"; sleep .1
for _ in 1 2 3 4 5; do [ -s "$CALLS" ] && break; sleep .05; done
assert_eq "$(wc -l < "$CALLS" | tr -d ' ')" 1 "one failed curl attempt"
grep -Eq -- --max-time home/lib/notify-send.sh && grep -Eq -- '--max-time 10' home/lib/notify-send.sh && ok "curl timeout bounded" || no "curl timeout bounded"
source "$REPO/home/lib/notify-send.sh"
LOG_MAX=64
notify_source="$(printf 's%.0s' $(seq 1 300))" notify_event="$(printf 'e%.0s' $(seq 1 300))" notify_session="$(printf 'i%.0s' $(seq 1 300))" notify_diag failed 500
[ "$(wc -c < "$LOGDIR/notify.log")" -le 8192 ] && ok "caller metadata bounded" || no "caller metadata bounded"
ROT="$TMP/rotation"; mkdir -p "$ROT"; AGENT_NOTIFY_LOG_DIR="$ROT" bash -c 'source "$1"; LOG_MAX=64; for n in 1 2 3 4 5; do notify_source=source notify_event=event notify_session="session-$n-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" notify_diag failed 500; done; [ -f "$2/notify.log.1" ] && [ "$(wc -c < "$2/notify.log")" -le 128 ]' _ "$REPO/home/lib/notify-send.sh" "$ROT" && ok "rotation cap reached" || no "rotation cap reached"
[ -f "$LOGDIR/notify.log" ] && [ "$(stat -c %a "$LOGDIR" 2>/dev/null || stat -f %Lp "$LOGDIR")" = 700 ] && ok "diagnostic log and dir permissions" || no "diagnostic log and dir permissions"
[ -z "$(PUSHOVER_APP_TOKEN= PUSHOVER_USER_KEY= AGENT_NOTIFY_LOG_DIR="$TMP/missing" bash "$REPO/home/lib/notify-send.sh" 2>&1)" ] && [ ! -e "$TMP/missing" ] && ok "missing credentials silent" || no "missing credentials silent"
[ "$(wc -c < "$LOGDIR/notify.log")" -lt 10000 ] && ok "diagnostic bounded" || no "diagnostic bounded"
[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
