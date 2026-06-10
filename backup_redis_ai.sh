#!/usr/bin/env bash
# Backup myarea-ai-redis (conversation history, journals, sessions).
# Triggers a fresh save, copies the RDB out, keeps 7 days.
set -euo pipefail
DEST=/home/temp/backups/redis-ai
mkdir -p "$DEST"
STAMP="$(date +%Y%m%d-%H%M%S)"

# Force a fresh point-in-time save inside the container
docker exec myarea-ai-redis redis-cli SAVE >/dev/null

# Copy the dump out
docker cp myarea-ai-redis:/data/dump.rdb "$DEST/dump-$STAMP.rdb"

# Keep only the last 7 daily backups
ls -1t "$DEST"/dump-*.rdb | tail -n +8 | xargs -r rm -f

echo "$(date -Is) redis-ai backup: dump-$STAMP.rdb ($(du -h "$DEST/dump-$STAMP.rdb" | cut -f1))"
