#!/bin/bash
# Custom Claude Code status line.
#
# Layout:  [LEFT]                                                      [RIGHT]
#   LEFT : <cwd> |<branch> (<worktree>) <gitstatus>|  {agent}  PR#n
#   RIGHT: <model> <effort> <think> | ctx%/size | $cost (Δ$turn) |
#          5h%(reset) 7d%(reset) | mo $used/$limit pct%
#   where (reset) is compact time until each window resets, e.g. (2h14m) / (2d7h),
#   Δ$turn is the cost accrued by the current/most-recent turn, and "mo" is
#   monthly usage-credit spend (see usage-fetch.sh; a trailing ! means the cached
#   figure is stale because refreshes are failing).
#
# git status uses gitprompt.pl if found ($CLAUDE_STATUSLINE_GITPROMPT or PATH),
# else falls back to plain git. Requires bash 4+ (uses mapfile).
# Runs as a shell command outside the model => zero token cost.

INPUT=$(cat)

# ---- colors ----
ORANGE=$'\033[38;5;172m'
CYAN=$'\033[38;5;39m'
DIM=$'\033[38;5;245m'
GREEN=$'\033[38;5;78m'
YELLOW=$'\033[38;5;220m'
RED=$'\033[38;5;203m'
MAGENTA=$'\033[38;5;170m'
RESET=$'\033[0m'

# visible length of a string (strip ANSI SGR escapes).
# Note: wide/zero-width glyphs count as 1, so right-alignment can be off by a
# few columns when the LEFT side contains them — acceptable for a status line.
vlen() {
  local s
  s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "${#s}"
}

# ================= LEFT =================
LEFT=""

# ================= fields from stdin =================
if [ -z "$INPUT" ] || ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "$LEFT"; exit 0
fi

mapfile -t F < <(
  jq -r '
    .model.display_name // "?",
    .model.id // "",
    .effort.level // "",
    ( .thinking.enabled // false | tostring ),
    ( .context_window.used_percentage // "" | tostring ),
    ( .context_window.context_window_size // "" | tostring ),
    ( .cost.total_cost_usd // "" | tostring ),
    ( .rate_limits.five_hour.used_percentage // "" | tostring ),
    ( .rate_limits.seven_day.used_percentage // "" | tostring ),
    ( .workspace.git_worktree // "" ),
    ( .agent.name // "" ),
    ( .cwd // .workspace.current_dir // "" ),
    ( .pr.number // "" | tostring ),
    ( .pr.review_state // "" ),
    ( .workspace.repo.name // "" ),
    ( .rate_limits.five_hour.resets_at // "" | tostring ),
    ( .rate_limits.seven_day.resets_at // "" | tostring ),
    ( .session_id // "" ),
    ( .prompt_id // "" )
  ' <<<"$INPUT" 2>/dev/null
)
MNAME=${F[0]}; MID=${F[1]}; EFFORT=${F[2]}; THINK=${F[3]}; CTXPCT=${F[4]}
CTXSIZE=${F[5]}; COST=${F[6]}; H5=${F[7]}; D7=${F[8]}; WT=${F[9]}
AGENT=${F[10]}; CWD=${F[11]}; PRNUM=${F[12]}; PRSTATE=${F[13]}; REPO=${F[14]}
H5RESET=${F[15]}; D7RESET=${F[16]}; SESSION_ID=${F[17]}; PROMPT_ID=${F[18]}

CFGDIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
NOW=$(date +%s)

# mtime of a file, portable. GNU coreutils first (-c %Y); BSD/macOS second
# (-f %m). Order matters: GNU's -f means "filesystem info" and would emit
# garbage, so never let it run when -c works. Empty if stat fails.
mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
  case "$m" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$m" ;; esac
}

# full model id (e.g. claude-sonnet-4-6); fall back to display name
MODEL=${MID:-$MNAME}

# used_percentage/context_window_size from the payload are relative to the
# model's full context window, but Claude Code actually auto-compacts against
# CLAUDE_CODE_AUTO_COMPACT_WINDOW (often much smaller, e.g. 200k on a 1M-window
# model). Back out used tokens from the full-window percentage, then re-express
# as a fraction of the auto-compact window so ctx% reflects when compaction
# will actually fire.
if [ -n "$CTXPCT" ] && [ -n "$CTXSIZE" ] && [ -n "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" ]; then
  CTXPCT=$(awk -v p="$CTXPCT" -v size="$CTXSIZE" -v w="$CLAUDE_CODE_AUTO_COMPACT_WINDOW" \
    'BEGIN{ if (w+0>0) printf "%.0f", p*size/w; else print p }')
  CTXSIZE=$CLAUDE_CODE_AUTO_COMPACT_WINDOW
fi

hum() {
  awk -v n="$1" 'BEGIN{
    if (n=="" || n+0!=n) { print ""; exit }
    if (n>=1000000) printf "%.1fM", n/1000000;
    else if (n>=1000) printf "%.0fk", n/1000;
    else printf "%d", n;
  }'
}

# seconds-until-epoch -> compact "2h14m" / "45m" / "30s". Empty if no/past reset.
dur_until() {
  local target=$1 now rem
  [ -z "$target" ] && { printf ''; return; }
  now=$(date +%s)
  rem=$(( target - now ))
  [ "$rem" -le 0 ] 2>/dev/null && { printf ''; return; }
  awk -v r="$rem" 'BEGIN{
    d=int(r/86400); h=int((r%86400)/3600); m=int((r%3600)/60); s=r%60;
    if (d>0) printf "%dd %dh", d, h;
    else if (h>0) printf "%dh %02dm", h, m;
    else if (m>0) printf "%dm", m;
    else printf "%ds", s;
  }'
}

# color for a usage percentage: green < 50, yellow 50-79, red >= 80.
pctcol() {
  if   [ "$1" -ge 80 ] 2>/dev/null; then printf '%s' "$RED"
  elif [ "$1" -ge 50 ] 2>/dev/null; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

# ================= derived: per-prompt cost + monthly credit spend =================
# The payload reports only a cumulative session total (cost.total_cost_usd), so
# "cost of this request" has to be derived: remember the session total as it
# stood when the current prompt_id first appeared, and subtract. The delta ticks
# up live during a turn, then holds that value until the next prompt arrives —
# so while idle it reads as "what the last turn cost".
DELTA=""
if [ -n "$COST" ] && [ -n "$SESSION_ID" ] && [ -n "$PROMPT_ID" ]; then
  CSTATE_DIR="$CFGDIR/.cost-state"
  CSTATE="$CSTATE_DIR/${SESSION_ID//[^a-zA-Z0-9_-]/_}"
  PREV_PID=""; PREV_BASE=""
  [ -f "$CSTATE" ] && read -r PREV_PID PREV_BASE < "$CSTATE" 2>/dev/null

  if [ "$PREV_PID" != "$PROMPT_ID" ] || [ -z "$PREV_BASE" ]; then
    # New prompt (or first render of this session): the total so far becomes the
    # baseline. refreshInterval is 1s, so this lands within a second of the turn
    # starting and almost no cost has accrued yet.
    NEW_SESSION=0
    [ ! -d "$CSTATE_DIR" ] && { mkdir -p "$CSTATE_DIR" 2>/dev/null; NEW_SESSION=1; }
    [ ! -f "$CSTATE" ] && NEW_SESSION=1
    printf '%s %s\n' "$PROMPT_ID" "$COST" > "$CSTATE" 2>/dev/null
    PREV_BASE=$COST
    # Sessions never revisit their state file once closed, so prune on the rare
    # first-write path rather than on every render.
    [ "$NEW_SESSION" = 1 ] && find "$CSTATE_DIR" -type f -mtime +7 -delete 2>/dev/null
  fi

  DELTA=$(awk -v c="$COST" -v b="$PREV_BASE" 'BEGIN{
    if (b=="" || b+0!=b) { print ""; exit }
    d = c - b; if (d < 0) d = 0;          # totals only grow; guard anyway
    printf "%.2f", d;
  }')
fi

# Monthly usage-credit spend. Not in the payload (rate_limits is null on
# enterprise / API-provider sessions), so usage-fetch.sh pulls it from
# /api/oauth/usage into a cache file out-of-band. The statusline only ever reads
# that cache — never the network — and kicks off a detached refresh when the
# cache goes stale, so rendering can never block on HTTP.
BUDGET=""
UCACHE="$CFGDIR/.usage-cache.json"
UFETCH="$CFGDIR/usage-fetch.sh"
USAGE_TTL=${CLAUDE_STATUSLINE_USAGE_TTL:-300}
UAGE=""
if [ -f "$UCACHE" ]; then
  UMT=$(mtime "$UCACHE")
  [ -n "$UMT" ] && UAGE=$(( NOW - UMT ))
fi
if [ -x "$UFETCH" ] && { [ -z "$UAGE" ] || [ "$UAGE" -ge "$USAGE_TTL" ] 2>/dev/null; }; then
  # Detached: stdout/stderr to /dev/null so Claude Code never waits on the child
  # holding the pipe open, and the subshell orphans it so we exit immediately.
  ( "$UFETCH" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1
fi
if [ -f "$UCACHE" ]; then
  mapfile -t U < <(
    jq -r '
      ( .used // "" | tostring ),
      ( .limit // "" | tostring ),
      ( .percent // "" | tostring )
    ' "$UCACHE" 2>/dev/null
  )
  UUSED=${U[0]:-}; ULIMIT=${U[1]:-}; UPCT=${U[2]:-}
  if [ -n "$UUSED" ] && [ -n "$ULIMIT" ]; then
    [ -z "$UPCT" ] && UPCT=$(awk -v u="$UUSED" -v l="$ULIMIT" \
      'BEGIN{ if (l+0>0) printf "%.0f", u/l*100; else print 0 }')
    UPCTN=$(printf '%.0f' "$UPCT" 2>/dev/null) || UPCTN=0
    UCOL=$(pctcol "$UPCTN")
    BUDGET="${DIM}mo${RESET} ${UCOL}\$$(awk -v v="$UUSED" 'BEGIN{printf "%.2f", v}')${RESET}"
    BUDGET+="${DIM}/\$$(awk -v v="$ULIMIT" 'BEGIN{printf "%.2f", v}')${RESET}"
    BUDGET+=" ${UCOL}${UPCTN}%${RESET}"
    # A cache this far past its TTL means refreshes are failing (expired login,
    # no network). Flag it rather than presenting stale numbers as current.
    [ -n "$UAGE" ] && [ "$UAGE" -ge $(( USAGE_TTL * 6 )) ] 2>/dev/null \
      && BUDGET+="${RED}!${RESET}"
  fi
fi

# ================= LEFT: cwd + git (gitprompt.pl) + agent + PR =================
if [ -n "$REPO" ]; then
  [ -n "$LEFT" ] && LEFT+="  "
  LEFT+="${GREEN}${REPO}${RESET}"
fi
if [ -n "$CWD" ]; then
  DISP=${CWD/#$HOME/\~}
  [ -n "$LEFT" ] && LEFT+=" "
  LEFT+="${CYAN}${DISP}${RESET}"
fi

# gitprompt is optional: honor $CLAUDE_STATUSLINE_GITPROMPT, else look on PATH,
# else fall back to plain git for branch + dirty flag.
BRANCH=""; GSTAT=""
GP="${CLAUDE_STATUSLINE_GITPROMPT:-}"
[ -z "$GP" ] && GP="$(command -v gitprompt.pl 2>/dev/null || true)"
if [ -n "$CWD" ] && [ -d "$CWD" ] && [ -n "$GP" ] && [ -x "$GP" ] && command -v perl >/dev/null 2>&1; then
  GOUT=$(cd "$CWD" && PS0=$'%b\x01%c%u%f%F%A%B' \
        perl "$GP" c=+ u=! f=? 'F=»' 'A=↑' 'B=↓' statuscount=1 2>/dev/null)
  BRANCH=${GOUT%%$'\x01'*}
  GSTAT=${GOUT#*$'\x01'}
elif [ -n "$CWD" ] && [ -d "$CWD" ] && command -v git >/dev/null 2>&1; then
  BRANCH=$(cd "$CWD" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ -n "$BRANCH" ] && [ -n "$(cd "$CWD" && git status --porcelain 2>/dev/null)" ]; then
    GSTAT="!"
  fi
fi
if [ -n "$BRANCH" ]; then
  LEFT+=" ${DIM}|${RESET}${GREEN}${BRANCH}${RESET}"
  [ -n "$WT" ] && LEFT+=" ${DIM}(${WT})${RESET}"
  if [ -z "$GSTAT" ]; then
    LEFT+=" ${GREEN}✔${RESET}"
  else
    LEFT+=" ${YELLOW}${GSTAT}${RESET}"
  fi
  LEFT+="${DIM}|${RESET}"
fi

[ -n "$AGENT" ] && LEFT+="  ${MAGENTA}{${AGENT}}${RESET}"

if [ -n "$PRNUM" ]; then
  case "$PRSTATE" in
    approved)          PCOL=$GREEN ;;
    changes_requested) PCOL=$RED ;;
    *)                 PCOL=$DIM ;;
  esac
  LEFT+="  ${PCOL}PR#${PRNUM}${RESET}"
  [ -n "$PRSTATE" ] && LEFT+="${DIM}(${PRSTATE})${RESET}"
fi

# ================= RIGHT: model + ctx + cost + rate =================
RIGHT="${CYAN}${MODEL:-?}${RESET}"
if [ -n "$EFFORT" ]; then
  # color effort by intensity ramp, with specials distinct:
  #   low green, medium yellow, high orange, xhigh red, max magenta,
  #   ultracode cyan, auto dim, anything else dim.
  case "$EFFORT" in
    low)       ECOL=$GREEN ;;
    medium)    ECOL=$YELLOW ;;
    high)      ECOL=$ORANGE ;;
    xhigh)     ECOL=$RED ;;
    max)       ECOL=$MAGENTA ;;
    ultracode) ECOL=$CYAN ;;
    auto)      ECOL=$DIM ;;
    *)         ECOL=$DIM ;;
  esac
  RIGHT+=" ${ECOL}${EFFORT}${RESET}"
fi
[ "$THINK" = "true" ] && RIGHT+=" ${DIM}think${RESET}"

if [ -n "$CTXPCT" ]; then
  # color relative to the auto-compact trigger threshold (CLAUDE_AUTOCOMPACT_PCT_OVERRIDE,
  # default 80): red at/past it, yellow from 75% of the way there, green below that.
  ACPCT=${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-80}
  CTX_YELLOW=$(( ACPCT * 3 / 4 ))
  if   [ "$CTXPCT" -ge "$ACPCT" ] 2>/dev/null; then CCOL=$RED
  elif [ "$CTXPCT" -ge "$CTX_YELLOW" ] 2>/dev/null; then CCOL=$YELLOW
  else CCOL=$GREEN; fi
  RIGHT+=" ${DIM}|${RESET} ${DIM}ctx ${RESET}${CCOL}${CTXPCT}%${RESET}"
  if [ -n "$CTXSIZE" ]; then
    # color the window size by tier: >=1M orange, else blue (200k).
    if [ "$CTXSIZE" -ge 1000000 ] 2>/dev/null; then SCOL=$ORANGE; else SCOL=$CYAN; fi
    RIGHT+="${DIM}/${RESET}${SCOL}$(hum "$CTXSIZE")${RESET}"
  fi
fi

# Cost and rate-limits are mutually exclusive: subscription/Max plans report
# rate_limits, so show $cost ONLY when no rate-limit data is present (i.e. an
# API-key/pay-as-you-go session). When rate limiting is in play, the 5h/7d
# windows below replace the dollar figure.
if [ -n "$COST" ] && [ -z "$H5$D7" ]; then
  RIGHT+=" ${DIM}|${RESET} ${YELLOW}\$$(awk -v c="$COST" 'BEGIN{printf "%.2f", c}')${RESET}"
  # per-turn delta alongside the session total
  [ -n "$DELTA" ] && RIGHT+=" ${DIM}(${RESET}${CYAN}Δ\$${DELTA}${RESET}${DIM})${RESET}"
fi

if [ -n "$H5$D7" ]; then
  RIGHT+=" ${DIM}|${RESET}"
  if [ -n "$H5" ]; then
    H5N=$(printf '%.0f' "$H5"); H5C=$(pctcol "$H5N")
    RIGHT+=" ${DIM}5h:${RESET} ${H5C}${H5N}%${RESET}"
    H5LEFT=$(dur_until "$H5RESET")
    [ -n "$H5LEFT" ] && RIGHT+=" ${CYAN}(${H5LEFT})${RESET}"
  fi
  if [ -n "$D7" ]; then
    D7N=$(printf '%.0f' "$D7"); D7C=$(pctcol "$D7N")
    RIGHT+=" ${DIM}7d:${RESET} ${D7C}${D7N}%${RESET}"
    D7LEFT=$(dur_until "$D7RESET")
    [ -n "$D7LEFT" ] && RIGHT+=" ${CYAN}(${D7LEFT})${RESET}"
  fi
fi

# Monthly credit spend is plan-level, not session-level, so unlike $cost it is
# not mutually exclusive with the rate-limit windows — show it whenever the
# cache has it.
[ -n "$BUDGET" ] && RIGHT+=" ${DIM}|${RESET} ${BUDGET}"

# ================= compose: right-align RIGHT to the terminal edge =================
# Claude Code (v2.1.153+) sets $COLUMNS to the terminal width before running the
# script. It does NOT give the script a TTY, so `tput cols` / `stty size` cannot
# work — $COLUMNS is the only reliable source. If it is unset (older Claude),
# render inline so nothing ever overflows and gets truncated.
WIDTH=0
[ -n "$COLUMNS" ] && [ "$COLUMNS" -gt 0 ] 2>/dev/null && WIDTH=$COLUMNS

# ---- agent state badge (written by ~/.claude/hooks/agent-state.sh) ----
BADGE=""
STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.agent-state"
# Safety net for a missed idle transition: every "working" hook event rewrites
# the state file, refreshing its mtime. If "working" is older than STALE_SECS,
# the main loop is almost certainly idle (a Stop that never fired, or a late
# background event) — fall back to idle rather than showing "working" forever.
# A genuine single tool call longer than STALE_SECS can briefly false-idle;
# tune via CLAUDE_STATUSLINE_WORKING_STALE_SECS.
STALE_SECS=${CLAUDE_STATUSLINE_WORKING_STALE_SECS:-120}
if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
  ST=$(head -c 16 "$STATE_FILE" 2>/dev/null | tr -cd 'a-z')
  if [ "$ST" = "working" ]; then
    MT=$(mtime "$STATE_FILE")
    case "$MT" in
      '') ;;  # stat failed — leave as working
      *) [ $(( NOW - MT )) -ge "$STALE_SECS" ] && ST=idle ;;
    esac
  fi
  case "$ST" in
    working) BADGE="${YELLOW}● working${RESET}" ;;
    idle)    BADGE="${GREEN}○ idle${RESET}" ;;
  esac
fi

LV=$(vlen "$LEFT"); RV=$(vlen "$RIGHT"); BV=$(vlen "$BADGE")
# Claude reserves a 2-space buffer on BOTH sides (matches the footer): usable
# area is COLUMNS - LEFT_INDENT - RIGHT_RESERVE. Filling past that truncates.
LEFT_INDENT=2
RIGHT_RESERVE=2
PAD=$(( WIDTH - LEFT_INDENT - RIGHT_RESERVE - LV - RV ))

# Does the whole thing fit on one line? With a badge we need room to center it in
# the gap (PAD >= BV+2); without, just a 1-col gap. If it does not fit, drop to a
# two-line layout (LEFT + badge on line 1, RIGHT right-aligned on line 2) rather
# than truncating — the badge stays on line 1 ("split after working/idle").
if [ -n "$BADGE" ]; then ONE_MIN=$(( BV + 2 )); else ONE_MIN=1; fi

if [ "$WIDTH" -gt 0 ] && [ "$PAD" -ge "$ONE_MIN" ]; then
  if [ -n "$BADGE" ]; then
    # center the badge inside the gap
    LGAP=$(( (PAD - BV) / 2 )); RGAP=$(( PAD - BV - LGAP ))
    printf '%*s%s%*s%s%*s%s\n' \
      "$LEFT_INDENT" '' "$LEFT" "$LGAP" '' "$BADGE" "$RGAP" '' "$RIGHT"
  else
    printf '%*s%s%*s%s\n' "$LEFT_INDENT" '' "$LEFT" "$PAD" '' "$RIGHT"
  fi
elif [ "$WIDTH" -gt 0 ]; then
  # two lines: line 1 = LEFT (+ badge pushed to the right edge), line 2 = RIGHT
  # right-aligned to the same edge the one-line layout would use.
  PAD1=$(( WIDTH - LEFT_INDENT - RIGHT_RESERVE - LV - BV ))
  if [ -n "$BADGE" ] && [ "$PAD1" -ge 1 ]; then
    printf '%*s%s%*s%s\n' "$LEFT_INDENT" '' "$LEFT" "$PAD1" '' "$BADGE"
  elif [ -n "$BADGE" ]; then
    printf '%*s%s %s\n' "$LEFT_INDENT" '' "$LEFT" "$BADGE"
  else
    printf '%*s%s\n' "$LEFT_INDENT" '' "$LEFT"
  fi
  PAD2=$(( WIDTH - RIGHT_RESERVE - RV ))
  [ "$PAD2" -lt "$LEFT_INDENT" ] && PAD2=$LEFT_INDENT
  printf '%*s%s\n' "$PAD2" '' "$RIGHT"
else
  printf '%*s%s   %s%s\n' "${LEFT_INDENT:-2}" '' "$LEFT" \
    "${BADGE:+$BADGE   }" "$RIGHT"
fi
