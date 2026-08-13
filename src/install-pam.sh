#!/bin/sh
# install-pam.sh - safely manages the single AuthTrail PAM session hook line.

AUTHTRAIL_PAM_MARK='# AuthTrail successful privilege transition hook - managed by install.sh'
AUTHTRAIL_PAM_LINE='session optional pam_exec.so /usr/local/lib/authtraild/authtrail-pam-hook.sh'
AUTHTRAIL_PAM_LEGACY_LINE='session optional pam_exec.so seteuid /usr/local/lib/authtraild/authtrail-pam-hook.sh'

pam_file_has_hook()
{
    grep -Fqx "$AUTHTRAIL_PAM_LINE" "$1" 2>/dev/null
}

pam_file_install_hook()
{
    pam_target=$1
    pam_tmp=$2
    [ -f "$pam_target" ] || return 1
    if pam_file_has_hook "$pam_target" && ! grep -Fqx "$AUTHTRAIL_PAM_LEGACY_LINE" "$pam_target" 2>/dev/null; then
        return 0
    fi
    cp -p "$pam_target" "$pam_tmp" || return 1
    awk -v mark="$AUTHTRAIL_PAM_MARK" -v line="$AUTHTRAIL_PAM_LINE" \
        -v legacy="$AUTHTRAIL_PAM_LEGACY_LINE" \
        '$0 != mark && $0 != line && $0 != legacy { print }' "$pam_target" >"$pam_tmp" || return 1
    printf '\n%s\n%s\n' "$AUTHTRAIL_PAM_MARK" "$AUTHTRAIL_PAM_LINE" >>"$pam_tmp" || return 1
    cp -p "$pam_tmp" "$pam_target"
}

pam_file_remove_hook()
{
    pam_target=$1
    pam_tmp=$2
    [ -f "$pam_target" ] || return 0
    awk -v mark="$AUTHTRAIL_PAM_MARK" -v line="$AUTHTRAIL_PAM_LINE" \
        -v legacy="$AUTHTRAIL_PAM_LEGACY_LINE" \
        '$0 != mark && $0 != line && $0 != legacy { print }' "$pam_target" >"$pam_tmp" || return 1
    cp -p "$pam_tmp" "$pam_target"
}
