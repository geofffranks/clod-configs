#!/usr/bin/env bash
# Focused suite for home/lib/notify-event-watcher.sh (Slice 2, plan-002 r3.9
# attention mappings + r3.1 freshness/claim contracts). Drives process_frame
# directly with frames copied verbatim from the r3.9 real-session capture —
# no sockets, no network, no credentials. Mock curl is placed on PATH for the
# whole run so nothing can dial out.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -r "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "ok: $1"; pass=$((pass+1)); }; no(){ echo "FAIL: $1"; fail=$((fail+1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || { echo "got: [$1] expected: [$2]"; no "$3"; }; }

NW_LIB="$REPO/home/lib/notify-event-watcher.sh"
FIXTURE="$REPO/scripts/fixtures/probe-frames.jsonl"

# Mock curl: log and refuse, guaranteeing no network egress from the suite.
printf '#!/usr/bin/env bash\nprintf "curl %%s\\n" "$*" >> "%s/curl.calls"\nexit 7\n' "$TMP" > "$TMP/curl"
chmod +x "$TMP/curl"

# Fixed whole-second epochs for the fixture frames (GNU/BSD date -verified).
E_ASK1=1789354455      # seq 1472 2026-09-14T02:54:15Z
E_ASK2=1789354732      # seq 5704 2026-09-14T02:58:52Z
E_PLAN=1789355093      # seq 10452 2026-09-14T03:04:53Z
E_GOAL_DONE=1789355212 # seq 14493 2026-09-14T03:06:52Z
E_GOAL_PROP=1789355216 # seq 14570 2026-09-14T03:06:56Z

fx(){ grep -m1 "\"seq\":$1," "$FIXTURE" | sed 's/^data: //'; }

# pf <state_root> <now_epoch> <frame_json> -> prints captured send lines (kind|key|session|body)
pf(){
  local out="$TMP/pf.out"; : > "$out"
  NOTIFY_WATCHER_STATE_ROOT="$1" NOTIFY_WATCHER_TEST_CAP="$out" \
    bash -c '
      source "$1" || exit 9
      cap_send(){ printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$NOTIFY_WATCHER_TEST_CAP"; }
      NOTIFY_WATCHER_SENDER=cap_send
      notify_watcher_process_frame "$2" "$3"
    ' _ "$NW_LIB" "$3" "$2" >/dev/null 2>&1
  cat "$out" 2>/dev/null
}
# number of send lines a pf case produced
pf_n(){ pf "$@" | wc -l | tr -d ' '; }
fresh(){ mkdir -p "$TMP/$1"; printf '%s' "$TMP/$1"; }

# --- library presence -------------------------------------------------------
if [ -f "$NW_LIB" ]; then ok "watcher library exists"; else no "watcher library exists"; fi

# --- epoch parsing (portable RFC3339 -> whole-second epoch) -----------------
if source "$NW_LIB" 2>/dev/null; then
  assert_eq "$(notify_watcher_epoch '2026-09-14T02:54:15.539562201Z' 2>/dev/null)" "$E_ASK1" "epoch parses RFC3339 with fraction"
  assert_eq "$(notify_watcher_epoch '2026-09-14T02:54:15Z' 2>/dev/null)" "$E_ASK1" "epoch parses RFC3339 without fraction"
  if notify_watcher_epoch 'not-a-timestamp' >/dev/null 2>&1; then no "epoch rejects malformed"; else ok "epoch rejects malformed"; fi
else
  no "watcher library sources"
fi

# --- mapping: one send per RT-verified pending ------------------------------
R=$(fresh map1)
assert_eq "$(pf "$R" $((E_ASK1+1)) "$(fx 1472)")" \
  "question_pending|01a09dd6-31f3-7530-b368-5ca3f5bd42d9|0b1k44-audio|1 question needs your answer — What should happen with the untracked file \`scripts/capture-probe-events.s" \
  "ask_user_question maps question_pending with count and bounded first question"
assert_eq "$(pf "$R" $((E_PLAN+1)) "$(fx 10452)")" \
  "approval_pending|01a09ddf-ec3b-7822-b95f-85ace3e81239|0b1k44-audio|approve plan handoff" \
  "plan_handoff interrogative maps approval_pending"
assert_eq "$(pf "$R" $((E_GOAL_PROP+1)) "$(fx 14570)")" \
  "approval_pending|01a09de1-cd72-7db1-9995-6f35ba4b4a33|0b1k44-audio|accept goal proposal" \
  "goal_proposal interrogative maps approval_pending"
assert_eq "$(pf "$R" $((E_GOAL_DONE+1)) "$(fx 14493)" | cut -c1-72)" \
  "goal_completed|01a09ddf-f4af-7080-912e-52c64d6e97dc:completed|0b1k44-audio|goal completed: Read and implement fully the plan file /home/dev/.l" \
  "goal_driver_update completed maps goal_completed with goal.id:completed claim key"

# --- claim dedup: re-render / duplicate representation ----------------------
assert_eq "$(pf_n "$R" $((E_ASK1+2)) "$(fx 1472)")" 0 "duplicate interrogative frame is claim-deduped"
assert_eq "$(pf_n "$R" $((E_GOAL_DONE+2)) "$(fx 14493 | jq -c '.seq=14494')")" 0 \
  "second goal_completed frame claims once per goal.id even at a new seq"
assert_eq "$(pf_n "$R" $((E_PLAN+2)) "$(fx 10452)")" 0 "plan_handoff re-render deduped"

# --- baseline: first frame starts the cursor; replay never notifies ---------
R=$(fresh base1)
assert_eq "$(pf_n "$R" $((E_ASK2+1)) "$(fx 5704)")" 1 "first post-connect frame is eligible (baseline starts at first frame)"
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472)")" 0 "frame below cursor seq is skipped as replay"

# --- silence: every non-mapped family and transition ------------------------
for s in 128 129 130 556 11962; do
  R=$(fresh "sil$s")
  assert_eq "$(pf_n "$R" $((E_ASK1+3)) "$(fx $s)")" 0 "seq $s $(fx "$s" | jq -r .event.type) stays silent"
done
R=$(fresh silacc)
assert_eq "$(pf_n "$R" $((E_GOAL_PROP+2)) "$(fx 14571)")" 0 "goal_driver_update accepted stays silent"

# --- allowlist: unmapped interrogative types are silent ---------------------
R=$(fresh silperm)
assert_eq "$(pf_n "$R" $((E_PLAN+3)) "$(fx 10452 | jq -c '.event.interrogative_type="permission"')")" 0 \
  "permission interrogative is outside the allowlist"

# --- freshness (plan r3.1) --------------------------------------------------
R=$(fresh stale)
assert_eq "$(pf_n "$R" $((E_ASK1+121)) "$(fx 1472)")" 0 "event older than 120s at processing is skipped stale"
R=$(fresh future)
assert_eq "$(pf_n "$R" $((E_ASK1-6)) "$(fx 1472)")" 0 "emitted_at more than +5s in the future is skipped unverifiable"
R=$(fresh boundary)
assert_eq "$(pf_n "$R" "$E_ASK1" "$(fx 1472)")" 1 "age exactly at tolerance boundary still processes"

# --- malformed / missing emitted_at: diagnostic-skip ------------------------
R=$(fresh malformed)
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472 | jq -c '.emitted_at="yesterday"')")" 0 "malformed emitted_at skips"
R=$(fresh missing)
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472 | jq -c 'del(.emitted_at)')")" 0 "missing emitted_at skips"

# --- missing interrogative_id: skip, never synthesize -----------------------
R=$(fresh noid)
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472 | jq -c 'del(.event.interrogative_id)')")" 0 \
  "missing interrogative_id diagnostic-skips without a synthetic key"

# --- clock-discontinuity backstop (plan r3.1) -------------------------------
R=$(fresh disc)
pf "$R" $((E_ASK1+1)) "$(fx 1472)" >/dev/null
assert_eq "$(pf_n "$R" $((E_ASK1+1-60)) "$(fx 5704)")" 0 "backward clock jump beyond +5s suppresses the frame"
assert_eq "$(pf_n "$R" $((E_ASK1+1-58)) "$(fx 5704)")" 1 "post-rebaseline frames evaluate normally again"

# --- discovery: ready sessions with a port ----------------------------------
SD="$TMP/sessions"; mkdir -p "$SD/a" "$SD/b" "$SD/c"
printf '{"state":"ready","session_id":"a","port":42967,"credential_file_path":"%s/a/credential.json"}' "$SD/a" > "$SD/a/startup.json"
printf '{"state":"starting","session_id":"b","port":42968}' > "$SD/b/startup.json"
printf '{"state":"ready","session_id":"c"}' > "$SD/c/startup.json"
printf '{"kind":"bearer","token":"tok-abc","version":1}' > "$SD/a/credential.json"
if source "$NW_LIB" 2>/dev/null; then
  assert_eq "$(NOTIFY_WATCHER_SESSIONS_DIR="$SD" notify_watcher_discover 2>/dev/null)" "$SD/a" "discovery lists only ready sessions with a port"
  assert_eq "$(notify_watcher_curl_args "$SD/a" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')" \
    "-sS -N --max-time 0 -H Authorization: Bearer tok-abc http://127.0.0.1:42967/events" \
    "curl args use Bearer token verbatim from credential.json"
else
  no "watcher library sources (discovery)"
fi

# --- production sender wiring: notify_identity_title + notify_send ----------
SEND_LOG="$TMP/send.log"
bash -c '
  source "$1" || exit 9
  notify_send(){ printf "%s\n" "title=$notify_title body=$notify_body" >> "$2"; }
  notify_watcher_default_send sess-1 question_pending k1 "1 question needs your answer"
' _ "$NW_LIB" "$SEND_LOG" >/dev/null 2>&1
assert_eq "$(cat "$SEND_LOG" 2>/dev/null)" "title=(sess-1) body=1 question needs your answer" \
  "default sender composes identity title and sends via notify_send"

# --- nothing dialed out -----------------------------------------------------
[ -e "$TMP/curl.calls" ] && no "suite made no network calls" || ok "suite made no network calls"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
