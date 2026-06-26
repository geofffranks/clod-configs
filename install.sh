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
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    echo "  new:       $rel"
  elif cmp -s "$src" "$dst"; then
    echo "  unchanged: $rel"
  else
    mv "$dst" "$dst.bak-$TS"
    cp "$src" "$dst"
    echo "  updated:   $rel (previous saved to $rel.bak-$TS)"
  fi
done < <(find "$SRC_DIR" -type f -print0)

# 2. Make scripts executable.
for f in statusline.sh bash-guard/hook.sh branch-guard/hook.sh git-safe/hook.sh \
         read-once/hook.sh read-once/compact.sh read-once/read-once \
         skill-once/hook.sh skill-once/compact.sh \
         hooks/no-remote-writes.sh hooks/agent-state.sh \
         agent-join/hook.sh; do
  [ -f "$DEST/$f" ] && chmod +x "$DEST/$f"
done

# 3. Merge the settings fragment, one patch at a time. Each individual difference
#    between your settings.json and the recommended merge is accepted or declined
#    on its own (interactive [y/N]). Additive patches (new keys, new hooks) and
#    value conflicts are all offered. Escape hatches keep their old meaning:
#    --overwrite / CLAUDE_CONFIG_OVERWRITE accept everything; no readable TTY
#    accepts additive patches only and declines conflicts.
#
#    recmerge = the "recommended wins, hooks unioned" merge (the old fragwins).
#    It is the upper bound of what could change; patches are the diff from yours.
# shellcheck disable=SC2016  # $home/$mine/$frag/$e/$ex/$rec/$p are jq variables
merge_filter='
  def cmdkey: sub("^~"; $home);
  .[0] as $mine | .[1] as $frag
  | ($mine * $frag)
  | .hooks = (
      reduce (($frag.hooks // {}) | to_entries[]) as $e (($mine.hooks // {});
        .[$e.key] as $cur
        | ([ ($cur // [])[] | .hooks[]?.command | cmdkey ]) as $have
        | .[$e.key] = ( ($cur // [])
            + [ $e.value[] | select( ([.hooks[]?.command | cmdkey] - $have) | length > 0 ) ] ))
    )
'
# Enumerate patches: generic leaf/array values (arrays atomic, hooks excluded)
# plus per-entry hook additions. Emitted as NDJSON, sorted by .sortkey for a
# stable prompt order. $e/$r/$f are slurped existing/recmerge/fragment.
# shellcheck disable=SC2016
enum_filter='
  def cmdkey: sub("^~"; $home);
  $e[0] as $ex | $r[0] as $rec | $f[0] as $frag
  | ( [ $rec | paths(type != "object")
        | select(all(.[]; type == "string"))   # never descend through an array index -> arrays stay atomic
        | select(.[0] != "hooks") ]            # hooks are handled by the hook branch below
      | map(. as $p | {kind:"generic", path:$p, rec:($rec|getpath($p)), your:($ex|getpath($p))})
      | map(select(.rec != .your))             # differs: covers both new and conflict
      | map(. + {ckind:(if .your == null then "new" else "conflict" end),
                 sortkey:("1:" + (.path|join(".")))}) ) as $generic
  | ( [ ($frag.hooks // {}) | to_entries[]
        | .key as $ev
        | ([ ($ex.hooks[$ev] // [])[] | .hooks[]?.command | cmdkey ]) as $have
        | (.value | to_entries[])
        | select( ([.value.hooks[]?.command | cmdkey] - $have) | length > 0 )
        | {kind:"hook", event:$ev, idx:.key, entry:.value,
           sortkey:("2:" + $ev + ":" + ((.key + 1000)|tostring))} ] ) as $hooks
  | ($generic + $hooks) | sort_by(.sortkey) | .[]
'
# Apply accepted patches onto your file: .[0] = existing, .[1] = accepted array.
# shellcheck disable=SC2016
apply_filter='
  reduce .[1][] as $p (.[0];
    if $p.kind == "hook"
    then .hooks[$p.event] = ((.hooks[$p.event] // []) + [$p.entry])
    else setpath($p.path; $p.rec) end)
'
if command -v jq >/dev/null 2>&1; then
  if [ -f "$SETTINGS" ]; then
    work="$(mktemp -d)"
    staged=""                                  # in-$DEST staging file, removed on abort
    trap 'rm -rf "$work"; [ -n "$staged" ] && rm -f "$staged"' EXIT
    existing="$work/existing.json"
    recmerge="$work/recmerge.json"
    patches="$work/patches.ndjson"
    accepted="$work/accepted.ndjson"
    jq -S . "$SETTINGS" > "$existing"
    jq -S -s --arg home "$HOME" "$merge_filter" "$SETTINGS" "$FRAG" > "$recmerge"
    jq -c -n --arg home "$HOME" \
      --slurpfile e "$existing" --slurpfile r "$recmerge" --slurpfile f "$FRAG" \
      "$enum_filter" > "$patches"
    : > "$accepted"

    if [ ! -s "$patches" ]; then
      echo "  settings.json already up to date — no changes."
    else
      tty_src="${CLAUDE_CONFIG_TTY:-/dev/tty}"
      mode="interactive"
      if [ "$force" = "1" ]; then
        mode="force"
        echo "  --overwrite / CLAUDE_CONFIG_OVERWRITE set — taking all recommended values."
      elif [ ! -r "$tty_src" ]; then
        mode="notty"
      fi

      # Pre-loop advisory: name the conflicting keys (stderr, so it survives a
      # stdout redirect). In notty mode conflicts are skipped; say so.
      conflicts="$(jq -r -s '[ .[] | select(.ckind == "conflict") | .path | join(".") ] | join(", ")' "$patches")"
      if [ -n "$conflicts" ] && [ "$mode" != "force" ]; then
        {
          echo ""
          if [ "$mode" = "notty" ]; then
            echo "  ⚠  Recommended value(s) differ from yours: $conflicts"
            echo "     No terminal to prompt at — keeping yours (conflicts skipped, additive changes applied)."
            echo "     Re-run with --overwrite (or CLAUDE_CONFIG_OVERWRITE=1) to take recommended values."
          else
            echo "  ⚠  Recommended value(s) differ from yours: $conflicts"
          fi
          echo ""
        } >&2
      fi

      a_conf=0; a_new=0; a_hook=0; declined=0
      while IFS= read -r patch; do
        kind="$(jq -r '.kind' <<<"$patch")"
        ckind="$(jq -r '.ckind // .kind' <<<"$patch")"   # new | conflict | hook
        accept=0
        case "$mode" in
          force) accept=1 ;;
          notty) [ "$ckind" != "conflict" ] && accept=1 ;;  # additive only
          interactive)
            {
              if [ "$kind" = "hook" ]; then
                ev="$(jq -r '.event' <<<"$patch")"
                cmds="$(jq -r '[.entry.hooks[]?.command] | join(", ")' <<<"$patch")"
                echo "  + hook on $ev: $cmds"
              elif [ "$ckind" = "conflict" ]; then
                p="$(jq -r '.path | join(".")' <<<"$patch")"
                echo "  ~ $p"
                echo "      yours:       $(jq -rc '.your' <<<"$patch")"
                echo "      recommended: $(jq -rc '.rec'  <<<"$patch")"
              else
                p="$(jq -r '.path | join(".")' <<<"$patch")"
                echo "  + $p (new) = $(jq -rc '.rec' <<<"$patch")"
              fi
              printf "    apply? [y/N]: "
            } >&2
            reply=""
            read -r reply < "$tty_src" || reply=""
            case "$reply" in y | Y) accept=1 ;; *) accept=0 ;; esac
            ;;
        esac
        if [ "$accept" = "1" ]; then
          printf '%s\n' "$patch" >> "$accepted"
          case "$ckind" in
            conflict) a_conf=$((a_conf + 1)) ;;
            new) a_new=$((a_new + 1)) ;;
            hook) a_hook=$((a_hook + 1)) ;;
          esac
        else
          declined=$((declined + 1))
        fi
      done < "$patches"

      jq -s '.' "$accepted" > "$work/accepted-arr.json"
      jq -S -s "$apply_filter" "$existing" "$work/accepted-arr.json" > "$work/chosen.json"
      chosen="$work/chosen.json"
      echo "  applied $((a_conf + a_new + a_hook)) ($a_conf conflict, $a_new new, $a_hook hook), declined $declined"

      if [ "$(jq -s '.[0] == .[1]' "$chosen" "$existing")" = "true" ]; then
        echo "  settings.json unchanged — no write."
      else
        # Stage, back up, then atomically swap — a failure at any step leaves
        # settings.json intact and no orphan files.
        staged="$SETTINGS.new-$TS"
        cp "$chosen" "$staged"
        cp "$SETTINGS" "$SETTINGS.bak-$TS"
        mv "$staged" "$SETTINGS"               # atomic replace (same directory)
        staged=""
        echo "  updated settings.json (previous saved to settings.json.bak-$TS)"
      fi
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
