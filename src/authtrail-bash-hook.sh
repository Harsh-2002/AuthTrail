#!/bin/bash
# authtrail-bash-hook.sh - the one intentionally Bash-specific component (section 6). Sourced from /etc/bash.bashrc only - never change shell options here.

_authtrail_bash_hook()
{
    local ec=$?

    command -v jq >/dev/null 2>&1 || return "$ec"
    command -v logger >/dev/null 2>&1 || return "$ec"

    local hist_line hist_num hist_cmd
    hist_line=$(HISTTIMEFORMAT='' builtin history 1 2>/dev/null)
    read -r hist_num hist_cmd <<<"$hist_line"

    # First firing in a new shell sees a stale HISTFILE entry, not anything typed here - seed the baseline instead of logging it.
    if [ -z "${_AUTHTRAIL_LAST_HISTNUM+set}" ]; then
        _AUTHTRAIL_LAST_HISTNUM=$hist_num
        return "$ec"
    fi

    # Only log once per new history entry - otherwise a blank Enter re-logs the previous command.
    if [ -z "$hist_num" ] || [ "$hist_num" = "$_AUTHTRAIL_LAST_HISTNUM" ]; then
        return "$ec"
    fi
    _AUTHTRAIL_LAST_HISTNUM=$hist_num

    [ -n "$hist_cmd" ] || return "$ec"

    local tty
    tty=$(command tty 2>/dev/null)
    case "$tty" in
        '' | 'not a tty') return "$ec" ;;
    esac

    local cwd user json
    cwd=$PWD
    user=$(id -un 2>/dev/null)

    json=$(jq -nc \
        --arg tty "$tty" \
        --arg user "$user" \
        --arg cwd "$cwd" \
        --arg command "$hist_cmd" \
        --arg exit_code "$ec" \
        --arg pid "$$" \
        '{tty:$tty, user:$user, cwd:$cwd, command:$command, exit_code:$exit_code, pid:$pid}' 2>/dev/null)

    if [ -n "$json" ]; then
        logger -t authtrail-command -- "$json" 2>/dev/null
    fi

    return "$ec"
}

# Prepends to string or array PROMPT_COMMAND without removing existing prompt hooks.
if declare -p PROMPT_COMMAND 2>/dev/null | grep -q '^declare -a'; then
    _authtrail_pc_found=0
    for _authtrail_pc_item in "${PROMPT_COMMAND[@]}"; do
        if [[ "$_authtrail_pc_item" == *'_authtrail_bash_hook'* ]]; then
            _authtrail_pc_found=1
            break
        fi
    done
    if [ "$_authtrail_pc_found" -eq 0 ]; then
        PROMPT_COMMAND=('_authtrail_bash_hook' "${PROMPT_COMMAND[@]}")
    fi
    unset _authtrail_pc_found _authtrail_pc_item
else
    # shellcheck disable=SC2128,SC2178 # Runtime declare check above separates array and scalar forms.
    case "${PROMPT_COMMAND:-}" in
        *_authtrail_bash_hook*) : ;;
        '') PROMPT_COMMAND='_authtrail_bash_hook' ;;
        *) PROMPT_COMMAND="_authtrail_bash_hook;${PROMPT_COMMAND}" ;;
    esac
fi
