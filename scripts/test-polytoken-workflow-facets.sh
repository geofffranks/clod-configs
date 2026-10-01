#!/usr/bin/env bash
# Existing facet loader/effective-tool checks; no prompt phrase assertions.
set -euo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"
LIVE_CFG=${POLYTOKEN_USER_CONFIG_DIR:-$HOME/.config/polytoken}
T=$(mktemp -d); PID=''
cleanup() {
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 40); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null || true; fi
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
inventory() {
  local actual expected
  actual=$(printf '%s\n' polytoken/facets/*.md | xargs -n1 basename | sort)
  expected=$(printf '%s\n' code-review.md process-friction-triage.md product-design.md project-manager.md quick-delivery.md | sort)
  test "$actual" = "$expected"
  test "$(printf '%s\n' polytoken/subagents/*.md | wc -l)" -eq 16
  echo 'PASS: three lifecycle facets, standalone facets preserved, sixteen subagents'
}
validate() {
  for f in polytoken/facets/*.md; do polytoken validate facet "$REPO/$f"; done
  for f in polytoken/subagents/*.md; do polytoken validate subagent "$REPO/$f"; done
  for f in home/skills/*/SKILL.md; do polytoken validate skill "$REPO/$f"; done
  echo 'PASS: official source definition parser'
}
start_daemon() {
  command -v jq >/dev/null; command -v yq >/dev/null
  mkdir -p "$T/config/facets" "$T/config/subagents" "$T/project" "$T/sessions"
  cp "$LIVE_CFG/config.yaml" "$T/config/config.yaml"
  cp -R polytoken/facets/. "$T/config/facets/"
  cp -R polytoken/subagents/. "$T/config/subagents/"
  # Effective-tools on this CLI cannot resolve installed @mg groups. Pin only
  # copied facet definitions for tool exposure checks; source/live routing stays
  # unchanged and this does not validate quota/model-group routing.
  for f in "$T/config/facets/"*.md; do
    sed -i 's/model: "@mg:pm_facet"/model: "codex\/gpt-6-luna"/' "$f"
  done
  echo 'limitation: isolated concrete model fixture; quota/model-group routing untested'
  # No live mutation/provider invocation: isolated config, artifacts and daemon.
  TOKEN=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
  printf '{"version":1,"kind":"polytoken-daemon-credential","token":"%s"}' "$TOKEN" > "$T/credential.json"
  chmod 600 "$T/credential.json"
  PORT=$((20000 + RANDOM % 40000)); URL="http://127.0.0.1:$PORT"
  polytoken daemon --global-config-dir "$T/config" --project-dir "$T/project" \
    --sessions-dir "$T/sessions" --credential-file "$T/credential.json" \
    --listen "127.0.0.1:$PORT" > "$T/daemon.log" 2>&1 & PID=$!
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 1 -H "Authorization: Bearer $TOKEN" "$URL/health" >/dev/null 2>&1; then return; fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.5
  done
  echo 'FAIL: isolated daemon unavailable' >&2
  tail -n 12 "$T/daemon.log" >&2
  return 1
}
api() { curl --fail-with-body -sS --max-time 20 -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "$@"; }
contains() { jq -e --arg n "$2" '.plan.full_schema | any(.name == $n)' "$1" >/dev/null; }
effective() {
  start_daemon
  for facet in product-design project-manager quick-delivery code-review; do
    if ! api "$URL/tools/effective?facet=$facet" > "$T/$facet.json"; then
      echo "FAIL: effective tools for $facet" >&2
      cat "$T/$facet.json" >&2
      return 1
    fi
  done
  for n in file_read shell_exec subagent write_plan handoff_plan; do contains "$T/product-design.json" "$n"; done
  for n in file_write file_edit_search_replace shell_service switch_facet complete_goal; do
    if contains "$T/product-design.json" "$n"; then echo "FAIL: designer exposes $n" >&2; return 1; fi
  done
  for facet in project-manager quick-delivery; do
    for n in file_write file_edit_search_replace shell_exec lsp subagent; do contains "$T/$facet.json" "$n"; done
    for n in write_plan edit_plan handoff_plan; do
      if contains "$T/$facet.json" "$n"; then echo "FAIL: $facet exposes $n" >&2; return 1; fi
    done
    jq -e 'all(.plan.full_schema[]; (.name | startswith("mcp__") | not) or (.name | startswith("mcp__ratatoskr__")))' "$T/$facet.json" >/dev/null
  done
  for n in web_fetch web_search file_edit_search_replace lsp shell_service; do
    if contains "$T/code-review.json" "$n"; then echo "FAIL: snapshot coordinator exposes $n" >&2; return 1; fi
  done
  # Controller transitions test capability, not an agent's approval obedience.
  # The copied config starts in product-design; avoid a no-change request.
  for facet in project-manager quick-delivery product-design; do
    if ! api -X POST -d "{\"facet\":\"$facet\"}" "$URL/facet" > "$T/transition.json"; then
      echo "FAIL: controller transition to $facet" >&2
      cat "$T/transition.json" >&2
      return 1
    fi
  done
  echo 'PASS: isolated effective-tool grants/denies and three facet transitions'
}
case "${1:-}" in
  --inventory) inventory ;;
  --validate-definitions) validate ;;
  --designer-authority|--delivery-policy|--approval-contract|--ratatoskr) effective ;;
  --code-review-contracts) bash scripts/test-code-review-contracts.sh ;;
  --docs) echo 'MANUAL: review role split, Git choices, panel budgets, manual completion and conditional tool procedures; no parser proves obedience' ;;
  --selftest) bash -n "$0"; echo 'PASS: harness shell syntax; runtime cleanup exercised by effective-tool mode' ;;
  ''|full) inventory; validate; effective; bash scripts/test-code-review-contracts.sh ;;
  *) echo "usage: $0 [--inventory|--validate-definitions|--designer-authority|--delivery-policy|--approval-contract|--ratatoskr|--code-review-contracts|--docs|--selftest]" >&2; exit 2 ;;
esac
