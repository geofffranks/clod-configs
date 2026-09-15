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
E_CANCEL=1789355136    # seq 11962 2026-09-14T03:05:36Z
E_PERM=1789355400      # seq 20001 (mirror-derived) 2026-09-14T03:10:00Z
E_PERM_REAL=1789446641  # real captured null-seq interrogative 2026-09-15T04:30:41Z (seq:null)

fx(){ grep -m1 "\"seq\":$1," "$FIXTURE" | sed 's/^data: //'; }
fx_iid(){ grep -m1 "\"interrogative_id\":\"$1\"" "$FIXTURE" | sed 's/^data: //'; }

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
out="$(pf "$R" $((E_ASK1+1)) "$(fx 1472)")"
case "$out" in
  "0b1k44-audio|question_pending|01a09dd6-31f3-7530-b368-5ca3f5bd42d9|1 question needs your answer"*) ok "ask_user_question maps question_pending with count and bounded first question" ;;
  *) echo "got: [$out]"; no "ask_user_question maps question_pending with count and bounded first question" ;;
esac
[ "${#out}" -le 200 ] && ok "ask body is bounded" || no "ask body is bounded"
assert_eq "$(pf "$R" $((E_PLAN+1)) "$(fx 10452)")" \
  "0b1k44-audio|approval_pending|01a09ddf-ec3b-7822-b95f-85ace3e81239|approve plan handoff" \
  "plan_handoff interrogative maps approval_pending"
assert_eq "$(pf "$R" $((E_GOAL_PROP+1)) "$(fx 14570)")" \
  "0b1k44-audio|approval_pending|01a09de1-cd72-7db1-9995-6f35ba4b4a33|accept goal proposal" \
  "goal_proposal interrogative maps approval_pending"
R=$(fresh mapgoal)
out="$(pf "$R" $((E_GOAL_DONE+1)) "$(fx 14493)")"
case "$out" in
  "0b1k44-audio|goal_completed|01a09ddf-f4af-7080-912e-52c64d6e97dc:completed|goal completed: Read and implement fully"*) ok "goal_driver_update completed maps goal_completed with goal.id:completed claim key" ;;
  *) echo "got: [$out]"; no "goal_driver_update completed maps goal_completed with goal.id:completed claim key" ;;
esac
[ "${#out}" -le 320 ] && ok "goal_completed body is bounded" || no "goal_completed body is bounded"

# --- claim dedup: re-render / duplicate representation ----------------------
assert_eq "$(pf_n "$R" $((E_ASK1+2)) "$(fx 1472)")" 0 "duplicate interrogative frame is claim-deduped"
assert_eq "$(pf_n "$R" $((E_ASK1+3)) "$(fx 1472 | jq -c '.seq=1473')")" 0 \
  "same interrogative at a new seq is claim-deduped (re-render)"
assert_eq "$(pf_n "$R" $((E_GOAL_DONE+2)) "$(fx 14493 | jq -c '.seq=14494')")" 0 \
  "second goal_completed frame claims once per goal.id even at a new seq"
assert_eq "$(pf_n "$R" $((E_PLAN+2)) "$(fx 10452)")" 0 "plan_handoff re-render deduped"

# --- F10: the dedupe asserts above must run in a root whose cursor is BELOW ---
# --- the deduped seqs, so they genuinely reach notify_claim_acquire. Re-run  ---
# --- the three replay-masked asserts in a fresh root seeded by seq 130.     ---
R=$(fresh claimroot)
assert_eq "$(pf_n "$R" $((E_ASK1+3)) "$(fx 130)")" 0 "seed frame seq 130 (hook_fired) stays silent"
assert_eq "$(pf_n "$R" $((E_ASK1+4)) "$(fx 1472)")" 1 "claim root: first question frame sends (cursor below)"
assert_eq "$(pf_n "$R" $((E_ASK1+5)) "$(fx 1472)")" 0 "claim root: duplicate interrogative frame is claim-deduped (not replay)"
assert_eq "$(pf_n "$R" $((E_ASK1+6)) "$(fx 1472 | jq -c '.seq=1473')")" 0 \
  "claim root: same interrogative at a new seq is claim-deduped (re-render, not replay)"
assert_eq "$(pf_n "$R" $((E_PLAN+1)) "$(fx 10452)")" 1 "claim root: plan_handoff frame sends (cursor below)"
assert_eq "$(pf_n "$R" $((E_PLAN+2)) "$(fx 10452)")" 0 "claim root: plan_handoff re-render deduped (not replay)"

# --- mapping: turn_cancelled -> cancel push ---------------------------------
R=$(fresh cancel1)
out="$(pf "$R" $((E_CANCEL+1)) "$(fx 11962)")"
case "$out" in
  "0b1k44-audio|turn_cancelled|01a09ddf-f4c8-71d0-b97e-5f656a9dd8f3:cancelled|turn cancelled — user_cancelled"*) ok "turn_cancelled maps cancel push with prompt_id:cancelled claim and bounded reason" ;;
  *) echo "got: [$out]"; no "turn_cancelled maps cancel push with prompt_id:cancelled claim and bounded reason" ;;
esac
[ "${#out}" -le 200 ] && ok "cancel body is bounded" || no "cancel body is bounded"
assert_eq "$(pf_n "$R" $((E_CANCEL+2)) "$(fx 11962 | jq -c '.seq=11963')")" 0 \
  "same turn_cancelled at a new seq is claim-deduped (re-render)"
R=$(fresh cancel2)
assert_eq "$(pf "$R" $((E_CANCEL+1)) "$(fx 11962 | jq -c 'del(.event.reason)')")" \
  "0b1k44-audio|turn_cancelled|01a09ddf-f4c8-71d0-b97e-5f656a9dd8f3:cancelled|turn cancelled" \
  "turn_cancelled without reason sends body with no trailing separator"
R=$(fresh cancel3)
assert_eq "$(pf_n "$R" $((E_CANCEL+1)) "$(fx 11962 | jq -c 'del(.event.prompt_id)')")" 0 \
  "turn_cancelled missing prompt_id diagnostic-skips without a synthetic key"
R=$(fresh cancel4)
pf "$R" $((E_GOAL_PROP+2)) "$(fx 14571)" >/dev/null
assert_eq "$(pf_n "$R" $((E_CANCEL+2)) "$(fx 11962)")" 0 \
  "turn_cancelled at or below cursor seq is skipped as replay"
R=$(fresh cancel5)
assert_eq "$(pf_n "$R" $((E_CANCEL+121)) "$(fx 11962)")" 0 \
  "stale turn_cancelled older than 120s stays silent"

# --- F1: long reason is cut at exactly 80 chars for the variable part -------
long_reason="$(printf 'r%.0s' $(seq 1 130))"
R=$(fresh cancel6)
out="$(pf "$R" $((E_CANCEL+1)) "$(fx 11962 | jq -c --arg r "$long_reason" '.event.reason=$r')")"
expected="0b1k44-audio|turn_cancelled|01a09ddf-f4c8-71d0-b97e-5f656a9dd8f3:cancelled|turn cancelled — $long_reason"
[ "${#expected}" -gt 200 ] || no "F1 cancel case: expected value should exceed the uncut bound"
expected="0b1k44-audio|turn_cancelled|01a09ddf-f4c8-71d0-b97e-5f656a9dd8f3:cancelled|turn cancelled — $(printf 'r%.0s' $(seq 1 80))"
assert_eq "$out" "$expected" "turn_cancelled with >80-char reason cuts reason at exactly 80 chars"
[ "${#out}" -le 200 ] && ok "cancel body with long reason stays bounded" || no "cancel body with long reason stays bounded"

# --- baseline: first frame starts the cursor; replay never notifies ---------
R=$(fresh base1)
assert_eq "$(pf_n "$R" $((E_ASK2+1)) "$(fx 5704)")" 1 "first post-connect frame is eligible (baseline starts at first frame)"
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472)")" 0 "frame below cursor seq is skipped as replay"

# --- silence: every non-mapped family and transition ------------------------
for s in 128 129 130 556; do
  R=$(fresh "sil$s")
  assert_eq "$(pf_n "$R" $((E_ASK1+3)) "$(fx $s)")" 0 "seq $s $(fx "$s" | jq -r .event.type) stays silent"
done
R=$(fresh silacc)
assert_eq "$(pf_n "$R" $((E_GOAL_PROP+2)) "$(fx 14571)")" 0 "goal_driver_update accepted stays silent"

# --- allowlist: permission interrogatives now map; other subtypes silent ----
R=$(fresh silperm)
assert_eq "$(pf "$R" $((E_PLAN+3)) "$(fx 10452 | jq -c '.event.interrogative_type="permission" | .event.permission_tool_call={"tool_name":"shell_exec","tool_use_id":"t1","input":{"executable":"git"}}')")" \
  "0b1k44-audio|approval_pending|01a09ddf-ec3b-7822-b95f-85ace3e81239|permission needed: shell_exec" \
  "permission interrogative maps approval_pending with tool name only"
R=$(fresh silperm2)
assert_eq "$(pf_n "$R" $((E_PLAN+3)) "$(fx 10452 | jq -c '.event.interrogative_type="something_else"')")" 0 \
  "unmapped interrogative subtype stays silent"

# --- mapping: permission interrogative (mirror-derived fixture) -------------
R=$(fresh perm1)
out="$(pf "$R" $((E_PERM+1)) "$(fx 20001)")"
assert_eq "$out" "0b1k44-audio|approval_pending|01a09de2-6b88-7360-8697-979523062e33|permission needed: bash" \
  "permission interrogative fixture maps approval_pending with tool name"
case "$out" in *CANARY*) no "permission body never leaks permission_tool_call.input" ;; *) ok "permission body never leaks permission_tool_call.input" ;; esac
[ "${#out}" -le 200 ] && ok "permission body is bounded" || no "permission body is bounded"
assert_eq "$(pf_n "$R" $((E_PERM+2)) "$(fx 20001 | jq -c '.seq=20002')")" 0 \
  "same permission interrogative at a new seq is claim-deduped (re-render)"
R=$(fresh perm2)
assert_eq "$(pf_n "$R" $((E_PERM+1)) "$(fx 20001 | jq -c 'del(.event.interrogative_id)')")" 0 \
  "permission interrogative missing interrogative_id diagnostic-skips"
R=$(fresh perm3)
assert_eq "$(pf "$R" $((E_PERM+1)) "$(fx 20001 | jq -c 'del(.event.permission_tool_call)')")" \
  "0b1k44-audio|approval_pending|01a09de2-6b88-7360-8697-979523062e33|permission needed to run a command" \
  "permission interrogative without permission_tool_call uses generic body"
R=$(fresh perm4)
assert_eq "$(pf_n "$R" $((E_PERM+121)) "$(fx 20001)")" 0 \
  "stale permission interrogative older than 120s stays silent"

# --- mapping: real captured null-seq permission interrogative ---------------
R=$(fresh permreal)
out="$(pf "$R" $((E_PERM_REAL+1)) "$(fx_iid 01a0a335-b361-7c61-8233-b13e1bb66a19)")"
assert_eq "$out" \
  "0b44fs-deal|approval_pending|01a0a335-b361-7c61-8233-b13e1bb66a19|permission needed: shell_exec" \
  "real null-seq permission interrogative maps approval_pending without leaking input"
case "$out" in *mktemp*) no "real permission body never leaks captured command input" ;; *) ok "real permission body never leaks captured command input" ;; esac
[ ! -f "$R/watch/0b44fs-deal/cursor" ] && ok "cursorless permission frame does not create a cursor" || no "cursorless permission frame does not create a cursor"
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472)")" 1 \
  "normal sequenced frame still sends after cursorless permission frame"
assert_eq "$(pf_n "$R" $((E_PERM_REAL+2)) "$(fx_iid 01a0a335-b361-7c61-8233-b13e1bb66a19)")" 0 \
  "same null-seq permission interrogative re-render is claim-deduped"
R=$(fresh permrealstale)
assert_eq "$(pf_n "$R" $((E_PERM_REAL+121)) "$(fx_iid 01a0a335-b361-7c61-8233-b13e1bb66a19)")" 0 \
  "stale null-seq permission interrogative older than 120s stays silent"
R=$(fresh permrealnoid)
assert_eq "$(pf_n "$R" $((E_PERM_REAL+1)) "$(fx_iid 01a0a335-b361-7c61-8233-b13e1bb66a19 | jq -c 'del(.event.interrogative_id)')")" 0 \
  "null-seq permission interrogative missing interrogative_id stays silent"
R=$(fresh permrealnullother)
assert_eq "$(pf_n "$R" $((E_ASK1+1)) "$(fx 1472 | jq -c '.seq=null')")" 0 \
  "null-seq non-interrogative remains bad-seq skipped"
R=$(fresh permrealgeneric)
assert_eq "$(pf "$R" $((E_PERM_REAL+1)) "$(fx_iid 01a0a335-b361-7c61-8233-b13e1bb66a19 | jq -c 'del(.event.permission_tool_call)')")" \
  "0b44fs-deal|approval_pending|01a0a335-b361-7c61-8233-b13e1bb66a19|permission needed to run a command" \
  "null-seq permission without permission_tool_call uses generic body"

# --- F1: long tool_name is cut at exactly 80 chars for the variable part ----
long_tool="$(printf 't%.0s' $(seq 1 130))"
R=$(fresh perm5)
out="$(pf "$R" $((E_PERM+1)) "$(fx 20001 | jq -c --arg t "$long_tool" '.event.permission_tool_call.tool_name=$t')")"
expected="0b1k44-audio|approval_pending|01a09de2-6b88-7360-8697-979523062e33|permission needed: $(printf 't%.0s' $(seq 1 80))"
assert_eq "$out" "$expected" "permission interrogative with >80-char tool_name cuts at exactly 80 chars"
[ "${#out}" -le 200 ] && ok "permission body with long tool_name stays bounded" || no "permission body with long tool_name stays bounded"

# --- F2: typed-ID guards — non-string / empty ids never synthesize keys ----
R=$(fresh typed1)
assert_eq "$(pf_n "$R" $((E_CANCEL+1)) "$(fx 11962 | jq -c '.event.prompt_id=12345')")" 0 \
  "turn_cancelled with numeric prompt_id diagnostic-skips (no synthetic key)"
R=$(fresh typed2)
assert_eq "$(pf_n "$R" $((E_CANCEL+1)) "$(fx 11962 | jq -c '.event.prompt_id=""')")" 0 \
  "turn_cancelled with empty-string prompt_id diagnostic-skips (no synthetic key)"
R=$(fresh typed3)
assert_eq "$(pf "$R" $((E_PERM+1)) "$(fx 20001 | jq -c '.event.permission_tool_call.tool_name=42')")" \
  "0b1k44-audio|approval_pending|01a09de2-6b88-7360-8697-979523062e33|permission needed to run a command" \
  "permission frame with numeric tool_name falls back to the generic body"

# --- F2: permission replay — frame below a freshly advanced cursor ----------
R=$(fresh permreplay)
# Advance the cursor past 20001 with a silent hook_fired frame (freshness kept
# by reusing a now near the original emitted_at family; cursor advances on any
# envelope-valid frame, mapped or not).
pf "$R" $((E_ASK1+3)) "$(fx 130 | jq -c '.seq=21000')" >/dev/null
assert_eq "$(pf_n "$R" $((E_PERM+2)) "$(fx 20001)")" 0 \
  "permission frame at or below cursor seq is skipped as replay"

# --- F2: distinct-episode independence — two cancels, different prompt_ids --
R=$(fresh episodes)
ep_out="$TMP/episodes.out"; : > "$ep_out"
NOTIFY_WATCHER_STATE_ROOT="$R" NOTIFY_WATCHER_TEST_CAP="$ep_out" \
  bash -c '
    source "$1" || exit 9
    cap_send(){ printf "%s|%s|%s|%s\n" "$1" "$2" "$3" "$4" >> "$NOTIFY_WATCHER_TEST_CAP"; }
    NOTIFY_WATCHER_SENDER=cap_send
    notify_watcher_process_frame "$3" "$2"
    notify_watcher_process_frame "$5" "$4"
  ' _ "$NW_LIB" \
    "$((E_CANCEL+1))" "$(fx 11962)" \
    "$((E_CANCEL+3))" "$(fx 11962 | jq -c '.seq=11964 | .event.prompt_id="01a09dff-0000-7000-8000-0000000000aa" | .event.emitted_at="2026-09-14T03:05:38Z"')" \
    >/dev/null 2>&1
assert_eq "$(wc -l < "$ep_out" | tr -d ' ')" 2 \
  "two cancels with different prompt_ids each send (distinct-episode independence)"

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
assert_eq "$(pf_n "$R" $((E_ASK2+1)) "$(fx 5704)")" 1 "post-rebaseline frames evaluate normally again"

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

# --- production sender wiring: enriched identity title + [sse:*] body tag ---
SEND_LOG="$TMP/send.log"
nw_send(){ # <kind> <key> <body> — runs the default sender with a notify_send capture
  NOTIFY_WATCHER_SESSIONS_DIR="$FIXSD" NOTIFY_SEND_CAP="$SEND_LOG" bash -c '
    source "$1" || exit 9
    notify_send(){ printf "%s\n" "title=$notify_title body=$notify_body" >> "$NOTIFY_SEND_CAP"; }
    notify_watcher_default_send "$2" "$3" "$4" "$5"
  ' _ "$NW_LIB" "$@" >/dev/null 2>&1
}
# No session metadata at all: identity falls back to "(sid)"; the body is tagged.
: > "$SEND_LOG"; FIXSD="$TMP/empty-sessions"; mkdir -p "$FIXSD"
nw_send sess-1 question_pending k1 "1 question needs your answer"
assert_eq "$(cat "$SEND_LOG" 2>/dev/null)" "title=(sess-1) body=[sse:question_pending] 1 question needs your answer" \
  "default sender composes identity title and tagged body via notify_send"
# Fixture sessions dir (never operator data): record.json .session_title beats
# session.json .inferred_title; project basename names a non-git project; the
# enriched title is asserted exactly for the pending + completed kinds.
FIXSD="$TMP/watchsessions"; mkdir -p "$FIXSD/sess-1"
printf '%s' '{"session_title":"my title"}' > "$FIXSD/sess-1/record.json"
printf '%s' '{"project_path":"'"$TMP"'/projx","inferred_title":"ignored"}' > "$FIXSD/sess-1/session.json"
: > "$SEND_LOG"; nw_send sess-1 question_pending k1 "1 question needs your answer"
assert_eq "$(cat "$SEND_LOG" 2>/dev/null)" "title=projx (sess-1) - my title body=[sse:question_pending] 1 question needs your answer" \
  "enriched title (record.json wins) for question_pending"
: > "$SEND_LOG"; nw_send sess-1 goal_completed k2 "goal completed: ship it"
assert_eq "$(cat "$SEND_LOG" 2>/dev/null)" "title=projx (sess-1) - my title body=[sse:goal_completed] goal completed: ship it" \
  "enriched title for goal_completed"
: > "$SEND_LOG"; nw_send sess-1 approval_pending k3 "approve plan handoff"
assert_eq "$(cat "$SEND_LOG" 2>/dev/null)" "title=projx (sess-1) - my title body=[sse:approval_pending] approve plan handoff" \
  "approval_pending body carries the sse tag"

# --- nothing dialed out -----------------------------------------------------
[ -e "$TMP/curl.calls" ] && no "suite made no network calls" || ok "suite made no network calls"

[ "$fail" -eq 0 ] && echo "PASS: $pass" || echo "FAILURES: $fail/$((pass+fail))"; exit "$fail"
