#!/usr/bin/env bash
# Scenario harness for ratatoskr/setup-gateway.sh. Everything runs against a
# fake $HOME with a stubbed toolchain (cargo/go/npm/node/codex/curl record
# invocations and succeed), so no build, no network, no macOS required.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/setup-gateway.sh"

pass=0 fail=0
ok() { echo "  ok: $1"; pass=$((pass + 1)); }
no() { echo "  FAIL: $1"; fail=$((fail + 1)); }
sc()  { echo; echo "=== $1 ==="; }

# make_sandbox — prints the fake home path. Sets no globals; callers capture.
make_sandbox() {
  local home
  home="$(mktemp -d)"
  mkdir -p "$home/workspace/ratatoskr/scripts" \
           "$home/workspace/foundry-mcp-tools/cmd/foundry-mcp" \
           "$home/workspace/codex-imagegen-mcp" \
           "$home/workspace/appium-mcp" \
           "$home/workspace/lm-studio-mcp-server" \
           "$home/.config/polytoken" \
           "$home/.config" \
           "$home/.local/bin"
  touch "$home/workspace/lm-studio-mcp-server/server.js"
  # Superseded wrappers that the setup must remove.
  for w in foundry-mcp codex-imagegen-mcp minime-vision; do
    printf '#!/bin/sh\nexit 0\n' > "$home/.local/bin/$w"
  done
  # Seed polytoken global config the way the installer leaves it.
  printf 'version: 3\nproviders:\n  zai:\n    auth:\n      key: stub\n' \
    > "$home/.config/polytoken/config.yaml"
  # Gateway repo stand-in: example plist (verbatim shape from the ratatoskr
  # repo) + recording deploy stub.
  cat > "$home/workspace/ratatoskr/local.ratatoskr.example.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.ratatoskr</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/YOU/.local/bin/rato</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/Users/YOU/Library/Logs/ratatoskr.log</string>
  <key>StandardErrorPath</key>
  <string>/Users/YOU/Library/Logs/ratatoskr.log</string>
</dict>
</plist>
PLIST
  cat > "$home/workspace/ratatoskr/scripts/deploy.sh" <<'DEPLOY'
#!/usr/bin/env bash
echo "deploy-ran" >> "$DEPLOYLOG"
exit 0
DEPLOY
  chmod +x "$home/workspace/ratatoskr/scripts/deploy.sh"
  printf '%s\n' "$home"
}

# make_stubbin SANDBOX — builds the stub toolchain inside the sandbox; prints path.
make_stubbin() {
  local bin="$1/stubbin"
  mkdir -p "$bin"
  cat > "$bin/cargo" <<'S'
#!/usr/bin/env bash
[ "$1" = "--version" ] && echo "cargo 1.90.0" || exit 0
S
  cat > "$bin/go" <<'S'
#!/usr/bin/env bash
if [ "$1" = "env" ]; then echo "$HOME/go"; else echo "go $*" >> "$TOOLLOG"; fi
S
  cat > "$bin/npm" <<'S'
#!/usr/bin/env bash
echo "npm $*" >> "$TOOLLOG"
exit 0
S
  cat > "$bin/node" <<'S'
#!/usr/bin/env bash
[ "$1" = "--version" ] && echo "v22.13.0" || { echo "node $*" >> "$TOOLLOG"; }
S
  cat > "$bin/codex" <<'S'
#!/usr/bin/env bash
echo "codex $*" >> "$TOOLLOG"
S
  cat > "$bin/curl" <<'S'
#!/usr/bin/env bash
echo "curl $*" >> "$TOOLLOG"
# The smoke probe captures -w '%{http_code}' output; emit a configurable code.
echo "${CURLCODE:-200}"
# Real curl exits nonzero exactly when it fails to get an answer (refused,
# timeout), so the stub needs an exit-status knob to pin that production path.
exit "${CURLEXIT:-0}"
S
  chmod +x "$bin"/*
  printf '%s\n' "$bin"
}

run_setup() { # run_setup SANDBOX STUBBIN ARGS...
  local home="$1" bin="$2"; shift 2
  HOME="$home" PATH="$bin:$PATH" RATO_REPO="$home/workspace/ratatoskr" \
    RATO_HOSTS_FILE="$home/hosts" TOOLLOG="$home/tool.log" DEPLOYLOG="$home/deploy.log" \
    bash "$SCRIPT" "$@"
}

# --- S1: dry-run prints the plan and writes nothing --------------------------
sc "S1 dry-run -> plan printed, nothing written, nothing run"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; : > "$SBX/hosts"
out="$(FOUNDRY_API_KEY=secret-test-key run_setup "$SBX" "$STUB" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "dry-run exits 0" || no "dry-run exits 0 (got $rc)"
case "$out" in *"(dry-run)"*) ok "plan lines present" ;; *) no "plan lines present" ;; esac
[ ! -e "$SBX/Library/Preferences/ratatoskr/config.json" ] && ok "config.json not written" || no "config.json not written"
[ ! -e "$SBX/Library/LaunchAgents/local.ratatoskr.plist" ] && ok "plist not installed" || no "plist not installed"
[ ! -s "$SBX/hosts" ] && ok "hosts file untouched" || no "hosts file untouched"
[ ! -e "$SBX/deploy.log" ] && ok "deploy not run" || no "deploy not run"
[ -e "$SBX/.local/bin/foundry-mcp" ] && ok "stale wrappers kept (dry-run)" || no "stale wrappers kept (dry-run)"
yq -e 'has("mcp_servers") | not' "$SBX/.config/polytoken/config.yaml" >/dev/null \
  && ok "polytoken config unwired" || no "polytoken config unwired"
[ ! -s "$SBX/tool.log" ] && ok "no builds executed" || no "no builds executed"
rm -rf "$SBX"

# --- S2: missing prereq fails loudly ------------------------------------------
sc "S2 missing prereq -> nonzero exit, actionable message"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; rm "$STUB/cargo"; : > "$SBX/hosts"
out="$(FOUNDRY_API_KEY=k run_setup "$SBX" "$STUB" --dry-run 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "missing cargo exits nonzero" || no "missing cargo exits nonzero"
case "$out" in *"cargo not found"*) ok "message names cargo and the fix" ;; *) no "message names cargo and the fix" ;; esac
[ ! -e "$SBX/deploy.log" ] && ok "nothing ran" || no "nothing ran"
rm -rf "$SBX"

# --- S3: full run wires everything --------------------------------------------
sc "S3 full run -> config, plist, hosts, wrappers, deploy, polytoken wiring"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; : > "$SBX/hosts"
out="$(FOUNDRY_API_KEY=secret-test-key run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "full run exits 0" || no "full run exits 0 (got $rc)"
CFG="$SBX/Library/Preferences/ratatoskr/config.json"
[ -f "$CFG" ] && ok "config.json written" || no "config.json written"
[ "$(stat -c %a "$CFG" 2>/dev/null)" = "600" ] && ok "config.json is 0600" || no "config.json is 0600"
jq -e '(.mcpClients | length) == 5' "$CFG" >/dev/null && ok "five upstreams" || no "five upstreams"
jq -e '.mcpClients.foundry.env.FOUNDRY_API_KEY == "secret-test-key"' "$CFG" >/dev/null \
  && ok "foundry key embedded from env" || no "foundry key embedded from env"
jq -e --arg p "$SBX/go/bin/foundry-mcp" '.mcpClients.foundry.command == $p' "$CFG" >/dev/null \
  && ok "foundry command is GOPATH bin" || no "foundry command is GOPATH bin"
jq -e --arg p "$SBX/workspace/lm-studio-mcp-server/server.js" '.mcpClients.minime_vision.args[0] == $p' "$CFG" >/dev/null \
  && ok "minime_vision resolves server.js under HOME" || no "minime_vision resolves server.js under HOME"
jq -e '.mcpClients.homeassistant.url == "http://192.168.2.247:8086/mcp"' "$CFG" >/dev/null \
  && ok "homeassistant http upstream" || no "homeassistant http upstream"
jq -e '.executeDeadlineMs == 660000 and .mcpClients["codex-imagegen"].supervision.callTimeoutMs == 600000' "$CFG" >/dev/null \
  && ok "deadlines and imagegen timeout budget" || no "deadlines and imagegen timeout budget"
PLIST="$SBX/Library/LaunchAgents/local.ratatoskr.plist"
[ -f "$PLIST" ] && ok "plist installed" || no "plist installed"
grep -q "/Users/YOU" "$PLIST" && no "plist /Users/YOU substituted" || ok "plist /Users/YOU substituted"
grep -q "$SBX/.local/bin/rato" "$PLIST" && ok "plist points at HOME rato" || no "plist points at HOME rato"
grep -A1 "<key>PATH</key>" "$PLIST" | grep -q "$STUB" \
  && ok "plist PATH captured from invoking shell" || no "plist PATH captured from invoking shell"
grep -q "host.docker.internal" "$SBX/hosts" && ok "hosts alias added" || no "hosts alias added"
[ -e "$SBX/.local/bin/foundry-mcp" ] && no "stale wrappers removed" || ok "stale wrappers removed"
grep -q "deploy-ran" "$SBX/deploy.log" && ok "deploy.sh invoked" || no "deploy.sh invoked"
grep -q "go install ./cmd/foundry-mcp" "$SBX/tool.log" && ok "foundry installed from source" || no "foundry installed from source"
PTC="$SBX/.config/polytoken/config.yaml"
yq -e '.mcp_servers.ratatoskr.url == "http://host.docker.internal:8910/mcp"' "$PTC" >/dev/null \
  && ok "polytoken wired to gateway URL" || no "polytoken wired to gateway URL"
yq -e '.providers.zai.auth.key == "stub"' "$PTC" >/dev/null \
  && ok "existing polytoken keys preserved" || no "existing polytoken keys preserved"
ls "$PTC".bak-* >/dev/null 2>&1 && ok "polytoken backup created" || no "polytoken backup created"
rm -rf "$SBX"

# --- S4: idempotent re-run + env-file key sourcing -----------------------------
sc "S4 re-run idempotent; env-file key sourcing strips quotes"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; : > "$SBX/hosts"
printf 'FOUNDRY_API_KEY="quoted-secret"\nOTHER=1\n' > "$SBX/.config/polytoken-container.env"
out="$(env -u FOUNDRY_API_KEY HOME="$SBX" PATH="$STUB:$PATH" RATO_REPO="$SBX/workspace/ratatoskr" \
  RATO_HOSTS_FILE="$SBX/hosts" TOOLLOG="$SBX/tool.log" DEPLOYLOG="$SBX/deploy.log" \
  bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "env-file run exits 0" || no "env-file run exits 0 (got $rc)"
jq -e '.mcpClients.foundry.env.FOUNDRY_API_KEY == "quoted-secret"' "$SBX/Library/Preferences/ratatoskr/config.json" >/dev/null \
  && ok "key sourced from env file, quotes stripped" || no "key sourced from env file, quotes stripped"
before="$(yq -o=json '.' "$SBX/.config/polytoken/config.yaml")"
out="$(env -u FOUNDRY_API_KEY HOME="$SBX" PATH="$STUB:$PATH" RATO_REPO="$SBX/workspace/ratatoskr" \
  RATO_HOSTS_FILE="$SBX/hosts" TOOLLOG="$SBX/tool.log" DEPLOYLOG="$SBX/deploy.log" \
  bash "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "re-run exits 0" || no "re-run exits 0 (got $rc)"
after="$(yq -o=json '.' "$SBX/.config/polytoken/config.yaml")"
[ "$before" = "$after" ] && ok "re-run leaves wired config untouched" || no "re-run leaves wired config untouched"
[ "$(grep -c 'host.docker.internal' "$SBX/hosts")" = 1 ] && ok "hosts alias not duplicated" || no "hosts alias not duplicated"
rm -rf "$SBX"

# --- S5: dead gateway -> wiring is skipped ------------------------------------
sc "S5 curl code 000 -> nonzero exit, polytoken wiring SKIPPED"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; : > "$SBX/hosts"
out="$(FOUNDRY_API_KEY=k CURLCODE=000 run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "dead gateway exits nonzero" || no "dead gateway exits nonzero"
case "$out" in *"polytoken wiring SKIPPED"*) ok "wiring skipped message" ;; *) no "wiring skipped message" ;; esac
yq -e 'has("mcp_servers") | not' "$SBX/.config/polytoken/config.yaml" >/dev/null \
  && ok "polytoken config left unwired" || no "polytoken config left unwired"
rm -rf "$SBX"

# --- S6: curl nonzero exit (real dead-gateway path) ----------------------------
sc "S6 curl exit 7 (refused) -> diagnostic fires, wiring SKIPPED"
SBX="$(make_sandbox)"; STUB="$(make_stubbin "$SBX")"; : > "$SBX/hosts"
out="$(FOUNDRY_API_KEY=k CURLEXIT=7 run_setup "$SBX" "$STUB" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "curl failure exits nonzero (not silent errexit)" || no "curl failure exits nonzero (not silent errexit)"
case "$out" in *"gateway not answering on loopback"*) ok "dead-gateway diagnostic present" ;; *) no "dead-gateway diagnostic present" ;; esac
yq -e 'has("mcp_servers") | not' "$SBX/.config/polytoken/config.yaml" >/dev/null \
  && ok "polytoken config left unwired" || no "polytoken config left unwired"
rm -rf "$SBX"

echo
echo "=== $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
