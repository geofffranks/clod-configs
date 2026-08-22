#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/lsp-servers.yaml"
FIXTURES="$ROOT/scripts/fixtures/lsp"
IMAGE="${POLY_IMAGE:-}"
ENGINE="${DOCKER_BIN:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing host command: $1"; }

parse_options() {
  COMMAND=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image) [[ $# -ge 2 ]] || fail "--image requires a value"; IMAGE="$2"; shift 2 ;;
      --engine) [[ $# -ge 2 ]] || fail "--engine requires a value"; ENGINE="$2"; shift 2 ;;
      manifest|artifacts|routing|config|protocol|native|docs|build-contract|executables|all)
        [[ -z "$COMMAND" ]] || fail "multiple subcommands supplied"; COMMAND="$1"; shift ;;
      *) fail "unknown option or subcommand: $1" ;;
    esac
  done
  COMMAND="${COMMAND:-all}"
}

[[ -f "$MANIFEST" ]] || fail "missing lsp-servers.yaml"
[[ -d "$FIXTURES" ]] || fail "missing scripts/fixtures/lsp"
need yq

manifest() {
  yq -e '.version == 1 and (.servers | type == "!!seq") and (.servers | length > 0)' "$MANIFEST" >/dev/null \
    || fail "manifest must declare version 1 and a non-empty servers list"
  local count
  count="$(yq '.servers | length' "$MANIFEST")"
  [[ "$count" -eq 17 ]] || fail "manifest must contain the selected 17 servers: $count"
  local duplicate_names
  duplicate_names="$(yq -r '.servers[].name' "$MANIFEST" | sort | uniq -d | head -n 1)"
  [[ -z "$duplicate_names" ]] || fail "duplicate manifest server name: $duplicate_names"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    yq -e ".servers[] | select(.name == \"$name\") | select((.version | length) > 0) | select((.source | length) > 0) | select((.executable | length) > 0) | select(.args != null and (.args | type == \"!!seq\")) | select((.language_id | length) > 0) | select((.root_markers | length) > 0) | select((.role | test(\"^(primary|auxiliary)$\"))) | select((.architectures | length) > 0) | select((.install.kind | length) > 0) | select((.install.destination | length) > 0) | select((.install.launcher | length) > 0) | select((.file_types | length) > 0 or (.filename_patterns | length) > 0)" "$MANIFEST" >/dev/null \
      || fail "incomplete manifest record: $name"
    while IFS= read -r architecture; do
      [[ "$architecture" == amd64 || "$architecture" == arm64 ]] || fail "unsupported architecture in manifest: $name -> $architecture"
    done < <(yq -r ".servers[] | select(.name == \"$name\") | .architectures[]" "$MANIFEST")
    kind="$(yq -r ".servers[] | select(.name == \"$name\") | .install.kind" "$MANIFEST")"
    case "$kind" in
      npm|archive|binary|apt|go|rustup|swiftly) ;;
      *) fail "unsupported install kind in manifest: $name -> $kind" ;;
    esac
    package="$(yq -r ".servers[] | select(.name == \"$name\") | .install.package // \"\"" "$MANIFEST")"
    case "$kind" in
      apt|go|rustup|swiftly) [[ -n "$package" ]] || fail "install package is required for $name ($kind)" ;;
    esac
    if [[ "$kind" == "npm" ]]; then
      package="$(yq -r ".servers[] | select(.name == \"$name\") | .install.package" "$MANIFEST")"
      source="$(yq -r ".servers[] | select(.name == \"$name\") | .source" "$MANIFEST")"
      [[ -n "$package" && "$source" == npm:* ]] || fail "npm record lacks package/source metadata: $name"
    fi
    if [[ "$kind" == "archive" || "$kind" == "binary" ]]; then
      yq -e ".servers[] | select(.name == \"$name\") | select((.sources.amd64 | length) > 0) | select((.sources.arm64 | length) > 0)" "$MANIFEST" >/dev/null \
        || fail "native record lacks explicit architecture URLs: $name"
    fi
  done < <(yq -r '.servers[].name' "$MANIFEST")
  local duplicate
  duplicate="$(yq -r '.servers[] | select(.role == "primary") | .file_types[]?' "$MANIFEST" | sort | uniq -d | head -n 1)"
  [[ -z "$duplicate" ]] || fail "duplicate primary file-type route: $duplicate"
}

artifacts() {
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    version="$(yq -r ".servers[] | select(.name == \"$name\") | .version" "$MANIFEST")"
    if [[ "$version" != toolchain:* && ! "$version" =~ ^[0-9] ]]; then
      fail "unreproducible or architecture-less artifact: $name"
    fi
    yq -e ".servers[] | select(.name == \"$name\") | select((.source | length) > 0) | select((.architectures | length) > 0) | select(.install.kind != null) | select((.install.destination | length) > 0) | select((.install.launcher | length) > 0)" "$MANIFEST" >/dev/null \
      || fail "incomplete artifact metadata: $name"
    kind="$(yq -r ".servers[] | select(.name == \"$name\") | .install.kind" "$MANIFEST")"
    source="$(yq -r ".servers[] | select(.name == \"$name\") | .source" "$MANIFEST")"
    if [[ "$kind" == "npm" ]]; then
      [[ "$source" == npm:*@* ]] || fail "npm source is not pinned: $name"
    elif [[ "$kind" == "archive" || "$kind" == "binary" ]]; then
      yq -e ".servers[] | select(.name == \"$name\") | select((.install.checksum.amd64 | length) == 64) | select((.install.checksum.arm64 | length) == 64)" "$MANIFEST" >/dev/null \
        || fail "native artifact lacks amd64/arm64 checksums: $name"
      [[ "$source" == https://* ]] || fail "native artifact source is not an HTTPS URL: $name"
    fi
  done < <(yq -r '.servers[].name' "$MANIFEST")
}

routing() {
  [[ -f "$FIXTURES/routing.txt" ]] || fail "missing routing fixture"
  while IFS='|' read -r path expected role; do
    [[ -z "$path" || "$path" == \#* ]] && continue
    actual_ext=".${path##*.}"
    if [[ "$path" == "Dockerfile" || "$path" == Dockerfile.* ]]; then actual_ext=""; fi
    found=0
    while IFS= read -r server; do
      [[ -n "$server" ]] || continue
      server_role="$(yq -r ".servers[] | select(.name == \"$server\") | .role" "$MANIFEST")"
      [[ "$server_role" == "$role" ]] || continue
      route_match=0
      if [[ "$actual_ext" != "" ]]; then
        while IFS= read -r extension; do
          [[ "$extension" == "$actual_ext" ]] && route_match=1
        done < <(yq -r ".servers[] | select(.name == \"$server\") | .file_types[]?" "$MANIFEST")
      elif [[ "$path" == Dockerfile* && "$server" == "$expected" ]] && yq -e ".servers[] | select(.name == \"$server\") | .filename_patterns[]? | select(. == \"^Dockerfile(\\\\..*)?\")" "$MANIFEST" >/dev/null; then
        route_match=1
      fi
      if [[ "$route_match" -eq 1 ]]; then
        if [[ "$role" == "primary" ]]; then
          [[ "$server" == "$expected" ]] || fail "fixture route is claimed by $server, expected $expected: $path"
          found=$((found + 1))
        elif [[ "$server" == "$expected" ]]; then
          found=$((found + 1))
        fi
      fi
    done < <(yq -r '.servers[].name' "$MANIFEST")
    if [[ "$role" == "primary" ]]; then
      [[ "$found" -eq 1 ]] || fail "routing fixture must have exactly one expected primary: $path -> $expected ($role)"
    else
      [[ "$found" -eq 1 ]] || fail "routing fixture missing expected auxiliary: $path -> $expected ($role)"
    fi
    yq -r ".servers[] | select(.name == \"$expected\") | .role" "$MANIFEST" | grep -Fxq "$role" \
      || fail "routing fixture declares unknown server/role: $path -> $expected ($role)"
  done < "$FIXTURES/routing.txt"
}

config() {
  local parent="$(cd "$ROOT/.." && pwd)" tmp
  [[ -f "$parent/scripts/install-polytoken.sh" ]] || fail "parent installer not found: $parent/scripts/install-polytoken.sh"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  POLYTOKEN_CONFIG_DIR="$tmp" POLYTOKEN_CONFIG_TTY=/dev/null bash "$parent/scripts/install-polytoken.sh" 0 >/dev/null
  yq -e '.daemon.lsp.enabled == true and (.daemon.lsp.servers | length > 0)' "$tmp/config.yaml" >/dev/null \
    || fail "installed config has no enabled LSP servers"
  yq -e '(.daemon.lsp.servers | keys | length) == 17' "$tmp/config.yaml" >/dev/null \
    || fail "installed config must have exactly 17 LSP mappings"
  expected_names="$(yq -r '.servers[].name' "$MANIFEST" | sort | tr '\n' ' ')"
  actual_names="$(yq -r '.daemon.lsp.servers | keys[]' "$tmp/config.yaml" | sort | tr '\n' ' ')"
  [[ "$actual_names" == "$expected_names" ]] || fail "config server keys drift from manifest"
  if command -v polytoken >/dev/null 2>&1; then
    validation_output="$(polytoken --config-dir "$tmp" config validate --user 2>&1)" || validation_status=$?
    if [[ "${validation_status:-0}" -ne 0 ]]; then
      grep -Fq 'at least one provider is required' <<<"$validation_output" \
        || fail "generated user config failed for an unexpected validation reason: $validation_output"
    fi
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    expected="$(yq -r ".servers[] | select(.name == \"$name\") | .executable" "$MANIFEST")"
    expected_args="$(yq -r ".servers[] | select(.name == \"$name\") | .args | join(\" \")" "$MANIFEST")"
    expected_language="$(yq -r ".servers[] | select(.name == \"$name\") | .language_id" "$MANIFEST")"
    expected_files="$(yq -r ".servers[] | select(.name == \"$name\") | .file_types | join(\" \")" "$MANIFEST")"
    expected_roots="$(yq -r ".servers[] | select(.name == \"$name\") | .root_markers | join(\" \")" "$MANIFEST")"
    actual="$(yq -r ".daemon.lsp.servers.\"$name\".command // \"\"" "$tmp/config.yaml")"
    actual_args="$(yq -r ".daemon.lsp.servers.\"$name\".args // [] | join(\" \")" "$tmp/config.yaml")"
    actual_language="$(yq -r ".daemon.lsp.servers.\"$name\".language_id // \"\"" "$tmp/config.yaml")"
    actual_files="$(yq -r ".daemon.lsp.servers.\"$name\".file_types // [] | join(\" \")" "$tmp/config.yaml")"
    actual_roots="$(yq -r ".daemon.lsp.servers.\"$name\".root_markers // [] | join(\" \")" "$tmp/config.yaml")"
    [[ "$actual" == "$expected" ]] || fail "config command mismatch for $name: $actual != $expected"
    [[ "$actual_args" == "$expected_args" ]] || fail "config args mismatch for $name: $actual_args != $expected_args"
    [[ "$actual_language" == "$expected_language" ]] || fail "config language mismatch for $name: $actual_language != $expected_language"
    [[ "$actual_files" == "$expected_files" ]] || fail "config file types mismatch for $name: $actual_files != $expected_files"
    [[ "$actual_roots" == "$expected_roots" ]] || fail "config root markers mismatch for $name: $actual_roots != $expected_roots"
  done < <(yq -r '.servers[].name' "$MANIFEST")
  yq -e '.servers[] | select(.name == "docker-langserver") | .filename_patterns[] == "^Dockerfile(\\..*)?"' "$MANIFEST" >/dev/null \
    || fail "manifest drops Dockerfile filename pattern"
  yq -e '.daemon.lsp.servers."docker-langserver".filename_patterns[] == "^Dockerfile(\\..*)?"' "$tmp/config.yaml" >/dev/null \
    || fail "config drops Dockerfile filename pattern"
}

require_runtime_image() {
  [[ -n "$IMAGE" ]] || fail "runtime checks require --image IMAGE (or POLY_IMAGE)"
  [[ -n "$ENGINE" ]] || fail "runtime checks require --engine docker|podman (or DOCKER_BIN)"
  need "$ENGINE"
  "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1 \
    || fail "image is not available locally: $IMAGE"
}

protocol() {
  require_runtime_image
  "$ENGINE" run --rm -i "$IMAGE" sh -lc '
    set -eu
    python3 - <<'PY'
import json, subprocess, sys
servers = [
    ["typescript-language-server", "--stdio"], ["pyright-langserver", "--stdio"],
    ["yaml-language-server", "--stdio"], ["bash-language-server", "start"],
    ["vscode-json-language-server", "--stdio"], ["vscode-css-language-server", "--stdio"],
    ["vscode-html-language-server", "--stdio"],
]
def send(proc, message):
    body = json.dumps(message).encode()
    proc.stdin.write(b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
    proc.stdin.flush()
def receive(proc):
    headers = b""
    while b"\r\n\r\n" not in headers:
        chunk = proc.stdout.read(1)
        if not chunk:
            raise SystemExit("protocol closed before response")
        headers += chunk
    length = next(int(line.split(b":", 1)[1]) for line in headers.split(b"\r\n") if line.lower().startswith(b"content-length:"))
    return json.loads(proc.stdout.read(length))
for command in servers:
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    send(proc, {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":None,"rootUri":None,"capabilities":{}}})
    initialized = receive(proc)
    if initialized.get("id") != 1 or "result" not in initialized:
        raise SystemExit(f"invalid initialize response: {command[0]}")
    send(proc, {"jsonrpc":"2.0","method":"initialized","params":{}})
    send(proc, {"jsonrpc":"2.0","id":2,"method":"shutdown","params":None})
    shutdown = receive(proc)
    if shutdown.get("id") != 2 or "result" not in shutdown:
        raise SystemExit(f"invalid shutdown response: {command[0]}")
    proc.stdin.close()
    proc.wait(timeout=10)
    if proc.returncode != 0:
        raise SystemExit(f"protocol exit {proc.returncode}: {command[0]}")
print("protocol initialize/shutdown probes passed")
PY
  '
}

native() {
  require_runtime_image
  "$ENGINE" run --rm "$IMAGE" sh -lc '
    set -eu
    for command_name in lua-language-server clangd gopls rust-analyzer sourcekit-lsp kotlin-lsp marksman docker-langserver emmet-language-server; do
      command -v "$command_name" >/dev/null || { echo "missing native executable: $command_name" >&2; exit 1; }
      timeout 10s "$command_name" --help >/dev/null 2>&1 || test "$?" -eq 124
    done
    printf "native bounded-start probes passed\\n"
  '
  yq -e '.servers[] | select(.name == "sourcekit-lsp") | select(.version == "6.2.2")' "$MANIFEST" >/dev/null \
    || fail "Swift native contract is not pinned"
  yq -e '.servers[] | select(.name == "kotlin-lsp") | select(.version == "262.9593.0")' "$MANIFEST" >/dev/null \
    || fail "Kotlin native contract is not pinned"
  grep -Fq 'Apple SDK' "$ROOT/README.md" && grep -Fq 'signing' "$ROOT/README.md" || fail "README omits Swift native limitation"
  grep -Fq 'Android SDK/device/build behavior' "$ROOT/README.md" || fail "README omits Kotlin native limitation"
}

docs() {
  local name
  for name in $(yq -r '.servers[].name' "$MANIFEST"); do
    grep -Fq "$name" "$ROOT/README.md" || fail "README omits manifest server: $name"
  done
  grep -Fq 'Perl remains an installed CLI/runtime tool only' "$ROOT/README.md" || fail "README overclaims Perl support"
  grep -Fq 'ha-roku-cloud' "$ROOT/README.md" || fail "README omits repository path correction"
  grep -Fq 'get.polytoken.dev' "$ROOT/README.md" || fail "README installer provenance is stale"
  grep -Fq 'POLYTOKEN_QUOTA_DIR' "$ROOT/README.md" || fail "README omits quota build override"
}


build_contract() {
  [[ -x "$ROOT/build.sh" ]] || fail "build.sh is not executable"
  grep -Fq 'POLYTOKEN_QUOTA_DIR' "$ROOT/build.sh" || fail "build.sh lacks POLYTOKEN_QUOTA_DIR override"
  grep -Fq -- '--build-context quota=' "$ROOT/build.sh" || fail "build.sh lacks quota named context"
  grep -Fq 'DOCKER_BIN' "$ROOT/build.sh" || fail "build.sh lacks DOCKER_BIN override"
  grep -Fq 'DOCKER_BUILDKIT=1' "$ROOT/build.sh" || fail "build.sh does not enable BuildKit"
  grep -Fq 'get.polytoken.dev' "$ROOT/Dockerfile" || fail "Dockerfile installer provenance changed"
  grep -Fq 'https://get.polytoken.dev' "$ROOT/README.md" || fail "README installer provenance is stale"
  python3 - "$ROOT/Dockerfile" <<'PY' || fail "base apt package layer must continue into localedef"
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
package_line = next(line for line in lines if "libcurl4-openssl-dev" in line)
assert package_line.rstrip().endswith("\\")
assert any(line.lstrip().startswith("&& localedef ") for line in lines)
PY
  python3 - "$ROOT/Dockerfile" <<'PY' || fail "LSP smoke-check cleanup must run as root"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
start = text.index("# ---- LSP executable smoke check ----")
end = text.index("# ---- CLI tools ----", start)
block = text[start:end]
assert "USER root" in block
assert "USER dev" in block
assert block.index("USER root") < block.index("COPY lsp-servers.yaml")
assert block.index("USER dev") > block.index("rm -f /tmp/lsp-servers.yaml")
PY
  npm_path_line="$(grep -n 'ENV PATH=' "$ROOT/Dockerfile" | head -n 1 | cut -d: -f1)"
  npm_install_line="$(grep -n 'RUN npm install --global' "$ROOT/Dockerfile" | head -n 1 | cut -d: -f1)"
  [[ "$npm_path_line" -lt "$npm_install_line" ]] || fail "mise PATH must precede npm installation"
  go_toolchain="$(grep -o 'go@[0-9][0-9.]*' "$ROOT/Dockerfile" | head -n 1 | cut -d@ -f2)"
  dockerfile_gopls_version="$(grep -o 'gopls@v[0-9][0-9.]*' "$ROOT/Dockerfile" | head -n 1 | cut -d@ -f2)"
  manifest_gopls_version="$(yq -r '.servers[] | select(.name == "gopls") | .version' "$MANIFEST")"
  [[ "$go_toolchain" == "1.26.5" ]] || fail "Go toolchain must remain pinned to 1.26.5 for polytoken-quota"
  [[ "$dockerfile_gopls_version" == "v$manifest_gopls_version" ]] || fail "Dockerfile and manifest gopls pins differ"
  [[ "$manifest_gopls_version" == "0.23.0" ]] || fail "gopls pin must remain compatible with Go 1.26"
  grep -Fq 'GOBIN=/home/dev/.local/bin go install' "$ROOT/Dockerfile" || fail "gopls must install into the manifest destination"
  python3 - "$ROOT/Dockerfile" <<'PY' || fail "Swiftly archive architecture/checksum contract is invalid"
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
assert "https://download.swift.org/swiftly/linux/swiftly-1.1.2-${swiftly_arch}.tar.gz" in text
assert "raw.githubusercontent.com/swiftlang/swiftly/main/install.sh" not in text
case_line = next(line for line in text.splitlines() if 'case "$TARGETARCH" in' in line)
case_body = case_line.split('case "$TARGETARCH" in ', 1)[1]
branches = {}
for branch in case_body.split(' ;; '):
    if branch.startswith('amd64)'):
        branches['amd64'] = branch[len('amd64)'):]
    elif branch.startswith('arm64)'):
        branches['arm64'] = branch[len('arm64)'):]
assert 'swiftly_arch="x86_64"' in branches['amd64']
assert 'swiftly_sha="21ad3d6376af0b423435f1f7295364add66c7173ea342654f4ae536c20ae88ba"' in branches['amd64']
assert 'swiftly_arch="aarch64"' in branches['arm64']
assert 'swiftly_sha="cb53dfea98f23a2bf62e89c2abbbf2f331ba5ad8ebc4a68a37e918b964848627"' in branches['arm64']
PY
  grep -Fq 'SWIFTLY_HOME_DIR=/home/dev/.local/share/swiftly' "$ROOT/Dockerfile" || fail "Swiftly home directory must be explicit"
  grep -Fq 'SWIFTLY_BIN_DIR=/home/dev/.local/bin' "$ROOT/Dockerfile" || fail "Swiftly bin directory must match the LSP launcher path"
  grep -Fq 'swiftly init --skip-install --no-modify-profile --quiet-shell-followup --assume-yes' "$ROOT/Dockerfile" || fail "Swiftly initialization must be noninteractive and avoid profile mutation"
  grep -Fq '"$SWIFTLY_BIN_DIR/swiftly" install "$SWIFT_VERSION" --assume-yes' "$ROOT/Dockerfile" || fail "Swiftly install must invoke the initialized binary"
  grep -Fq '"$SWIFTLY_BIN_DIR/swiftly" use "$SWIFT_VERSION" --assume-yes' "$ROOT/Dockerfile" || fail "Swiftly use must invoke the initialized binary"
  grep -Fq 'swift_bin="$SWIFTLY_BIN_DIR/sourcekit-lsp"' "$ROOT/Dockerfile" || fail "Swift sourcekit-lsp must use Swiftly's managed launcher"
  grep -Fq 'test -x "$swift_bin"; test "$swift_bin" = /home/dev/.local/bin/sourcekit-lsp' "$ROOT/Dockerfile" || fail "Swift sourcekit-lsp launcher must be verified at its manifest path"
  ! grep -Fq 'ln -sf "$swift_bin" "$HOME/.local/bin/sourcekit-lsp"' "$ROOT/Dockerfile" || fail "Swift sourcekit-lsp must not self-link"
  yq -e '.servers[] | select(.name == "sourcekit-lsp") | select(.version == "6.2.2") | select(.install.package == "swift-6.2.2-RELEASE") | select(.install.destination == "/home/dev/.local/share/swiftly") | select(.install.launcher == "/home/dev/.local/bin/sourcekit-lsp")' "$MANIFEST" >/dev/null || fail "Swiftly manifest paths/version do not match the managed launcher contract"
  swift_version="$(grep -o 'ARG SWIFT_VERSION=[0-9][0-9.]*' "$ROOT/Dockerfile" | cut -d= -f2)"
  manifest_swift_version="$(yq -r '.servers[] | select(.name == "sourcekit-lsp") | .version' "$MANIFEST")"
  [[ "$swift_version" == "$manifest_swift_version" ]] || fail "Dockerfile and manifest Swift versions differ"
  grep -Fq 'swiftly_sha="21ad3d6376af0b423435f1f7295364add66c7173ea342654f4ae536c20ae88ba"' "$ROOT/Dockerfile" || fail "Swiftly amd64 checksum is not pinned correctly"
  grep -Fq 'swiftly_sha="cb53dfea98f23a2bf62e89c2abbbf2f331ba5ad8ebc4a68a37e918b964848627"' "$ROOT/Dockerfile" || fail "Swiftly arm64 checksum is not pinned correctly"
  grep -Fq 'gnupg2' "$ROOT/Dockerfile" || fail "Swift toolchain signature/runtime dependencies are incomplete"
  [[ -f "$ROOT/../polytoken-quota/go.mod" ]] || echo "build contract noted: sibling polytoken-quota checkout is absent in this environment"
}

executables() {
  require_runtime_image
  "$ENGINE" run --rm -i "$IMAGE" sh -lc '
    set -eu
    while IFS= read -r command_name; do
      command -v "$command_name" >/dev/null || { echo "missing executable: $command_name" >&2; exit 1; }
    done
  ' < <(yq -r '.servers[].executable' "$MANIFEST")
}

parse_options "$@"
case "$COMMAND" in
  manifest) manifest ;;
  artifacts) artifacts ;;
  routing) routing ;;
  config) config ;;
  protocol) protocol ;;
  native) native ;;
  docs) docs ;;
  build-contract) build_contract ;;
  executables) executables ;;
  all) manifest; artifacts; routing; config; protocol; native; docs; build_contract ;;
  *) fail "usage: $0 [manifest|artifacts|routing|config|protocol|native|docs|build-contract|executables|all] [--image IMAGE] [--engine docker|podman]" ;;
esac

echo "LSP support checks passed: $COMMAND"
