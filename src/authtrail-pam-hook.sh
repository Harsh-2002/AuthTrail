#!/bin/sh
# authtrail-pam-hook.sh - reports successful PAM-backed sudo/su session transitions to authtraild.

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

case "${PAM_SERVICE:-}" in
    sudo | sudo-i | su | su-l) ;;
    *) exit 0 ;;
esac

case "${PAM_TYPE:-}" in
    open_session | close_session) ;;
    *) exit 0 ;;
esac

from_user=${PAM_RUSER:-${SUDO_USER:-}}
to_user=${PAM_USER:-}
[ -n "$to_user" ] || exit 0
[ -z "$from_user" ] || [ "$from_user" != "$to_user" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0
command -v logger >/dev/null 2>&1 || exit 0

event_json=$(jq -nc \
    --arg action "$PAM_TYPE" \
    --arg service "$PAM_SERVICE" \
    --arg from_user "$from_user" \
    --arg to_user "$to_user" \
    --arg tty "${PAM_TTY:-}" \
    --arg rhost "${PAM_RHOST:-}" \
    --arg command "${SUDO_COMMAND:-}" \
    --arg pid "$PPID" \
    '{action:$action,service:$service,from_user:$from_user,to_user:$to_user,
      tty:$tty,rhost:$rhost,command:$command,pid:$pid}' 2>/dev/null) || exit 0

logger -t authtrail-privilege -- "$event_json" 2>/dev/null || :
exit 0
