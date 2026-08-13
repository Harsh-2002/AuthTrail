#!/bin/sh
# uninstall.sh - removes AuthTrail. Preserves logs/config by default (--purge deletes them); only touches the guarded block install.sh added.

set -eu
umask 022

PROGRAM='uninstall.sh'
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-auditd.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-pam.sh"

PREFIX_SBIN=/usr/local/sbin
PREFIX_LIB=/usr/local/lib/authtraild
ATCTL_PATH=/usr/local/sbin/atctl
CONF_DIR=/etc/authtraild
LOG_DIR=/var/log/authtraild
RUN_DIR=/run/authtraild
DATA_DIR=/var/lib/authtraild
SSHD_DROPIN=/etc/ssh/sshd_config.d/90-authtraild.conf
SYSTEMD_UNIT=/etc/systemd/system/authtraild.service
LOGROTATE_FILE=/etc/logrotate.d/authtraild
AUDIT_RULES_FILE=/etc/audit/rules.d/90-authtraild.rules
BASHRC_FILE=/etc/bash.bashrc
BASH_HOOK_MARK_BEGIN='# BEGIN AUTHTRAIL COMMAND HOOK - managed by install.sh, do not edit by hand'
BASH_HOOK_MARK_END='# END AUTHTRAIL COMMAND HOOK'
PROFILE_HOOK=/etc/profile.d/91-authtrail-session.sh
PAM_SUDO_FILE=/etc/pam.d/sudo
PAM_SUDO_I_FILE=/etc/pam.d/sudo-i
PAM_SU_FILE=/etc/pam.d/su

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *)
            printf '%s: unknown argument: %s\n' "$PROGRAM" "$arg" >&2
            exit 2
            ;;
    esac
done

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
warn() { printf '%s: WARNING: %s\n' "$PROGRAM" "$*" >&2; }

[ "$(id -u)" -eq 0 ] || {
    printf '%s: must be run as root\n' "$PROGRAM" >&2
    exit 1
}

# --- Stop and disable the service -------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop authtraild 2>/dev/null || :
    systemctl disable authtraild 2>/dev/null || :
fi

# --- Remove the systemd unit --------------------------------------------------

if [ -f "$SYSTEMD_UNIT" ]; then
    rm -f "$SYSTEMD_UNIT"
    log "removed $SYSTEMD_UNIT"
fi

# --- Remove SSH drop-in, validate, reload only if the result is valid --------

if [ -f "$SSHD_DROPIN" ]; then
    rm -f "$SSHD_DROPIN"
    log "removed $SSHD_DROPIN"

    if command -v sshd >/dev/null 2>&1; then
        if sshd -t; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn 'could not reload sshd - reload it manually'
        else
            warn 'sshd -t failed after removing the AuthTrail drop-in - investigate before reloading sshd; it has NOT been reloaded'
        fi
    fi
fi

# --- Remove auditd rules ---------------------------------------------------------

if [ -f "$AUDIT_RULES_FILE" ]; then
    if authtrail_audit_rules_file_is_managed "$AUDIT_RULES_FILE"; then
        disable_authtrail_audit_rules "$AUDIT_RULES_FILE"
        log "removed AuthTrail-managed $AUDIT_RULES_FILE"
    else
        warn "$AUDIT_RULES_FILE is customized; leaving it and active audit configuration unchanged"
    fi
fi

# --- Remove the global bash hook (only our own guarded block) -------------------

if [ -f "$BASHRC_FILE" ] && grep -q "$BASH_HOOK_MARK_BEGIN" "$BASHRC_FILE" 2>/dev/null; then
    awk -v b="$BASH_HOOK_MARK_BEGIN" -v e="$BASH_HOOK_MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$BASHRC_FILE" >"${BASHRC_FILE}.authtrail-tmp"
    mv -f "${BASHRC_FILE}.authtrail-tmp" "$BASHRC_FILE"
    log "removed AuthTrail block from $BASHRC_FILE"
fi

if [ -f "$PROFILE_HOOK" ]; then
    rm -f "$PROFILE_HOOK"
    log "removed $PROFILE_HOOK"
fi

for pam_file in "$PAM_SUDO_FILE" "$PAM_SUDO_I_FILE" "$PAM_SU_FILE"; do
    if [ -f "$pam_file" ] && pam_file_has_hook "$pam_file"; then
        pam_tmp=$(mktemp /etc/pam.d/.authtrail-remove.XXXXXX)
        pam_file_remove_hook "$pam_file" "$pam_tmp" || warn "could not remove AuthTrail hook from $pam_file"
        rm -f "$pam_tmp"
        log "removed AuthTrail hook from $pam_file"
    fi
done

# --- Remove binaries/library ------------------------------------------------------

rm -f "$PREFIX_SBIN/authtraild" "$PREFIX_SBIN/authtrailctl"
if [ -L "$ATCTL_PATH" ] && [ "$(readlink "$ATCTL_PATH" 2>/dev/null || :)" = 'authtrailctl' ]; then
    rm -f "$ATCTL_PATH"
fi
rm -rf "$PREFIX_LIB"
log 'removed binaries and library'

command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload

# --- Logs / config: preserved unless --purge --------------------------------------

if [ "$PURGE" -eq 1 ]; then
    rm -rf "$LOG_DIR" "$CONF_DIR"
    rm -f "$LOGROTATE_FILE"
    log "purged $LOG_DIR, $CONF_DIR and $LOGROTATE_FILE"
else
    log "preserved $LOG_DIR, $CONF_DIR and $LOGROTATE_FILE (re-run with --purge to remove them)"
fi

rm -rf "$RUN_DIR"
rm -rf "$DATA_DIR/slack-queue"
rmdir "$DATA_DIR" 2>/dev/null || :

log 'uninstall complete'
