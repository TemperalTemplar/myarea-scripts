#!/usr/bin/env bash
# rc_dm_poller.sh
# Poll Rocket.Chat for unread DMs and light each recipient's platform bell.
# Reads ONLY unread counts (never message content) from RC Mongo.
# Dedups via Redis so a standing-unread DM notifies once, not every cycle.
#
# Run on a timer (~every 60s).
set -euo pipefail

AGG="http://localhost:8930/api/notifications/push"   # aggregator (inside myarea-ai net, but we curl via container)
SERVICE_KEY="$(grep -E '^SERVICE_API_KEY=' /home/temp/myarea-ai/.env | cut -d= -f2-)"

# 1. Pull DM subscriptions with unread > 0:  owner_username <TAB> with_name <TAB> unread <TAB> roomId
ROWS="$(snap run rocketchat-server.mongo parties --quiet --eval '
  db.rocketchat_subscription.find(
    { t: "d", unread: { $gt: 0 } },
    { "u.username": 1, name: 1, unread: 1, rid: 1 }
  ).forEach(function(s){
    if (s.u && s.u.username) {
      print(s.u.username + "\t" + (s.name||"someone") + "\t" + (s.unread||0) + "\t" + (s.rid||""));
    }
  });
')"

[ -z "$ROWS" ] && exit 0

while IFS=$'\t' read -r owner withname unread rid; do
  [ -z "$owner" ] && continue
  lowner="$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')"

  # resolve owner username -> authentik sub
  sub="$(docker exec myarea-ai-redis redis-cli HGET rc:user_subs "$lowner")"
  [ -z "$sub" ] && continue   # user not synced yet; skip

  # dedup: only notify if unread count went UP since last time we saw this room
  seen_key="rc:dm_seen:${lowner}:${rid}"
  last="$(docker exec myarea-ai-redis redis-cli GET "$seen_key" 2>/dev/null || echo 0)"
  [ -z "$last" ] && last=0
  if [ "$unread" -le "$last" ]; then
    continue   # no new messages since last notify
  fi

  # push to the bell
  docker exec myarea-ai-redis sh -c "true"  # ensure container reachable
  curl -s -X POST "$AGG" \
    -H "Content-Type: application/json" \
    -H "X-Service-Key: ${SERVICE_KEY}" \
    -d "{\"recipient\":\"${sub}\",\"actor\":\"${withname}\",\"type\":\"chat_dm\",\"app\":\"chat\",\"title\":\"New message from ${withname}\",\"body\":\"You have ${unread} unread in Rocket.Chat\",\"url\":\"https://rocket.wrds361.com\"}" >/dev/null 2>&1 || true

  # remember the count we just notified at
  docker exec myarea-ai-redis redis-cli SET "$seen_key" "$unread" EX 604800 >/dev/null
done <<< "$ROWS"
