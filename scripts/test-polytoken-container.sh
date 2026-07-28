#!/usr/bin/env bash
# Regression tests for polytoken-container/run.sh permission-mode enforcement.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/polytoken-container/run.sh"

pass=0
fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  not ok: $1" >&2; fail=$((fail + 1)); }

run_case() {
  local name="$1" existing="$2" docker_fail="${3:-0}" docker_signal="${4:-0}"
  local tmp home project fakebin capture original
  tmp="$(mktemp -d)"
  home="$tmp/home"
  project="$home/workspace/example"
  fakebin="$tmp/bin"
  capture="$tmp/launch-config.yaml"
  mkdir -p "$project" "$home/.config/polytoken" "$home/bin" "$fakebin"

  cat > "$fakebin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" -it "* ]]; then
  cp "$PWD/.polytoken/config.yaml" "$CAPTURE"
  if [[ "${DOCKER_SIGNAL:-0}" == 1 ]]; then
    kill -TERM "$PPID"
    sleep 1
    exit 143
  fi
  if [[ "${DOCKER_FAIL:-0}" == 1 ]]; then
    exit 17
  fi
fi
exit 0
DOCKER
  chmod +x "$fakebin/docker"

  if [[ "$existing" == 1 ]]; then
    mkdir -p "$project/.polytoken"
    original=$'version: 2\ndefault_permission_matcher: autonomous\ncustom_key: preserved\n'
    printf '%s' "$original" > "$project/.polytoken/config.yaml"
  else
    original=""
  fi

  (
    cd "$project" || exit 1
    HOME="$home" CAPTURE="$capture" DOCKER_FAIL="$docker_fail" DOCKER_SIGNAL="$docker_signal" PATH="$fakebin:$PATH" \
      POLY_PASS_ENV= bash "$LAUNCHER" >/dev/null 2>&1
  )
  local rc=$?

  if [[ "$docker_signal" == 1 ]]; then
    if [[ "$rc" -eq 143 ]]; then
      ok "$name: launcher propagates signal termination"
    else
      no "$name: launcher propagates signal termination"
    fi
  elif [[ "$docker_fail" == 1 ]]; then
    if [[ "$rc" -eq 17 ]]; then
      ok "$name: launcher propagates container failure"
    else
      no "$name: launcher propagates container failure"
    fi
  elif [[ "$rc" -ne 0 ]]; then
    no "$name: launcher exited successfully"
  else
    ok "$name: launcher exited successfully"
  fi

  if [[ -f "$capture" ]] && [[ "$(yq -r '.default_permission_matcher' "$capture" 2>/dev/null)" == "bypass_plus" ]]; then
    ok "$name: launch config forces bypass_plus"
  else
    no "$name: launch config forces bypass_plus"
  fi

  if [[ "$existing" == 1 ]]; then
    if [[ -f "$project/.polytoken/config.yaml" ]] && cmp -s <(printf '%s' "$original") "$project/.polytoken/config.yaml"; then
      ok "$name: existing project config restored unchanged"
    else
      no "$name: existing project config restored unchanged"
    fi
  elif [[ ! -e "$project/.polytoken/config.yaml" ]]; then
    ok "$name: generated project config removed"
  else
    no "$name: generated project config removed"
  fi

  rm -rf "$tmp"
}

echo "==> polytoken container permission-mode regression"
run_case "absent project config" 0
run_case "existing project config" 1
run_case "failed container with existing project config" 1 1
run_case "signaled container with existing project config" 1 0 1

echo "==> $pass passed, $fail failed"
(( fail == 0 ))
