#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/home" && pwd)"
DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
TS="$(date +%Y%m%d-%H%M%S)"
FRAG="$SRC_DIR/settings.recommended.json"
SETTINGS="$DEST/settings.json"

# Force-overwrite knob: env CLAUDE_CONFIG_OVERWRITE=1 or the --overwrite flag.
force=0
[ "${CLAUDE_CONFIG_OVERWRITE:-}" = "1" ] && force=1
for arg in "$@"; do
  case "$arg" in
    --overwrite) force=1 ;;
    -h | --help)
      echo "usage: install.sh [--overwrite]"
      echo "  --overwrite                 take recommended settings over your existing values (no prompt)"
      echo "  CLAUDE_CONFIG_OVERWRITE=1   same, via environment"
      exit 0
      ;;
    *)
      echo "install.sh: unknown argument: $arg" >&2
      echo "usage: install.sh [--overwrite]" >&2
      exit 2
      ;;
  esac
done

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

# 3. Merge the settings fragment. Non-destructive by default: new keys are added,
#    but a value you already set is overwritten only with consent (an interactive
#    "y", --overwrite, or CLAUDE_CONFIG_OVERWRITE=1).
#
#    Hooks are special. jq's `*` deep-merges objects but REPLACES arrays wholesale,
#    so a plain `*` on `hooks.<Event>` (an array of matchers) would silently drop
#    your own hooks. We instead UNION hook arrays (concat + dedup by command) in
#    BOTH directions, so your hooks survive even when you choose overwrite. With
#    hooks unioned identically either way, the two merges differ ONLY on conflicting
#    non-hook scalars — so over == keep exactly when nothing of yours would change.
#
#    $fw selects the conflict winner for non-hook keys: recommended (existing*frag)
#    when true, yours (frag*existing) when false. Hooks union regardless.
# shellcheck disable=SC2016  # $fw/$mine/$frag/$e are jq variables, not shell ones
#   Dedup compares commands by a NORMALIZED key (leading ~ expanded to $HOME):
#   Claude Code expands ~ at runtime, so "~/.claude/x.sh" and "/home/you/.claude/x.sh"
#   are the same hook. Without this they read as distinct and the fragment hook is
#   appended next to your equivalent on every run.
merge_filter='
  def cmdkey: sub("^~"; $home);
  .[0] as $mine | .[1] as $frag
  | ( if $fw then ($mine * $frag) else ($frag * $mine) end )
  | .hooks = (
      reduce (($frag.hooks // {}) | to_entries[]) as $e (($mine.hooks // {});
        .[$e.key] as $cur
        | ([ ($cur // [])[] | .hooks[]?.command | cmdkey ]) as $have
        | .[$e.key] = ( ($cur // [])
            + [ $e.value[] | select( ([.hooks[]?.command | cmdkey] - $have) | length > 0 ) ] )
      )
    )
'
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    work="$(mktemp -d)"
    staged=""                                # in-$DEST staging file, removed on abort
    trap 'rm -rf "$work"; [ -n "$staged" ] && rm -f "$staged"' EXIT
    fragwins="$work/fragwins.json"   # recommended wins on non-hook conflicts; hooks unioned
    keepmine="$work/keepmine.json"   # your values win on conflicts; hooks unioned; new keys added
    existing="$work/existing.json"
    jq -S -s --arg home "$HOME" --argjson fw true  "$merge_filter" "$SETTINGS" "$FRAG" > "$fragwins"
    jq -S -s --arg home "$HOME" --argjson fw false "$merge_filter" "$SETTINGS" "$FRAG" > "$keepmine"
    jq -S . "$SETTINGS" > "$existing"

    # Semantic compare (jq ==), not byte compare: jq preserves number literals,
    # so a value re-spelled as 1.0 vs 1 must not masquerade as an overwrite.
    if [ "$(jq -s '.[0] == .[1]' "$fragwins" "$keepmine")" = "true" ]; then
      chosen="$fragwins"                       # only additions/hook-unions — nothing of yours changes
    else
      # Conflicts are non-hook only (hooks union identically in both merges), so
      # exclude "hooks" when naming the keys that would actually be overwritten.
      overkeys="$(jq -r -s '.[0] as $e | .[1] as $m | [ $e | keys[] | select(. != "hooks" and $e[.] != $m[.]) ] | join(", ")' "$SETTINGS" "$fragwins")"
      # Warning, diff, and prompt are advisories for a human decision — send them
      # to stderr together so they stay coherent if stdout is redirected to a log.
      {
        echo ""
        echo "  ⚠  Recommended settings would OVERWRITE value(s) you already set: $overkeys"
        echo ""
        diff -u -L "your settings.json" -L "after recommended merge" "$existing" "$fragwins" || true
        echo ""
      } >&2
      tty_src="${CLAUDE_CONFIG_TTY:-/dev/tty}"
      if [ "$force" = "1" ]; then
        chosen="$fragwins"
        echo "  --overwrite / CLAUDE_CONFIG_OVERWRITE set — taking recommended values."
      elif [ -r "$tty_src" ]; then
        # Prompt to stderr so it stays visible if stdout is redirected to a log.
        {
          echo "  Apply recommended values over yours?"
          echo "    y = take recommended (your file is backed up to settings.json.bak-$TS)"
          echo "    N = keep your values, still add new keys + recommended hooks   [default]"
          printf "  [y/N]: "
        } >&2
        reply=""
        read -r reply < "$tty_src" || reply=""
        case "$reply" in
          y | Y) chosen="$fragwins" ;;
          *) chosen="$keepmine" ;;
        esac
      else
        chosen="$keepmine"
        echo "  No terminal to prompt at — kept your values and added new keys + hooks."
        echo "  Re-run with --overwrite (or CLAUDE_CONFIG_OVERWRITE=1) to take recommended values."
      fi
    fi

    if [ "$(jq -s '.[0] == .[1]' "$chosen" "$existing")" = "true" ]; then
      echo "  settings.json already up to date — no changes."
    else
      # Stage first, back up second, then atomically swap — a failure at any step
      # leaves settings.json intact (never half-written) and no orphan files.
      staged="$SETTINGS.new-$TS"
      cp "$chosen" "$staged"
      cp "$SETTINGS" "$SETTINGS.bak-$TS"
      mv "$staged" "$SETTINGS"                 # atomic replace (same directory)
      staged=""
      echo "  updated settings.json (previous saved to settings.json.bak-$TS)"
    fi
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
