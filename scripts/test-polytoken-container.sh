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

echo "==> image/repo carry no MCP wrapper layer"
if grep -q "mcp-wrappers" "$ROOT/polytoken-container/Dockerfile"; then
  no "Dockerfile free of mcp-wrappers"
else
  ok "Dockerfile free of mcp-wrappers"
fi
if [ -d "$ROOT/polytoken-container/mcp-wrappers" ]; then
  no "mcp-wrappers directory absent"
else
  ok "mcp-wrappers directory absent"
fi
if grep -qiE 'MCP wrappers?|go run' "$ROOT/polytoken-container/run.sh" "$ROOT/polytoken-container/build.sh"; then
  no "run.sh/build.sh free of stale wrapper references"
else
  ok "run.sh/build.sh free of stale wrapper references"
fi

echo "==> image includes the local polytoken-quota checkout"
quota_tmp="$(mktemp -d)"
quota_capture="$quota_tmp/docker-args"
quota_fake="$quota_tmp/docker"
mkdir -p "$quota_tmp/quota/cmd/polytoken-quota"
printf 'module example/polytoken-quota\ngo 1.26.5\n' > "$quota_tmp/quota/go.mod"
cat > "$quota_fake" <<'DOCKER'
#!/usr/bin/env bash
printf 'BUILDKIT=%s\nARGS=%s\n' "$DOCKER_BUILDKIT" "$*" > "$DOCKER_CAPTURE"
DOCKER
chmod +x "$quota_fake"
if DOCKER_CAPTURE="$quota_capture" POLYTOKEN_QUOTA_DIR="$quota_tmp/quota" DOCKER_BIN="$quota_fake" \
    "$ROOT/polytoken-container/build.sh" >/dev/null 2>&1 \
    && grep -q -- '^BUILDKIT=1$' "$quota_capture" \
    && grep -q -- '--build-context quota=' "$quota_capture" \
    && grep -q -- "$quota_tmp/quota" "$quota_capture"; then
  ok "build.sh passes absolute quota context with BuildKit"
else
  no "build.sh passes absolute quota context with BuildKit"
fi
quota_missing_capture="$quota_tmp/missing-docker-args"
if DOCKER_CAPTURE="$quota_missing_capture" POLYTOKEN_QUOTA_DIR="$quota_tmp/missing" DOCKER_BIN="$quota_fake" \
    "$ROOT/polytoken-container/build.sh" >/dev/null 2>&1; then
  no "build.sh rejects missing quota checkout"
elif [ -e "$quota_missing_capture" ]; then
  no "build.sh rejects missing quota checkout before Docker"
else
  ok "build.sh rejects missing quota checkout before Docker"
fi
rm -rf "$quota_tmp"
if grep -q -- '--build-context quota=' "$ROOT/polytoken-container/build.sh"; then
  ok "build.sh supplies quota named context"
else
  no "build.sh supplies quota named context"
fi
if grep -q -- 'POLYTOKEN_QUOTA_DIR' "$ROOT/polytoken-container/build.sh" \
    && grep -q -- 'pwd' "$ROOT/polytoken-container/build.sh"; then
  ok "build.sh supports absolute quota source override"
else
  no "build.sh supports absolute quota source override"
fi
if grep -q -- 'go@1.26.5' "$ROOT/polytoken-container/Dockerfile" \
    && grep -q -- '1.26.5' "$ROOT/polytoken-container/README.md"; then
  ok "image pins the quota-required Go version"
else
  no "image pins the quota-required Go version"
fi
if grep -q -- 'COPY --from=quota' "$ROOT/polytoken-container/Dockerfile"; then
  ok "Dockerfile copies quota named context"
else
  no "Dockerfile copies quota named context"
fi
if grep -q -- 'go build' "$ROOT/polytoken-container/Dockerfile" \
    && grep -q -- './cmd/polytoken-quota' "$ROOT/polytoken-container/Dockerfile"; then
  ok "Dockerfile builds quota command"
else
  no "Dockerfile builds quota command"
fi
if grep -q -- '/home/dev/.local/bin/polytoken-quota' "$ROOT/polytoken-container/Dockerfile"; then
  ok "Dockerfile installs quota binary on PATH"
else
  no "Dockerfile installs quota binary on PATH"
fi

if grep -q -- 'polytoken-quota' "$ROOT/polytoken-container/README.md"; then
  ok "README documents quota binary"
else
  no "README documents quota binary"
fi

echo "==> $pass passed, $fail failed"
(( fail == 0 ))
