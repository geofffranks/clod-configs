#!/usr/bin/env bash
# Contract test harness for the managed workflow facets (workflow-designer,
# workflow-delivery) and their installer support. No `set -e`: assertions keep
# running; the exit status is the assertion count.
#
# Modes:
#   --inventory             managed facet inventory + source subagent inventory
#   --validate-definitions  polytoken validate for every managed facet/subagent
#   --designer-authority    designer frontmatter, delegation-boundary prompt
#                           contract, and runtime effective-tool absence
#   --approval-contract     designer review/handoff wording, delivery approval
#                           provenance wording, and daemon handoff transitions
#   --delivery-policy       delivery frontmatter, risk-based isolation,
#                           change classes, review-count matrices, and
#                           runtime effective-tool exposure (isolated daemon)
#   --ratatoskr             ratatoskr-only MCP grants, inspect-before-execute,
#                           and evidence-tier contract
#   --live-gateway          opt-in container-to-host gateway smoke; requires
#                           POLYTOKEN_LIVE_GATEWAY=1, else an explicit skip
#   --docs                  README workflow roles, gates, override, and MCP routing
#   --selftest              deterministic lifecycle tests for the shared
#                           child tracker and bounded TERM->KILL escalation
#                           (no daemon required)
#
# Default (no args): full run of the mandatory source checks. It does not
# require the live gateway.
#
# Runtime evidence: daemon-backed modes start an ISOLATED polytoken daemon
# (isolated config/project/session dirs, pre-created credential file) and use
# the documented /tools/effective?facet=, /facet, and /interrogative/{id}/respond
# controller endpoints. If the daemon cannot start, the authority checks FAIL —
# static prompt checks never substitute for runtime evidence.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACETS_SRC="$REPO/polytoken/facets"
SUBAGENTS_SRC="$REPO/polytoken/subagents"
LIVE_CFG="${POLYTOKEN_USER_CONFIG_DIR:-$HOME/.config/polytoken}"

pass=0 fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }
sc() { echo; echo "=== $1 ==="; }
finish() {
  echo
  echo "=== $pass passed, $fail failed ==="
  [ "$fail" -eq 0 ]
}

# --- source-file assertion helpers ---
# Collapsed text of a file: newlines and run of spaces reduced to one space,
# so contract phrases may span wrapped markdown lines.
collapse() { tr '\n' ' ' < "$1" | tr -s ' '; }
expect_in() { # label file phrase
  if collapse "$2" | grep -Fq -- "$3"; then
    ok "$1"
  else
    no "$1 (missing: $3)"
  fi
}
expect_not_in() { # label file phrase
  if collapse "$2" | grep -Fq -- "$3"; then
    no "$1 (stale or contradicting phrase present: $3)"
  else
    ok "$1"
  fi
}
# Enable, in an isolated config copy, exactly the disabled models that the
# managed definitions pin or fall back to. Enabling ALL disabled models is
# unsafe: the daemon's strict config check rejects enabled entries like
# zai/glm-4.7 as "custom model overrides require a provider reference".
# Model liveness is a live-environment property, reported, not silently
# rewritten across the board.
enable_referenced_models() { # config-yaml
  local cfg="$1" fmfile refs key cur
  fmfile="$(mktemp)"; refs="$(mktemp)"
  local f
  for f in "$FACETS_SRC/"*.md "$SUBAGENTS_SRC/"*.md; do
    awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "$f" > "$fmfile"
    { yq -r '.polytoken.model // ""' "$fmfile"; yq -r '.polytoken.fallback_models[]?' "$fmfile"; } \
      | sed 's/(.*$//' >> "$refs"
  done
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    # No `// true` fallback here: yq's alt operator treats `false` as empty,
    # so `false // true` prints "true" and the enable step would be skipped.
    cur="$(yq -r ".models.\"$key\".enabled" "$cfg")" 2>/dev/null
    [ "$cur" = "false" ] && yq -i ".models.\"$key\".enabled = true" "$cfg"
  done < <(sort -u "$refs")
  rm -f "$fmfile" "$refs"
}
referenced_disabled_note() { # config-yaml (live copy, pre-enable)
  local cfg="$1" fmfile refs note
  fmfile="$(mktemp)"; refs="$(mktemp)"
  local f
  for f in "$FACETS_SRC/"*.md "$SUBAGENTS_SRC/"*.md; do
    awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "$f" > "$fmfile"
    { yq -r '.polytoken.model // ""' "$fmfile"; yq -r '.polytoken.fallback_models[]?' "$fmfile"; } \
      | sed 's/(.*$//' >> "$refs"
  done
  note="$(while IFS= read -r key; do
    [ -n "$key" ] || continue
    # Raw value, no `//`: yq's alt operator maps `false` to the fallback,
    # which would hide exactly the disabled models we must report.
    yq -r ".models.\"$key\".enabled" "$cfg" | grep -qx false && echo "$key"
  done < <(sort -u "$refs"))"
  if [ -n "$note" ]; then
    echo "  limitation: live config disables the referenced model(s) enabled only in the"
    echo "              isolated copy: $(printf '%s' "$note" | tr '\n' ' ')"
  fi
  rm -f "$fmfile" "$refs"
}
# Frontmatter JSON value: yq -o=json over lines 2..(closing ---).
fm_json() { # file yq-expr
  local f="$1" expr="$2" fm rc
  fm="$(mktemp)"
  awk 'NR==1 && $0=="---"{next} /^---$/{exit} {print}' "$f" > "$fm"
  yq -o=json -I=0 "$expr" "$fm"
  rc=$?
  rm -f "$fm"
  return $rc
}
expect_fm() { # label file yq-expr expected-json
  local actual
  actual="$(fm_json "$2" "$3")" || { no "$2: unparseable frontmatter for $3"; return; }
  if [ "$actual" = "$4" ]; then
    ok "$1"
  else
    no "$1"
    echo "       want: $4"
    echo "       got:  $actual"
  fi
}
expect_list() { # label file yq-expr comma-separated exact-order list
  local want
  want="$(printf '[%s]\n' "${4//,/, }" | yq -o=json -I=0 '.')"
  expect_fm "$1" "$2" "$3" "$want"
}

# --- shared child/temp-dir tracker (cleanup contract) -----------------
# Every background process started by this harness is registered in CHILD_PIDS;
# DAEMON_PID is a convenience alias for the isolated daemon's tracked PID.
# cleanup() terminates children within bounded deadlines before removing dirs.
DAEMON_PID=""
DAEMON_WORK=""
DAEMON_URL=""
DAEMON_TKN=""
WORK_DIRS=()
CHILD_PIDS=()
declare -A CHILD_OWNED=()
TERM_TIMEOUT=2
PROC_DEAD_OVERRIDE=""
proc_dead() { # pid -> 0 when dead, reaped, or a zombie
  [ -n "$PROC_DEAD_OVERRIDE" ] && return 1
  kill -0 "$1" 2>/dev/null || return 0
  [ "$(ps -o command= -p "$1" 2>/dev/null | head -1)" = "<defunct>" ]
}
track_child() { # pid [owned]: register PID and explicit shell-ownership metadata
  local pid="$1" owned="${2:-1}"
  CHILD_PIDS+=("$pid")
  CHILD_OWNED["$pid"]="$owned"
}
remove_child() { # pid: remove tracker entry and ownership metadata
  local pid="$1" p; local -a remaining=()
  for p in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
    [ "$p" = "$pid" ] || remaining+=("$p")
  done
  CHILD_PIDS=("${remaining[@]}")
  unset 'CHILD_OWNED[$pid]'
}
reap_child() { # pid: wait only for explicitly registered shell-owned children
  local pid="$1"
  [ "${CHILD_OWNED[$pid]:-0}" = 1 ] || return 0
  wait "$pid" 2>/dev/null || true
}
kill_child() { # pid: bounded TERM/KILL; wait only after death is confirmed
  local pid="$1" i limit
  proc_dead "$pid" && { reap_child "$pid"; return 0; }
  kill -TERM "$pid" 2>/dev/null || true
  limit=$((TERM_TIMEOUT * 5))
  for i in $(seq 1 "$limit"); do
    proc_dead "$pid" && { reap_child "$pid"; return 0; }
    sleep 0.2
  done
  kill -KILL "$pid" 2>/dev/null || true
  for i in $(seq 1 "$limit"); do
    proc_dead "$pid" && { reap_child "$pid"; return 0; }
    sleep 0.2
  done
  echo "  cleanup: child pid $pid still alive/unreapable after TERM/KILL deadlines" >&2
  return 1
}
cleanup() {
  local p w rc=0 handled=0
  local -a unresolved=()
  local -A unresolved_owned=()
  # DAEMON_PID aliases a tracked child. Handle it explicitly once, then remove
  # it from the shared tracker only after successful handling.
  if [ -n "$DAEMON_PID" ]; then
    if kill_child "$DAEMON_PID"; then
      handled=1
      remove_child "$DAEMON_PID"
      DAEMON_PID=""
    else
      rc=1
      unresolved+=("$DAEMON_PID")
      unresolved_owned["$DAEMON_PID"]="${CHILD_OWNED[$DAEMON_PID]:-0}"
    fi
  fi
  for p in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do
    [ -n "$DAEMON_PID" ] && [ "$p" = "$DAEMON_PID" ] && continue
    if kill_child "$p"; then
      handled=1
    else
      rc=1
      unresolved+=("$p")
      unresolved_owned["$p"]="${CHILD_OWNED[$p]:-0}"
    fi
  done
  CHILD_PIDS=("${unresolved[@]}")
  CHILD_OWNED=()
  for p in ${unresolved[@]+"${unresolved[@]}"}; do
    CHILD_OWNED["$p"]="${unresolved_owned[$p]:-0}"
  done
  # Workdirs remain available for diagnostics while any child is unresolved.
  if [ "$rc" -eq 0 ] && [ "${#CHILD_PIDS[@]}" -eq 0 ] && [ -z "$DAEMON_PID" ]; then
    for w in ${WORK_DIRS[@]+"${WORK_DIRS[@]}"}; do rm -rf "$w"; done
    WORK_DIRS=()
  else
    rc=1
    echo "  cleanup: retaining ${#WORK_DIRS[@]} workdir(s) for unresolved child diagnostics" >&2
  fi
  [ "$rc" -eq 0 ] || echo "  cleanup: unresolved child tracker entries retained" >&2
  return "$rc"
}
trap cleanup EXIT
on_interrupt() { # sig: bounded cleanup on SIGINT/SIGTERM, then canonical exit
  trap - EXIT INT TERM
  cleanup
  case "$1" in INT) exit 130 ;; *) exit 143 ;; esac
}
trap 'on_interrupt INT' INT
trap 'on_interrupt TERM' TERM

start_daemon() {
  local work cfg proj sess token port i attempt
  command -v polytoken >/dev/null 2>&1 || { echo "  polytoken CLI not found" >&2; return 1; }
  [ -f "$LIVE_CFG/config.yaml" ] || { echo "  no live config at $LIVE_CFG/config.yaml" >&2; return 1; }
  work="$(mktemp -d)"
  WORK_DIRS+=("$work")
  cfg="$work/gcfg"; proj="$work/proj"; sess="$work/sessions"
  mkdir -p "$cfg/facets" "$cfg/subagents" "$proj" "$sess"
  cp "$LIVE_CFG/config.yaml" "$cfg/config.yaml"
  # Isolated copy only: enable ONLY the disabled models that the managed
  # definitions pin or fall back to. Enabling ALL disabled entries breaks the
  # daemon's strict config check (entries without provider refs are rejected
  # as "custom model overrides"). The live limitation is reported, not hidden.
  referenced_disabled_note "$cfg/config.yaml"
  enable_referenced_models "$cfg/config.yaml"
  cp "$FACETS_SRC/"*.md "$cfg/facets/"
  cp "$SUBAGENTS_SRC/"*.md "$cfg/subagents/"
  DAEMON_WORK="$work"
  DAEMON_URL=""; DAEMON_TKN=""; DAEMON_PID=""
  for attempt in 1 2 3; do
    port=$((20000 + RANDOM % 40000))
    token="$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"
    printf '{"version":1,"kind":"polytoken-daemon-credential","token":"%s"}' "$token" > "$work/cred.json"
    chmod 600 "$work/cred.json"
    polytoken daemon --global-config-dir "$cfg" --project-dir "$proj" \
      --sessions-dir "$sess" --credential-file "$work/cred.json" \
      --listen "127.0.0.1:$port" > "$work/daemon.log" 2>&1 &
    DAEMON_PID=$!
    track_child "$DAEMON_PID" 1
    for i in $(seq 1 60); do
      if curl -sS --max-time 1 -H "Authorization: Bearer $token" \
           "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
        DAEMON_URL="http://127.0.0.1:$port"
        DAEMON_TKN="$token"
        return 0
      fi
      sleep 0.5
    done
    kill_child "$DAEMON_PID"
    DAEMON_PID=""
  done
  echo "  isolated daemon failed to start; log tail:" >&2
  tail -n 8 "$work/daemon.log" >&2
  return 1
}
stop_daemon() {
  if [ -n "$DAEMON_PID" ]; then
    kill_child "$DAEMON_PID"
  fi
  DAEMON_PID=""
}
# dapi METHOD PATH BODY OUTFILE -> prints HTTP status code
dapi() {
  local method="$1" path="$2" body="$3" out="$4"
  local -a args=(-sS --max-time 20 -o "$out" -w '%{http_code}' -X "$method"
    -H "Authorization: Bearer $DAEMON_TKN" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(-d "$body")
  curl "${args[@]}" "$DAEMON_URL$path"
}
daemon_state() { # prints JSON body of GET /state
  local out="$DAEMON_WORK/state.json"
  dapi GET /state "" "$out" >/dev/null
  cat "$out"
}
effective_plan() { # facet OUTFILE -> 0 on success; OUTFILE holds the response
  local code out
  out="$2"
  code="$(dapi GET "/tools/effective?facet=$1" "" "$out")"
  [ "$code" = 200 ]
}
plan_names() { # planJSONfile -> sorted tool names
  jq -r '.plan.full_schema[].name' "$1" | sort
}
require_daemon() { # label
  if ! start_daemon; then
    no "$1: isolated daemon unavailable — runtime authority checks cannot run"
    echo "       (per contract, static checks never substitute: mode fails)" >&2
    return 1
  fi
  return 0
}

DESIGNER="$FACETS_SRC/workflow-designer.md"
DELIVERY="$FACETS_SRC/workflow-delivery.md"

# =====================================================================
run_inventory() {
  sc "managed_facet_inventory"
  [ -f "$DESIGNER" ] && ok "designer source file present" || no "designer source file present"
  [ -f "$DELIVERY" ] && ok "delivery source file present" || no "delivery source file present"
  [ -f "$DESIGNER" ] && [ -f "$DELIVERY" ] || return
  local found
  found="$(find "$FACETS_SRC" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sort)"
  [ "$found" = "$(printf '%s\n' workflow-delivery.md workflow-designer.md | sort)" ] \
    && ok "source facets are exactly the two managed definitions" \
    || { no "source facets are exactly the two managed definitions"; printf '%s\n' "$found" | sed 's/^/       /'; }
  [ "$(fm_json "$DESIGNER" '.name')" = '"workflow-designer"' ] \
    && ok "designer: frontmatter name matches file stem" || no "designer: frontmatter name matches file stem"
  [ "$(fm_json "$DELIVERY" '.name')" = '"workflow-delivery"' ] \
    && ok "delivery: frontmatter name matches file stem" || no "delivery: frontmatter name matches file stem"
  local head
  for f in "$DESIGNER" "$DELIVERY"; do
    head="$(awk '/^---$/{c++; next} c==2{print; exit}' "$f")"
    [ "$head" = '{{ transclude("polytoken://system_prompts/facet.md") }}' ] \
      && ok "$(basename "$f"): body starts with the facet base transclusion" \
      || no "$(basename "$f"): body starts with the facet base transclusion (got: $head)"
  done
  sc "managed source subagent inventory (14)"
  local actual expected
  expected="$(printf '%s\n' abstraction-reviewer agent-workflow-architect agent-workflow-engineer \
    completeness-reviewer correctness-reviewer general-reviewer implementer maintainability-reviewer \
    mobile-app-expert researcher reviewer software-architect software-engineer validator | sort)"
  actual="$(find "$SUBAGENTS_SRC" -maxdepth 1 -type f -name '*.md' -printf '%f\n' | sed 's/\.md$//' | sort)"
  [ "$actual" = "$expected" ] && ok "14 managed subagent definitions present" \
    || { no "14 managed subagent definitions present"; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/       /'; }
}

# =====================================================================
run_validate_definitions() {
  sc "all_source_definitions_validate"
  command -v polytoken >/dev/null 2>&1 || { no "polytoken CLI available"; return; }
  [ -f "$LIVE_CFG/config.yaml" ] || { no "live config to seed isolated validation dir"; return; }
  local work f name out
  work="$(mktemp -d)"; WORK_DIRS+=("$work")
  mkdir -p "$work/facets" "$work/subagents"
  cp "$LIVE_CFG/config.yaml" "$work/config.yaml"
  referenced_disabled_note "$work/config.yaml"
  enable_referenced_models "$work/config.yaml"
  for f in "$FACETS_SRC/"*.md; do
    if out="$(polytoken --config-dir "$work" validate facet "$f" 2>&1)"; then
      ok "validate facet: $(basename "$f")"
    else
      no "validate facet: $(basename "$f")"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  done
  for f in "$SUBAGENTS_SRC/"*.md; do
    if out="$(polytoken --config-dir "$work" validate subagent "$f" 2>&1)"; then
      ok "validate subagent: $(basename "$f")"
    else
      no "validate subagent: $(basename "$f")"
      printf '%s\n' "$out" | sed 's/^/       /'
    fi
  done
}

# =====================================================================
run_designer_authority() {
  sc "designer frontmatter contract"
  expect_fm "designer: model pin" "$DESIGNER" '.polytoken.model' '"codex/gpt-5.6-luna"'
  expect_list "designer: fallback_models" "$DESIGNER" '.polytoken.fallback_models' "zai/glm-5.2"
  expect_list "designer: tools" "$DESIGNER" '.polytoken.tools' \
    "file_read,glob,grep,web_search,web_fetch,subagent,message_subagent,skill,job_status,job_block,job_result,job_cancel,list_jobs,ask_user_question,tool_search,write_plan,edit_plan,handoff_plan,read_goal,block_goal,mcp__ratatoskr"
  expect_list "designer: tools_deny" "$DESIGNER" '.polytoken.tools_deny' \
    "file_write,file_edit_search_replace,shell_exec,shell_monitor,shell_service,lsp,switch_facet,complete_goal"
  expect_list "designer: undeferred_tools" "$DESIGNER" '.polytoken.undeferred_tools' \
    "file_read,glob,grep,subagent,message_subagent,skill,job_status,job_block,job_result,list_jobs,ask_user_question,write_plan,edit_plan,handoff_plan"
  expect_list "designer: skills_allow" "$DESIGNER" '.polytoken.skills_allow' \
    "tag!research,brainstorming,agent-orchestration"
  expect_fm "designer: skills_deny empty" "$DESIGNER" '.polytoken.skills_deny' '[]'
  expect_fm "designer: autonomous_hint" "$DESIGNER" '.polytoken.autonomous_hint' \
    '"Allow read-only investigation, read-only specialist consultation, plan editing, and approval handoff; deny direct or delegated project mutation during design."'
  expect_fm "designer: compaction_hint" "$DESIGNER" '.polytoken.compaction_hint' \
    '"Preserve goals, constraints, evidence, alternatives, specialist job IDs/results, review dispositions, plan revision, and approval state."'
  [ "$(fm_json "$DESIGNER" '.polytoken.facet_transitions')" = "null" ] \
    && ok "designer: no facet_transitions block" || no "designer: no facet_transitions block"

  sc "designer delegation boundary disclosure contract (prompt)"
  expect_in "discloses no facet-level subagent-name allowlist" "$DESIGNER" \
    "Polytoken has no facet-level subagent-name allowlist"
  expect_in "names the boundary as a non-runtime prompt contract" "$DESIGNER" \
    "not a runtime security boundary"
  expect_in "prohibits write-capable subagent dispatch" "$DESIGNER" \
    "Never dispatch write-capable or implementation roles"
  expect_in "never claims enforcement of name restrictions" "$DESIGNER" \
    "never claim that Polytoken technically enforces subagent-name restrictions"
  expect_not_in "makes no positive runtime-enforcement claim" "$DESIGNER" \
    "Polytoken prevents"
  expect_in "consults architect and read-only specialists only" "$DESIGNER" \
    'Consult via `agent-workflow-architect` and conditional read-only specialists only'
  expect_in "bounds concurrency to 4" "$DESIGNER" "limit concurrency to 4 simultaneous subagents"
  expect_in "forbids duplicate active assignments" "$DESIGNER" \
    "never hold two active assignments"

  sc "designer_effective_tools_are_read_only + designer_mutation_attempt_is_unavailable (runtime)"
  if require_daemon "designer authority (runtime)"; then
    local out="$DAEMON_WORK/designer-effective.json"
    if effective_plan workflow-designer "$out"; then
      ok "runtime: /tools/effective resolved workflow-designer"
      [ "$(jq -r '.model' "$out")" = "codex/gpt-5.6-luna" ] \
        && ok "runtime: designer model pin resolves" || no "runtime: designer model pin resolves (got $(jq -r .model "$out"))"
      local names n missing=""
      names="$(plan_names "$out")"
      local required="ask_user_question block_goal edit_plan file_read glob grep handoff_plan job_block job_cancel job_result job_status list_jobs message_subagent read_goal skill subagent tool_search web_fetch web_search write_plan"
      for n in $required; do
        grep -qx "$n" <<<"$names" || missing="$missing $n"
      done
      [ -z "$missing" ] && ok "runtime: required designer tools all exposed" || no "runtime: required designer tools present (missing:$missing)"
      local forbidding="file_write file_edit_search_replace shell_exec shell_monitor shell_service lsp switch_facet complete_goal" absent=""
      for n in $forbidding; do
        grep -qx "$n" <<<"$names" && absent="$absent $n"
      done
      [ -z "$absent" ] && ok "runtime: mutation/self-transition/goal-completion tools absent" \
        || no "runtime: designer mutation tools absent (present:$absent)"
    else
      no "runtime: /tools/effective resolved workflow-designer"
    fi
    stop_daemon
  fi
}

# =====================================================================
run_approval_contract() {
  sc "designer_review_and_target_contract (prompt)"
  expect_in "explicitly dispatches built-in plan-reviewer" "$DESIGNER" \
    "explicitly dispatch the named built-in \`plan-reviewer\` subagent against the saved plan"
  expect_in "rebut-or-fix Critical/High then fresh rereview" "$DESIGNER" \
    "dispatch a fresh \`plan-reviewer\` rereview against the revised saved plan"
  expect_in "loops until no blocking finding" "$DESIGNER" "Repeat until no blocking finding remains"
  expect_in "requests explicit operator approval" "$DESIGNER" \
    "present the final plan to the operator and request explicit approval"
  expect_in "handoff target is workflow-delivery by prompt contract" "$DESIGNER" \
    "call \`handoff_plan\` with target facet \`workflow-delivery\`"
  expect_in "discloses handoff accepts any target argument" "$DESIGNER" \
    "\`handoff_plan\` accepts any target argument, so do not claim the target is technically restricted"
  expect_in "never switches or hands off before approval" "$DESIGNER" \
    "never switch or hand off before approval"
  expect_in "does not use switch_facet at all" "$DESIGNER" "Do not use \`switch_facet\`"

  sc "delivery_unverified_provenance_disclosure (prompt)"
  expect_in "defaults approval provenance unverified" "$DELIVERY" \
    "Default to \`approval provenance unverified\`"
  expect_in "states no documented activation provenance exists" "$DELIVERY" \
    "no documented activation reason, previous-facet field, or approved-handoff flag"
  expect_in "direct invocation is execution authority" "$DELIVERY" \
    "operator authorization to execute the requested work"
  expect_in "direct invocation is not reviewed-plan proof" "$DELIVERY" \
    "It is **not** proof that a plan was reviewed or approved"
  expect_in "reports provenance state plainly" "$DELIVERY" "report the provenance state plainly"
  expect_in "material redesign returns to designer for renewed approval" "$DELIVERY" \
    "returns to \`workflow-designer\` for renewed planning and operator approval"
  expect_in "bounded in-scope decisions proceed" "$DELIVERY" \
    "Ordinary bounded implementation decisions within the approved scope can proceed without returning"

  sc "approved handoff to workflow-delivery (runtime controller)"
  if ! require_daemon "approval handoff (runtime)"; then return; fi
  local out="$DAEMON_WORK/handoff.json" code
  local base; base="$(daemon_state | jq -r .active_facet 2>/dev/null)"
  code="$(dapi POST /facet '{"facet":"workflow-designer"}' "$out")"
  [ "$code" = 200 ] && ok "runtime: can activate designer from active facet ($base)" \
    || no "runtime: can activate designer (HTTP $code: $(cat "$out" | head -c 200))"
  [ "$(daemon_state | jq -r .active_facet)" = "workflow-designer" ] \
    && ok "runtime: active facet is workflow-designer" || no "runtime: active facet is workflow-designer"
  code="$(dapi POST /facet '{"facet":"no-such-facet"}' "$out")"
  [ "$code" = 422 ] && ok "runtime: unknown facet rejected (422)" \
    || no "runtime: unknown facet rejected (got HTTP $code)"
  code="$(dapi POST /facet '{"facet":"workflow-delivery"}' "$out")"
  [ "$code" = 200 ] && ok "runtime: operator-approved handoff designer -> workflow-delivery succeeds (POST /facet 200)" \
    || no "runtime: handoff designer -> workflow-delivery (HTTP $code: $(cat "$out" | head -c 200))"
  [ "$(daemon_state | jq -r .active_facet)" = "workflow-delivery" ] \
    && ok "runtime: active facet is workflow-delivery after handoff" \
    || no "runtime: active facet is workflow-delivery after handoff"

  sc "conditional return to designer gates on confirmation (runtime)"
  local logfile known newid i
  # Baseline of pending interrogative IDs, captured before triggering.
  known="$(daemon_state | jq -r '.pending_interrogatives[].interrogative_id' 2>/dev/null | head -n 1)"
  local curlout="$DAEMON_WORK/condswitch.log"
  curl -sS --max-time 60 -w '%{http_code}' -X POST -H "Authorization: Bearer $DAEMON_TKN" \
    -H 'Content-Type: application/json' -d '{"facet":"workflow-designer"}' \
    "$DAEMON_URL/facet" > "$curlout" 2>&1 &
  local curlpid=$!
  track_child "$curlpid" 1
  newid=""
  for i in $(seq 1 40); do
    local pending; pending="$(daemon_state | jq -r '.pending_interrogatives[].interrogative_id' 2>/dev/null)"
    if [ -n "$known" ]; then
      newid="$(grep -v -x -F -- "$known" <<<"$pending" | head -1)"
    else
      newid="$(head -1 <<<"$pending")"
    fi
    [ -n "$newid" ] && break
    sleep 0.5
  done
  [ -n "$newid" ] && ok "runtime: conditional transition raised a confirmation interrogative" \
    || no "runtime: conditional transition raised a confirmation interrogative"
  if [ -n "$newid" ]; then
    local q
    q="$(daemon_state | jq -r ".pending_interrogatives[] | select(.interrogative_id==\"$newid\") | .question" 2>/dev/null)"
    [ "$q" = "Material redesign requires renewed planning and operator approval." ] \
      && ok "runtime: interrogative asks the exact delivery->designer condition" \
      || no "runtime: interrogative asks the exact condition (got: $q)"
    code="$(dapi POST "/interrogative/$newid/respond" '{"kind":"confirmation_answer","confirmed":true}' "$out")"
    [ "$code" = 200 ] && ok "runtime: confirmation accepted (HTTP 200)" || no "runtime: confirmation accepted (HTTP $code)"
  fi
  # Allow the confirmed response to flush before bounded lifecycle cleanup.
  for i in $(seq 1 50); do
    proc_dead "$curlpid" && break
    sleep 0.2
  done
  if kill_child "$curlpid"; then
    local finalcode; finalcode="$(tail -1 "$curlout")"
    [ "$finalcode" = 200 ] && ok "runtime: conditional switch POST completed 200 after confirmation" \
      || no "runtime: conditional switch POST completed 200 (got $finalcode)"
  else
    no "runtime: conditional switch child terminated and was reaped within bounded deadline"
    no "runtime: conditional switch POST completed 200 after confirmation (child still alive/unreapable)"
  fi
  [ "$(daemon_state | jq -r .active_facet)" = "workflow-designer" ] \
    && ok "runtime: confirmed switch lands on workflow-designer" \
    || no "runtime: confirmed switch lands on workflow-designer"
  # The session log lives under the on-disk session directory, which differs
  # from the session_id field of /state. The isolated sessions dir belongs to
  # this daemon alone, so locate it directly.
  logfile="$(find "$DAEMON_WORK/sessions" -name 'log.jsonl' -type f 2>/dev/null | head -1)"
  [ -n "$logfile" ] && \
    grep -q '"from_facet":"workflow-delivery","to_facet":"workflow-designer"' "$logfile" \
    && ok "runtime: session log records the delivery -> designer facet_switch" \
    || no "runtime: session log records the delivery -> designer facet_switch"
  stop_daemon
}

# =====================================================================
run_delivery_policy() {
  sc "delivery frontmatter contract"
  expect_fm "delivery: model pin" "$DELIVERY" '.polytoken.model' '"codex/gpt-5.6-luna"'
  expect_list "delivery: fallback_models" "$DELIVERY" '.polytoken.fallback_models' "zai/glm-5.2"
  expect_list "delivery: tools" "$DELIVERY" '.polytoken.tools' \
    "file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec,shell_monitor,shell_service,subagent,message_subagent,skill,job_status,job_block,job_result,job_cancel,list_jobs,ask_user_question,tool_search,todo_create,todo_update,todo_complete,todo_delete,todo_list,pushd,popd,switch_facet,read_goal,complete_goal,block_goal,mcp__ratatoskr"
  expect_list "delivery: tools_deny" "$DELIVERY" '.polytoken.tools_deny' \
    "write_plan,edit_plan,handoff_plan"
  expect_list "delivery: undeferred_tools" "$DELIVERY" '.polytoken.undeferred_tools' \
    "file_read,file_write,file_edit_search_replace,glob,grep,lsp,shell_exec,subagent,message_subagent,skill,job_status,job_block,job_result,list_jobs,ask_user_question,todo_create,todo_update,todo_complete,todo_list,read_goal,complete_goal,block_goal"
  expect_list "delivery: skills_allow" "$DELIVERY" '.polytoken.skills_allow' \
    "tag!research,brainstorming,agent-orchestration,git-workflow,using-git-worktrees,systematic-debugging,test-driven-development,receiving-code-review,requesting-code-review,verification-before-completion,artifact-retention-policy"
  expect_fm "delivery: skills_deny empty" "$DELIVERY" '.polytoken.skills_deny' '[]'
  expect_fm "delivery: autonomous_hint" "$DELIVERY" '.polytoken.autonomous_hint' \
    '"Allow approved bounded implementation and verification; require confirmation for scope expansion, remote writes, destructive operations, or unverified authority."'
  expect_fm "delivery: compaction_hint" "$DELIVERY" '.polytoken.compaction_hint' \
    '"Preserve approval evidence or its absence, approved scope, change classes, worktree/CWD, jobs, revisions, review dispositions, tests, limitations, and completion state."'
  [ "$(fm_json "$DELIVERY" '.polytoken.facet_transitions.workflow-designer.allowed')" = "true" ] \
    && ok "delivery: facet_transitions.workflow-designer.allowed is true" \
    || no "delivery: facet_transitions.workflow-designer.allowed is true"
  expect_fm "delivery: transition condition exact" "$DELIVERY" \
    '.polytoken.facet_transitions.workflow-designer.condition' \
    '"Material redesign requires renewed planning and operator approval."'

  sc "risk_class_matrix + dirty_tree_and_parallel_writer_isolation (prompt)"
  expect_in "worktree+branch for multi-file/executable/high-risk/dirty/isolated" "$DELIVERY" \
    "Use a feature branch plus a separate worktree whenever the work is multi-file, executable (scripts, hooks, code, MCP), high-risk, starts from a dirty tree, or needs physical isolation."
  expect_in "bounded edit in current clean tree permitted" "$DELIVERY" \
    "bounded prompt/config/document edit in the current tree only when the tree is clean"
  expect_in "exact worktree cwd passed to writers" "$DELIVERY" \
    "Pass the selected worktree as the exact \`cwd\` of every write-capable subagent you dispatch"
  expect_in "overlapping slices serialized" "$DELIVERY" "Serialize overlapping implementation slices"
  expect_in "parallel only distinct worktrees, disjoint ownership, one integration owner" "$DELIVERY" \
    "Parallel writers are allowed only in distinct worktrees with disjoint file ownership and one named integration owner"
  expect_in "never overwrites unexpected work; stops and reports" "$DELIVERY" \
    "Never overwrite unrelated work: if unexpected changes overlap your scope, stop and report rather than continuing"

  sc "delegation and concurrency (prompt)"
  expect_in "delegates bounded slices to agent-workflow-engineer" "$DELIVERY" \
    "Delegate bounded implementation slices to \`agent-workflow-engineer\`"
  expect_in "correlates dispatches by job ID" "$DELIVERY" "correlate every dispatch by job ID"
  expect_in "bounds concurrency to 4" "$DELIVERY" "limit concurrency to 4 simultaneous subagents"
  expect_in "forbids duplicate active assignments" "$DELIVERY" \
    "never hold two active assignments to the same role on the same scope"

  sc "change-class test policy matrix (prompt)"
  expect_in "prompt/docs: no TDD" "$DELIVERY" "Prompt/Markdown/docs: no TDD"
  expect_in "declarative: no forced RED/GREEN; validate exposure" "$DELIVERY" \
    "Declarative facet/subagent/configuration: no forced RED/GREEN; validate"
  expect_in "executable: RED/GREEN then focused and broader" "$DELIVERY" \
    "Executable scripts, hooks, code, and MCP behavior: RED/GREEN TDD, then focused and broader checks"
  expect_in "mixed tasks split" "$DELIVERY" "Split mixed tasks"

  sc "review_count_matrix (prompt)"
  expect_in "every substantive change: one architect review" "$DELIVERY" \
    "one independent \`agent-workflow-architect\` review"
  expect_in "second fresh review for high-risk surfaces" "$DELIVERY" \
    "A second fresh workflow review is additionally required"
  expect_in "names the high-risk surfaces" "$DELIVERY" \
    "permissions, authority, approval gates, delegation, autonomous behavior, MCP routing, or destructive capabilities"
  expect_in "reviewers never fix their own findings" "$DELIVERY" "Reviewers never fix their own findings"
  expect_in "batch fixes, rerun only affected checks" "$DELIVERY" \
    "Batch valid blocking findings into one coherent fix, then rerun only the affected checks"

  sc "evidence and completion (prompt)"
  expect_in "evidence tiers named" "$DELIVERY" \
    "container-local evidence, host evidence mediated through ratatoskr, and manual operator confirmation"
  expect_in "no automatic remote writes" "$DELIVERY" "No remote writes: never push, open a PR"
  expect_in "verify before complete_goal" "$DELIVERY" "Verify before \`complete_goal\`"

  # Runtime tool-plan evidence (isolated daemon), same contract as
  # --designer-authority: a daemon-start failure FAILS this mode; static
  # prompt checks never substitute for runtime evidence.
  sc "delivery_effective_tools are mutation surface + plan tools denied (runtime)"
  if ! require_daemon "delivery policy (runtime)"; then return; fi
  local out="$DAEMON_WORK/delivery-effective.json"
  if effective_plan workflow-delivery "$out"; then
    ok "runtime: /tools/effective resolved workflow-delivery"
    [ "$(jq -r '.model' "$out")" = "codex/gpt-5.6-luna" ] \
      && ok "runtime: delivery model pin resolves" || no "runtime: delivery model pin resolves (got $(jq -r '.model' "$out"))"
    local names n missing=""
    names="$(plan_names "$out")"
    local required="file_edit_search_replace file_write job_cancel lsp pushd popd shell_exec shell_monitor shell_service switch_facet todo_complete todo_create todo_delete todo_list todo_update"
    for n in $required; do
      grep -qx "$n" <<<"$names" || missing="$missing $n"
    done
    [ -z "$missing" ] && ok "runtime: required mutation-surface tools all exposed" \
      || no "runtime: required mutation tools present (missing:$missing)"
    local denied="write_plan edit_plan handoff_plan" present=""
    for n in $denied; do
      grep -qx "$n" <<<"$names" && present="$present $n"
    done
    [ -z "$present" ] && ok "runtime: plan tools denied (write_plan/edit_plan/handoff_plan absent)" \
      || no "runtime: plan tools denied (present:$present)"
    local bad_mcp
    bad_mcp="$(jq -r '.plan.full_schema[].name' "$out" | grep '^mcp__' | grep -v '^mcp__ratatoskr__' || true)"
    [ -z "$bad_mcp" ] && ok "runtime: effective MCP tools stay in ratatoskr namespace" \
      || no "runtime: non-ratatoskr MCP tools present in effective plan ($bad_mcp)"
  else
    no "runtime: /tools/effective resolved workflow-delivery"
  fi
  stop_daemon
}

# =====================================================================
run_ratatoskr() {
  sc "ratatoskr-only MCP grants (frontmatter)"
  local f
  for f in "$DESIGNER" "$DELIVERY"; do
    local b="$(basename "$f" .md)"
    local mcp_tools nonrs
    mcp_tools="$(fm_json "$f" '.polytoken.tools' | jq -r '.[] | select(startswith("mcp__"))')"
    local only_rs=1 t
    for t in $mcp_tools; do [ "$t" = "mcp__ratatoskr" ] || only_rs=0; done
    [ -n "$mcp_tools" ] && [ "$only_rs" = 1 ] \
      && ok "$b: only mcp__ratatoskr MCP namespace granted" || no "$b: only mcp__ratatoskr MCP namespace granted"
    fm_json "$f" '.' | grep -q 'ALL_MCP' && no "$b: no tag!ALL_MCP grant" || ok "$b: no tag!ALL_MCP grant"
  done
  sc "inspect-before-execute and reconnect rules (prompt)"
  for f in "$DESIGNER" "$DELIVERY"; do
    local b="$(basename "$f" .md)"
    expect_in "$b: list servers/tools then inspect schema before executing" "$f" \
      "Before executing anything through the gateway: list the available servers and tools, then inspect the selected tool's schema"
    expect_in "$b: reconnect only on auth/token expiry" "$f" \
      "Reconnect an upstream only after an authentication or token-expiry failure"
    expect_in "$b: never direct upstream MCP first" "$f" \
      "Never set up or authenticate a duplicate direct MCP connection first"
  done
  sc "evidence_tier_contract (prompt)"
  expect_in "designer: three evidence tiers" "$DESIGNER" \
    "container-local evidence, host evidence mediated through ratatoskr, and manual operator confirmation"
  expect_in "delivery: three evidence tiers" "$DELIVERY" \
    "container-local evidence, host evidence mediated through ratatoskr, and manual operator confirmation"
  sc "ratatoskr_only_effective_grants (runtime)"
  if ! require_daemon "ratatoskr namespace (runtime)"; then return; fi
  local out facet
  # The daemon connects to the ratatoskr gateway asynchronously after boot;
  # /tools/effective has no mcp__ratatoskr__* entries until the connection
  # lands (~10-20s empirically). Wait for it to appear before asserting —
  # a 60s timeout is a real failure, not a static substitution.
  local waited=0
  while [ "$waited" -lt 60 ]; do
    effective_plan workflow-delivery "$DAEMON_WORK/mcp-wait.json" || true
    [ -n "$(jq -r '.plan.full_schema[].name' "$DAEMON_WORK/mcp-wait.json" 2>/dev/null \
        | grep '^mcp__ratatoskr__' | head -1)" ] && break
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$waited" -ge 60 ]; then
    no "runtime: ratatoskr gateway tools appeared in effective plan within 60s"
    stop_daemon
    return
  fi
  for facet in workflow-designer workflow-delivery; do
    out="$DAEMON_WORK/$facet-effective.json"
    if effective_plan "$facet" "$out"; then
      bad_mcp="$(jq -r '.plan.full_schema[].name' "$out" | grep '^mcp__' | grep -v '^mcp__ratatoskr__' || true)"
      [ -z "$bad_mcp" ] && ok "runtime $facet: effective MCP tools stay in ratatoskr namespace" \
        || no "runtime $facet: non-ratatoskr MCP tools present ($bad_mcp)"
      [ -n "$(jq -r '.plan.full_schema[].name' "$out" | grep '^mcp__ratatoskr__' | head -1)" ] \
        && ok "runtime $facet: ratatoskr gateway tools exposed" \
        || no "runtime $facet: no mcp__ratatoskr__* tools in effective plan"
    else
      no "runtime $facet: /tools/effective failed"
    fi
  done
  stop_daemon
}

# =====================================================================
run_live_gateway() {
  sc "live_gateway_smoke (container -> host.docker.internal:8910/mcp)"
  if [ "${POLYTOKEN_LIVE_GATEWAY:-0}" != "1" ]; then
    echo "  SKIP: live gateway smoke requires POLYTOKEN_LIVE_GATEWAY=1 (explicit skip; offline CI is expected)"
    return
  fi
  local code
  code="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://host.docker.internal:8910/mcp 2>/dev/null || echo 000)"
  if [ "$code" != "000" ]; then
    ok "gateway reachable at host.docker.internal:8910/mcp (HTTP $code)"
  else
    no "gateway reachable at host.docker.internal:8910/mcp (no HTTP response)"
  fi
  echo "  limitation: container-local reachability probe only; gateway capability and"
  echo "              upstream health are host-tier evidence via mcp__ratatoskr, not this smoke"
}

run_docs() {
  sc "docs validation"
  local readme="$REPO/README.md"
  expect_in "README: workflow facets listed" "$readme" '`workflow-designer` and `workflow-delivery`'
  expect_in "README: specialist roles named" "$readme" '`agent-workflow-architect` and `agent-workflow-engineer`'
  expect_in "README: operator approval before handoff" "$readme" 'waits for approval. After approval it hands the plan to `workflow-delivery`'
  expect_in "README: direct delivery invocation provenance" "$readme" 'it does not prove that a plan was reviewed or approved'
  expect_in "README: risk-based TDD policy" "$readme" 'runtime validation instead of forced TDD'
  expect_in "README: Ratatoskr-only MCP routing" "$readme" 'execute through `mcp__ratatoskr`; they do not connect directly to upstream MCP servers'
}

# =====================================================================
# --- lifecycle selftest (deterministic; no daemon, no network) ---
# Tests the shared child tracker and the bounded TERM -> KILL -> reap
# escalation that the EXIT/INT/TERM interrupt paths rely on. Children are
# same-tree coprocesses of this shell (or of the spawned fixture), so signal
# delivery is deterministic; every wait is bounded.
assert_dead() { # label pid
  if kill -0 "$2" 2>/dev/null; then
    no "$1 (pid $2 still alive)"
  else
    ok "$1"
  fi
}
int_trap_probe() { # outfile -> 0 if a coprocess can trap SIGINT here
  # Some non-interactive environments (e.g. this sandbox's tool wrappers)
  # enter with SIGINT ignored; bash cannot trap a signal ignored on entry,
  # so a SIGINT interruption assertion would test the environment, not the
  # harness. Detect that explicitly and report it as a limitation.
  local o="$1" pid i
  bash -c 'trap "echo INT_TRAPPED" INT; sleep 2; echo INT_DONE' > "$o" 2>&1 &
  pid=$!
  sleep 0.4
  kill -INT "$pid" 2>/dev/null
  local stopped=0
  for i in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then stopped=1; break; fi
    sleep 0.25
  done
  if [ "$stopped" != 1 ]; then
    # Never wait unconditionally after a timeout: use the same bounded
    # termination contract as cleanup, then report probe failure.
    kill_child "$pid" || true
    return 1
  fi
  # A confirmed-dead probe may not be this shell's child; never block on wait.
  reap_child "$pid"
  grep -q INT_TRAPPED "$o"
}
run_lifecycle_fixture() { # --_lifecycle-fixture (used only by --selftest)
  # Reports its workdir and tracked child pid, then blocks until signaled.
  # The interrupt traps (added by --selftest's fix) must kill the child via
  # tracked cleanup and remove the workdir before exit.
  local work
  work="$(mktemp -d)"
  WORK_DIRS+=("$work")
  sleep 300 > /dev/null 2>&1 &
  track_child "$!" 1
  { echo "$work"; echo "$!"; } > "$LIFIXTURE_PIDFILE"
  # Short sleeps: bash runs trapped signals only once the current command
  # finishes, so a long sleep would delay the interrupt path needlessly.
  while :; do sleep 1; done
}
run_selftest() {
  sc "lifecycle_selftest: bounded failure paths never block"
  local fake_pid failure_start failure_elapsed
  sleep 30 >/dev/null 2>&1 & fake_pid=$!
  failure_start=$SECONDS
  PROC_DEAD_OVERRIDE=1
  TERM_TIMEOUT=0
  if ! kill_child "$fake_pid" >/dev/null 2>&1; then
    ok "kill_child: still-alive simulation returns failure without blocking"
  else
    no "kill_child: still-alive simulation returns failure without blocking"
  fi
  failure_elapsed=$((SECONDS - failure_start))
  [ "$failure_elapsed" -lt 2 ] && ok "kill_child: still-alive simulation is bounded" \
    || no "kill_child: still-alive simulation is bounded (${failure_elapsed}s)"
  PROC_DEAD_OVERRIDE=""
  TERM_TIMEOUT=2
  local transition_pid
  ( sleep 30 ) & transition_pid=$!
  track_child "$transition_pid" 1
  TERM_TIMEOUT=0
  if ! kill_child "$transition_pid" >/dev/null 2>&1; then
    ok "conditional transition timeout path fails within bounded lifecycle"
  else
    no "conditional transition timeout path fails within bounded lifecycle"
  fi
  TERM_TIMEOUT=2
  kill -KILL "$transition_pid" 2>/dev/null || true
  wait "$transition_pid" 2>/dev/null || true
  CHILD_PIDS=(); CHILD_OWNED=(); WORK_DIRS=(); DAEMON_PID=""
  sc "lifecycle_selftest: dead-child reaping is ownership-aware"
  local zombie_pid foreign_pid foreign_err
  ( exit 0 ) & zombie_pid=$!
  track_child "$zombie_pid" 1
  sleep 0.1
  if kill_child "$zombie_pid"; then
    if ! kill -0 "$zombie_pid" 2>/dev/null; then
      ok "kill_child: shell-owned zombie collected by wait"
    else
      no "kill_child: shell-owned zombie collected by wait (still present)"
    fi
  else
    no "kill_child: shell-owned zombie collected by wait (kill_child failed)"
  fi
  remove_child "$zombie_pid"
  foreign_pid=999999999
  track_child "$foreign_pid" 0
  foreign_err="$(mktemp)"
  if kill_child "$foreign_pid" 2>"$foreign_err"; then
    [ ! -s "$foreign_err" ] && ok "kill_child: confirmed-dead non-child remains quiet" \
      || no "kill_child: confirmed-dead non-child remains quiet (stderr emitted)"
  else
    no "kill_child: confirmed-dead non-child remains quiet (kill_child failed)"
  fi
  rm -f "$foreign_err"
  remove_child "$foreign_pid"
  sc "lifecycle_selftest: cleanup preserves unresolved state and probe timeout is bounded"
  local unresolved_work unresolved_pid probe_start probe_elapsed
  # Keep this fixture outside every pre-existing tracked workdir: cleanup must
  # retain the unresolved entry and therefore must not remove its parent.
  unresolved_work="$(mktemp -d /dev/shm/workflow-facet-unresolved.XXXXXX)"
  WORK_DIRS+=("$unresolved_work")
  # Use a confirmed-dead, non-child PID: the forced probe must not trigger a
  # shell wait diagnostic or require an actual process to remain alive.
  unresolved_pid=999999999
  track_child "$unresolved_pid" 0
  PROC_DEAD_OVERRIDE=1; TERM_TIMEOUT=0
  if ! cleanup >/dev/null 2>&1; then
    [ "${#CHILD_PIDS[@]}" -eq 1 ] && [ "${CHILD_PIDS[0]}" = "$unresolved_pid" ] && ok "cleanup: failed child remains tracked" || no "cleanup: failed child remains tracked (got ${CHILD_PIDS[*]})"
    [ -d "$unresolved_work" ] && ok "cleanup: unresolved child workdir retained" || no "cleanup: unresolved child workdir retained"
  else
    no "cleanup: reports unresolved child failure"
    no "cleanup: failed child remains tracked"
    no "cleanup: unresolved child workdir retained"
  fi
  PROC_DEAD_OVERRIDE=""; TERM_TIMEOUT=2
  kill -KILL "$unresolved_pid" 2>/dev/null || true
  wait "$unresolved_pid" 2>/dev/null || true
  CHILD_PIDS=(); CHILD_OWNED=(); rm -rf "$unresolved_work"; WORK_DIRS=()
  probe_start=$SECONDS
  PROC_DEAD_OVERRIDE=1; TERM_TIMEOUT=0
  if ! int_trap_probe "$(mktemp)" >/dev/null 2>&1; then
    probe_elapsed=$((SECONDS - probe_start))
    [ "$probe_elapsed" -lt 8 ] && ok "int_trap_probe: timeout fails without unbounded wait" || no "int_trap_probe: timeout remains bounded"
  else
    no "int_trap_probe: timeout fails without unbounded wait"
  fi
  PROC_DEAD_OVERRIDE=""; TERM_TIMEOUT=2
  sc "lifecycle_selftest: cleanup tracks every child, TERM then bounded KILL escalation"
  local w sleep_pid stall_pid
  w="$(mktemp -d)"; WORK_DIRS+=("$w")
  # (a) ordinary child: dies to plain TERM.
  sleep 60 > /dev/null 2>&1 &
  sleep_pid=$!
  track_child "$sleep_pid" 1
  # (b) stalling child: ignores TERM, must be escalated to KILL.
  sh -c 'trap "" TERM; while :; do sleep 0.2; done' > /dev/null 2>&1 &
  stall_pid=$!
  track_child "$stall_pid" 1
  # Direct call of the same function the interrupt traps run.
  cleanup
  assert_dead "cleanup: TERM-able child killed" "$sleep_pid"
  assert_dead "cleanup: TERM-ignoring child escalated to KILL" "$stall_pid"
  [ ! -e "$w" ] && ok "cleanup: workdir removed after children handled" \
    || no "cleanup: workdir removed after children handled ($w still exists)"
  [ "${#CHILD_PIDS[@]}" -eq 0 ] && ok "cleanup: child tracker emptied after reap" \
    || no "cleanup: child tracker emptied after reap (${#CHILD_PIDS[@]} left)"

  sc "lifecycle_selftest: SIGINT/SIGTERM interruption runs bounded cleanup"
  local pidfile fixture_out lpid fwork fchild i rc sig want stopped
  local outdir; outdir="$(mktemp -d)"; WORK_DIRS+=("$outdir")
  local int_trappable=1
  if ! int_trap_probe "$outdir/int-trap-probe.out"; then
    int_trappable=0
  fi
  for sig in INT TERM; do
    if [ "$sig" = "INT" ] && [ "$int_trappable" != 1 ]; then
      # SIGINT is ignored on entry in this environment (bash cannot trap a
      # signal ignored on entry, so the signal round would test the sandbox,
      # not the harness). Verify the identical on_interrupt handler instead,
      # executed directly in a subshell with a real tracked child + workdir.
      local hwork hchild
      hwork="$(mktemp -d)"; WORK_DIRS+=("$hwork")
      (
        # Scope the tracker state to this subshell's own entries: cleanup
        # inside the handler must not remove the selftest's own workdirs.
        sleep 300 > /dev/null 2>&1 &
        CHILD_PIDS=("$!")
        CHILD_OWNED=( ["$!"]=1 )
        WORK_DIRS=("$hwork")
        echo "$!" > "$outdir/INT-handler.child"
        on_interrupt INT
      )
      rc=$?
      want=130
      [ "$rc" = "$want" ] && ok "handler ($sig): on_interrupt exited with status $want" \
        || no "handler ($sig): on_interrupt exited with status $want (got $rc)"
      hchild="$(cat "$outdir/INT-handler.child" 2>/dev/null)"
      if [ -n "$hchild" ]; then
        assert_dead "handler ($sig): tracked child killed" "$hchild"
      else
        no "handler ($sig): tracked child killed (child pid not reported)"
      fi
      [ ! -e "$hwork" ] && ok "handler ($sig): workdir removed after children handled" \
        || no "handler ($sig): workdir removed after children handled ($hwork still exists)"
      echo "  limitation: SIGINT is ignored on entry in this environment (not trap-able);"
      echo "              the INT handler was executed directly. Interactive terminals"
      echo "              (Ctrl-C trap-able) get the same handler via the INT trap."
      continue
    fi
    pidfile="$outdir/${sig}.pid"; fixture_out="$outdir/${sig}.out"
    LIFIXTURE_PIDFILE="$pidfile" bash "$0" --_lifecycle-fixture > "$fixture_out" 2>&1 &
    lpid=$!
    track_child "$lpid" 1
    fwork=""; fchild=""
    for i in $(seq 1 40); do
      if [ -f "$pidfile" ]; then
        fwork="$(sed -n 1p "$pidfile")"; fchild="$(sed -n 2p "$pidfile")"
        [ -n "$fwork" ] && break
      fi
      kill -0 "$lpid" 2>/dev/null || break
      sleep 0.25
    done
    # Track the fixture's own child plus its workdir in THIS shell too, so a
    # failed run can never leak them (fallback cleanup at exit).
    [ -n "$fchild" ] && track_child "$fchild" 0
    [ -n "$fwork" ] && WORK_DIRS+=("$fwork")
    if [ -n "$fwork" ]; then
      ok "fixture ($sig): started with tracked child under a real workdir"
    else
      no "fixture ($sig): started with tracked child (pidfile not ready)"
      continue
    fi
    kill -"$sig" "$lpid" 2>/dev/null
    # Bounded wait for the interrupt path: trap -> cleanup -> exit. The wait
    # itself is bounded so a broken interrupt path can never hang this test.
    # 20s bound: the observed handler latency in slow sandboxes is ~5-10s.
    stopped=0
    for i in $(seq 1 80); do
      if ! kill -0 "$lpid" 2>/dev/null; then stopped=1; break; fi
      sleep 0.25
    done
    case "$sig" in INT) want=130 ;; TERM) want=143 ;; *) want=0 ;; esac
    if [ "$stopped" = 1 ]; then
      wait "$lpid" 2>/dev/null; rc=$?
      [ "$rc" = "$want" ] && ok "fixture ($sig): interrupt exited with status $want within 20s" \
        || no "fixture ($sig): interrupt exited with status $want within 20s (got $rc)"
    else
      no "fixture ($sig): did not exit within 20s of SIG$sig — leak guard engaged"
      kill -KILL "$fchild" 2>/dev/null
      kill -KILL "$lpid" 2>/dev/null
      TERM_TIMEOUT=2
      kill_child "$lpid" >/dev/null 2>&1 || true
    fi
    assert_dead "fixture ($sig): tracked child killed on interruption" "$fchild"
    [ ! -e "$fwork" ] && ok "fixture ($sig): workdir removed after children handled on interruption" \
      || no "fixture ($sig): workdir removed after children handled ($fwork still exists)"
  done
}

# =====================================================================
case "${1:-}" in
  --inventory)            run_inventory ;;
  --validate-definitions) run_validate_definitions ;;
  --designer-authority)   run_designer_authority ;;
  --approval-contract)    run_approval_contract ;;
  --delivery-policy)      run_delivery_policy ;;
  --ratatoskr)            run_ratatoskr ;;
  --live-gateway)         run_live_gateway ;;
  --docs)                 run_docs ;;
  --selftest)             run_selftest ;;
  --_lifecycle-fixture)   run_lifecycle_fixture ;;
  ""|full)
    run_inventory
    run_validate_definitions
    run_designer_authority
    run_approval_contract
    run_delivery_policy
    run_ratatoskr
    run_selftest
    run_docs
    ;;
  *)
    echo "usage: $0 [--inventory|--validate-definitions|--designer-authority|--approval-contract|--delivery-policy|--ratatoskr|--live-gateway|--docs|--selftest]" >&2
    exit 2
    ;;
esac
finish
