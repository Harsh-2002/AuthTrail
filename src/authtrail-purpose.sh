#!/bin/sh
# authtrail-purpose.sh - mandatory interactive SSH access justification helper.

set -u

RUN_DIR=${AUTH_TRAIL_RUN_DIR:-/run/authtraild}
DISABLE_FILE=/etc/authtraild/disable-purpose
TOKEN=''
RESPONSE=''

is_interactive_ssh()
{
    [ -n "${SSH_CONNECTION:-}" ] &&
    [ -n "${SSH_TTY:-}" ] &&
    [ -t 0 ] &&
    [ -t 1 ]
}

send_abort()
{
    reason=$1
    [ -n "$TOKEN" ] || return 0
    msg=$(jq -nc --arg token "$TOKEN" --arg reason "$reason" \
        '{action:"abort",token:$token,reason:$reason}') || return 0
    logger -t authtrail-purpose -- "$msg" 2>/dev/null || :
}

abort_signal()
{
    trap - HUP INT TERM
    send_abort input_aborted
    printf '\nAuthTrail: access justification was not recorded; closing this interactive session.\n' >&2
    exit 1
}

wait_for_status()
{
    unwanted=$1
    attempts=0
    while [ "$attempts" -lt 100 ]; do
        if [ -r "$RESPONSE" ]; then
            response_json=$(sed -n '1p' "$RESPONSE" 2>/dev/null)
            response_status=$(printf '%s' "$response_json" | jq -r '.status // empty' 2>/dev/null)
            if [ -n "$response_status" ] && [ "$response_status" != "$unwanted" ]; then
                printf '%s' "$response_json"
                return 0
            fi
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    return 1
}

clear_screen()
{
    printf '\033[2J\033[H'
}

# Values displayed here ultimately originate in SSH/key metadata. Keep control
# bytes from becoming terminal control sequences; the durable event retains the
# original value unchanged.
safe_display()
{
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | cut -c 1-160
}

fail_mode_without_daemon()
{
    if [ -r "$RUN_DIR/purpose/policy.json" ]; then
        jq -r '.fail_mode // "closed"' "$RUN_DIR/purpose/policy.json" 2>/dev/null || printf 'closed'
    else
        printf 'closed'
    fi
}

draw_prompt()
{
    hostname_value=$(safe_display "$1")
    identity_value=$(safe_display "$2")
    account_value=$(safe_display "$3")
    source_value=$(safe_display "$4")
    auth_value=$(safe_display "$5")
    error_value=$6

    if [ "$fullscreen" = 'true' ] && [ "${TERM:-dumb}" != 'dumb' ]; then
        clear_screen
        printf '\033[1;36mAUTHTRAIL\033[0m  \033[2mSSH ACCESS\033[0m\n'
        printf '%s\n\n' '────────────────────────────────────────────────────────────'
        printf '\033[1mAccess justification required\033[0m\n'
        printf '%s\n\n' 'This system requires an auditable reason for interactive access.'
        printf '  %-18s \033[1m%s\033[0m\n' 'Server' "$hostname_value"
        printf '  %-18s \033[1m%s\033[0m\n' 'Verified identity' "$identity_value"
        printf '  %-18s %s\n' 'Linux account' "$account_value"
        printf '  %-18s %s via %s\n' 'Connection' "$source_value" "$auth_value"
        printf '\n\033[1mProvide a justification or ticket reference.\033[0m\n'
        printf '%s\n' 'Examples: CHG-1042 - deploy release 4.2; INC-2048 - investigate outage; routine maintenance.'
        printf '\033[2mThe justification is recorded in the server audit trail.\033[0m\n'
        if [ -n "$error_value" ]; then
            printf '\n\033[1;31m%s\033[0m\n' "$(safe_display "$error_value")"
        fi
        printf '\n\033[1mJustification\033[0m \033[2m(%s-%s characters)\033[0m\n' "$min_length" "$max_length"
    else
        printf '%s\n' 'AuthTrail - access justification required'
        printf 'Server: %s\nVerified identity: %s\nLinux account: %s\nConnection: %s via %s\n' \
            "$hostname_value" "$identity_value" "$account_value" "$source_value" "$auth_value"
        printf '\nProvide a justification or ticket reference (%s-%s characters).\n' "$min_length" "$max_length"
        printf '%s\n' 'Example: INC-2048 - investigate outage. This is recorded in the audit trail.'
        [ -z "$error_value" ] || printf '%s\n' "$error_value"
    fi
    printf '> '
}

is_interactive_ssh || exit 0
[ ! -e "$DISABLE_FILE" ] || exit 0
[ -z "${AUTHTRAIL_PURPOSE_DONE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 1
command -v logger >/dev/null 2>&1 || exit 1

TOKEN=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
[ "${#TOKEN}" -eq 32 ] || exit 1
RESPONSE="$RUN_DIR/purpose/$TOKEN.json"

source_ip=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f1)
source_port=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f2)
query=$(jq -nc --arg token "$TOKEN" --arg source_ip "$source_ip" \
    --arg source_port "$source_port" --arg tty "$SSH_TTY" \
    '{action:"query",token:$token,source_ip:$source_ip,source_port:$source_port,tty:$tty}') || exit 1
logger -t authtrail-purpose -- "$query" 2>/dev/null || exit 1

response=$(wait_for_status '') || {
    if [ "$(fail_mode_without_daemon)" = 'open' ]; then
        printf 'AuthTrail: purpose service did not respond; shell allowed by fail-open policy.\n' >&2
        exit 0
    fi
    printf 'AuthTrail: purpose service did not respond; closing this interactive session.\n' >&2
    exit 1
}
status=$(printf '%s' "$response" | jq -r '.status // "error"')
case "$status" in
    recorded | skipped) exit 0 ;;
    required) ;;
    *)
        fail_mode=$(printf '%s' "$response" | jq -r '.fail_mode // "closed"')
        if [ "$fail_mode" = 'open' ]; then
            printf 'AuthTrail: purpose service unavailable; shell allowed by fail-open policy.\n' >&2
            exit 0
        fi
        printf 'AuthTrail: purpose could not be initialized; closing this interactive session.\n' >&2
        exit 1
        ;;
esac

session_id=$(printf '%s' "$response" | jq -r '.session_id')
hostname_value=$(printf '%s' "$response" | jq -r '.hostname')
identity_value=$(printf '%s' "$response" | jq -r '.identity')
account_value=$(printf '%s' "$response" | jq -r '.account')
source_value=$(printf '%s' "$response" | jq -r '.source')
auth_value=$(printf '%s' "$response" | jq -r '.auth_method')
min_length=$(printf '%s' "$response" | jq -r '.min_length')
max_length=$(printf '%s' "$response" | jq -r '.max_length')
fullscreen=$(printf '%s' "$response" | jq -r '.fullscreen')
clear_after=$(printf '%s' "$response" | jq -r '.clear_after')

trap abort_signal HUP INT TERM
error_value=''
while :; do
    draw_prompt "$hostname_value" "$identity_value" "$account_value" "$source_value" "$auth_value" "$error_value"
    if ! IFS= read -r purpose; then
        abort_signal
    fi
    purpose=$(printf '%s' "$purpose" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    purpose_length=$(printf '%s' "$purpose" | wc -m | tr -d ' ')
    case "$purpose_length" in '' | *[!0-9]*) purpose_length=0 ;; esac
    if [ "$purpose_length" -lt "$min_length" ]; then
        error_value="Justification must contain at least $min_length characters."
        continue
    fi
    if [ "$purpose_length" -gt "$max_length" ]; then
        error_value="Justification must contain no more than $max_length characters."
        continue
    fi
    break
done

submit=$(jq -nc --arg token "$TOKEN" --arg purpose "$purpose" \
    '{action:"submit",token:$token,purpose:$purpose}') || abort_signal
logger -t authtrail-purpose -- "$submit" 2>/dev/null || abort_signal
recorded=$(wait_for_status required) || abort_signal
recorded_status=$(printf '%s' "$recorded" | jq -r '.status // "error"')
[ "$recorded_status" = 'recorded' ] || abort_signal
trap - HUP INT TERM

if [ "$clear_after" = 'true' ] && [ "${TERM:-dumb}" != 'dumb' ]; then
    clear_screen
fi
safe_session_id=$(safe_display "$session_id")
safe_purpose=$(safe_display "$purpose")
if [ "${TERM:-dumb}" != 'dumb' ]; then
    printf '\033[1;32mJustification recorded. Access granted.\033[0m\n'
else
    printf 'Justification recorded. Access granted.\n'
fi
printf 'Justification: %s\nSession: %s\nReview: atctl session %s\n\n' \
    "$safe_purpose" "$safe_session_id" "$safe_session_id"
exit 0
