#!/usr/bin/env bash
#
# polytoken container launcher.
#   - mounts:  ~/workspace, ~/.config/polytoken, ~/bin, ~/.gitconfig,
#              ~/.config/gh (ro), ~/.gitignore (ro), ~/.local/share/polytoken,
#              ~/.codex, ~/go/pkg/mod, ~/.claude
#   - masks container-local node_modules for selected repos via named volumes
#     (see POLY_NODE_MODULES_MASK below) so the linux container and the macOS
#     host each keep their own npm install at the same path
#   - launches polytoken in the repo under ~/workspace you run this from
#     (or at the ~/workspace root if launched elsewhere)
#   - passes ALL arguments through to polytoken
#   - forces Bypass+ permission mode via an ephemeral .polytoken/config.yaml
#     (the host keeps Autonomous from its global config)
#   - extra mounts via env var:  POLY_EXTRA_MOUNTS='-v /extra:/home/dev/extra'
#   - API keys via env file:    POLY_ENV_FILE (default ~/.config/polytoken-container.env)
#
set -euo pipefail

IMAGE="${POLY_IMAGE:-polytoken-dev}"
TAG="${POLY_TAG:-latest}"
DEV_HOME="/home/dev"

HOST_WS="$HOME/workspace"
HOST_CFG="$HOME/.config/polytoken"
HOST_BIN="$HOME/bin"
HOST_GITCFG="$HOME/.gitconfig"
ENV_FILE="${POLY_ENV_FILE:-$HOME/.config/polytoken-container.env}"

# ---- container working directory ----
rel="${PWD#"$HOST_WS"}"   # "/dcs-retribution" or ""
rel="${rel#/}"            # "dcs-retribution" or ""
if [[ -n "$rel" ]]; then
  CWD="$DEV_HOME/workspace/$rel"
else
  CWD="$DEV_HOME/workspace"
  echo "run.sh: not under ~/workspace — landing at workspace root." >&2
fi

# ---- required mounts must exist on the host ----
for d in "$HOST_WS" "$HOST_CFG" "$HOST_BIN"; do
  [[ -d "$d" ]] || { echo "run.sh: missing mount source: $d" >&2; exit 1; }
done

# ---- mount flags (MOUNTS is always non-empty, so safe to expand) ----
MOUNTS=(
  -v "$HOST_WS:$DEV_HOME/workspace"
  -v "$HOST_CFG:$DEV_HOME/.config/polytoken"
  -v "$HOST_BIN:$DEV_HOME/bin"
)
[[ -f "$HOST_GITCFG" ]] && MOUNTS+=(-v "$HOST_GITCFG:$DEV_HOME/.gitconfig.host:ro")
[[ -d "$HOME/.config/gh" ]] && MOUNTS+=(-v "$HOME/.config/gh:$DEV_HOME/.config/gh:ro")
[[ -f "$HOME/.gitignore" ]] && MOUNTS+=(-v "$HOME/.gitignore:$DEV_HOME/.gitignore:ro")
# Persist the container's polytoken logs/sessions to the host via a DEDICATED dir.
# Do NOT mount the host's ~/.local/share/polytoken directly: macOS Docker stamps a
# dir that a root container once wrote with a user.containers.override_stat xattr,
# which makes it appear root-owned (700) and unwritable to the dev user. A fresh
# dedicated dir avoids that. Created here so it is owned by you, not root.
HOST_PTDAT="$HOME/.local/share/polytoken-dev"
mkdir -p "$HOST_PTDAT"
MOUNTS+=(-v "$HOST_PTDAT:$DEV_HOME/.local/share/polytoken")
# codex CLI auth/config for codex-imagegen-mcp (rw: codex writes sessions/images).
# Codex creates executable aliases under ~/.codex/tmp/arg0. A prior root-run
# container may have left that subdirectory root-owned, so repair it below.
CODEX_MOUNT=0
[[ -d "$HOME/.codex" ]] && { MOUNTS+=(-v "$HOME/.codex:$DEV_HOME/.codex"); CODEX_MOUNT=1; }
# Go module cache (shared, portable across darwin/linux) so the `go run` MCP
# wrappers don't re-fetch deps on every container session.
[[ -d "$HOME/go/pkg/mod" ]] && MOUNTS+=(-v "$HOME/go/pkg/mod:$DEV_HOME/go/pkg/mod")
# claude CLI auth/config (rw: claude writes sessions, projects, statsig). The
# build stamps DEV_UID = host uid, so bind-mount ownership lines up with no repair.
[[ -d "$HOME/.claude" ]] && MOUNTS+=(-v "$HOME/.claude:$DEV_HOME/.claude")
# Mask per-repo node_modules with container-local named volumes. npm's
# platform-specific native bindings (linux in here, darwin on the Mac) cannot
# share one directory; each side gets its own install at the same path, and
# named volumes persist across --rm launches. Replace the repo list with:
#   POLY_NODE_MODULES_MASK="repoA repoB/sub"
# (repo paths relative to ~/workspace, up to two components deep).
POLY_NODE_MODULES_MASK_DEFAULT="track-data-collection track-data-collection/mobile appium-mcp"
for rel in ${POLY_NODE_MODULES_MASK:-$POLY_NODE_MODULES_MASK_DEFAULT}; do
  vol="polytoken-nm-$(printf '%s' "$rel" | tr '/' '-')"
  MOUNTS+=(-v "$vol:$DEV_HOME/workspace/$rel/node_modules")
done
if [[ -n "${POLY_EXTRA_MOUNTS:-}" ]]; then
  # shellcheck disable=SC2206
  MOUNTS+=($POLY_EXTRA_MOUNTS)
fi

# ---- API keys / env ----
# (a) static file (for keys you'd rather not export in your shell)
ENV_FLAGS=""
[[ -f "$ENV_FILE" ]] && ENV_FLAGS="--env-file $ENV_FILE"

# (b) forward provider tokens already exported in your shell into the container.
#     `-e VAR` (no value) makes docker read each value from the host environment.
#     Extend the list with:  POLY_PASS_ENV="FOO_KEY BAR_TOKEN"
# GH_TOKEN: gh stores its OAuth token in the macOS Keychain (not in the
# ~/.config/gh files we mount), so it can't cross the container boundary.
# Pass it as an env var instead — gh prefers GH_TOKEN over the keychain.
POLY_PASS_ENV_DEFAULT="ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN OPENAI_API_KEY GEMINI_API_KEY \
GROQ_API_KEY DEEPSEEK_API_KEY MISTRAL_API_KEY NEURALWATT_API_KEY ZAI_API_KEY OPENROUTER_API_KEY \
BRAVE_SEARCH_API_KEY TAVILY_API_KEY EXA_API_KEY KAGI_API_KEY FOUNDRY_API_KEY \
GH_TOKEN"
for v in $POLY_PASS_ENV_DEFAULT ${POLY_PASS_ENV:-}; do
  if [ -n "${!v:-}" ]; then
    ENV_FLAGS="$ENV_FLAGS -e $v"
  fi
done

# ---- per-launch: force Bypass+ permission mode in the container ----
# Drops an ephemeral .polytoken/config.yaml overriding the host's global
# Autonomous mode (polytoken merges project config over global — verified). The
# container's filesystem boundary + global deny rules (git push / rm -rf / gh
# writes) are the safety net, so we want zero prompts here. Removed on exit so
# the host keeps Autonomous. (Bypass+ ignores ask rules, so none are generated.)
GEN_CFG="$PWD/.polytoken/config.yaml"
BACKUP_DIR=""

restore_project_config() {
  local status="${1:-$?}"
  trap - EXIT INT TERM HUP
  rm -f "$GEN_CFG"
  if [[ -n "$BACKUP_DIR" ]]; then
    mv "$BACKUP_DIR/config.yaml" "$GEN_CFG"
    rmdir "$BACKUP_DIR" 2>/dev/null || rm -rf "$BACKUP_DIR"
  fi
  exit "$status"
}
trap restore_project_config EXIT
trap 'restore_project_config 130' INT
trap 'restore_project_config 143' TERM
trap 'restore_project_config 129' HUP

mkdir -p "$PWD/.polytoken"
if [[ -e "$GEN_CFG" || -L "$GEN_CFG" ]]; then
  BACKUP_DIR="$(mktemp -d "$PWD/.polytoken/.container-config.XXXXXX")"
  mv "$GEN_CFG" "$BACKUP_DIR/config.yaml"
fi

cat > "$GEN_CFG" <<YAML
# AUTO-GENERATED by the polytoken container launcher — safe to delete.
# Forces Bypass+ in the container; the host keeps Autonomous via global config.
version: 2
default_permission_matcher: bypass_plus
YAML

# Repair Codex's helper-alias directory inside the bind mount before launching
# as dev. The image's USER cannot fix ownership after ~/.codex is mounted.
if [[ "$CODEX_MOUNT" == 1 ]]; then
  echo "run.sh: repairing Codex alias directory ownership" >&2
  docker run --rm --user 0 \
    -v "$HOME/.codex:$DEV_HOME/.codex" \
    "$IMAGE:$TAG" \
    sh -c 'mkdir -p /home/dev/.codex/tmp/arg0 && chmod 700 /home/dev/.codex/tmp/arg0 && chown -R dev:dev /home/dev/.codex/tmp/arg0'
fi

echo "run.sh: repairing Codex alias directory ownership" >&2
docker run --rm --user 0 \
  -v "$HOST_PTDAT:$DEV_HOME/.local/share/polytoken" \
  "$IMAGE:$TAG" \
  sh -c 'mkdir -p /home/dev/.local/share/polytoken && chmod 700 /home/dev/.local/share/polytoken && chown -R dev:dev /home/dev/.local/share/polytoken'

# chown the masked node_modules volumes so the dev user can npm-install into
# them (docker creates missing volume mountpoints as root). The repair
# container mounts ONLY the volumes, so find touches exactly the masked paths.
if [[ -n "${POLY_NODE_MODULES_MASK:-$POLY_NODE_MODULES_MASK_DEFAULT}" ]]; then
  NM_REPAIR=()
  for rel in ${POLY_NODE_MODULES_MASK:-$POLY_NODE_MODULES_MASK_DEFAULT}; do
    vol="polytoken-nm-$(printf '%s' "$rel" | tr '/' '-')"
    NM_REPAIR+=(-v "$vol:$DEV_HOME/workspace/$rel/node_modules")
  done
  echo "run.sh: repairing masked node_modules volume ownership" >&2
  docker run --rm --user 0 "${NM_REPAIR[@]}" "$IMAGE:$TAG" \
    sh -c 'find /home/dev/workspace -maxdepth 3 -type d -name node_modules -exec chown -R dev:dev {} +'
fi

echo "run.sh: launching polytoken in $CWD" >&2

set +u
if [[ "${1}" == "bash" ]]; then
  cmd=bash
  shift
else
  cmd=/home/dev/.local/bin/polytoken
fi
set -u

# shellcheck disable=SC2086  (ENV_FLAGS intentionally word-split)
docker run --rm -it --init \
  -e TERM="${TERM:-xterm-256color}" \
  -e COLORTERM=truecolor \
  $ENV_FLAGS \
  "${MOUNTS[@]}" \
  -w "$CWD" \
  "$IMAGE:$TAG" \
  ${cmd} "$@"
