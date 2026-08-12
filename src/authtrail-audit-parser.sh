#!/bin/sh
# authtrail-audit-parser.sh - converts auditd records into audit.exec events (section 18). Run on demand/cron, not a continuous follower. Needs kernel audit access (see docs/operations.md).
# shellcheck disable=SC2034 # EV_* fields are consumed by build_event_json() in the sourced libauthtrail.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$SCRIPT_DIR/libauthtrail.sh" ]; then
    AUTHTRAIL_LIB="$SCRIPT_DIR/libauthtrail.sh"
elif [ -f /usr/local/lib/authtraild/libauthtrail.sh ]; then
    AUTHTRAIL_LIB=/usr/local/lib/authtraild/libauthtrail.sh
else
    printf 'authtrail-audit-parser: cannot locate libauthtrail.sh\n' >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$AUTHTRAIL_LIB"

load_config
require_runtime

SINCE='recent'
if [ "${1:-}" = '--since' ] && [ -n "${2:-}" ]; then
    SINCE=$2
fi

if [ "$AUTH_TRAIL_AUDITD_ENABLED" != '1' ]; then
    exit 0
fi

if ! have_cmd ausearch; then
    log_stderr 'ausearch not available; auditd evidence layer inactive on this host'
    exit 0
fi

ensure_log_files

# Extracts pid/exe/argv from ausearch -i's interpreted type=SYSCALL/type=EXECVE lines - not a full replay of every audit field.
ausearch -k authtrail-exec -ts "$SINCE" -i 2>/dev/null | awk '
    /^type=SYSCALL/ {
        pid = ""; exe = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^pid=/) { split($i, a, "="); pid = a[2] }
            if ($i ~ /^exe=/) { split($i, a, "="); exe = a[2]; gsub(/"/, "", exe) }
        }
    }
    /^type=EXECVE/ {
        argv = ""
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^a[0-9]+=/) {
                split($i, a, "=")
                val = a[2]
                gsub(/"/, "", val)
                argv = (argv == "") ? val : argv " " val
            }
        }
        if (pid != "" && argv != "") {
            printf "%s\037%s\037%s\n", pid, exe, argv
        }
    }
' | while IFS="$(printf '\037')" read -r a_pid a_exe a_argv; do
    # 0x1F not tab: tab is always "IFS whitespace" to `read` and would collapse an empty exe field.
    [ -n "$a_pid" ] || continue

    EV_EVENT='audit.exec'
    EV_PID=$a_pid
    EV_COMMAND=$(truncate_command "$(redact_command "$a_argv")")
    EV_EXTRA_JSON=$(jq -nc --arg exe "$a_exe" '{exe: ($exe | select(. != "") // null)}')
    emit_event >/dev/null
done

log_stderr 'audit sync complete'
