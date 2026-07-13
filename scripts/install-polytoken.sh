#!/usr/bin/env bash
# scripts/install-polytoken.sh — install native Polytoken configuration.
#
# Invoked by install.sh as: scripts/install-polytoken.sh FORCE
#   FORCE is "0" or "1". Consumes:
#     POLYTOKEN_CONFIG_DIR  destination config root (default ~/.config/polytoken)
#     POLYTOKEN_CONFIG_TTY  readable TTY for per-patch prompts (default /dev/tty)
#
# jq is used for hooks.json; mikefarah/yq v4 is required for YAML merges. If a
# required dependency is missing, nothing structured is changed.
set -euo pipefail

FORCE="${1:-0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${POLYTOKEN_CONFIG_DIR:-$HOME/.config/polytoken}"
TS="$(date +%Y%m%d-%H%M%S)"
TTY="${POLYTOKEN_CONFIG_TTY:-/dev/tty}"

PT_CFG="$ROOT/polytoken/config.recommended.yaml"
PT_PERMS="$ROOT/polytoken/permissions.recommended.yaml"
PT_HOOKS="$ROOT/polytoken/hooks.json"
PT_AGENTS="$ROOT/polytoken/AGENTS.md"
PT_ADAPTER="$ROOT/polytoken/hooks/adapter.sh"

# Canonical scripts installed under compat/ (mirrors home/ layout).
COMPAT_DIRS=(bash-guard branch-guard git-safe read-once skill-once)
COMPAT_HOOKS=(hooks/no-remote-writes.sh)
# Executable managed scripts, relative to DEST.
EXEC_SCRIPTS=(
  hooks/adapter.sh
  compat/bash-guard/hook.sh compat/branch-guard/hook.sh compat/git-safe/hook.sh
  compat/read-once/hook.sh compat/read-once/compact.sh compat/read-once/read-once
  compat/skill-once/hook.sh compat/skill-once/compact.sh
  compat/hooks/no-remote-writes.sh
)

# Clean up any staged files we leave behind on error. Must return 0 so the EXIT
# trap never overrides the script's real exit status.
STAGED_FILES=()
cleanup() {
  local f
  for f in "${STAGED_FILES[@]}"; do [ -f "$f" ] && rm -f "$f"; done
  return 0
}
trap cleanup EXIT

die() { echo "polytoken: $*" >&2; exit 1; }

# ---- dependency gates (before any structured change) ----
require_jq() {
  command -v jq >/dev/null 2>&1 \
    || die "jq is required (https://stedolan.github.io/jq)"
}
require_yq_v4() {
  command -v yq >/dev/null 2>&1 \
    || die "mikefarah/yq v4 is required for YAML merges (https://github.com/mikefarah/yq); the Python yq wrapper is not supported"
  yq --version 2>/dev/null | grep -Eq 'version v4\.' \
    || die "mikefarah/yq v4 is required (got: $(yq --version 2>&1))"
}
require_jq
require_yq_v4

# ---- interaction mode ----
mode=interactive
[ "$FORCE" = "1" ] && mode=force
if [ "$mode" = "interactive" ] && [ ! -r "$TTY" ]; then
  mode=notty
fi

prompt_yn() {
  # Returns 0 to accept, 1 to decline, honoring the global mode.
  local label="$1" ckind="$2"
  case "$mode" in
    force) return 0 ;;
    notty) [ "$ckind" = "conflict" ] && return 1 || return 0 ;;
    interactive)
      printf '  %s [y/N]: ' "$label" >&2
      local reply=""
      read -r reply < "$TTY" || reply=""
      case "$reply" in y|Y) return 0 ;; *) return 1 ;; esac
      ;;
  esac
}

# ---- plain managed-file copy (AGENTS.md, skills, compat, adapter) ----
copy_managed_file() {
  local src="$1" dst="$2" rel="${2#"$DEST"/}"
  mkdir -p "$(dirname "$dst")"
  if [ ! -e "$dst" ]; then
    cp "$src" "$dst"
    echo "  new:       $rel"
  elif cmp -s "$src" "$dst"; then
    echo "  unchanged: $rel"
  else
    if prompt_yn "$rel differs; replace with recommended?" conflict; then
      cp "$dst" "$dst.bak-$TS"
      cp "$src" "$dst"
      echo "  updated:   $rel (previous saved to $rel.bak-$TS)"
    else
      echo "  preserved: $rel (differs; kept yours)"
    fi
  fi
}

# ---- validated atomic write for structured files ----
# validate_staged KIND DST STAGED: parse + structural + contextual polytoken
# validation. Returns nonzero (without touching DST) if STAGED is invalid.
validate_staged() {
  local kind="$1" dst="$2" staged="$3" rel="${2#"$DEST"/}"
  case "$kind" in
    hooks)
      jq -e 'type == "array"
             and (([.[]?.name] | length) == ([.[]?.name] | unique | length))
             and all(.[]?; has("name") and (.event == "pre_tool_use" or .event == "post_compaction") and (.handler.bash | type == "string"))' \
        "$staged" >/dev/null 2>&1 \
        || { echo "polytoken: $rel validation failed (bad hook array structure); existing file unchanged" >&2; return 1; }
      ;;
    config|permissions)
      yq e . "$staged" >/dev/null 2>&1 \
        || { echo "polytoken: $rel validation failed (invalid YAML); existing file unchanged" >&2; return 1; }
      ;;
  esac
  # Contextual validation: only meaningful when DEST already holds a complete,
  # valid config (providers/models). On a fresh/partial dir we rely on the
  # parse+structural checks above, since the recommended overlay alone is not a
  # standalone-valid config.
  if [ -f "$DEST/config.yaml" ]; then
    local t
    t="$(mktemp -d)"
    cp -R "$DEST/." "$t/" 2>/dev/null || true
    rm -f "$t/$rel"
    cp "$staged" "$t/$rel"
    if ! polytoken --config-dir "$t" config validate --user >/dev/null 2>&1; then
      # STAGED failed in context. Was DEST already valid before substitution? If
      # so, STAGED broke an otherwise-valid config -> reject. If DEST itself is
      # not polytoken-validatable (e.g. fresh/partial), rely on parse+structural.
      local t2
      t2="$(mktemp -d)"
      cp -R "$DEST/." "$t2/" 2>/dev/null || true
      if polytoken --config-dir "$t2" config validate --user >/dev/null 2>&1; then
        rm -rf "$t" "$t2"
        echo "polytoken: $rel validation failed; existing file unchanged" >&2
        return 1
      fi
      rm -rf "$t2"
    fi
    rm -rf "$t"
  fi
  return 0
}

# atomic_write KIND DST STAGED: validate, back up only if changed, rename.
atomic_write() {
  local kind="$1" dst="$2" staged="$3" rel="${2#"$DEST"/}"
  validate_staged "$kind" "$dst" "$staged" || { rm -f "$staged"; return 1; }
  if [ -f "$dst" ] && cmp -s "$staged" "$dst"; then
    rm -f "$staged"
    echo "  unchanged: $rel"
    return 0
  fi
  if [ -f "$dst" ]; then
    cp "$dst" "$dst.bak-$TS"
    mv -f "$staged" "$dst"
    echo "  updated:   $rel (previous saved to $rel.bak-$TS)"
  else
    mv -f "$staged" "$dst"
    echo "  new:       $rel"
  fi
}

# ---- hooks.json: render token + merge by unique name ----
render_hooks() {
  # Substitute the literal __POLYTOKEN_CONFIG_DIR__ token with the jq-escaped
  # absolute DEST, safely (no shell interpolation into JSON).
  jq --arg dir "$DEST" \
     'walk(if type == "string" then gsub("__POLYTOKEN_CONFIG_DIR__"; $dir) else . end)' \
     "$PT_HOOKS"
}

install_hooks() {
  local dst="$DEST/hooks.json" staged work
  staged="$dst.new-$TS"
  STAGED_FILES+=("$staged")
  work="$(mktemp -d)"
  if [ ! -f "$dst" ]; then
    render_hooks > "$staged"
    atomic_write hooks "$dst" "$staged"
    rm -rf "$work"
    return
  fi

  local existing
  existing="$dst"
  # Capture rendered recommended and existing as single-line JSON slurp files.
  render_hooks > "$work/rec.json"
  jq -c -S . "$existing" > "$work/ex.json" 2>"$work/ex.err" || {
    cat "$work/ex.err" >&2
    rm -rf "$work"; rm -f "$staged"
    die "hooks.json is not valid JSON; existing file unchanged"
  }

  # Enumerate per-hook patches: {ckind:new|conflict, name, rec}.
  # $e[0]=existing array, $r[0]=rendered recommended array.
  # shellcheck disable=SC2016
  local enum_filter='
    $e[0] as $ex | $r[0] as $rec
    | [ $rec[] | . as $entry
        | ([ $ex[] | select(.name == $entry.name) ] | length) as $have
        | ([ $ex[] | select(.name == $entry.name and . == $entry) ] | length) as $same
        | if $have == 0 then {ckind:"new", name:$entry.name, rec:$entry}
          elif $same == 1 then empty
          else {ckind:"conflict", name:$entry.name, rec:$entry} end ]
    | sort_by(.name) | .[]
  '
  jq -c -n --slurpfile e "$work/ex.json" --slurpfile r "$work/rec.json" "$enum_filter" > "$work/patches.ndjson"

  conflicts=0
  if [ -s "$work/patches.ndjson" ]; then
    conflicts="$(jq -r '[.[] | select(.ckind == "conflict") | .name] | join(", ")' <(jq -s '.' "$work/patches.ndjson"))"
    if [ -n "$conflicts" ] && [ "$mode" != "force" ]; then
      {
        echo ""
        if [ "$mode" = "notty" ]; then
          echo "  ⚠  Recommended hook(s) differ from yours: $conflicts"
          echo "     No terminal to prompt at — keeping yours (conflicts skipped, additions applied)."
          echo "     Re-run with --overwrite to take recommended values."
        else
          echo "  ⚠  Recommended hook(s) differ from yours: $conflicts"
        fi
        echo ""
      } >&2
    fi

    : > "$work/accepted.ndjson"
    local a_new=0 a_conf=0 declined=0
    while IFS= read -r patch; do
      local ckind name
      ckind="$(jq -r '.ckind' <<<"$patch")"
      name="$(jq -r '.name' <<<"$patch")"
      if prompt_yn "  ~ hook $name: replace with recommended?" "$ckind"; then
        printf '%s\n' "$patch" >> "$work/accepted.ndjson"
        case "$ckind" in new) a_new=$((a_new + 1)) ;; conflict) a_conf=$((a_conf + 1)) ;; esac
      else
        declined=$((declined + 1))
      fi
    done < "$work/patches.ndjson"
    echo "  hooks: applied $((a_new + a_conf)) ($a_new new, $a_conf conflict), declined $declined" >&2
  else
    : > "$work/accepted.ndjson"
  fi

  # If nothing was accepted, the file is semantically unchanged — skip the write
  # so no spurious backup is created by formatting-only differences.
  if [ ! -s "$work/accepted.ndjson" ]; then
    echo "  unchanged: hooks.json (no accepted changes)"
    rm -rf "$work"; rm -f "$staged"
    return
  fi

  # Apply: new entries appended; same-name conflicts replaced in place. Existing
  # order and unrelated entries are preserved. Then reject any duplicate names.
  # shellcheck disable=SC2016
  local apply_filter='
    reduce .[1][] as $p (.[0];
      if $p.ckind == "new" then . + [$p.rec]
      else [ .[] | if .name == $p.name then $p.rec else . end ] end)
  '
  jq -s '.' "$work/accepted.ndjson" > "$work/accepted-arr.json"
  jq -c -S -s "$apply_filter" "$work/ex.json" "$work/accepted-arr.json" > "$work/merged.json"
  if ! jq -e '((([.[]?.name] | length) == ([.[]?.name] | unique | length)))' "$work/merged.json" >/dev/null; then
    rm -rf "$work"; rm -f "$staged"
    die "hooks.json merge produced duplicate names; existing file unchanged"
  fi
  jq -c -S . "$work/merged.json" > "$staged"
  rm -rf "$work"
  atomic_write hooks "$dst" "$staged"
}

# ---- config.yaml: yq-v4 leaf/atomic-array patch merge ----
install_config() {
  local dst="$DEST/config.yaml" staged work
  staged="$dst.new-$TS"
  STAGED_FILES+=("$staged")

  if [ ! -f "$dst" ]; then
    cp "$PT_CFG" "$staged"
    atomic_write config "$dst" "$staged"
    return
  fi

  work="$(mktemp -d)"
  # Parse existing first; a malformed file aborts before any write. yq is the YAML
  # processor; the patch logic runs on the JSON projection via jq (yq's expression
  # language does not expose jq's paths/getpath/setpath), then serializes back to
  # YAML with yq.
  if ! yq -o=json . "$dst" > "$work/ex.json" 2>"$work/ex.err"; then
    cat "$work/ex.err" >&2
    rm -rf "$work"; rm -f "$staged"
    die "config.yaml is not valid YAML; existing file unchanged"
  fi
  yq -o=json . "$PT_CFG" > "$work/rec.json"

  # Enumerate leaf/atomic-array patches (descend through maps; never into arrays).
  # $e/$r are slurped (array-wrapped) documents; $e[0]=existing, $r[0]=recommended.
  # shellcheck disable=SC2016
  local enum_filter='
    $r[0] as $rec | $e[0] as $ex
    | [ $rec | paths(type != "object")
        | select(all(.[]; type == "string"))
        | . as $p
        | {path:$p, rec:($rec | getpath($p)), your:($ex | getpath($p))}
        | select(.rec != .your)
        | . + {ckind:(if .your == null then "new" else "conflict" end),
               key:(.path | join("."))} ]
    | sort_by(.key) | .[]
  '
  # Apply accepted patches onto the existing object. ex.json is the raw object;
  # accepted.ndjson is an array of patches.
  # shellcheck disable=SC2016
  local apply_filter='reduce .[1][] as $p (.[0]; setpath($p.path; $p.rec))'

  jq -c -S -n --slurpfile e "$work/ex.json" --slurpfile r "$work/rec.json" "$enum_filter" \
    > "$work/patches.ndjson" 2>"$work/enum.err" || {
      cat "$work/enum.err" >&2
      rm -rf "$work"; rm -f "$staged"
      die "config.yaml merge failed; existing file unchanged"
    }

  if [ -s "$work/patches.ndjson" ]; then
    conflicts="$(jq -r '[.[] | select(.ckind == "conflict") | .key] | join(", ")' <(jq -s '.' "$work/patches.ndjson"))"
    if [ -n "$conflicts" ] && [ "$mode" != "force" ]; then
      {
        echo ""
        if [ "$mode" = "notty" ]; then
          echo "  ⚠  Recommended value(s) differ from yours: $conflicts"
          echo "     No terminal to prompt at — keeping yours (conflicts skipped, additive changes applied)."
          echo "     Re-run with --overwrite to take recommended values."
        else
          echo "  ⚠  Recommended value(s) differ from yours: $conflicts"
        fi
        echo ""
      } >&2
    fi

    : > "$work/accepted.ndjson"
    local a_new=0 a_conf=0 declined=0
    while IFS= read -r patch; do
      local ckind key
      ckind="$(jq -r '.ckind' <<<"$patch")"
      key="$(jq -r '.key' <<<"$patch")"
      if prompt_yn "  ~ $key = $(jq -rc '.rec' <<<"$patch")" "$ckind"; then
        printf '%s\n' "$patch" >> "$work/accepted.ndjson"
        case "$ckind" in new) a_new=$((a_new + 1)) ;; conflict) a_conf=$((a_conf + 1)) ;; esac
      else
        declined=$((declined + 1))
      fi
    done < "$work/patches.ndjson"
    echo "  config: applied $((a_new + a_conf)) ($a_new new, $a_conf conflict), declined $declined" >&2

    # Nothing accepted -> semantically unchanged; skip the write (no backup).
    if [ ! -s "$work/accepted.ndjson" ]; then
      echo "  unchanged: config.yaml (no accepted changes)"
      rm -f "$staged"; rm -rf "$work"
      return
    fi
    jq -s '.' "$work/accepted.ndjson" > "$work/accepted-arr.json"
    jq -c -S -s "$apply_filter" "$work/ex.json" "$work/accepted-arr.json" > "$work/merged.json"
    yq -o=yaml -P '.' "$work/merged.json" > "$staged"
  else
    echo "  config.yaml already up to date — no changes."
    rm -f "$staged"; rm -rf "$work"
    return
  fi
  rm -rf "$work"
  atomic_write config "$dst" "$staged"
}

# ---- permissions.yaml: install only when absent; leave valid existing untouched ----
install_permissions() {
  local dst="$DEST/permissions.yaml"
  if [ ! -f "$dst" ]; then
    local staged="$dst.new-$TS"
    STAGED_FILES+=("$staged")
    cp "$PT_PERMS" "$staged"
    atomic_write permissions "$dst" "$staged"
    return
  fi
  # A valid existing file is left byte-identical: the recommendation carries no
  # rules to merge. An invalid file is reported but never rewritten.
  if yq e . "$dst" >/dev/null 2>&1; then
    echo "  unchanged: permissions.yaml (existing rules preserved)"
  else
    echo "  preserved: permissions.yaml (invalid; left untouched — recommendation has no rules to merge)" >&2
  fi
}

# =========================================================================
echo "Installing Polytoken config into: $DEST"
mkdir -p "$DEST"

# 1. Plain managed files: AGENTS.md, adapter, compat scripts, skills.
copy_managed_file "$PT_AGENTS" "$DEST/AGENTS.md"
copy_managed_file "$PT_ADAPTER" "$DEST/hooks/adapter.sh"
for d in "${COMPAT_DIRS[@]}"; do
  if [ -d "$ROOT/home/$d" ]; then
    while IFS= read -r -d '' src; do
      rel="${src#"$ROOT/home/"}"
      copy_managed_file "$src" "$DEST/compat/$rel"
    done < <(find "$ROOT/home/$d" -type f -print0)
  fi
done
for h in "${COMPAT_HOOKS[@]}"; do
  [ -f "$ROOT/home/$h" ] && copy_managed_file "$ROOT/home/$h" "$DEST/compat/$h"
done
# Canonical skills (single tree shared with Claude).
if [ -d "$ROOT/home/skills" ]; then
  while IFS= read -r -d '' src; do
    rel="${src#"$ROOT/home/skills/"}"
    copy_managed_file "$src" "$DEST/skills/$rel"
  done < <(find "$ROOT/home/skills" -type f -print0)
fi

# 2. Mark executable scripts executable.
for s in "${EXEC_SCRIPTS[@]}"; do
  [ -f "$DEST/$s" ] && chmod +x "$DEST/$s"
done

# 3. Structured, validated, atomic merges.
install_permissions
install_hooks
install_config

echo "Done."
