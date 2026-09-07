#!/bin/bash
# claudetop — htop for your Claude Code sessions
# https://github.com/liorwn/claudetop
#
# Real-time status line showing project context, token usage,
# cost insights, cache efficiency, and smart alerts.
#
# Environment variables:
#   CLAUDETOP_THEME          compact|minimal|full (default: full)
#   CLAUDETOP_DAILY_BUDGET   daily budget in USD (e.g., 50)
#   CLAUDETOP_TAG            tag for session tracking (e.g., "auth-refactor")
#   CLAUDETOP_USAGE          on|off — plan usage windows: 5h, 7d, per-model (Fable/Opus/Sonnet),
#                            extra-usage credits (default: on; needs claudetop-usage installed)
#   CLAUDETOP_USAGE_TTL      seconds between background refreshes of the usage cache (default: 60)
#   CLAUDETOP_ITERM          iTerm2 integration (default: off)
#                            title     — set tab/window title with cost & model
#                            statusbar — set user variables for iTerm2 status bar
#                            badge     — show watermark overlay with key metrics
#                            bgcolor   — tint terminal background by session state
#                            all       — enable all four
#                            Comma-separated: "title,badge,bgcolor"
#
# Plugin system: drop executable scripts into ~/.claude/claudetop.d/
# Each plugin receives the session JSON on stdin and outputs a single
# formatted string (ANSI OK). Plugins run with a 1s timeout.

set -euo pipefail

THEME="${CLAUDETOP_THEME:-full}"
ITERM_MODE="${CLAUDETOP_ITERM:-}"
HISTORY_FILE="${HOME}/.claude/claudetop-history.jsonl"

# Read JSON from stdin
JSON=$(cat)

# Extract fields with jq (fallback to defaults if missing)
PROJECT_DIR=$(echo "$JSON" | jq -r '.workspace.project_dir // .cwd // "unknown"')
CWD=$(echo "$JSON" | jq -r '.cwd // "unknown"')
MODEL_NAME=$(echo "$JSON" | jq -r '.model.display_name // "unknown"')
MODEL_ID=$(echo "$JSON" | jq -r '.model.id // "unknown"')

# Token counts
INPUT_TOKENS=$(echo "$JSON" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$JSON" | jq -r '.context_window.total_output_tokens // 0')
CTX_USED=$(echo "$JSON" | jq -r '.context_window.used_percentage // 0')
CACHE_READ=$(echo "$JSON" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
CACHE_CREATE=$(echo "$JSON" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
REGULAR_INPUT=$(echo "$JSON" | jq -r '.context_window.current_usage.input_tokens // 0')

# Cost & duration
COST=$(echo "$JSON" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$JSON" | jq -r '.cost.total_duration_ms // 0')
LINES_ADDED=$(echo "$JSON" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$JSON" | jq -r '.cost.total_lines_removed // 0')

# --- Formatting helpers ---

shorten_path() {
  echo "$1" | sed "s|$HOME|~|"
}

fmt_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf "%.1fM" "$(echo "scale=1; $n / 1000000" | bc)"
  elif [ "$n" -ge 1000 ]; then
    printf "%.1fK" "$(echo "scale=1; $n / 1000" | bc)"
  else
    echo "$n"
  fi
}

fmt_duration() {
  local ms=$1
  local secs=$((ms / 1000))
  if [ "$secs" -ge 3600 ]; then
    printf "%dh %dm" $((secs / 3600)) $(((secs % 3600) / 60))
  elif [ "$secs" -ge 60 ]; then
    printf "%dm %ds" $((secs / 60)) $((secs % 60))
  else
    printf "%ds" "$secs"
  fi
}

# Cache-aware cost estimate per model
CURRENT_TOTAL_IN=$((CACHE_READ + CACHE_CREATE + REGULAR_INPUT))
if [ "$CURRENT_TOTAL_IN" -gt 0 ]; then
  EST_CACHE_READ=$(echo "scale=0; $INPUT_TOKENS * $CACHE_READ / $CURRENT_TOTAL_IN" | bc)
  EST_CACHE_CREATE=$(echo "scale=0; $INPUT_TOKENS * $CACHE_CREATE / $CURRENT_TOTAL_IN" | bc)
  EST_REGULAR=$(echo "scale=0; $INPUT_TOKENS * $REGULAR_INPUT / $CURRENT_TOTAL_IN" | bc)
else
  EST_CACHE_READ=0
  EST_CACHE_CREATE=0
  EST_REGULAR=$INPUT_TOKENS
fi

calc_cost() {
  local in_price=$1 cache_write_price=$2 cache_read_price=$3 out_price=$4
  echo "scale=4; ($EST_REGULAR * $in_price / 1000000) + ($EST_CACHE_CREATE * $cache_write_price / 1000000) + ($EST_CACHE_READ * $cache_read_price / 1000000) + ($OUTPUT_TOKENS * $out_price / 1000000)" | bc
}

fmt_cost() {
  local c=$1
  if [ "$(echo "$c >= 1" | bc)" -eq 1 ]; then
    printf "\$%.2f" "$c"
  else
    printf "\$%.3f" "$c"
  fi
}

# --- Extract project name ---
PROJECT_NAME=$(basename "$PROJECT_DIR")
SHORT_CWD=$(shorten_path "$CWD")
SHORT_PROJECT=$(shorten_path "$PROJECT_DIR")

REL_PATH=""
if [ "$CWD" != "$PROJECT_DIR" ] && [[ "$CWD" == "$PROJECT_DIR"* ]]; then
  REL_PATH="${CWD#$PROJECT_DIR}"
fi

# --- ANSI Colors ---
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
BLUE="\033[34m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
MAGENTA="\033[35m"
RED="\033[31m"
WHITE="\033[37m"
GRAY="\033[90m"

# --- Time of day ---
TIME_NOW=$(date +"%H:%M")
HOUR=$(date +"%H")
if [ "$HOUR" -ge 22 ] || [ "$HOUR" -lt 6 ]; then
  TIME_FMT="${MAGENTA}${TIME_NOW}${RESET}"
else
  TIME_FMT="${DIM}${TIME_NOW}${RESET}"
fi

# --- Session tag ---
TAG_FMT=""
if [ -n "${CLAUDETOP_TAG:-}" ]; then
  TAG_FMT=" ${DIM}#${CLAUDETOP_TAG}${RESET}"
fi

# --- Load pricing (from daily cache or hardcoded defaults) ---
PRICING_FILE="${HOME}/.claude/claudetop-pricing.json"
if [ -f "$PRICING_FILE" ]; then
  # Read all prices in a single jq call for performance
  # Uses cache_write_5min as default cache write tier (Claude Code uses 5min TTL)
  PRICES=$(jq -r '[
    .models.opus.input, (.models.opus.cache_write_5min // .models.opus.cache_write // (.models.opus.input * 1.25)), .models.opus.cache_read, .models.opus.output,
    .models.sonnet.input, (.models.sonnet.cache_write_5min // .models.sonnet.cache_write // (.models.sonnet.input * 1.25)), .models.sonnet.cache_read, .models.sonnet.output,
    .models.haiku.input, (.models.haiku.cache_write_5min // .models.haiku.cache_write // (.models.haiku.input * 1.25)), .models.haiku.cache_read, .models.haiku.output,
    (.models.sonnet.long_context_input // 0), (.models.sonnet.long_context_output // 0), (.models.sonnet.long_context_threshold // 0)
  ] | @tsv' "$PRICING_FILE" 2>/dev/null) || PRICES=""
fi

if [ -n "${PRICES:-}" ]; then
  read -r O_IN O_CW O_CR O_OUT S_IN S_CW S_CR S_OUT H_IN H_CW H_CR H_OUT S_LC_IN S_LC_OUT S_LC_THRESH <<< "$PRICES"
else
  # Hardcoded fallback (Claude 4.6 pricing as of March 2026)
  O_IN=5; O_CW=6.25; O_CR=0.50; O_OUT=25
  S_IN=3; S_CW=3.75; S_CR=0.30; S_OUT=15
  H_IN=1; H_CW=1.25; H_CR=0.10; H_OUT=5
  S_LC_IN=6; S_LC_OUT=22.50; S_LC_THRESH=200000
fi

# --- Sonnet long-context pricing ---
# If total input tokens exceed threshold, Sonnet gets more expensive
S_EFF_IN="$S_IN"
S_EFF_OUT="$S_OUT"
S_EFF_CW="$S_CW"
if [ "${S_LC_THRESH:-0}" -gt 0 ] && [ "$INPUT_TOKENS" -gt "${S_LC_THRESH}" ]; then
  S_EFF_IN="${S_LC_IN}"
  S_EFF_OUT="${S_LC_OUT}"
  S_EFF_CW=$(echo "scale=2; $S_LC_IN * 1.25" | bc)
fi

# --- Cost estimates per model (cache-aware, dynamic pricing) ---
OPUS_COST=$(calc_cost   "$O_IN" "$O_CW" "$O_CR" "$O_OUT")
SONNET_COST=$(calc_cost "$S_EFF_IN" "$S_EFF_CW" "$S_CR" "$S_EFF_OUT")
HAIKU_COST=$(calc_cost  "$H_IN" "$H_CW" "$H_CR" "$H_OUT")

ACTUAL_COST_FMT=$(fmt_cost "$COST")

# When actual cost >> snapshot estimate (stale session / post-compaction),
# scale all model estimates by the same ratio so comparisons remain meaningful.
# E.g. if you spent $5.61 on Sonnet but snapshot says ~$0.60, scale factor=9.35x
# and Opus estimate becomes ~$8.30 instead of a misleading ~$0.89.
STALE_SCALE="1"
case "$MODEL_ID" in
  *opus*)   _BASE_COST="$OPUS_COST" ;;
  *sonnet*) _BASE_COST="$SONNET_COST" ;;
  *haiku*)  _BASE_COST="$HAIKU_COST" ;;
  *)        _BASE_COST="0" ;;
esac
if [ "$(echo "$_BASE_COST > 0 && $COST / $_BASE_COST > 1.5" | bc 2>/dev/null)" = "1" ]; then
  STALE_SCALE=$(echo "scale=4; $COST / $_BASE_COST" | bc)
  OPUS_COST=$(echo "scale=4; $OPUS_COST * $STALE_SCALE" | bc)
  SONNET_COST=$(echo "scale=4; $SONNET_COST * $STALE_SCALE" | bc)
  HAIKU_COST=$(echo "scale=4; $HAIKU_COST * $STALE_SCALE" | bc)
fi

# Model estimates always prefixed with ~ (they're approximations)
OPUS_COST_FMT="~$(fmt_cost "$OPUS_COST")"
SONNET_COST_FMT="~$(fmt_cost "$SONNET_COST")"
HAIKU_COST_FMT="~$(fmt_cost "$HAIKU_COST")"

# Highlight current model (scaled estimates are accurate, no * needed)
case "$MODEL_ID" in
  *opus*)
    OPUS_COST_FMT="${BOLD}${OPUS_COST_FMT}${RESET}${DIM}"
    ;;
  *sonnet*)
    SONNET_COST_FMT="${BOLD}${SONNET_COST_FMT}${RESET}${DIM}"
    ;;
  *haiku*)
    HAIKU_COST_FMT="${BOLD}${HAIKU_COST_FMT}${RESET}${DIM}"
    ;;
esac

IN_FMT=$(fmt_tokens "$INPUT_TOKENS")
OUT_FMT=$(fmt_tokens "$OUTPUT_TOKENS")
DUR_FMT=$(fmt_duration "$DURATION_MS")

# --- Cost velocity ($/hr) ---
VELOCITY=""
RATE=0
if [ "$DURATION_MS" -gt 30000 ]; then
  HOURS=$(echo "scale=6; $DURATION_MS / 3600000" | bc)
  RATE=$(echo "scale=2; $COST / $HOURS" | bc)
  if [ "$(echo "$RATE >= 8" | bc)" -eq 1 ]; then
    VELOCITY="${RED}\$${RATE}/hr${RESET}"
  elif [ "$(echo "$RATE >= 3" | bc)" -eq 1 ]; then
    VELOCITY="${YELLOW}\$${RATE}/hr${RESET}"
  else
    VELOCITY="${GREEN}\$${RATE}/hr${RESET}"
  fi
fi

# --- Cache hit ratio ---
CACHE_RATIO=""
CACHE_PCT=0
TOTAL_INPUT=$((CACHE_READ + CACHE_CREATE + REGULAR_INPUT))
if [ "$TOTAL_INPUT" -gt 0 ]; then
  CACHE_PCT=$(echo "scale=0; $CACHE_READ * 100 / $TOTAL_INPUT" | bc)
  if [ "$CACHE_PCT" -ge 60 ]; then
    CACHE_RATIO="${GREEN}${CACHE_PCT}%${RESET}"
  elif [ "$CACHE_PCT" -ge 30 ]; then
    CACHE_RATIO="${YELLOW}${CACHE_PCT}%${RESET}"
  else
    CACHE_RATIO="${RED}${CACHE_PCT}%${RESET}"
  fi
fi

# --- Context composition ---
# Show input token breakdown: fresh vs cached vs output ratio
CTX_COMP=""
if [ "$TOTAL_INPUT" -gt 0 ]; then
  FRESH_PCT=$(echo "scale=0; $REGULAR_INPUT * 100 / $TOTAL_INPUT" | bc)
  WRITE_PCT=$(echo "scale=0; $CACHE_CREATE * 100 / $TOTAL_INPUT" | bc)
  READ_PCT=$CACHE_PCT
  # Output as % of total tokens (input + output)
  TOTAL_ALL=$((TOTAL_INPUT + OUTPUT_TOKENS))
  if [ "$TOTAL_ALL" -gt 0 ]; then
    OUT_PCT=$(echo "scale=0; $OUTPUT_TOKENS * 100 / $TOTAL_ALL" | bc)
    IN_PCT=$((100 - OUT_PCT))
    CTX_COMP="${DIM}in:${IN_PCT}%${RESET} ${DIM}out:${OUT_PCT}%${RESET}"
    # Show cache breakdown: fresh|write|read
    CTX_COMP="${CTX_COMP} ${DIM}(${RESET}${GRAY}fresh:${FRESH_PCT}%${RESET} ${GRAY}cwrite:${WRITE_PCT}%${RESET} ${GRAY}cread:${READ_PCT}%${RESET}${DIM})${RESET}"
  fi
fi

# --- Output efficiency (cost per line changed) ---
EFFICIENCY=""
CPL=0
TOTAL_LINES=$((LINES_ADDED + LINES_REMOVED))
if [ "$TOTAL_LINES" -gt 0 ]; then
  CPL=$(echo "scale=4; $COST / $TOTAL_LINES" | bc)
  if [ "$(echo "$CPL >= 0.1" | bc)" -eq 1 ]; then
    CPL_FMT=$(printf "\$%.2f" "$CPL")
  else
    CPL_FMT=$(printf "\$%.3f" "$CPL")
  fi
  if [ "$(echo "$CPL >= 0.05" | bc)" -eq 1 ]; then
    EFFICIENCY="${RED}${CPL_FMT}/line${RESET}"
  elif [ "$(echo "$CPL >= 0.01" | bc)" -eq 1 ]; then
    EFFICIENCY="${YELLOW}${CPL_FMT}/line${RESET}"
  else
    EFFICIENCY="${GREEN}${CPL_FMT}/line${RESET}"
  fi
fi

# --- Compact warning ---
COMPACT_WARN=""
if [ "$CTX_USED" -ge 80 ]; then
  COMPACT_WARN=" ${RED}${BOLD}COMPACT SOON${RESET}"
elif [ "$CTX_USED" -ge 70 ]; then
  COMPACT_WARN=" ${YELLOW}~$(echo "scale=0; (100 - $CTX_USED) * 2" | bc)% left${RESET}"
fi

# --- Context bar (visual) ---
CTX_BAR=""
BAR_LEN=10
FILLED=$((CTX_USED * BAR_LEN / 100))
for ((i=0; i<BAR_LEN; i++)); do
  if [ $i -lt $FILLED ]; then
    if [ "$CTX_USED" -ge 80 ]; then
      CTX_BAR="${CTX_BAR}\033[31m█${RESET}"
    elif [ "$CTX_USED" -ge 50 ]; then
      CTX_BAR="${CTX_BAR}\033[33m█${RESET}"
    else
      CTX_BAR="${CTX_BAR}\033[32m█${RESET}"
    fi
  else
    CTX_BAR="${CTX_BAR}\033[90m░${RESET}"
  fi
done

# --- Line delta ---
DELTA=""
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
  DELTA=" ${DIM}${GREEN}+${LINES_ADDED}${RESET}${DIM}/${YELLOW}-${LINES_REMOVED}${RESET}"
fi

# --- Daily budget + forecast (from history) ---
BUDGET_FMT=""
FORECAST_FMT=""
if [ -f "$HISTORY_FILE" ]; then
  TODAY=$(date +"%Y-%m-%d")
  # Sum today's completed sessions + current session cost (fast: grep + jq)
  TODAY_PAST=$(grep "\"$TODAY" "$HISTORY_FILE" 2>/dev/null | jq -s '[.[].cost_usd] | add // 0' 2>/dev/null) || TODAY_PAST=0
  TODAY_TOTAL=$(echo "scale=2; $TODAY_PAST + $COST" | bc)

  # Budget alert
  if [ -n "${CLAUDETOP_DAILY_BUDGET:-}" ]; then
    BUDGET_PCT=$(echo "scale=0; $TODAY_TOTAL * 100 / $CLAUDETOP_DAILY_BUDGET" | bc 2>/dev/null) || BUDGET_PCT=0
    BUDGET_LEFT=$(echo "scale=2; $CLAUDETOP_DAILY_BUDGET - $TODAY_TOTAL" | bc)
    if [ "$(echo "$BUDGET_PCT >= 100" | bc)" -eq 1 ]; then
      BUDGET_FMT="${RED}${BOLD}OVER BUDGET${RESET} ${DIM}(\$${TODAY_TOTAL}/\$${CLAUDETOP_DAILY_BUDGET})${RESET}"
    elif [ "$(echo "$BUDGET_PCT >= 80" | bc)" -eq 1 ]; then
      BUDGET_FMT="${YELLOW}budget: \$${BUDGET_LEFT} left${RESET}"
    fi
  fi

  # Monthly forecast — extrapolate from recent daily average
  # Use last 7 days of history for more stable estimate
  WEEK_AGO=$(date -v-7d +"%Y-%m-%d" 2>/dev/null || date -d "7 days ago" +"%Y-%m-%d" 2>/dev/null || echo "")
  if [ -n "$WEEK_AGO" ]; then
    WEEK_COST=$(grep -E "\"(${WEEK_AGO}|$(date -v-6d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-5d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-4d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-3d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-2d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-1d +"%Y-%m-%d" 2>/dev/null || true)|${TODAY})" "$HISTORY_FILE" 2>/dev/null | jq -s '[.[].cost_usd] | add // 0' 2>/dev/null) || WEEK_COST=0
    # Count distinct days in the window
    DAYS_WITH_DATA=$(grep -E "\"(${WEEK_AGO}|$(date -v-6d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-5d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-4d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-3d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-2d +"%Y-%m-%d" 2>/dev/null || true)|$(date -v-1d +"%Y-%m-%d" 2>/dev/null || true)|${TODAY})" "$HISTORY_FILE" 2>/dev/null | jq -r '.timestamp[:10]' 2>/dev/null | sort -u | wc -l | tr -d ' ') || DAYS_WITH_DATA=0
    if [ "$DAYS_WITH_DATA" -gt 0 ]; then
      DAILY_AVG=$(echo "scale=2; $WEEK_COST / $DAYS_WITH_DATA" | bc)
      MONTHLY_EST=$(echo "scale=0; $DAILY_AVG * 30" | bc)
      if [ "$(echo "$MONTHLY_EST > 0" | bc)" -eq 1 ]; then
        FORECAST_FMT="${DIM}~\$${MONTHLY_EST}/mo${RESET}"
      fi
    fi
  fi
fi

# --- Plan usage windows (5h session / 7d all models / per-model weekly, e.g. Fable) ---
# The live 5h and 7d numbers arrive in the status JSON itself (rate_limits).
# Per-model weekly windows and extra-usage credits come from a cache that
# claudetop-usage writes; this script never touches the network — it reads the
# cache and re-launches the fetcher in the background when the cache is stale.
USAGE_MODE="${CLAUDETOP_USAGE:-on}"
USAGE_CACHE="${CLAUDETOP_USAGE_CACHE:-$HOME/.claude/claudetop-usage.json}"
USAGE_TTL="${CLAUDETOP_USAGE_TTL:-60}"
USAGE_BIN="${CLAUDETOP_USAGE_BIN:-$HOME/.claude/claudetop-usage}"
# Fallbacks: a claudetop-usage sitting next to this script (works when the
# script is a symlink into a synced folder), then anything on PATH.
if [ ! -x "$USAGE_BIN" ]; then
  _self_dir=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
  if [ -x "$_self_dir/claudetop-usage" ]; then
    USAGE_BIN="$_self_dir/claudetop-usage"
  else
    USAGE_BIN=$(command -v claudetop-usage 2>/dev/null || true)
  fi
fi
NOW_EPOCH=$(date +%s)

USAGE_LINE=""       # full theme: one bar per window
USAGE_SHORT=""      # minimal theme: "5h:82% 7d:64% Fable:81%"
USAGE_TOP_LABEL=""  # tightest window (highest % used) — compact theme + alert
USAGE_TOP_PCT=0
USAGE_TOP_FMT=""
USAGE_TOP_RESET=""
USAGE_CACHE_STATUS=""
PLAIN_USAGE=""

fmt_reset() {
  local at=${1:-0} d
  [ "$at" -gt 0 ] 2>/dev/null || { echo ""; return; }
  d=$(( at - NOW_EPOCH ))
  if [ "$d" -le 0 ]; then echo "now"
  elif [ "$d" -ge 86400 ]; then printf '%dd%dh' $((d / 86400)) $(((d % 86400) / 3600))
  elif [ "$d" -ge 3600 ]; then printf '%dh%02dm' $((d / 3600)) $(((d % 3600) / 60))
  else printf '%dm' $((d / 60)); fi
}

usage_color() {
  if [ "$1" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 50 ]; then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"; fi
}

usage_bar() {
  local pct=$1 color bar="" i filled len=${BAR_LEN:-10}
  color=$(usage_color "$pct")
  filled=$(( pct * len / 100 )); [ "$filled" -gt "$len" ] && filled=$len
  for ((i = 0; i < len; i++)); do
    if [ $i -lt $filled ]; then bar="${bar}${color}█${RESET}"; else bar="${bar}${GRAY}░${RESET}"; fi
  done
  printf '%s' "$bar"
}

if [ "$USAGE_MODE" != "off" ]; then
  USAGE_CACHE_JSON='{}'
  if [ -f "$USAGE_CACHE" ]; then
    USAGE_CACHE_JSON=$(cat "$USAGE_CACHE" 2>/dev/null) || USAGE_CACHE_JSON='{}'
    [ -n "$USAGE_CACHE_JSON" ] || USAGE_CACHE_JSON='{}'
    USAGE_CACHE_STATUS=$(jq -r '.status // ""' <<< "$USAGE_CACHE_JSON" 2>/dev/null) || USAGE_CACHE_STATUS=""
  fi

  # Live windows first (fresh from the last API response), then cached buckets
  # that Claude Code doesn't pass through (per-model weeklies).
  USAGE_ROWS=$(jq -rn --argjson s "$JSON" --argjson c "$USAGE_CACHE_JSON" '
    def row(k; l; p; r): select(p != null) | [k, l, (p | round), (r // 0)] | @tsv;
    [ ($s.rate_limits.five_hour   // empty | row("five_hour";   "5h";    .used_percentage; .resets_at)),
      ($s.rate_limits.seven_day   // empty | row("seven_day";   "7d";    .used_percentage; .resets_at)),
      ($s.rate_limits.spend_limit // empty | row("spend_limit"; "spend"; .used_percentage; .resets_at)) ] as $live
    | ($live | map(split("\t")[0])) as $have
    | ($live + [ ($c.buckets // [])[]
                 | select(.pct != null)
                 | .key as $k | select(($have | index($k)) == null)
                 | row(.key; .label; .pct; .resets_at) ])[]
  ' 2>/dev/null) || USAGE_ROWS=""

  if [ -n "$USAGE_ROWS" ]; then
    while IFS=$'\t' read -r _ u_label u_pct u_at; do
      [ -n "$u_label" ] || continue
      u_pct=${u_pct%.*}
      u_color=$(usage_color "$u_pct")
      u_reset=$(fmt_reset "$u_at")
      u_seg="${DIM}${u_label}${RESET} $(usage_bar "$u_pct") ${u_color}${u_pct}%${RESET}"
      [ -n "$u_reset" ] && u_seg="${u_seg} ${GRAY}↻${u_reset}${RESET}"
      USAGE_LINE="${USAGE_LINE:+$USAGE_LINE  }${u_seg}"
      USAGE_SHORT="${USAGE_SHORT:+$USAGE_SHORT }${DIM}${u_label}:${RESET}${u_color}${u_pct}%${RESET}"
      PLAIN_USAGE="${PLAIN_USAGE:+$PLAIN_USAGE }${u_label}:${u_pct}%"
      if [ -z "$USAGE_TOP_LABEL" ] || [ "$u_pct" -gt "$USAGE_TOP_PCT" ]; then
        USAGE_TOP_LABEL=$u_label
        USAGE_TOP_PCT=$u_pct
        USAGE_TOP_FMT="${DIM}${u_label}${RESET} ${u_color}${u_pct}%${RESET}"
        USAGE_TOP_RESET=$u_reset
      fi
    done <<< "$USAGE_ROWS"
  fi

  # Extra-usage credits (pay-as-you-go top-up beyond the plan windows)
  USAGE_EXTRA=$(jq -r 'select(.extra.enabled == true) | .extra | "\(.used_minor // 0)\t\(.limit_minor // 0)\t\(.decimals // 2)"' <<< "$USAGE_CACHE_JSON" 2>/dev/null) || USAGE_EXTRA=""
  if [ -n "$USAGE_EXTRA" ]; then
    IFS=$'\t' read -r x_used x_limit x_dec <<< "$USAGE_EXTRA"
    x_div=1; for ((i = 0; i < x_dec; i++)); do x_div=$((x_div * 10)); done
    if [ "${x_limit:-0}" -gt 0 ]; then
      x_used_fmt=$(echo "scale=2; $x_used / $x_div" | bc | sed 's/^\./0./; s/\.00$//')
      x_limit_fmt=$(echo "$x_limit / $x_div" | bc)
      USAGE_LINE="${USAGE_LINE:+$USAGE_LINE  }${DIM}credits${RESET} ${GRAY}\$${x_used_fmt}/\$${x_limit_fmt}${RESET}"
    fi
  fi

  # Cache couldn't be refreshed (auth/network) — flag the numbers as possibly stale
  if [ -n "$USAGE_LINE" ] && [ "$USAGE_CACHE_STATUS" = "error" ]; then
    USAGE_LINE="${YELLOW}!${RESET} ${USAGE_LINE}"
  fi
fi

# --- Plugin system ---
PLUGIN_DIR="${HOME}/.claude/claudetop.d"
PLUGIN_OUTPUT=""
if [ -d "$PLUGIN_DIR" ]; then
  for plugin in "$PLUGIN_DIR"/*; do
    [ -f "$plugin" ] && [ -x "$plugin" ] || continue
    result=$(echo "$JSON" | perl -e 'alarm 1; exec @ARGV' "$plugin" 2>/dev/null) || true
    if [ -n "$result" ]; then
      if [ -n "$PLUGIN_OUTPUT" ]; then
        PLUGIN_OUTPUT="${PLUGIN_OUTPUT}  ${DIM}|${RESET}  ${result}"
      else
        PLUGIN_OUTPUT="$result"
      fi
    fi
  done
fi

# --- Alerts ---
declare -a ALERTS

# Cost milestones
for THRESHOLD in 25 10 5; do
  if [ "$(echo "$COST >= $THRESHOLD" | bc)" -eq 1 ]; then
    ALERTS+=("${RED}${BOLD}\$${THRESHOLD} MARK${RESET}")
    break
  fi
done

# Budget alert
if [ -n "$BUDGET_FMT" ]; then
  ALERTS+=("$BUDGET_FMT")
fi

# Stale session
DURATION_HOURS=$(echo "scale=2; $DURATION_MS / 3600000" | bc)
if [ "$(echo "$DURATION_HOURS >= 2" | bc)" -eq 1 ] && [ "$CTX_USED" -ge 60 ]; then
  ALERTS+=("${YELLOW}CONSIDER FRESH SESSION${RESET}")
fi

# Cache collapse
DURATION_MIN=$((DURATION_MS / 60000))
if [ "$DURATION_MIN" -ge 5 ] && [ "$TOTAL_INPUT" -gt 0 ]; then
  if [ "$CACHE_PCT" -lt 20 ]; then
    ALERTS+=("${RED}LOW CACHE${RESET}")
  fi
fi

# Velocity spike
if [ -n "$VELOCITY" ] && [ "$(echo "$RATE >= 15" | bc)" -eq 1 ]; then
  ALERTS+=("${RED}BURN RATE${RESET}")
fi

# Output stall
if [ "$(echo "$COST >= 1" | bc)" -eq 1 ] && [ "$TOTAL_LINES" -eq 0 ]; then
  ALERTS+=("${YELLOW}SPINNING?${RESET}")
fi

# Model mismatch
if [ "$TOTAL_LINES" -gt 0 ] && [ "$(echo "$CPL >= 0.05" | bc)" -eq 1 ]; then
  case "$MODEL_ID" in
    *opus*) ALERTS+=("${CYAN}TRY /fast${RESET}") ;;
  esac
fi

# Plan window nearly exhausted (5h / 7d / per-model)
if [ -n "$USAGE_TOP_LABEL" ] && [ "$USAGE_TOP_PCT" -ge 90 ]; then
  ALERTS+=("${RED}${BOLD}${USAGE_TOP_LABEL} LIMIT ${USAGE_TOP_PCT}%${RESET}${USAGE_TOP_RESET:+ ${DIM}↻${USAGE_TOP_RESET}${RESET}}")
fi

# Build alert string
ALERT_STR=""
for alert in "${ALERTS[@]+"${ALERTS[@]}"}"; do
  if [ -n "$ALERT_STR" ]; then
    ALERT_STR="${ALERT_STR}  ${DIM}|${RESET}  ${alert}"
  else
    ALERT_STR="$alert"
  fi
done

# =============================================
# OUTPUT — Theme-aware rendering
# =============================================

if [ "$THEME" = "compact" ]; then
  # --- COMPACT: 1 line ---
  printf "%b " "$TIME_FMT"
  printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
  printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
  printf "  ${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf " %b" "$VELOCITY"
  fi
  printf "  %b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  if [ -n "$USAGE_TOP_FMT" ]; then
    printf "  %b" "$USAGE_TOP_FMT"
  fi
  printf "%b" "$TAG_FMT"
  if [ -n "$ALERT_STR" ]; then
    printf "  %b" "$ALERT_STR"
  fi
  echo ""

elif [ "$THEME" = "minimal" ]; then
  # --- MINIMAL: 2 lines ---
  # Line 1: project + model + duration + lines
  printf "%b  " "$TIME_FMT"
  printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
  if [ -n "$REL_PATH" ]; then
    printf "${DIM}%s${RESET}" "$REL_PATH"
  fi
  printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
  printf "  ${DIM}%s${RESET}" "$DUR_FMT"
  printf "%b" "$DELTA"
  printf "%b" "$TAG_FMT"
  echo ""

  # Line 2: cost + velocity + context + cache + alerts
  printf "${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf "  %b" "$VELOCITY"
  fi
  if [ -n "$FORECAST_FMT" ]; then
    printf "  %b" "$FORECAST_FMT"
  fi
  printf "  %b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  if [ -n "$CACHE_RATIO" ]; then
    printf "  ${DIM}cache:${RESET} %b" "$CACHE_RATIO"
  fi
  if [ -n "$USAGE_SHORT" ]; then
    printf "  %b" "$USAGE_SHORT"
  fi
  if [ -n "$ALERT_STR" ]; then
    printf "  %b" "$ALERT_STR"
  fi
  echo ""

else
  # --- FULL: 3-5 lines (default) ---

  # Line 1: Time + Project + folder + model + duration + line delta + tag
  printf "%b  " "$TIME_FMT"
  printf "${BOLD}${BLUE}%s${RESET}" "$PROJECT_NAME"
  if [ -n "$REL_PATH" ]; then
    printf "${DIM}%s${RESET}" "$REL_PATH"
  else
    printf " ${DIM}%s${RESET}" "$SHORT_PROJECT"
  fi
  printf "  ${CYAN}%s${RESET}" "$MODEL_NAME"
  printf "  ${DIM}%s${RESET}" "$DUR_FMT"
  printf "%b" "$DELTA"
  printf "%b" "$TAG_FMT"
  echo ""

  # Line 2: Tokens + context bar + compact warning + cost + velocity + forecast
  printf "${DIM}%s in / %s out  ${RESET}" "$IN_FMT" "$OUT_FMT"
  printf "%b ${DIM}%s%%${RESET}" "$CTX_BAR" "$CTX_USED"
  printf "%b" "$COMPACT_WARN"
  printf "  ${GREEN}%s${RESET}" "$ACTUAL_COST_FMT"
  if [ -n "$VELOCITY" ]; then
    printf "  %b" "$VELOCITY"
  fi
  if [ -n "$FORECAST_FMT" ]; then
    printf "  %b" "$FORECAST_FMT"
  fi
  echo ""

  # Line 3: Cache + efficiency + model costs + context composition
  printf "${DIM}cache:${RESET} "
  if [ -n "$CACHE_RATIO" ]; then
    printf "%b" "$CACHE_RATIO"
  else
    printf "${GRAY}--${RESET}"
  fi
  if [ -n "$EFFICIENCY" ]; then
    printf "  ${DIM}efficiency:${RESET} %b" "$EFFICIENCY"
  fi
  printf "${DIM}  opus:%b  sonnet:%b  haiku:%b${RESET}" "$OPUS_COST_FMT" "$SONNET_COST_FMT" "$HAIKU_COST_FMT"
  echo ""

  # Line 4 (optional): Plan usage windows — 5h / 7d / per-model / credits
  if [ -n "$USAGE_LINE" ]; then
    printf "${DIM}plan:${RESET} %b\n" "$USAGE_LINE"
  fi

  # Line 5 (optional): Context composition (when there's data)
  if [ -n "$CTX_COMP" ]; then
    printf "%b\n" "$CTX_COMP"
  fi

  # Line 6 (optional): Alerts + Plugin outputs
  LINE5=""
  if [ -n "$ALERT_STR" ]; then
    LINE5="$ALERT_STR"
  fi
  if [ -n "$PLUGIN_OUTPUT" ]; then
    if [ -n "$LINE5" ]; then
      LINE5="${LINE5}  ${DIM}|${RESET}  ${PLUGIN_OUTPUT}"
    else
      LINE5="$PLUGIN_OUTPUT"
    fi
  fi
  if [ -n "$LINE5" ]; then
    printf "%b\n" "$LINE5"
  fi
fi

# =============================================
# iTerm2 Integration
# =============================================
# Writes iTerm2 state to ~/.claude/claudetop-iterm-state. A shell prompt hook
# (PROMPT_COMMAND / precmd) reads this file and emits the escape sequences.
# This two-step approach is needed because Claude Code's status line script
# doesn't have direct terminal access (/dev/tty unavailable in sandbox).
#
# The prompt hook is installed by `install.sh` or can be added manually:
#   source ~/.claude/claudetop-iterm-hook.sh

if [ -n "$ITERM_MODE" ]; then
  # Per-session state file so multiple Claude Code sessions don't clobber each other
  ITERM_STATE_FILE="${HOME}/.claude/claudetop-iterm-state.${ITERM_SESSION_ID:-default}"
  ITERM_WATCHER="${HOME}/.claude/claudetop-iterm-watcher.sh"

  iterm_wants() {
    [ "$ITERM_MODE" = "all" ] && return 0
    case ",$ITERM_MODE," in *",$1,"*) return 0 ;; esac
    return 1
  }

  # Discover TTY from parent process tree and register it
  # (status line script can't call `tty` but can find the TTY via the parent shell)
  ITERM_TTY_MAP="${HOME}/.claude/claudetop-iterm-ttys"
  if [ -n "${ITERM_SESSION_ID:-}" ]; then
    _PARENT_TTY=$(ps -p $PPID -o tty= 2>/dev/null | tr -d ' ')
    if [ -n "$_PARENT_TTY" ] && [ "$_PARENT_TTY" != "??" ]; then
      _PARENT_TTY="/dev/${_PARENT_TTY}"
      # Write/update TTY mapping
      grep -v "^${ITERM_SESSION_ID}=" "$ITERM_TTY_MAP" 2>/dev/null > "${ITERM_TTY_MAP}.tmp" || true
      echo "${ITERM_SESSION_ID}=${_PARENT_TTY}" >> "${ITERM_TTY_MAP}.tmp"
      mv "${ITERM_TTY_MAP}.tmp" "$ITERM_TTY_MAP"
    fi
  fi

  # Auto-launch watcher if not already running for this iTerm session
  if [ -n "${ITERM_SESSION_ID:-}" ] && [ -x "$ITERM_WATCHER" ]; then
    if ! pgrep -f "claudetop-iterm-watcher.sh ${ITERM_SESSION_ID}" >/dev/null 2>&1; then
      nohup "$ITERM_WATCHER" "$ITERM_SESSION_ID" >/dev/null 2>&1 &
    fi
  fi

  # Plain-text versions (no ANSI) for iTerm2 chrome
  PLAIN_COST=$(printf "$%s" "$(echo "scale=2; $COST / 1" | bc)")
  PLAIN_VELOCITY=""
  if [ -n "$VELOCITY" ] && [ "$(echo "$RATE > 0" | bc)" -eq 1 ]; then
    PLAIN_VELOCITY="\$${RATE}/hr"
  fi

  # Status line only runs during active responses — always set black.
  # Stop hook sets green AFTER the last render, so it won't be overwritten.

  # Build state file — one key=value per line, read by the watcher
  {
    echo "iterm_session=${ITERM_SESSION_ID:-}"
    echo "timestamp=$(date +%s)"
    echo "project=${PROJECT_NAME}"
    echo "model=${MODEL_NAME}"
    echo "cost=${PLAIN_COST}"
    echo "velocity=${PLAIN_VELOCITY}"
    echo "ctx=${CTX_USED}"
    echo "cache=${CACHE_PCT}"
    echo "duration=${DUR_FMT}"
    echo "tokens_in=${IN_FMT}"
    echo "tokens_out=${OUT_FMT}"
    echo "lines_added=${LINES_ADDED}"
    echo "lines_removed=${LINES_REMOVED}"
    [ -n "${CLAUDETOP_TAG:-}" ] && echo "tag=${CLAUDETOP_TAG}"
    [ -n "$PLAIN_USAGE" ] && echo "usage=${PLAIN_USAGE}"
    [ -n "$USAGE_TOP_LABEL" ] && echo "usage_top=${USAGE_TOP_LABEL} ${USAGE_TOP_PCT}%"
    echo "bgcolor=000000"
    echo "modes=${ITERM_MODE}"
  } > "$ITERM_STATE_FILE"
fi

# =============================================
# Background refresh of the plan-usage cache
# =============================================
# Done last so it never delays the render. Double-fork + no inherited fds, so
# Claude Code's status line pipe closes as soon as this script exits.
if [ "$USAGE_MODE" != "off" ] && [ -n "$USAGE_BIN" ] && [ -x "$USAGE_BIN" ]; then
  _u_ttl=$USAGE_TTL
  # No plan windows for this credential (API key / Bedrock / Vertex): back off to hourly
  [ "$USAGE_CACHE_STATUS" = "unavailable" ] && _u_ttl=3600
  _u_age=$((_u_ttl + 1))
  if [ -f "$USAGE_CACHE" ]; then
    _u_m=$(stat -f %m "$USAGE_CACHE" 2>/dev/null || stat -c %Y "$USAGE_CACHE" 2>/dev/null || echo 0)
    _u_age=$(( NOW_EPOCH - _u_m ))
  fi
  if [ "$_u_age" -gt "$_u_ttl" ]; then
    ( CLAUDETOP_USAGE_CACHE="$USAGE_CACHE" CLAUDETOP_USAGE_TTL="$_u_ttl" nohup "$USAGE_BIN" >/dev/null 2>&1 </dev/null & ) 2>/dev/null
  fi
fi
