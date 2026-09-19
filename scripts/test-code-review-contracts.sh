#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; H="$ROOT/scripts/code-review-helper.py"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok(){ echo "ok: $1"; }; bad(){ echo "FAIL: $1" >&2; exit 1; }; run(){ python3 "$H" "$@"; }
cat >"$T/pre.json" <<'JSON'
{"authenticated":true,"read_capable":true,"write_capable":false,"pagination_complete":true,"pages":[[1],[2]]}
JSON
run preflight "$T/pre.json" | grep -q '"status": "ready"' && ok preflight || bad preflight
OUT="$T/outside"; POISON="$T/poisoned-build-hook"; mkdir "$OUT"; printf untouched >"$OUT/write-canary"; printf '#!/bin/sh\ntouch "%s/executed"\n' "$OUT" >"$POISON"; chmod +x "$POISON"
cat >"$T/snap.json" <<'JSON'
{"scope_id":"scope","review_run_id":"run-1","repository":"owner/repo","base_sha":"base","head_sha":"head","merge_base_sha":"merge","stable_identity":true,"pagination_complete":true,"build_hook_path":"__POISON__","files":{"src/a.txt":{"base":"old","head":"new"},"hook":{"head":"x","base":"y","binary":true},"build-hook":{"base":"#!/bin/sh\ntouch __MARKER__\n","head":"#!/bin/sh\ntouch __MARKER__\n","mode":"100755","generated":true}}}
JSON
sed -i "s#__POISON__#$POISON#g; s#__MARKER__#$OUT/hook-executed#g" "$T/snap.json"
mkdir "$T/state"; CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/snap.json" >"$T/capture.json"; grep -q captured "$T/capture.json" || bad snapshot
D=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["snapshot_digest"])' "$T/capture.json"); test -f "$T/state/snapshot/run-1/files/base/src/a.txt" || bad materialized-base; test -f "$T/state/snapshot/run-1/files/head/src/a.txt" || bad materialized-head; grep -q 'digest_algorithm' "$T/state/snapshot/run-1/manifest.json" || bad digest-algorithm; grep -q 'files_inventory' "$T/state/snapshot/run-1/manifest.json" || bad inventory
CODE_REVIEW_STATE_ROOT="$T/state" run verify <(printf '{"snapshot":"%s"}' "$T/state/snapshot/run-1") >/dev/null || bad verify; ok verify
cp -a "$T/state/snapshot/run-1" "$T/old"; if CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/snap.json" >/dev/null 2>&1; then bad run-collision; else ok run-collision; fi; cat >"$T/snap2.json" <<'JSON'
{"scope_id":"scope","review_run_id":"run-2","repository":"owner/repo","base_sha":"base","head_sha":"head","merge_base_sha":"merge","stable_identity":true,"pagination_complete":true,"files":{"src/a.txt":{"base":"old","head":"new"}}}
JSON
CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/snap2.json" >/dev/null; cmp -s "$T/old/manifest.json" "$T/state/snapshot/run-1/manifest.json" || bad immutable-snapshot; ok snapshot-and-immutability
cat >"$T/manifest-snap.json" <<'JSON'
{"scope_id":"scope","review_run_id":"manifest-run","repository":"owner/repo","base_sha":"base","head_sha":"head","merge_base_sha":"merge","stable_identity":true,"pagination_complete":true,"files":{"manifest.json":{"base":"root-base","head":"root-head"},"app/manifest.json":{"base":"nested-base","head":"nested-head"}}}
JSON
CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/manifest-snap.json" >"$T/manifest-capture.json" || bad manifest-capture
MOUT="$T/state/snapshot/manifest-run"; CODE_REVIEW_STATE_ROOT="$T/state" run verify <(printf '{"snapshot":"%s"}' "$MOUT") >/dev/null || bad manifest-verify; ok manifest-root-and-nested-verify
printf tampered >"$MOUT/files/base/manifest.json"; if CODE_REVIEW_STATE_ROOT="$T/state" run verify <(printf '{"snapshot":"%s"}' "$MOUT") >"$T/manifest-root-tamper.out" 2>&1; then bad manifest-root-tamper; else ok manifest-root-tamper-blocked; fi; grep -q 'snapshot digest mismatch' "$T/manifest-root-tamper.out" || bad manifest-root-tamper-reason
CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/manifest-snap.json" >/dev/null 2>&1 && bad manifest-run-collision || true
rm -rf "$MOUT"; CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/manifest-snap.json" >/dev/null || bad manifest-recapture
MOUT="$T/state/snapshot/manifest-run"; printf tampered >"$MOUT/files/head/app/manifest.json"; if CODE_REVIEW_STATE_ROOT="$T/state" run verify <(printf '{"snapshot":"%s"}' "$MOUT") >"$T/manifest-nested-tamper.out" 2>&1; then bad manifest-nested-tamper; else ok manifest-nested-tamper-blocked; fi; grep -q 'snapshot digest mismatch' "$T/manifest-nested-tamper.out" || bad manifest-nested-tamper-reason
cat >"$T/incomplete.json" <<'JSON'
{"authenticated":true,"read_capable":true,"pagination_complete":false,"pages":[]}
JSON
if run preflight "$T/incomplete.json" >/dev/null 2>&1; then bad pagination-negative; else ok pagination-negative; fi
cat >"$T/candidate.json" <<JSON
{"expected":{"head_sha":"head","snapshot_digest":"$D","scope_id":"scope","review_run_id":"run-1"},"candidate":{"head_sha":"wrong","snapshot_digest":"bad","scope_id":"scope","review_run_id":"run-1"}}
JSON
if run candidate "$T/candidate.json" >/dev/null 2>&1; then bad candidate-mismatch; else ok candidate-mismatch; fi
cat >"$T/journal.json" <<'JSON'
{"root":"x","event":{"scope_id":"scope","review_run_id":"run-1","state":"started"}}
JSON
J="$T/state/journal.jsonl"; run journal "$T/journal.json" "$J" "$T/state" >/dev/null; printf '{bad\n' >>"$J"; if run journal "$T/journal.json" "$J" "$T/state" >/dev/null 2>&1; then bad corrupt-journal; else ok corrupt-journal; fi
for invalid_record in null '[]' '{}'; do
  printf '%s\n' "$invalid_record" >"$T/invalid-journal.jsonl"; before=$(sha256sum "$T/invalid-journal.jsonl"); printf '{"event":{"review_run_id":"run-1","state":"next"}}\n' >"$T/valid-event.json"
  if run journal "$T/valid-event.json" "$T/invalid-journal.jsonl" "$T/state" >"$T/invalid-journal.out" 2>&1; then bad "journal-$invalid_record-accepted"; else ok "journal-$invalid_record-blocked"; fi
  test "$before" = "$(sha256sum "$T/invalid-journal.jsonl")" || bad "journal-$invalid_record-mutated"
  grep -q '"status": "blocked"' "$T/invalid-journal.out" || bad "journal-$invalid_record-blocked-json"
done
cat >"$T/follow.json" <<'JSON'
{"prior":{"repository":"owner/repo","base_sha":"base","merge_base_sha":"merge"},"current":{"repository":"owner/repo","base_sha":"changed","merge_base_sha":"merge","changed_paths":["b"]},"unresolved_paths":["a"]}
JSON
if run followup "$T/follow.json" >/dev/null 2>&1; then bad changed-base; else ok changed-base; fi
cat >"$T/force.json" <<'JSON'
{"prior":{"repository":"owner/repo","base_sha":"base","merge_base_sha":"merge"},"current":{"repository":"owner/repo","base_sha":"base","merge_base_sha":"merge","force_pushed":true,"changed_paths":["b"]}}
JSON
if run followup "$T/force.json" >/dev/null 2>&1; then bad force-push; else ok force-push; fi
cat >"$T/target.json" <<'JSON'
{"prior":{"repository":"owner/repo","base_sha":"base","merge_base_sha":"merge"},"current":{"repository":"owner/repo","base_sha":"base","merge_base_sha":"merge","changed_paths":["b"]},"unresolved_paths":["a"]}
JSON
run followup "$T/target.json" | grep -q '"paths": \["a", "b"\]' && ok changed-hunk-targets || bad changed-hunk-targets
test ! -e "$OUT/hook-executed" && ok AC.8-build-hook-uninvoked || bad AC.8-build-hook; test "$(cat "$OUT/write-canary")" = untouched && ok AC.8-outside-canary-unchanged || bad AC.8-outside-canary; test -e "$T/state/snapshot/run-1/manifest.json" || bad state-root; ok AC.8-state-root
cat >"$T/missing.json" <<'JSON'
{"expected":{"head_sha":"head","snapshot_digest":"x","scope_id":"scope","review_run_id":"run"},"candidate":{}}
JSON
if run candidate "$T/missing.json" >/dev/null 2>&1; then bad missing-evidence-clean; else ok missing-evidence-blocked; fi
cat >"$T/bounds.json" <<'JSON'
{"authenticated":true,"read_capable":true,"pagination_complete":true,"pages":[],"acquisition_attempts":"bad"}
JSON
if run snapshot "$T/bounds.json" >/dev/null 2>&1; then bad malformed-bounds; else ok malformed-bounds-json-blocked; fi
mkdir -p "$T/checkout" "$T/trusted"; printf '#!/bin/sh\n' >"$T/checkout/code-review-helper.py"; chmod +x "$T/checkout/code-review-helper.py"; printf '# trusted\n' >"$T/trusted/code-review-helper.py"
cat >"$T/resolve.json" <<JSON
{"helper_path":"$T/checkout/code-review-helper.py","target_checkout":"$T/checkout"}
JSON
if run resolve "$T/resolve.json" >/dev/null 2>&1; then bad malicious-helper; else ok malicious-helper-rejected; fi
cat >"$T/resolve-good.json" <<JSON
{"helper_path":"$T/trusted/code-review-helper.py","target_checkout":"$T/checkout"}
JSON
run resolve "$T/resolve-good.json" >/dev/null || bad trusted-helper; ok trusted-helper
ln -s "$T/outside" "$T/state/link-out" 2>/dev/null || true
ln -s "$OUT" "$T/state/outside-link"
cat >"$T/escape.json" <<JSON
{"scope_id":"scope","review_run_id":"escape","repository":"owner/repo","base_sha":"b","head_sha":"h","merge_base_sha":"m","stable_identity":true,"pagination_complete":true,"files":{"../../../../../../outside/escaped":{"base":"x","head":"y"}}}
JSON
escape_rc=0; CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/escape.json" >"$T/escape.out" 2>/dev/null || escape_rc=$?; if [ -e "$OUT/escaped" ]; then bad traversal-canary; else ok traversal-canary-absent; fi; [ "$escape_rc" -ne 0 ] && ok traversal-helper-failed-closed || bad traversal-helper-failed-closed; grep -q '"status": "blocked"' "$T/escape.out" && ok traversal-blocked-json || bad traversal-blocked-json; test ! -e "$T/state/snapshot/escape" && ok traversal-no-artifacts || bad traversal-artifacts
cat >"$T/inside-traversal.json" <<'JSON'
{"scope_id":"scope","review_run_id":"inside-traversal","repository":"owner/repo","base_sha":"b","head_sha":"h","merge_base_sha":"m","stable_identity":true,"pagination_complete":true,"files":{"src/../inside":{"base":"x","head":"y"}}}
JSON
inside_rc=0; CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$T/inside-traversal.json" >"$T/inside-traversal.out" 2>/dev/null || inside_rc=$?; [ "$inside_rc" -ne 0 ] && ok inside-root-traversal-blocked || bad inside-root-traversal; grep -q '"status": "blocked"' "$T/inside-traversal.out" && ok inside-traversal-blocked-json || bad inside-traversal-blocked-json; test ! -e "$T/state/snapshot/inside-traversal" && ok inside-traversal-no-artifacts || bad inside-traversal-artifacts
for invalid_path in './src/a' 'src/./a'; do
  run_id="raw-dot-${invalid_path#./}"; run_id=${run_id//\//-}; input="$T/$run_id.json"; output="$T/$run_id.out"
  printf '{"scope_id":"scope","review_run_id":"%s","repository":"owner/repo","base_sha":"b","head_sha":"h","merge_base_sha":"m","stable_identity":true,"pagination_complete":true,"files":{"%s":{"base":"x","head":"y"}}}\n' "$run_id" "$invalid_path" >"$input"
  dot_rc=0; CODE_REVIEW_STATE_ROOT="$T/state" run snapshot "$input" >"$output" 2>/dev/null || dot_rc=$?
  [ "$dot_rc" -ne 0 ] && ok "raw-path-$invalid_path-blocked" || bad "raw-path-$invalid_path-accepted"
  grep -q '"status": "blocked"' "$output" && ok "raw-path-$invalid_path-blocked-json" || bad "raw-path-$invalid_path-json"
  test ! -e "$T/state/snapshot/$run_id" && ok "raw-path-$invalid_path-no-artifacts" || bad "raw-path-$invalid_path-artifacts"
done
test ! -e "$OUT/executed" && ok poison-payload-marker-absent || bad poison-payload-marker
PYTHONPYCACHEPREFIX="$T/pycache" python3 -m py_compile "$H"; test -e "$T/pycache" && ok pycache-isolated || bad pycache-location; ok syntax
