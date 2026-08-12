#!/bin/sh
# install-auditd.sh - auditd installation policy helpers shared by installer tests.

auditd_setting_from_config()
{
    config_file=$1
    default_value=${2:-0}
    value=''

    if [ -r "$config_file" ]; then
        value=$(awk -F= '
            /^AUTH_TRAIL_AUDITD_ENABLED=/ {
                value=$2
                gsub(/[[:space:]'"'"']/, "", value)
            }
            END { print value }
        ' "$config_file")
    fi

    case "$value" in
        0 | 1) printf '%s' "$value" ;;
        '') printf '%s' "$default_value" ;;
        *) return 1 ;;
    esac
}

authtrail_audit_rules_file_is_managed()
{
    rules_file=$1
    [ -f "$rules_file" ] || return 1
    grep -Eq '^# AuthTrail (auditd rules fragment|opt-in auditd rules)' "$rules_file" || return 1
    rule_count=$(awk '!/^[[:space:]]*(#|$)/ { count++ } END { print count+0 }' "$rules_file")
    [ "$rule_count" -eq 2 ] || return 1
    grep -Fqx -- '-a always,exit -F arch=b64 -S execve,execveat -k authtrail-exec' "$rules_file" || return 1
    grep -Fqx -- '-a always,exit -F arch=b32 -S execve,execveat -k authtrail-exec' "$rules_file"
}

unload_authtrail_audit_rules()
{
    command -v auditctl >/dev/null 2>&1 || return 0
    auditctl -d always,exit -F arch=b64 -S execve,execveat -k authtrail-exec >/dev/null 2>&1 || :
    auditctl -d always,exit -F arch=b32 -S execve,execveat -k authtrail-exec >/dev/null 2>&1 || :
}

load_authtrail_audit_rules()
{
    command -v auditctl >/dev/null 2>&1 || return 1
    if auditctl -l 2>/dev/null | grep -q 'authtrail-exec'; then
        return 0
    fi
    auditctl -a always,exit -F arch=b64 -S execve,execveat -k authtrail-exec >/dev/null 2>&1 || return 1
    if ! auditctl -a always,exit -F arch=b32 -S execve,execveat -k authtrail-exec >/dev/null 2>&1; then
        auditctl -d always,exit -F arch=b64 -S execve,execveat -k authtrail-exec >/dev/null 2>&1 || :
        return 1
    fi
}

disable_authtrail_audit_rules()
{
    rules_file=$1
    [ -f "$rules_file" ] || return 0
    authtrail_audit_rules_file_is_managed "$rules_file" || return 2
    rm -f "$rules_file" || return 1
    unload_authtrail_audit_rules
}
