#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/home" && pwd)"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TS="$(date +%Y%m%d-%H%M%S)"
FRAG="$SRC_DIR/settings.recommended.json"
SETTINGS="$DEST/settings.json"

echo "Installing Claude config into: $DEST"
mkdir -p "$DEST"

# 1. Copy every file under home/ EXCEPT the settings fragment (merged separately).
while IFS= read -r -d '' src; do
  rel="${src#"$SRC_DIR"/}"
  [ "$rel" = "settings.recommended.json" ] && continue
  dst="$DEST/$rel"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && ! cmp -s "$src" "$dst"; then
    mv "$dst" "$dst.bak-$TS"
    echo "  backed up: $rel -> $rel.bak-$TS"
  fi
  cp "$src" "$dst"
done < <(find "$SRC_DIR" -type f -print0)

# 2. Make scripts executable.
for f in statusline.sh bash-guard/hook.sh branch-guard/hook.sh git-safe/hook.sh \
         read-once/hook.sh read-once/compact.sh read-once/read-once \
         hooks/no-remote-writes.sh hooks/agent-state.sh; do
  [ -f "$DEST/$f" ] && chmod +x "$DEST/$f"
done

# 3. Merge the settings fragment (deep merge; fragment has no permissions, so an
#    existing permissions block is preserved).
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-$TS"
    tmp="$(mktemp)"
    jq -s '.[0] * .[1]' "$SETTINGS" "$FRAG" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  merged settings.recommended.json into settings.json (existing permissions preserved)"
    echo "  previous settings.json saved to settings.json.bak-$TS"
  else
    cp "$FRAG" "$SETTINGS"
    echo "  wrote new settings.json from the recommended fragment"
  fi
else
  echo "  jq not found — skipping settings merge."
  echo "  Manually merge keys from: $FRAG"
  echo "  into: $SETTINGS  (do NOT overwrite your permissions block)"
fi

echo "Done."
