#!/usr/bin/env bash
# rc_sync_subs.sh
# Sync Rocket.Chat username -> Authentik sub mappings into myarea-ai-redis,
# so the notification receiver + launcher can resolve any RC user to their
# platform sub with zero manual maintenance.
#
# Reads RC's Mongo (parties.users), writes Redis hash  rc:user_subs
# Run on a timer (every few minutes). New RC users appear automatically.
set -euo pipefail

# 1. Pull username -> sub pairs from RC Mongo as TSV (username<TAB>sub)
PAIRS="$(snap run rocketchat-server.mongo parties --quiet --eval '
  db.users.find(
    { "services.authentik.id": { $exists: true }, "type": "user" },
    { username: 1, "services.authentik.id": 1 }
  ).forEach(function(u){
    if (u.username && u.services && u.services.authentik && u.services.authentik.id) {
      print(u.username + "\t" + u.services.authentik.id);
    }
  });
')"

if [ -z "$PAIRS" ]; then
  echo "$(date -Is) rc_sync_subs: no user pairs found; aborting (leaving existing map intact)"
  exit 0
fi

# 2. Write each pair into Redis hash rc:user_subs (lowercased username key)
COUNT=0
while IFS=$'\t' read -r uname sub; do
  [ -z "$uname" ] && continue
  [ -z "$sub" ] && continue
  lname="$(printf '%s' "$uname" | tr '[:upper:]' '[:lower:]')"
  docker exec myarea-ai-redis redis-cli HSET rc:user_subs "$lname" "$sub" >/dev/null
  COUNT=$((COUNT+1))
done <<< "$PAIRS"

echo "$(date -Is) rc_sync_subs: synced $COUNT user(s)"
