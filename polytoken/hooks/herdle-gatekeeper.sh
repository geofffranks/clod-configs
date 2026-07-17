#!/usr/bin/env bash
# herdle-gatekeeper.sh — PreToolUse hook: herdle lifecycle gatekeeper.
#
# Prefers a native herdle binary ($HOME/bin/herdle); falls back to building
# from source — the path used inside the polytoken-dev container, where no
# prebuilt binary is installed (mirrors the MCP-server go-from-source pattern).
#
# We build once to a cached binary and exec it directly on subsequent calls,
# NOT `go run`, which mangles non-zero exit codes to 1. herdle's exit code must
# be preserved exactly: 0 = allow, 2 = deny (intentional lifecycle gate). The
# hook fires on every tool call, so the cached binary avoids per-call overhead.
# A rebuild happens only when a .go / go.mod / go.sum file is newer than the
# cached binary.
#
# Polytoken writes the tool-call envelope to stdin; herdle reads it. If herdle
# is unavailable on either path the hook fails open (exit 0).

HERDLE="$HOME/bin/herdle"
SRCDIR="$HOME/workspace/herdle"
BIN="${XDG_CACHE_HOME:-$HOME/.cache}/herdle-gatekeeper/herdle"

if [ -x "$HERDLE" ]; then
  exec "$HERDLE" hook gatekeeper --agent polytoken
fi

if [ -d "$SRCDIR/cmd/herdle" ]; then
  # Rebuild only when a tracked source file is newer than the cached binary.
  if [ ! -x "$BIN" ] || \
     find "$SRCDIR" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) \
       -newer "$BIN" -print -quit 2>/dev/null | grep -q .; then
    mkdir -p "$(dirname "$BIN")"
    ( cd "$SRCDIR" && go build -o "$BIN" ./cmd/herdle ) || exit 0
  fi
  exec "$BIN" hook gatekeeper --agent polytoken
fi

# No herdle available — fail open.
exit 0
