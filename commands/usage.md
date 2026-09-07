---
description: Show Claude plan usage windows (5h session, 7d all models, per-model weekly like Fable/Opus/Sonnet, extra-usage credits)
argument-hint: "[--refresh]"
allowed-tools:
  - Bash
---

# claudetop-usage

Show how much of each Claude.ai plan window is used and how much is left, with reset times.

If `--refresh` is passed, force a refetch first; otherwise the cached numbers (refreshed at most every 60s by the status line) are shown.

```bash
if [ "$ARGUMENTS" = "--refresh" ]; then claudetop-usage --refresh; fi
claudetop-usage --show
```

Run the command and display the full formatted output to the user. Do not summarize.
