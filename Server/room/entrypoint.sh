#!/bin/sh
# Maps environment variables to azahar-room arguments.
set -e
set -- --room-name "${ROOM_NAME:-Bifold Room}" \
       --room-description "${ROOM_DESCRIPTION:-}" \
       --port "${ROOM_PORT:-24872}" \
       --max_members "${ROOM_MAX_MEMBERS:-16}" \
       --preferred-app "${ROOM_PREFERRED_APP:-Any}" \
       --preferred-app-id "${ROOM_PREFERRED_APP_ID:-0}" \
       --ban-list-file /home/room/banlist.txt \
       --log-file /home/room/room.log
[ -n "$ROOM_PASSWORD" ] && set -- "$@" --password "$ROOM_PASSWORD"
if [ -n "$LOBBY_URL" ] && [ -n "$LOBBY_TOKEN" ]; then
  set -- "$@" --web-api-url "$LOBBY_URL" --username "${LOBBY_USERNAME:-room}" --token "$LOBBY_TOKEN"
fi
# azahar-room reads commands from stdin; keep it open so the room does not spin on EOF.
tail -f /dev/null | exec azahar-room "$@"
