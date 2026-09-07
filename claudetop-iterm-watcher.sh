#!/bin/bash
# claudetop-iterm-watcher.sh — Background process that syncs claudetop state to iTerm2
#
# Usage: claudetop-iterm-watcher.sh <ITERM_SESSION_ID>
#
# Polls ~/.claude/claudetop-iterm-state every 2s. Reads state on change,
# but re-applies tab title every cycle (to override Claude Code's title).
# Writes escape sequences directly to the terminal's TTY device.

set -u

MY_SESSION="${1:-}"
[ -n "$MY_SESSION" ] || exit 0

STATE_FILE="$HOME/.claude/claudetop-iterm-state.${MY_SESSION}"
TTY_MAP="$HOME/.claude/claudetop-iterm-ttys"
LAST_MTIME=""
MY_TTY=""

# Cached state for re-applying title
CACHED_TITLE=""
CACHED_STALE=1
IDLE_STREAK=0          # consecutive cycles with no descendants — debounce green

get_tty() {
  [ -f "$TTY_MAP" ] || return 1
  local tty_path
  tty_path=$(grep "^${MY_SESSION}=" "$TTY_MAP" 2>/dev/null | tail -1 | cut -d= -f2-)
  [ -n "$tty_path" ] && [ -w "$tty_path" ] && echo "$tty_path" && return 0
  return 1
}

while true; do
  sleep 0.5

  [ -f "$STATE_FILE" ] || continue

  # Resolve TTY if not yet found
  if [ -z "$MY_TTY" ] || [ ! -w "$MY_TTY" ]; then
    MY_TTY=$(get_tty) || continue
  fi

  # Check if file changed — if so, re-read state
  CUR_MTIME=$(stat -f %m "$STATE_FILE" 2>/dev/null || stat -c %Y "$STATE_FILE" 2>/dev/null) || continue
  if [ "$CUR_MTIME" != "$LAST_MTIME" ]; then
    LAST_MTIME="$CUR_MTIME"
    IDLE_STREAK=0

    # Read state
    TIMESTAMP="" PROJECT="" MODEL="" COST="" VELOCITY="" CTX="" CACHE=""
    DURATION="" TOKENS_IN="" TOKENS_OUT="" LINES_ADDED="" LINES_REMOVED=""
    TAG="" BGCOLOR="" MODES="" ITERM_SESSION="" STATUS="" USAGE="" USAGE_TOP=""
    while IFS='=' read -r key value; do
      case "$key" in
        usage)          USAGE="$value" ;;
        usage_top)      USAGE_TOP="$value" ;;
        timestamp)      TIMESTAMP="$value" ;;
        project)        PROJECT="$value" ;;
        model)          MODEL="$value" ;;
        cost)           COST="$value" ;;
        velocity)       VELOCITY="$value" ;;
        ctx)            CTX="$value" ;;
        cache)          CACHE="$value" ;;
        duration)       DURATION="$value" ;;
        tokens_in)      TOKENS_IN="$value" ;;
        tokens_out)     TOKENS_OUT="$value" ;;
        lines_added)    LINES_ADDED="$value" ;;
        lines_removed)  LINES_REMOVED="$value" ;;
        tag)            TAG="$value" ;;
        bgcolor)        BGCOLOR="$value" ;;
        modes)          MODES="$value" ;;
        iterm_session)  ITERM_SESSION="$value" ;;
        status)         STATUS="$value" ;;
      esac
    done < "$STATE_FILE"

    # Session ended — reset terminal and exit
    if [ "$STATUS" = "ended" ]; then
      if [ -w "$MY_TTY" ]; then
        printf "\033]1337;SetColors=bg=default\007" > "$MY_TTY"
        printf "\033]1;\007" > "$MY_TTY"
        printf "\033]1337;SetBadgeFormat=\007" > "$MY_TTY"
      fi
      rm -f "$STATE_FILE"
      exit 0
    fi

    # Only apply for the matching pane
    if [ "$ITERM_SESSION" != "$MY_SESSION" ]; then
      CACHED_STALE=1
      continue
    fi

    # Check staleness
    NOW=$(date +%s)
    if [ -n "$TIMESTAMP" ] && [ $((NOW - TIMESTAMP)) -gt 300 ]; then
      printf "\033]1;\007" > "$MY_TTY"
      printf "\033]1337;SetBadgeFormat=\007" > "$MY_TTY"
      printf "\033]1337;SetColors=bg=default\007" > "$MY_TTY"
      CACHED_STALE=1
      LAST_MTIME=""
      continue
    fi

    CACHED_STALE=0

    # Mode check helper
    _w() {
      [ "$MODES" = "all" ] && return 0
      case ",$MODES," in *",$1,"*) return 0 ;; esac
      return 1
    }

    # Build and cache title
    if _w "title"; then
      CACHED_TITLE="${PROJECT} | ${COST}"
      [ -n "$VELOCITY" ] && CACHED_TITLE="${CACHED_TITLE} ${VELOCITY}"
      CACHED_TITLE="${CACHED_TITLE} | ${MODEL} | ctx:${CTX}%"
      [ -n "$USAGE_TOP" ] && CACHED_TITLE="${CACHED_TITLE} | ${USAGE_TOP}"
      [ -n "$TAG" ] && CACHED_TITLE="${CACHED_TITLE} #${TAG}"
      printf "\033]1;%s\007" "$CACHED_TITLE" > "$MY_TTY"
    fi

    # Status bar user variables (only on change)
    if _w "statusbar"; then
      _s() { printf "\033]1337;SetUserVar=%s=%s\007" "$1" "$(printf '%s' "$2" | base64)" > "$MY_TTY"; }
      _s "claudetop_cost" "$COST"
      _s "claudetop_model" "$MODEL"
      _s "claudetop_ctx" "${CTX}%"
      _s "claudetop_project" "$PROJECT"
      _s "claudetop_duration" "$DURATION"
      _s "claudetop_cache" "${CACHE}%"
      _s "claudetop_tokens_in" "$TOKENS_IN"
      _s "claudetop_tokens_out" "$TOKENS_OUT"
      [ -n "$VELOCITY" ] && _s "claudetop_velocity" "$VELOCITY"
      [ "${LINES_ADDED:-0}" -gt 0 ] 2>/dev/null && _s "claudetop_lines" "+${LINES_ADDED}/-${LINES_REMOVED}"
      [ -n "$TAG" ] && _s "claudetop_tag" "#${TAG}"
      [ -n "$USAGE" ] && _s "claudetop_usage" "$USAGE"
      [ -n "$USAGE_TOP" ] && _s "claudetop_usage_top" "$USAGE_TOP"
    fi

    # Badge (only on change) — project + model
    if _w "badge"; then
      B="${PROJECT} \u2022 ${MODEL}"
      printf "\033]1337;SetBadgeFormat=%s\007" "$(printf '%s' "$B" | base64)" > "$MY_TTY"
    fi

    # Background color (only on change)
    if _w "bgcolor" && [ -n "$BGCOLOR" ]; then
      if [ "$BGCOLOR" = "default" ]; then
        # Full reset — bgcolor, title, badge
        printf "\033]1337;SetColors=bg=default\007" > "$MY_TTY"
        printf "\033]1;\007" > "$MY_TTY"
        printf "\033]1337;SetBadgeFormat=\007" > "$MY_TTY"
        CACHED_TITLE=""
      else
        printf "\033]1337;SetColors=bg=%s\007" "$BGCOLOR" > "$MY_TTY"
      fi
    fi

  else
    # File didn't change — re-apply title every cycle to fight Claude Code's override
    if [ "$CACHED_STALE" -eq 0 ] && [ -n "$CACHED_TITLE" ] && [ -w "$MY_TTY" ]; then
      printf "\033]1;%s\007" "$CACHED_TITLE" > "$MY_TTY"
    fi

    # If state file hasn't changed for 3+ seconds and bgcolor is black,
    # Claude may be idle (permission prompt, waiting for input). Switch to green.
    # Check: sum CPU across all processes on this TTY. During thinking/streaming/
    # tool execution, the claude process or its tools will be using CPU.
    # MCP servers and caffeinate sit at 0% when idle so they don't interfere.
    # Requires 6 consecutive idle cycles (~3s) to debounce brief gaps.
    if [ "$CACHED_STALE" -eq 0 ] && [ -n "$LAST_MTIME" ] && [ -w "$MY_TTY" ]; then
      IDLE_NOW=$(date +%s)
      FILE_AGE=$((IDLE_NOW - LAST_MTIME))
      if [ "$FILE_AGE" -ge 3 ] && [ "${BGCOLOR:-}" = "000000" ]; then
        _TTY_SHORT="${MY_TTY#/dev/}"
        # Sum CPU of all processes on this TTY (excludes login/bash shell noise)
        _TTY_CPU=$(ps -eo tty,%cpu,comm 2>/dev/null | awk -v t="$_TTY_SHORT" '$1 == t && $3 !~ /^(login|-?bash|zsh)$/ {s+=$2} END {printf "%.1f", s+0}')
        if [ "$(printf '%s > 1.0\n' "${_TTY_CPU:-0}" | bc 2>/dev/null)" -eq 1 ]; then
          IDLE_STREAK=0
        else
          IDLE_STREAK=$((IDLE_STREAK + 1))
          # Only go green after 6 consecutive idle cycles (~3s debounce)
          if [ "$IDLE_STREAK" -ge 6 ]; then
            printf "\033]1337;SetColors=bg=152b17\007" > "$MY_TTY"
            BGCOLOR="152b17"
          fi
        fi
      else
        IDLE_STREAK=0
      fi
    fi
  fi
done
