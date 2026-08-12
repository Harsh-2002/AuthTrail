#!/bin/sh
# authtrail-session-hook.sh - /etc/profile.d/91-authtrail-session.sh. Dot-sourced at login only - never `exit` or change shell options here. See docs/architecture.md.

if [ -z "${SSH_CONNECTION:-}" ]; then
    return 0
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v logger >/dev/null 2>&1; then
    return 0
fi

if [ -z "${AUTHTRAIL_SESSION_INIT_DONE:-}" ]; then
    _at_tty=${SSH_TTY:-}

    if [ -n "$_at_tty" ]; then
        _at_client_ip=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f1)
        _at_client_port=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f2)
        _at_server_ip=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f3)
        _at_server_port=$(printf '%s' "$SSH_CONNECTION" | cut -d ' ' -f4)
        _at_user=${USER:-${LOGNAME:-}}

        _at_msg=$(jq -nc \
            --arg tty "$_at_tty" \
            --arg source_ip "$_at_client_ip" \
            --arg source_port "$_at_client_port" \
            --arg server_ip "$_at_server_ip" \
            --arg server_port "$_at_server_port" \
            --arg user "$_at_user" \
            '{tty:$tty, source_ip:$source_ip, source_port:$source_port, server_ip:$server_ip, server_port:$server_port, user:$user}' 2>/dev/null)

        if [ -n "$_at_msg" ]; then
            logger -t authtrail-session -- "$_at_msg" 2>/dev/null
        fi

        unset _at_client_ip _at_client_port _at_server_ip _at_server_port _at_user _at_msg
    fi

    unset _at_tty

    AUTHTRAIL_SESSION_INIT_DONE=1
    export AUTHTRAIL_SESSION_INIT_DONE
fi

if [ -z "${AUTHTRAIL_PURPOSE_DONE:-}" ] && [ -n "${SSH_TTY:-}" ] && [ -t 0 ] && [ -t 1 ]; then
    if [ -x /usr/local/lib/authtraild/authtrail-purpose.sh ]; then
        if /usr/local/lib/authtraild/authtrail-purpose.sh; then
            AUTHTRAIL_PURPOSE_DONE=1
            export AUTHTRAIL_PURPOSE_DONE
        else
            exit 1
        fi
    fi
fi
