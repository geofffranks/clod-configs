#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: install.sh [--target claude|polytoken|all] [--overwrite] [--notify-hook-only]
  --target claude             install Claude Code config (default)
  --target polytoken          install Polytoken config
  --target all                install both targets, independently
  --overwrite                 take recommended settings over your existing values (no prompt)
  --notify-hook-only          install just the notification stack: agent-notify hooks
                              (+ the Polytoken session watchdog and SSE watcher); no other config
  --containerized-polytoken   with --notify-hook-only: skip the macOS LaunchAgent and install the
                              keepalive hooks instead (sessions run in containers)
  CLAUDE_CONFIG_OVERWRITE=1   same, via environment
EOF
}

usage_error() {
  [ "$#" -gt 0 ] && echo "install.sh: $*" >&2
  usage >&2
  exit 2
}

# Parse arguments once. `--target` selects the install mode (default: claude);
# `--overwrite` (or CLAUDE_CONFIG_OVERWRITE=1) accepts recommended conflicts;
# `--notify-hook-only` installs just the attention-notification stack.
target=claude
force=0
notify_only=0
containerized=0
[ "${CLAUDE_CONFIG_OVERWRITE:-}" = "1" ] && force=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) [ "$#" -ge 2 ] || usage_error "--target requires a value"; target=$2; shift 2 ;;
    --overwrite) force=1; shift ;;
    --notify-hook-only) notify_only=1; shift ;;
    --containerized-polytoken) containerized=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage_error "unknown argument: $1" ;;
  esac
done
case "$target" in claude|polytoken|all) ;; *) usage_error "unknown target: $target" ;; esac
[ "$containerized" = 0 ] || [ "$notify_only" = 1 ] \
  || usage_error "--containerized-polytoken requires --notify-hook-only"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Polytoken scheduler gating — single owner (install.sh). The OS seam is read
# exactly once, here; scripts/install-polytoken.sh gates purely on the mode
# argument forwarded below and never reads the OS itself.
#   macOS native (no flag):  LaunchAgent owns the death scan -> polytoken mode
#                            "notify" drops the keepalive hook entries; the
#                            LaunchAgent runs default-on (operator decision C).
#   --containerized-polytoken OR non-macOS: mode "notify-container" keeps the
#                            keepalive hook entries (launchd absent; keepalive
#                            loops are the only way to keep the scans alive).
pt_host_os="${POLYTOKEN_INSTALL_OS:-$(uname -s 2>/dev/null || printf unknown)}"
pt_macos=0
[ "$pt_host_os" = "Darwin" ] && pt_macos=1
pt_mode=""
if [ "$notify_only" = 1 ]; then
  if [ "$pt_macos" = 1 ] && [ "$containerized" = 0 ]; then
    pt_mode="notify"
  else
    pt_mode="notify-container"
  fi
fi

# One LaunchAgent call site for the whole installer. The script self-seeds
# ~/.claude/session-watchdog.sh and loads the LaunchAgent; tests point
# POLYTOKEN_INSTALL_LA_SCRIPT at a recording stub.
install_polytoken_launch_agent() {
  if [ "$pt_macos" = 0 ]; then
    echo "  non-macOS host: no LaunchAgent; the session-start keepalive hooks keep the watchdog and SSE watcher running"
    return 0
  fi
  if [ "$containerized" = 1 ]; then
    echo "  --containerized-polytoken: LaunchAgent skipped; keepalive hooks installed instead"
    echo "  To also scan Mac-side sessions, run: $SELF_DIR/scripts/install-session-watchdog.sh"
    return 0
  fi
  bash "${POLYTOKEN_INSTALL_LA_SCRIPT:-$SELF_DIR/scripts/install-session-watchdog.sh}"
}

# The whole polytoken step (config install + scheduler), shared by the
# polytoken and all targets so the LaunchAgent fires exactly once per run.
install_polytoken_target() {
  local rc=0
  bash "$SELF_DIR/scripts/install-polytoken.sh" "$force" "$pt_mode" || rc=$?
  if [ "$rc" = 0 ]; then
    install_polytoken_launch_agent || rc=$?
  fi
  return "$rc"
}

install_claude() {
  SRC_DIR="$(cd "$SELF_DIR/home" && pwd)"
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
for f in statusline.sh usage-fetch.sh bash-guard/hook.sh branch-guard/hook.sh git-safe/hook.sh \
         read-once/hook.sh read-once/compact.sh read-once/read-once \
         skill-once/hook.sh skill-once/compact.sh \
         hooks/no-remote-writes.sh hooks/agent-state.sh hooks/agent-notify.sh \
         session-watchdog.sh \
         agent-join/hook.sh; do
  [ -f "$DEST/$f" ] && chmod +x "$DEST/$f"
done

# 2b. Migrate: remove deprecated hook entries that were superseded by skill-once/hook.sh.
#     The installer only adds hooks (never removes), so installations that accumulated
#     the old monolithic skill-once-hook.sh alongside the new package need an explicit
#     cleanup pass.  This runs before the merge so the final result is already clean.
if command -v jq >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  migrate_filter='
    def cmdkey: gsub("^~"; $home) | gsub("\\$HOME"; $home);

    # True if every command in this hook group is a deprecated script.
    def is_deprecated:
      [ .hooks[]?.command | cmdkey ] | length > 0 and all(
        test("/.claude/hooks/skill-once-hook\\.sh$") or
        test("/.claude/hooks/skill-once-compact\\.sh$")
      );

    # True if this PostCompact entry contains skill-once/compact.sh.
    def has_skill_once_compact:
      [ .hooks[]?.command | cmdkey ] | any(test("skill-once/compact\\.sh$"));

    # True if this PostCompact entry has ONLY read-once/compact.sh (no skill-once).
    def is_readonce_only:
      [ .hooks[]?.command | cmdkey ] | length > 0 and all(test("read-once/compact\\.sh$"));

    if .hooks then
      .hooks.PreToolUse  = [ (.hooks.PreToolUse  // [])[] | select(is_deprecated | not) ]
      | .hooks.PostCompact = (
          (.hooks.PostCompact // []) as $pc
          | if ($pc | any(has_skill_once_compact)) then
              [ $pc[] | select((is_deprecated or is_readonce_only) | not) ]
            else
              [ $pc[] | select(is_deprecated | not) ]
            end
        )
    else . end
  '
  migrated="$(jq -S --arg home "$HOME" "$migrate_filter" "$SETTINGS" 2>/dev/null)" || migrated=""
  if [ -n "$migrated" ] && [ "$(jq -S . "$SETTINGS")" != "$migrated" ]; then
    cp "$SETTINGS" "$SETTINGS.bak-$TS"
    printf '%s\n' "$migrated" > "$SETTINGS"
    echo "  migrated: removed deprecated skill-once hook entries (previous saved to settings.json.bak-$TS)"
  fi
fi

  merge_claude_settings
  echo "Done."
}

# Shared settings-merge machinery (prompted patch enumeration, cmdkey dedup,
# atomic write with backup discipline). Verbatim from the original inline
# block; both the full install and --notify-hook-only feed their FRAG through
# this — there is no bespoke notify-only write path.
merge_claude_settings() {
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
}

# Notify-only Claude install: just the attention-notification stack — the
# agent-notify hook, its single lib dependency (notify-mac.sh, the
# credential-free mac Notification Center lane), and the three agent-notify
# hook entries. No guards, skills, statusline, CLAUDE.md, env/model keys, or
# other recommended settings. The hook entries are derived at runtime by jq
# from the canonical settings.recommended.json (no committed fragment, no
# second name enumeration) with a fail-closed selector assertion.
install_claude_notify() {
  # Fail closed before touching anything: the hooks-only fragment is jq-derived.
  if ! command -v jq >/dev/null 2>&1; then
    echo "install.sh: --notify-hook-only requires jq (https://stedolan.github.io/jq)" >&2
    exit 1
  fi
  SRC_DIR="$(cd "$SELF_DIR/home" && pwd)"

  # 1. Derive the hooks-only fragment and assert the expected entries BEFORE
  #    anything is written to $DEST: a drifted or renamed source aborts here,
  #    leaving no partial install (no copied hook, no stray backups).
  FRAG="$(mktemp)"
  jq '{ hooks: (.hooks
        | with_entries(.value |= [ .[] | select([.hooks[]?.command] | any(test("/hooks/agent-notify\\.sh"))) ])
        | with_entries(select((.value | length) > 0)) ) }' \
    "$SRC_DIR/settings.recommended.json" > "$FRAG"
  if ! jq -e '
    ([.hooks | keys[]] | sort) == ["Stop", "UserPromptSubmit"]
    and ([.hooks | to_entries[] | .value[]] | length) == 2
    and ([.hooks | to_entries[] | .value[].hooks[].command] | length == 2)
    and ([.hooks | to_entries[] | .value[].hooks[].command] | all(test("/hooks/agent-notify\\.sh")))
    and (.hooks.UserPromptSubmit[0].hooks[0].async // false | not)
    and (.hooks.Stop[0].hooks[0].async == true)
  ' "$FRAG" >/dev/null; then
    rm -f "$FRAG"
    echo "install.sh: --notify-hook-only selector did not match the expected 2 agent-notify hook entries (UserPromptSubmit, Stop async); nothing installed" >&2
    exit 1
  fi

  DEST="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  TS="$(date +%Y%m%d-%H%M%S)"
  SETTINGS="$DEST/settings.json"

  echo "Installing Claude notify-only config into: $DEST"
  mkdir -p "$DEST"

  # 2. Copy exactly the notify files (same new/unchanged/updated protocol as a
  #    full install). The lib pair notify-identity/notify-send is deliberately
  #    excluded: the hook sources neither. notify-mac.sh must ship — the hook
  #    calls notify_mac_available/notify_mac_send for the default-on mac lane.
  for rel in hooks/agent-notify.sh lib/notify-mac.sh; do
    src="$SRC_DIR/$rel"
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
  done
  if [ -f "$DEST/hooks/agent-notify.sh" ]; then
    chmod +x "$DEST/hooks/agent-notify.sh"
  fi

  # 3. Merge through the same machinery as a full install. The skill-once
  #    migration pass (install_claude step 2b) is deliberately not run here:
  #    notify-only never rewrites settings.json beyond the notify entries.
  merge_claude_settings
  rm -f "$FRAG"

  echo "Done."
}

case "$target" in
  claude)
    if [ "$notify_only" = 1 ]; then install_claude_notify; else install_claude; fi
    ;;
  polytoken)
    install_polytoken_target
    ;;
  all)
    # Run both targets independently; report each result and exit nonzero if
    # either failed. A success is not rolled back when the other target fails.
    rc=0
    echo "==> target claude"
    if [ "$notify_only" = 1 ]; then install_claude_notify; else install_claude; fi
    if [ $? -eq 0 ]; then echo "target claude: OK"; else echo "target claude: FAILED"; rc=1; fi
    echo "==> target polytoken"
    if install_polytoken_target; then
      echo "target polytoken: OK"
    else
      echo "target polytoken: FAILED"; rc=1
    fi
    exit "$rc"
    ;;
esac
