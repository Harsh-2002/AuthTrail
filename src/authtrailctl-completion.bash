# authtrailctl Bash completion. Uses Bash builtins plus AuthTrail's required
# jq/coreutils commands; it does not depend on the bash-completion package.

_authtrailctl_session_ids()
{
    local run_dir log_file f
    run_dir=${AUTHTRAIL_COMPLETION_RUN_DIR:-/run/authtraild}
    log_file=${AUTHTRAIL_COMPLETION_LOG_FILE:-/var/log/authtraild/events.jsonl}

    if [[ -d $run_dir/sessions ]]; then
        for f in "$run_dir"/sessions/*; do
            [[ -e $f ]] || continue
            printf '%s\n' "${f##*/}"
        done
    fi

    if [[ -r $log_file ]]; then
        tail -n 5000 "$log_file" 2>/dev/null |
            jq -Rr 'fromjson? | .session_id? // empty' 2>/dev/null |
            sort -u
    fi
}

_authtrailctl_fingerprints()
{
    local key_map
    key_map=${AUTHTRAIL_COMPLETION_KEY_MAP:-/etc/authtraild/keys.map}
    [[ -r $key_map ]] || return 0
    awk -F '|' '!/^#/ && NF >= 2 { print $1 }' "$key_map" 2>/dev/null
}

_authtrailctl_complete()
{
    local cur command candidates candidate
    COMPREPLY=()
    cur=${COMP_WORDS[COMP_CWORD]}

    if (( COMP_CWORD == 1 )); then
        candidates='status test test-slack index-keys sessions recent recent-auth recent-commands recent-purpose purpose-status session identity verify version help --help -h'
        while IFS= read -r candidate; do
            COMPREPLY+=("$candidate")
        done < <(compgen -W "$candidates" -- "$cur")
        return 0
    fi

    command=${COMP_WORDS[1]}
    case "$command" in
        recent | recent-auth | recent-commands | recent-purpose)
            if (( COMP_CWORD == 2 )); then
                while IFS= read -r candidate; do
                    COMPREPLY+=("$candidate")
                done < <(compgen -W '--json --jsonl 10 20 50 100 200 500' -- "$cur")
            fi
            ;;
        session)
            if (( COMP_CWORD == 2 )); then
                while IFS= read -r candidate; do
                    COMPREPLY+=("$candidate")
                done < <(compgen -W "--json $(_authtrailctl_session_ids)" -- "$cur")
            elif (( COMP_CWORD == 3 )) && [[ ${COMP_WORDS[2]} == --json ]]; then
                while IFS= read -r candidate; do
                    COMPREPLY+=("$candidate")
                done < <(compgen -W "$(_authtrailctl_session_ids)" -- "$cur")
            fi
            ;;
        identity)
            if (( COMP_CWORD == 2 )); then
                while IFS= read -r candidate; do
                    COMPREPLY+=("$candidate")
                done < <(compgen -W "$(_authtrailctl_fingerprints)" -- "$cur")
            fi
            ;;
    esac
}

complete -F _authtrailctl_complete authtrailctl atctl
