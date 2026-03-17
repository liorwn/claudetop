#!/bin/bash
# update-pricing.sh — Fetch latest Claude model pricing
#
# Tries multiple sources in order:
#   1. claudetop repo on GitHub (community-maintained)
#   2. Anthropic API docs page (parsed)
#   3. Falls back to bundled pricing.json
#
# Run daily via cron or launchd:
#   0 6 * * * ~/.claude/update-pricing.sh
#
# Or install via: claudetop update-pricing

set -euo pipefail

CACHE_DIR="$HOME/.claude"
PRICING_FILE="$CACHE_DIR/claudetop-pricing.json"
REPO_URL="https://raw.githubusercontent.com/liorwn/claudetop/main/pricing.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$CACHE_DIR"

# Check if cache is fresh (updated today)
if [ -f "$PRICING_FILE" ]; then
  CACHED_DATE=$(jq -r '._updated // ""' "$PRICING_FILE" 2>/dev/null || echo "")
  TODAY=$(date +"%Y-%m-%d")
  if [ "$CACHED_DATE" = "$TODAY" ]; then
    echo "Pricing already up to date ($TODAY)"
    exit 0
  fi
fi

echo "Fetching latest Claude pricing..."

# Source 1: GitHub repo (most reliable, community-maintained)
FETCHED=""
if RESPONSE=$(curl -sf --max-time 5 "$REPO_URL" 2>/dev/null); then
  # Strict schema validation: all models must have expected fields with numeric values in [0, 1000]
  VALID=$(echo "$RESPONSE" | jq -e '
    def valid_price: type == "number" and . >= 0 and . <= 1000;
    .models.opus.input   | valid_price and
    .models.opus.output  | valid_price and
    .models.opus.cache_read | valid_price and
    .models.sonnet.input | valid_price and
    .models.sonnet.output | valid_price and
    .models.sonnet.cache_read | valid_price and
    .models.haiku.input  | valid_price and
    .models.haiku.output | valid_price and
    .models.haiku.cache_read | valid_price
  ' 2>/dev/null) || VALID=""
  if [ "$VALID" = "true" ]; then
    # Strip any unexpected keys — only keep .models and ._updated/_source/_notes
    FETCHED=$(echo "$RESPONSE" | jq '{_updated, _source, _notes, models}')
    echo "  Fetched from GitHub repo"
  else
    echo "  Warning: fetched pricing failed schema validation, skipping" >&2
  fi
fi

# Source 2: Try Anthropic API docs (future enhancement)
# Anthropic doesn't have a pricing API yet. If they add one, plug it in here.
# For now, the GitHub source is the primary path. Community PRs keep it current.

# Source 3: Fall back to bundled pricing.json from install
if [ -z "$FETCHED" ] && [ -f "$SCRIPT_DIR/pricing.json" ]; then
  FETCHED=$(cat "$SCRIPT_DIR/pricing.json")
  echo "  Using bundled pricing (offline fallback)"
fi

# Write to cache
if [ -n "$FETCHED" ]; then
  echo "$FETCHED" | jq '.' > "$PRICING_FILE"
  echo "  Saved to $PRICING_FILE"
  echo ""
  echo "Current pricing:"
  jq -r '.models | to_entries[] | "  \(.key): $\(.value.input)/MTok in, $\(.value.output)/MTok out"' "$PRICING_FILE"
else
  echo "  Failed to fetch pricing. Using existing cache or hardcoded defaults."
fi
