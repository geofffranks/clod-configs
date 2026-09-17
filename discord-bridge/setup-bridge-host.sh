#!/usr/bin/env bash
# discord-bridge/setup-bridge-host.sh — install/update the Mac host bridge as a
# launchd agent (one-shot deploy, mirroring ratatoskr/setup-gateway.sh).
#
# The bridge host (relay + Discord bot, discord_bridge.host) runs natively on
# the Mac so containers can reach its loopback relay; this script owns the
# launchd lifecycle, the dedicated 0600 env file, and the Mac venv:
#
#   1. precheck: python3, jq, curl, and podman (the /kill callback depends on
#      podman being on the PATH captured into the plist — fails loudly if not).
#   2. build/refresh the Mac venv at ~/.local/share/polytoken-discord/venv with
#      a fingerprint-keyed `pip install -e "$BRIDGE_REPO_DIR[live]"` (editable;
#      code stays live via the checkout). Override the interpreter with
#      BRIDGE_HOST_PYTHON; skip with BRIDGE_SETUP_SKIP_VENV=1.
#   3. generate the dedicated 0600 env file ~/.config/polytoken-discord.env,
#      seeding BRIDGE_RELAY_TOKEN by grep-not-source from the container env file
#      (~/.config/polytoken-container.env) — never sourcing it.
#   4. ensure the /etc/hosts alias `127.0.0.1 host.docker.internal` (same single
#      literal URL host + containers use, ratatoskr precedent).
#   5. render the LaunchAgent plist (HOME + PATH injection), python3 XML lint,
#      idempotent cmp-install to ~/Library/LaunchAgents/, then reload launchd.
#   6. smoke-check launchctl state + relay port liveness.
#
# Usage:
#   setup-bridge-host.sh             # install/update
#   setup-bridge-host.sh --dry-run   # print the plan, write nothing, run nothing
#   setup-bridge-host.sh --uninstall # unload + remove the LaunchAgent and plist
#
# Overridable for tests (fake HOME sandboxes everything): BRIDGE_REPO_DIR,
# BRIDGE_SETUP_HOSTS_FILE, BRIDGE_SETUP_PLIST_DST, BRIDGE_SETUP_CONTAINER_ENV,
# BRIDGE_SETUP_SKIP_VENV, BRIDGE_SETUP_SKIP_LAUNCHCTL.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="local.polytoken-discord-bridge"
BRIDGE_REPO_DIR="${BRIDGE_REPO_DIR:-$HOME/workspace/discord-pt-stream}"
BRIDGE_WRAPPER="$BRIDGE_REPO_DIR/scripts/bridge-host.sh"
ENV_FILE="${POLYTOKEN_DISCORD_ENV:-$HOME/.config/polytoken-discord.env}"
CONTAINER_ENV="${BRIDGE_SETUP_CONTAINER_ENV:-$HOME/.config/polytoken-container.env}"
PLIST_SRC="$SELF/discord-bridge/local.polytoken-discord-bridge.plist.example"
PLIST_DST="${BRIDGE_SETUP_PLIST_DST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
VENV_DIR="$HOME/.local/share/polytoken-discord/venv"
FPRINT="$HOME/.local/share/polytoken-discord/pyproject.fingerprint"
MAC_PYTHON="${BRIDGE_HOST_PYTHON:-}"
HOSTS_FILE="${BRIDGE_SETUP_HOSTS_FILE:-/etc/hosts}"
HOSTS_LINE="127.0.0.1 host.docker.internal # polytoken discord bridge: one URL for host + containers"
PORT=8765

DRY_RUN=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    *) echo "setup-bridge-host: unknown argument: $arg" >&2
       echo "usage: setup-bridge-host.sh [--dry-run] [--uninstall]" >&2
       exit 1 ;;
  esac
done

say() { echo "==> $*"; }
warn() { echo "!!  $*" >&2; }
die() { echo "!!  $*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would run: $*"
  else
    "$@"
  fi
}
require() { command -v "$1" >/dev/null 2>&1; }

# sha256 of a file, portable to macOS (no sha256sum; shasum -a 256 is BSD).
hash256() { # hash256 FILE -> hex digest (empty on failure)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

if [ "$UNINSTALL" -eq 1 ]; then
  say "uninstalling $LABEL"
  if require launchctl; then
    run launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    run launchctl remove "$LABEL" 2>/dev/null || true
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would remove $PLIST_DST"
  else
    rm -f "$PLIST_DST"
    echo "    removed $PLIST_DST (env file, venv, and logs left in place)"
  fi
  exit 0
fi

# ---- 1. precheck -------------------------------------------------------------
say "precheck"
require python3 || die "python3 not found — required for the venv and the plist XML lint"
require jq || die "jq not found — required to generate the env file"
require curl || die "curl not found — required for the relay port smoke probe"
if require podman; then
  echo "    podman: $(command -v podman)"
else
  die "podman not found — the /kill callback depends on it. Install podman and re-run (the plist PATH will capture it)."
fi
[ -x "$BRIDGE_WRAPPER" ] || die "missing wrapper: $BRIDGE_WRAPPER (clone discord-pt-stream to $BRIDGE_REPO_DIR or set BRIDGE_REPO_DIR)"

# ---- 2. Mac venv (fingerprint-keyed editable [live] install) -----------------
if [ "$DRY_RUN" -eq 0 ] && [ "${BRIDGE_SETUP_SKIP_VENV:-0}" != "1" ]; then
  say "ensuring Mac venv at $VENV_DIR (editable $BRIDGE_REPO_DIR[live])"
  mkdir -p "$(dirname "$VENV_DIR")" "$(dirname "$FPRINT")"
  venv_python="$VENV_DIR/bin/python3"
  fp="$( (hash256 "$BRIDGE_REPO_DIR/pyproject.toml"); python3 --version )"
  need_rebuild=0
  if [ ! -x "$venv_python" ]; then need_rebuild=1
  elif [ ! -f "$FPRINT" ] || [ "$(cat "$FPRINT" 2>/dev/null)" != "$fp" ]; then need_rebuild=1
  fi
  if [ "$need_rebuild" -eq 1 ]; then
    python3 -m venv "$VENV_DIR"
    if "$venv_python" -m pip install --quiet -e "$BRIDGE_REPO_DIR[live]"; then
      printf '%s\n' "$fp" > "$FPRINT"
      echo "    venv installed"
    else
      warn "pip install of [live] extra failed (offline?); keeping existing venv"
    fi
  else
    echo "    venv current (fingerprint unchanged)"
  fi
  MAC_PYTHON="${MAC_PYTHON:-$venv_python}"
else
  echo "    (dry-run or skipped) Mac venv untouched"
fi
[ -n "$MAC_PYTHON" ] || MAC_PYTHON="python3"

# ---- 3. dedicated 0600 env file, seeded by grep-not-source -------------------
say "generating $ENV_FILE (0600)"
# Read existing values (grep, never source) so reruns preserve your edits.
existing=""
if [ -r "$ENV_FILE" ]; then
  existing="$(cat "$ENV_FILE")"
fi
env_get() { # env_get KEY — existing file value or env var or empty
  local key="$1" val=""
  val="$(printf '%s\n' "$existing" | grep -E "^${key}=" | tail -1 | cut -d= -f2- | sed -E 's/^["'\'']|["'\'']$//g' || true)"
  if [ -n "$val" ]; then printf '%s\n' "$val"; elif [ -n "${!key:-}" ]; then printf '%s\n' "${!key}"; fi
}
# Seed the relay token by grep-not-source from the container env (setup-gateway
# pattern): a shared secret lives in both files and must stay in sync.
relay_token="$(env_get BRIDGE_RELAY_TOKEN)"
if [ -z "$relay_token" ] && [ -r "$CONTAINER_ENV" ]; then
  relay_token="$(grep -E '^BRIDGE_RELAY_TOKEN=' "$CONTAINER_ENV" | tail -1 | cut -d= -f2- | sed -E 's/^["'\'']|["'\'']$//g' || true)"
  if [ -n "$relay_token" ]; then
    echo "    seeded BRIDGE_RELAY_TOKEN from $CONTAINER_ENV (grep-not-source)"
  fi
fi

generate_env() {
  # BRIDGE_RELAY_BIND/ADVERTISE need non-empty defaults: host.py's
  # os.environ.get(name, default) returns "" for a set-but-empty line, which
  # _relay_bind() then rejects ("must be HOST:PORT") and bot's relay_advertise
  # falls back to ws://127.0.0.1:8765 — both wrong. Preserve any existing value
  # (env_get) and fall back to the documented defaults.
  local bind addr
  bind="$(env_get BRIDGE_RELAY_BIND)"; [ -n "$bind" ] || bind="127.0.0.1:8765"
  addr="$(env_get BRIDGE_RELAY_ADVERTISE)"; [ -n "$addr" ] || addr="ws://host.docker.internal:8765"
  cat <<EOF
# Polytoken Discord bridge host env (DEDICATED; not the container --env-file).
# Source of truth for the Mac host. 0600. Edit + kickstart to rotate:
#   launchctl kickstart -k gui/$(id -u)/$LABEL
DISCORD_BOT_TOKEN=$(env_get DISCORD_BOT_TOKEN)
DISCORD_GUILD_ID=$(env_get DISCORD_GUILD_ID)
DISCORD_CONTROL_CHANNEL_ID=$(env_get DISCORD_CONTROL_CHANNEL_ID)
DISCORD_OPERATOR_USER_ID=$(env_get DISCORD_OPERATOR_USER_ID)
DISCORD_CONTROL_CHANNEL_NAME=$(env_get DISCORD_CONTROL_CHANNEL_NAME)
BRIDGE_RELAY_BIND=$bind
BRIDGE_RELAY_ADVERTISE=$addr
BRIDGE_RELAY_TOKEN=$relay_token
BRIDGE_STATE_DB=$(env_get BRIDGE_STATE_DB)
BRIDGE_HOST_PYTHON=$MAC_PYTHON
BRIDGE_REPO_DIR=$BRIDGE_REPO_DIR
EOF
}
staged_env="$(generate_env)"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) env file contains: $(printf '%s\n' "$staged_env" | grep -oE '^[A-Z_]+=' | tr '\n' ' ')"
else
  mkdir -p "$(dirname "$ENV_FILE")"
  tmp_env="$(mktemp)" && printf '%s\n' "$staged_env" > "$tmp_env" \
    && chmod 600 "$tmp_env"
  if [ ! -f "$ENV_FILE" ] || ! cmp -s "$tmp_env" "$ENV_FILE"; then
    install -m 600 "$tmp_env" "$ENV_FILE"
    echo "    wrote $ENV_FILE"
  else
    echo "    unchanged: $ENV_FILE"
  fi
  rm -f "$tmp_env"
fi

# ---- 4. /etc/hosts alias ------------------------------------------------------
say "ensuring /etc/hosts alias ($HOSTS_LINE)"
if grep -qE '^\s*127\.0\.0\.1\s+.*host\.docker\.internal' "$HOSTS_FILE" 2>/dev/null; then
  echo "    already present"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "    (dry-run) would append (sudo required)"
  else
    printf '%s\n' "$HOSTS_LINE" | sudo tee -a "$HOSTS_FILE" >/dev/null \
      || { warn "could not add the /etc/hosts alias — add manually and re-run: $HOSTS_LINE"; }
    echo "    added"
  fi
fi

# ---- 5. LaunchAgent plist ------------------------------------------------------
say "installing $PLIST_DST (PATH captured from this shell so podman/the venv resolve)"
render_plist() {
  local escaped_path="${PATH//&/&amp;}"; escaped_path="${escaped_path//</&lt;}"; escaped_path="${escaped_path//>/&gt;}"
  # @HOME@ is substituted literally, so a $HOME containing &/</> would corrupt the
  # plist; escape those too (the XML lint below is the safety net).
  local esc_home="${HOME//&/&amp;}"; esc_home="${esc_home//</&lt;}"; esc_home="${esc_home//>/&gt;}"
  local esc_repo="${BRIDGE_REPO_DIR//&/&amp;}"; esc_repo="${esc_repo//</&lt;}"; esc_repo="${esc_repo//>/&gt;}"
  sed "s|@HOME@|$esc_home|g; s|@REPO@|$esc_repo|g; s|@PATH@|$escaped_path|g" "$PLIST_SRC"
}
if [ "$DRY_RUN" -eq 1 ]; then
  render_plist | python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.stdin)' \
    || die "rendered plist is not well-formed XML (dry-run lint)"
  echo "    (dry-run) plist rendered + XML-linted; not installed"
else
  staged="$(mktemp)"
  render_plist > "$staged"
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
  if [ "${BRIDGE_SETUP_SKIP_LAUNCHCTL:-0}" != "1" ] && require launchctl; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null \
      || launchctl load -w "$PLIST_DST" 2>/dev/null \
      || warn "launchctl bootstrap/load failed — review $PLIST_DST"
    echo "    launchd agent bootstrapped"
  else
    echo "    launchctl skipped (absent or BRIDGE_SETUP_SKIP_LAUNCHCTL=1)"
  fi
fi

# ---- 6. smoke ------------------------------------------------------------------
say "smoke check"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "    (dry-run) would verify launchctl state and probe tcp/127.0.0.1:${PORT}"
else
  launchctl_dir="$HOME/Library/LaunchAgents"
  if require launchctl; then
    if launchctl list | grep -q "$LABEL"; then
      echo "    launchctl: $LABEL loaded"
    else
      warn "launchctl: $LABEL not visible yet (it starts on next launch/error)"
    fi
  fi
  # A bare TCP probe: any HTTP status (or a WS rejection) means the relay is
  # answering; 000 means refused. The bridge speaks WebSocket on this port, so
  # do not require 2xx.
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)" || code="000"
  if [ "${code:-000}" != "000" ]; then
    echo "    relay answering on 127.0.0.1:${PORT} (HTTP $code — WebSocket endpoints often yield non-2xx on bare GET; that still proves liveness)"
  else
    warn "relay not answering yet on ${PORT} (000) — expected until the host starts with valid Discord creds; check ~/Library/Logs/discord-bridge.log"
  fi
fi

say "done"
[ "$DRY_RUN" -eq 1 ] || cat <<NEXT

Next steps:
  - fill $ENV_FILE with DISCORD_BOT_TOKEN/DISCORD_GUILD_ID etc. (secrets stay 0600)
  - kickstart now: launchctl kickstart -k gui/$(id -u)/$LABEL
  - toggle: launchctl bootout gui/$(id -u)/$LABEL (stop) / bootstrap (start)
  - rotate BRIDGE_RELAY_TOKEN in BOTH $ENV_FILE and $CONTAINER_ENV, then relaunch a container session
  - logs: ~/Library/Logs/discord-bridge.log
NEXT
