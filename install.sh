#!/bin/bash
# claudetop installer
# Copies claudetop.sh to ~/.claude/ and configures the status line + SessionEnd hook

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/claudetop.sh"
PLUGIN_DIR="$HOME/.claude/claudetop.d"
SETTINGS="$HOME/.claude/settings.json"
STATS_DEST="/usr/local/bin/claudetop-stats"

echo "Installing claudetop..."

# 1. Copy main script
cp "$SCRIPT_DIR/claudetop.sh" "$DEST"
chmod +x "$DEST"
echo "  Copied claudetop.sh -> $DEST"

# 2. Create plugin directory
mkdir -p "$PLUGIN_DIR"
echo "  Created plugin directory: $PLUGIN_DIR"

# 3. Copy bundled plugins (only git-branch is enabled by default)
cp "$SCRIPT_DIR/plugins/git-branch.sh" "$PLUGIN_DIR/"
chmod +x "$PLUGIN_DIR/git-branch.sh"
echo "  Enabled plugin: git-branch"

# 4. Copy example plugins to _examples/
mkdir -p "$PLUGIN_DIR/_examples"
for f in "$SCRIPT_DIR/plugins/examples/"*.sh; do
  [ -f "$f" ] || continue
  cp "$f" "$PLUGIN_DIR/_examples/"
  chmod +x "$PLUGIN_DIR/_examples/$(basename "$f")"
done
echo "  Copied example plugins to $PLUGIN_DIR/_examples/"

# 5. Install claudetop-stats CLI
if [ -w "$(dirname "$STATS_DEST")" ]; then
  cp "$SCRIPT_DIR/claudetop-stats" "$STATS_DEST"
  chmod +x "$STATS_DEST"
  echo "  Installed claudetop-stats -> $STATS_DEST"
else
  echo "  Installing claudetop-stats (requires sudo)..."
  sudo cp "$SCRIPT_DIR/claudetop-stats" "$STATS_DEST"
  sudo chmod +x "$STATS_DEST"
  echo "  Installed claudetop-stats -> $STATS_DEST"
fi

# 5b. Install claudetop-usage (plan usage windows: 5h / 7d / per-model / credits)
USAGE_SRC="$SCRIPT_DIR/claudetop-usage"
USAGE_DEST="$HOME/.claude/claudetop-usage"
USAGE_BIN_DEST="/usr/local/bin/claudetop-usage"
if [ -f "$USAGE_SRC" ]; then
  cp "$USAGE_SRC" "$USAGE_DEST"
  chmod +x "$USAGE_DEST"
  echo "  Installed claudetop-usage -> $USAGE_DEST"
  if [ -w "$(dirname "$USAGE_BIN_DEST")" ]; then
    cp "$USAGE_SRC" "$USAGE_BIN_DEST" && chmod +x "$USAGE_BIN_DEST"
    echo "  Installed claudetop-usage -> $USAGE_BIN_DEST"
  else
    sudo cp "$USAGE_SRC" "$USAGE_BIN_DEST" && sudo chmod +x "$USAGE_BIN_DEST"
    echo "  Installed claudetop-usage -> $USAGE_BIN_DEST"
  fi
  # Prime the cache so the first status line already has the per-model windows
  "$USAGE_DEST" --refresh 2>/dev/null || true
fi

# 6. Copy SessionEnd hook
HOOK_SRC="$SCRIPT_DIR/hooks/session-end.sh"
HOOK_DEST="$HOME/.claude/hooks/claudetop-session-end.sh"
mkdir -p "$HOME/.claude/hooks"
cp "$HOOK_SRC" "$HOOK_DEST"
chmod +x "$HOOK_DEST"
echo "  Copied session-end hook -> $HOOK_DEST"

# 7. Configure settings.json
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

if command -v jq &>/dev/null; then
  TMP=$(mktemp)

  # Add statusLine if not present
  if ! grep -q '"statusLine"' "$SETTINGS" 2>/dev/null; then
    jq '. + {"statusLine": {"type": "command", "command": "~/.claude/claudetop.sh", "padding": 1}}' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    TMP=$(mktemp)
    echo "  Configured statusLine in settings.json"
  else
    echo "  statusLine already configured (skipped)"
  fi

  # Add SessionEnd hook if not present
  if ! grep -q 'claudetop-session-end' "$SETTINGS" 2>/dev/null; then
    jq --arg hook "$HOOK_DEST" '
      .hooks //= {} |
      .hooks.SessionEnd //= [] |
      .hooks.SessionEnd += [{"matcher": "", "hooks": [{"type": "command", "command": $hook}]}]
    ' "$SETTINGS" > "$TMP"
    mv "$TMP" "$SETTINGS"
    echo "  Added SessionEnd hook to settings.json"
  else
    echo "  SessionEnd hook already configured (skipped)"
  fi
else
  echo ""
  echo "  jq not found. Add these to $SETTINGS manually:"
  echo '    "statusLine": { "type": "command", "command": "~/.claude/claudetop.sh", "padding": 1 }'
  echo '    "hooks": { "SessionEnd": [{"matcher":"","hooks":[{"type":"command","command":"~/.claude/hooks/claudetop-session-end.sh"}]}] }'
fi

# 8. Install claudetop-engine (analytics + dashboard)
ENGINE_SRC="$SCRIPT_DIR/claudetop-engine"
ENGINE_DEST="/usr/local/bin/claudetop-engine"
DASHBOARD_DEST="/usr/local/bin/claudetop-dashboard"
if [ -f "$ENGINE_SRC" ]; then
  if [ -w "$(dirname "$ENGINE_DEST")" ]; then
    cp "$ENGINE_SRC" "$ENGINE_DEST"
    chmod +x "$ENGINE_DEST"
    cp "$SCRIPT_DIR/claudetop-dashboard" "$DASHBOARD_DEST"
    chmod +x "$DASHBOARD_DEST"
  else
    echo "  Installing engine + dashboard (requires sudo)..."
    sudo cp "$ENGINE_SRC" "$ENGINE_DEST"
    sudo chmod +x "$ENGINE_DEST"
    sudo cp "$SCRIPT_DIR/claudetop-dashboard" "$DASHBOARD_DEST"
    sudo chmod +x "$DASHBOARD_DEST"
  fi
  echo "  Installed claudetop-engine -> $ENGINE_DEST"
  echo "  Installed claudetop-dashboard -> $DASHBOARD_DEST"
fi

# 9. Install iTerm2 prompt hook
ITERM_HOOK_SRC="$SCRIPT_DIR/claudetop-iterm-hook.sh"
ITERM_HOOK_DEST="$HOME/.claude/claudetop-iterm-hook.sh"
if [ -f "$ITERM_HOOK_SRC" ]; then
  cp "$ITERM_HOOK_SRC" "$ITERM_HOOK_DEST"
  chmod +x "$ITERM_HOOK_DEST"
  echo "  Installed iTerm2 hook -> $ITERM_HOOK_DEST"

  # Auto-source in shell profile if CLAUDETOP_ITERM is set
  SOURCE_LINE="[ -n \"\${CLAUDETOP_ITERM:-}\" ] && source \"$ITERM_HOOK_DEST\""
  SHELL_RC=""
  if [ -n "${ZSH_VERSION:-}" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
  elif [ -f "$HOME/.bash_profile" ]; then
    SHELL_RC="$HOME/.bash_profile"
  elif [ -f "$HOME/.bashrc" ]; then
    SHELL_RC="$HOME/.bashrc"
  fi

  if [ -n "$SHELL_RC" ] && ! grep -q "claudetop-iterm-hook" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# claudetop iTerm2 integration (tab title, badge, background color)" >> "$SHELL_RC"
    echo "$SOURCE_LINE" >> "$SHELL_RC"
    echo "  Added iTerm2 hook to $SHELL_RC"
  else
    echo "  iTerm2 hook already in shell profile (skipped)"
  fi
fi

# 10. Copy pricing updater + fetch initial pricing
UPDATER_DEST="$HOME/.claude/update-claudetop-pricing.sh"
cp "$SCRIPT_DIR/update-pricing.sh" "$UPDATER_DEST"
chmod +x "$UPDATER_DEST"
cp "$SCRIPT_DIR/pricing.json" "$HOME/.claude/claudetop-pricing.json"
echo "  Installed pricing updater + initial pricing"

# Try to fetch latest pricing now
"$UPDATER_DEST" 2>/dev/null || true

# 11. Set up daily pricing update (cron job at 6am)
CRON_CMD="0 6 * * * $UPDATER_DEST >/dev/null 2>&1"
if ! crontab -l 2>/dev/null | grep -q "update-claudetop-pricing"; then
  (crontab -l 2>/dev/null || true; echo "$CRON_CMD") | crontab -
  echo "  Added daily pricing update cron (6am)"
else
  echo "  Daily pricing cron already configured (skipped)"
fi

echo ""
echo "Done! Restart Claude Code to activate claudetop."
echo ""
echo "Optional config (add to env or ~/.bashrc):"
echo "  export CLAUDETOP_DAILY_BUDGET=50    # Daily budget alert"
echo "  export CLAUDETOP_THEME=minimal      # compact|minimal|full"
echo "  export CLAUDETOP_TAG=my-feature     # Tag sessions for tracking"
echo "  export CLAUDETOP_ITERM=all          # iTerm2: title + badge + bgcolor + statusbar"
echo ""
echo "Plan usage (subscribers): 5h / 7d / per-model windows + credits"
echo "  claudetop-usage --show   # Bars for every window, % used, % left, reset time"
echo "  export CLAUDETOP_USAGE=off          # Hide the plan line"
echo ""
echo "View analytics:"
echo "  claudetop-stats          # Today (from hook history)"
echo "  claudetop-stats week     # This week"
echo "  claudetop-stats all      # All time"
echo ""
echo "Deep analytics (scans ALL session files, per-turn, subagents):"
echo "  claudetop-engine scan    # Scan all JSONL -> SQLite"
echo "  claudetop-engine today   # Today from SQLite"
echo "  claudetop-engine stats   # All-time deep stats"
echo "  claudetop-dashboard      # Live web dashboard at localhost:8080"
echo ""
echo "Enable more plugins:"
echo "  cp $PLUGIN_DIR/_examples/spotify.sh $PLUGIN_DIR/"
echo "  cp $PLUGIN_DIR/_examples/gh-ci-status.sh $PLUGIN_DIR/"
echo "  cp $PLUGIN_DIR/_examples/meeting-countdown.sh $PLUGIN_DIR/"
