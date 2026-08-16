#!/usr/bin/env bash
# setup-gateway.sh — one-shot deploy of the ratatoskr MCP gateway on the Mac.
#
# Why this exists: every MCP server is fronted by the ratatoskr gateway running
# natively on the Mac (launchd agent, loopback :8910). Polytoken — host and
# container sessions — reaches it at http://host.docker.internal:8910/mcp,
# which resolves to loopback on the Mac via the /etc/hosts alias this script
# installs, and to the VM bridge inside dev containers.
#
# What it does (idempotent where possible):
#   1. precheck toolchain (cargo >=1.88, go, node >=22, codex, yq v4)
#   2. build upstream binaries: go install foundry-mcp + codex-imagegen-mcp,
#      npm build appium-mcp
#   3. generate ~/Library/Preferences/ratatoskr/config.json (0600 — it embeds
#      FOUNDRY_API_KEY as a literal; rotation = edit + reload-config)
#   4. install the LaunchAgent plist, injecting the invoking shell's PATH so
#      gateway children (node, codex) resolve under launchd
#   5. add the /etc/hosts alias `127.0.0.1 host.docker.internal` if missing
#   6. remove superseded MCP wrapper scripts from ~/.local/bin
#   7. run ratatoskr's scripts/deploy.sh (fmt/clippy/test gate, release build,
#      install to ~/.local/bin/rato, launchd restart, listening check)
#   8. smoke-check the endpoint, then wire mcp_servers.ratatoskr into the
#      global polytoken config — deliberately LAST so no session ever points
#      at a URL with nothing listening
#
# Usage:
#   setup-gateway.sh             # full deploy
#   setup-gateway.sh --refresh   # rebuild upstream binaries only (then use the
#                                 # gateway's reconnect-upstream tool to respawn)
#   setup-gateway.sh --dry-run   # print the plan, write nothing, run nothing
#
# Overridable for testing: RATO_REPO, RATO_HOSTS_FILE (default /etc/hosts).
# All other paths derive from $HOME so a fake HOME sandboxes the run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RATO_REPO="${RATO_REPO:-$HOME/workspace/ratatoskr}"
HOSTS_FILE="${RATO_HOSTS_FILE:-/etc/hosts}"
CONFIG_DIR="$HOME/Library/Preferences/ratatoskr"
CONFIG_FILE="$CONFIG_DIR/config.json"
PLIST_DST="$HOME/Library/LaunchAgents/local.ratatoskr.plist"
PT_CFG="$HOME/.config/polytoken/config.yaml"
GATEWAY_PORT=8910
GATEWAY_URL="http://host.docker.internal:${GATEWAY_PORT}/mcp"
HOSTS_LINE="127.0.0.1 host.docker.internal # ratatoskr gateway: one URL for host + containers"

DRY_RUN=0
REFRESH=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --refresh) REFRESH=1 ;;
    *) echo "setup-gateway: unknown argument: $arg" >&2
       echo "usage: setup-gateway.sh [--dry-run] [--refresh]" >&2
       exit 1 ;;
  esac
done

say()  { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
die()  { echo "!!  $*" >&2; exit 1; }
run()  {
  # run CMD... — executes unless --dry-run, prefixing the log line.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would run: $*"
  else
    "$@"
  fi
}

# ---- 1. precheck -------------------------------------------------------------
require() { command -v "$1" >/dev/null 2>&1; }

version_ge() { # version_ge HAVE WANT
  [ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

say "precheck"
require cargo || die "cargo not found — install Rust >=1.88 (https://rustup.rs); the gateway builds from source via scripts/deploy.sh"
CARGO_VER="$(cargo --version | awk '{print $2}')"
version_ge "$CARGO_VER" 1.88.0 || die "cargo $CARGO_VER is too old — ratatoskr requires >=1.88 (rustup update stable)"
require go || die "go not found — required to install foundry-mcp and codex-imagegen-mcp (brew install go / mise use -g go@latest)"
require node || die "node not found — required for minime_vision and appium (mise use -g node@lts)"
NODE_MAJOR="$(node --version | sed -E 's/^v([0-9]+).*/\1/')"
[ "$NODE_MAJOR" -ge 22 ] || die "node $(node --version) is too old — appium-mcp requires >=22 (mise use -g node@22)"
require codex || die "codex CLI not found — codex-imagegen wraps it (npm install -g @openai/codex)"
require yq || die "yq not found — required to wire the polytoken config (brew install yq; mikefarah/yq v4 required)"
yq --version 2>/dev/null | grep -Eq 'version v4\.' || die "mikefarah/yq v4 required (got: $(yq --version 2>&1))"
require curl || die "curl not found — required for the post-deploy smoke check"
require python3 || die "python3 not found — required for the plist lint (the compat hooks need it too)"

GOPATH_BIN="$(go env GOPATH)/bin"
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$GOPATH_BIN"

for d in "$RATO_REPO" \
         "$HOME/workspace/foundry-mcp-tools" \
         "$HOME/workspace/codex-imagegen-mcp" \
         "$HOME/workspace/lm-studio-mcp-server/server.js" \
         "$HOME/workspace/appium-mcp"; do
  [ -e "$d" ] || die "missing expected path: $d (clone it under ~/workspace, or override RATO_REPO for the gateway repo)"
done
echo "    precheck ok (cargo $CARGO_VER, node v$NODE_MAJOR)"

# ---- 2. build upstream binaries ----------------------------------------------
build_upstreams() {
  say "building upstream binaries"
  run bash -c "cd '$HOME/workspace/foundry-mcp-tools' && go install ./cmd/foundry-mcp"
  run bash -c "cd '$HOME/workspace/codex-imagegen-mcp' && go install ."
  run bash -c "cd '$HOME/workspace/appium-mcp' && npm install --no-fund --no-audit && npm run build"
}

if [ "$REFRESH" -eq 1 ]; then
  build_upstreams
  say "refresh done — reconnect each rebuilt upstream via the gateway's reconnect-upstream tool"
  exit 0
fi
build_upstreams

# ---- 3. FOUNDRY_API_KEY -------------------------------------------------------
ENV_FILE="$HOME/.config/polytoken-container.env"
FOUNDRY_API_KEY="${FOUNDRY_API_KEY:-}"
if [ -z "$FOUNDRY_API_KEY" ] && [ -r "$ENV_FILE" ]; then
  # Grep, never source: the env file is data, not executable shell.
  FOUNDRY_API_KEY="$(grep -E '^FOUNDRY_API_KEY=' "$ENV_FILE" | tail -1 | cut -d= -f2- | sed -E 's/^["'\'']|["'\'']$//g')"
fi
if [ -z "$FOUNDRY_API_KEY" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    FOUNDRY_API_KEY="dry-run-placeholder"
    echo "    (dry-run) FOUNDRY_API_KEY unresolved — would prompt interactively"
  else
    printf 'FOUNDRY_API_KEY: ' >&2
    read -rs FOUNDRY_API_KEY </dev/tty
    echo >&2
    [ -n "$FOUNDRY_API_KEY" ] || die "FOUNDRY_API_KEY is required (export it, add it to $ENV_FILE, or enter it when prompted)"
  fi
fi

# ---- 4. gateway config.json ---------------------------------------------------
say "generating $CONFIG_FILE (0600 — embeds FOUNDRY_API_KEY)"
generate_config() {
  jq -n \
    --arg gobin "$GOPATH_BIN" \
    --arg home "$HOME" \
    --arg foundry_key "$FOUNDRY_API_KEY" \
    --argjson port "$GATEWAY_PORT" \
    '{
      # 660s so an execute script can wrap a full 600s image-generation call.
      port: $port,
      executeDeadlineMs: 660000,
      mcpClients: {
        "codex-imagegen": {
          type: "stdio",
          command: ($gobin + "/codex-imagegen-mcp"),
          args: [],
          env: {
            CODEX_IMAGEGEN_DANGEROUSLY_BYPASS_SANDBOX: "true",
            CODEX_BIN: "codex",
            CODEX_IMAGEGEN_TIMEOUT: "600s"
          },
          hint: "Generate D&D scene/NPC artwork via the codex image model",
          supervision: { callTimeoutMs: 600000 }
        },
        foundry: {
          type: "stdio",
          command: ($gobin + "/foundry-mcp"),
          args: [],
          env: {
            FOUNDRY_API_KEY: $foundry_key,
            FOUNDRY_RELAY_URL: "http://192.168.2.247:3010"
          },
          hint: "Foundry VTT canon: character sheets, journals, scenes via the relay"
        },
        minime_vision: {
          type: "stdio",
          command: "node",
          args: [($home + "/workspace/lm-studio-mcp-server/server.js")],
          env: { LM_STUDIO_URL: "http://192.168.2.247:1234" },
          hint: "Local vision model (LM Studio) for image understanding",
          supervision: { callTimeoutMs: 120000 }
        },
        appium: {
          type: "stdio",
          command: "node",
          args: [($home + "/workspace/appium-mcp/dist/index.js")],
          hint: "Appium mobile automation: iOS/Android sessions, gestures, app management",
          supervision: { callTimeoutMs: 120000 }
        },
        homeassistant: {
          type: "http",
          url: "http://192.168.2.247:8086/mcp",
          hint: "Home Assistant entity state, config, template evaluation"
        }
      }
    }'
}

if [ "$DRY_RUN" -eq 1 ]; then
  generate_config | jq -e '(.mcpClients | length) == 5 and (.executeDeadlineMs == 660000)' >/dev/null \
    || die "generated config failed its structural check"
  echo "    (dry-run) config.json validated against the structural check; not written"
else
  mkdir -p "$CONFIG_DIR"
  staged="$(mktemp)"
  generate_config > "$staged"
  jq -e '(.mcpClients | length) == 5 and (.executeDeadlineMs == 660000)' "$staged" >/dev/null \
    || { rm -f "$staged"; die "generated config failed its structural check; nothing written"; }
  install -m 600 "$staged" "$CONFIG_FILE"
  rm -f "$staged"
  echo "    wrote $CONFIG_FILE"
fi

# ---- 5. LaunchAgent plist ------------------------------------------------------
say "installing $PLIST_DST (PATH captured from this shell: gateway children need it)"
render_plist() {
  # The example plist uses /Users/YOU placeholders; substitute $HOME (launchd
  # expands neither ~ nor env vars) and inject the invoking shell's PATH so
  # node/codex resolve for gateway children under launchd's minimal environment.
  # XML-escape the PATH first: &/</> in it would corrupt the plist (the
  # well-formedness gate would catch it, but only after a confusing failure).
  local escaped_path="${PATH//&/&amp;}"
  escaped_path="${escaped_path//</&lt;}"
  escaped_path="${escaped_path//>/&gt;}"
  sed "s|/Users/YOU|$HOME|g" "$RATO_REPO/local.ratatoskr.example.plist" \
    | awk -v path="$escaped_path" '
        { print }
        /<dict>/ && !seen {
          seen = 1
          print "  <key>EnvironmentVariables</key>"
          print "  <dict>"
          print "    <key>PATH</key>"
          print "    <string>" path "</string>"
          print "  </dict>"
        }'
}
if [ "$DRY_RUN" -eq 1 ]; then
  render_plist | grep -q 'EnvironmentVariables' \
    || die "rendered plist lost the EnvironmentVariables injection"
  echo "    (dry-run) plist rendered with PATH injection; not installed (XML lint deferred to the real run)"
else
  staged="$(mktemp)"
  render_plist > "$staged"
  # Well-formedness via python3 rather than plutil: this script is exercised by
  # the Linux test harness, and a parse check is what plutil's lint adds here.
  python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$staged" \
    || { rm -f "$staged"; die "rendered plist is not well-formed XML; nothing installed"; }
  mkdir -p "$(dirname "$PLIST_DST")"
  if [ ! -f "$PLIST_DST" ] || ! cmp -s "$staged" "$PLIST_DST"; then
    install -m 644 "$staged" "$PLIST_DST"
    echo "    installed $PLIST_DST"
  else
    echo "    unchanged: $PLIST_DST"
  fi
  rm -f "$staged"
fi

# ---- 6. /etc/hosts alias -------------------------------------------------------
say "ensuring /etc/hosts alias ($HOSTS_LINE)"
if grep -qE '^\s*127\.0\.0\.1\s+.*host\.docker\.internal' "$HOSTS_FILE" 2>/dev/null; then
  echo "    already present"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would append (sudo required)"
  else
    printf '%s\n' "$HOSTS_LINE" | sudo tee -a "$HOSTS_FILE" >/dev/null \
      || die "could not add the /etc/hosts alias — add this line manually and re-run: $HOSTS_LINE"
    echo "    added"
  fi
fi

# ---- 7. remove superseded wrappers ---------------------------------------------
say "removing superseded MCP wrapper scripts from ~/.local/bin"
for w in foundry-mcp codex-imagegen-mcp minime-vision; do
  [ -e "$HOME/.local/bin/$w" ] || continue
  run rm -f "$HOME/.local/bin/$w"
  [ "$DRY_RUN" -eq 1 ] || echo "    removed ~/.local/bin/$w"
done

# ---- 8. deploy + smoke + wire polytoken ----------------------------------------
say "deploying the gateway (full fmt/clippy/test gate via ratatoskr's deploy.sh)"
run bash -c "cd '$RATO_REPO' && scripts/deploy.sh"

say "smoke check"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would probe http://127.0.0.1:${GATEWAY_PORT}/mcp for HTTP liveness"
else
  # A bare GET on a streamable-HTTP MCP endpoint is not guaranteed to return
  # 2xx (rmcp may answer 405/400 without a session; curl -f would false-fail)
  # and an SSE 200 would hang an unbounded curl. deploy.sh already gated on
  # the "gateway listening" log line, so this probe only proves HTTP
  # liveness: any status code means the server answered; 000 means it did not.
  # The `|| code="000"` is load-bearing: real curl exits nonzero (7 refused,
  # 28 timeout) exactly when it prints 000, and without the guard errexit
  # would kill the script here — silently, before the diagnostic below.
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${GATEWAY_PORT}/mcp")" || code="000"
  [ "$code" != "000" ] \
    || die "gateway not answering on loopback (curl code 000) — check ~/Library/Logs/ratatoskr.log; polytoken wiring SKIPPED"
  echo "    gateway answering on 127.0.0.1:${GATEWAY_PORT} (HTTP $code)"
fi

say "wiring mcp_servers.ratatoskr into $PT_CFG"
wire_polytoken() {
  # Add-if-absent; an existing entry is compared by URL so a deliberate manual
  # override is preserved (reported, not clobbered). Backup only on real change,
  # matching the installer's backup-on-modify convention.
  local current
  current="$(yq -r '.mcp_servers.ratatoskr.url // ""' "$PT_CFG" 2>/dev/null)"
  if [ "$current" = "$GATEWAY_URL" ]; then
    echo "    already wired"
    return 0
  fi
  if [ -n "$current" ]; then
    warn "mcp_servers.ratatoskr exists with url $current — leaving it alone (expected $GATEWAY_URL)"
    return 0
  fi
  cp "$PT_CFG" "$PT_CFG.bak-$(date +%Y%m%dT%H%M%S)"
  yq -i ".mcp_servers.ratatoskr.transport = \"http\" | .mcp_servers.ratatoskr.url = \"$GATEWAY_URL\"" "$PT_CFG"
  yq -e ".mcp_servers.ratatoskr.url == \"$GATEWAY_URL\"" "$PT_CFG" >/dev/null \
    || die "polytoken config wiring failed verification"
  echo "    wired (backup saved alongside)"
}
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would run the add-if-absent yq merge"
else
  [ -f "$PT_CFG" ] || die "$PT_CFG missing — run the claude-config polytoken installer first"
  wire_polytoken
fi

say "done"
[ "$DRY_RUN" -eq 1 ] || cat <<NEXT

Next steps:
  - restart any running polytoken sessions so they pick up the gateway
  - from a dev container: curl -s -o /dev/null -m 5 -w '%{http_code}\n' $GATEWAY_URL
    (any code other than 000 proves the container -> Mac path)
  - in a session: call list-servers — all five upstreams should report healthy
NEXT
