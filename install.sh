#!/bin/sh
# install.sh - installs AuthTrail (docs/operations.md has the full workflow). Never reloads sshd without sshd -t passing first. Idempotent - safe to re-run.

set -eu
umask 022

PROGRAM='install.sh'
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-platform.sh"

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

SLACK_WEBHOOK=''
SLACK_WEBHOOK_SUPPLIED=0
SLACK_ROLLBACK=''
INSTALL_COMPLETE=0
for arg in "$@"; do
    case "$arg" in
        --force-bash-hook) : ;;
        --slack-webhook=*)
            SLACK_WEBHOOK=${arg#--slack-webhook=}
            SLACK_WEBHOOK_SUPPLIED=1
            ;;
        *)
            printf '%s: unknown argument: %s\n' "$PROGRAM" "$arg" >&2
            exit 2
            ;;
    esac
done

cleanup_install()
{
    if [ "$INSTALL_COMPLETE" -eq 0 ] && [ -n "$SLACK_ROLLBACK" ] && [ -f "$SLACK_ROLLBACK" ]; then
        install -m 0600 -o root -g root "$SLACK_ROLLBACK" "$CONF_DIR/authtraild.conf" 2>/dev/null || :
        rm -f "$SLACK_ROLLBACK"
    fi
}
trap cleanup_install EXIT

log() { printf '%s: %s\n' "$PROGRAM" "$*"; }
warn() { printf '%s: WARNING: %s\n' "$PROGRAM" "$*" >&2; }
die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die 'must be run as root'

if [ -e "$ATCTL_PATH" ] || [ -L "$ATCTL_PATH" ]; then
    if [ ! -L "$ATCTL_PATH" ] || [ "$(readlink "$ATCTL_PATH" 2>/dev/null || :)" != 'authtrailctl' ]; then
        die "$ATCTL_PATH already exists and is not managed by AuthTrail; refusing to overwrite it"
    fi
fi

# --- OS / prerequisite detection -------------------------------------------

detect_supported_platform || die 'unsupported Linux distribution (supported: Debian/Ubuntu, RHEL-family, Fedora)'

report_missing_prerequisites()
{
    [ -n "$missing_commands" ] || return 0
    printf '%s: missing required commands: %s\n' "$PROGRAM" "$missing_commands" >&2
    printf '%s: install the prerequisites, then re-run this same command:\n' "$PROGRAM" >&2
    printf '    %s %s\n' "$(package_install_command)" "$missing_packages" >&2
    exit 1
}

missing_commands=''
missing_packages=''
for c in systemctl journalctl sshd ssh-keygen bash jq awk sed grep cut tr date \
    hostname logger ps stat install mktemp od find sort getent tail wc chmod chown readlink ln \
    cp mv rm sleep dirname id; do
    if ! command -v "$c" >/dev/null 2>&1; then
        missing_commands="${missing_commands}${missing_commands:+ }$c"
        package=$(package_for_command "$c")
        case " $missing_packages " in
            *" $package "*) ;;
            *) missing_packages="${missing_packages}${missing_packages:+ }$package" ;;
        esac
    fi
done
report_missing_prerequisites

slack_transport_required=0
if slack_transport_required "$SLACK_WEBHOOK_SUPPLIED" "$CONF_DIR/authtraild.conf"; then
    slack_transport_required=1
fi
if [ "$slack_transport_required" -eq 1 ] && ! command -v curl >/dev/null 2>&1; then
    missing_commands='curl'
    missing_packages=$(package_for_command curl)
    report_missing_prerequisites
fi

if [ "$SLACK_WEBHOOK_SUPPLIED" -eq 1 ]; then
    if ! valid_slack_webhook_url "$SLACK_WEBHOOK"; then
        die 'invalid Slack Incoming Webhook URL (expected HTTPS with a /services/... path)'
    fi
fi

AUDITD_AVAILABLE=0
if command -v auditctl >/dev/null 2>&1; then
    AUDITD_AVAILABLE=1
else
    warn "auditd/auditctl not found - optional process-execution evidence is inactive (install with: $(package_install_command) auditd)"
fi

LOGROTATE_AVAILABLE=0
command -v logrotate >/dev/null 2>&1 && LOGROTATE_AVAILABLE=1

backup_if_exists()
{
    f=$1
    if [ -e "$f" ] && [ ! -e "${f}.authtrail-bak" ]; then
        cp -p "$f" "${f}.authtrail-bak"
        log "backed up $f -> ${f}.authtrail-bak"
    fi
}

install_template_if_absent()
{
    src=$1
    dst=$2
    mode=$3
    if [ -e "$dst" ]; then
        log "$dst already exists, leaving it in place"
    else
        install -m "$mode" -o root -g root "$src" "$dst"
        log "installed $dst"
    fi
}

# --- Directories -------------------------------------------------------------

install -d -m 0750 -o root -g root "$CONF_DIR"
install -d -m 0750 -o root -g root "$LOG_DIR"
install -d -m 0711 -o root -g root "$RUN_DIR"
install -d -m 0700 -o root -g root "$DATA_DIR" "$DATA_DIR/slack-queue" \
    "$DATA_DIR/slack-queue/pending" "$DATA_DIR/slack-queue/processing"
install -d -m 0755 -o root -g root "$PREFIX_LIB"

# --- Binaries + library -------------------------------------------------------

backup_if_exists "$PREFIX_SBIN/authtraild"
install -m 0750 -o root -g root "$REPO_DIR/src/authtraild" "$PREFIX_SBIN/authtraild"

backup_if_exists "$PREFIX_SBIN/authtrailctl"
install -m 0750 -o root -g root "$REPO_DIR/src/authtrailctl" "$PREFIX_SBIN/authtrailctl"
ln -sfn authtrailctl "$ATCTL_PATH"

install -m 0640 -o root -g root "$REPO_DIR/src/libauthtrail.sh" "$PREFIX_LIB/libauthtrail.sh"
install -m 0750 -o root -g root "$REPO_DIR/src/authtrail-session-hook.sh" "$PREFIX_LIB/authtrail-session-hook.sh"
install -m 0755 -o root -g root "$REPO_DIR/src/authtrail-bash-hook.sh" "$PREFIX_LIB/authtrail-bash-hook.sh"
install -m 0750 -o root -g root "$REPO_DIR/src/authtrail-audit-parser.sh" "$PREFIX_LIB/authtrail-audit-parser.sh"
install -m 0755 -o root -g root "$REPO_DIR/src/authtrail-purpose.sh" "$PREFIX_LIB/authtrail-purpose.sh"
install -m 0644 -o root -g root "$REPO_DIR/src/authtrailctl-completion.bash" "$PREFIX_LIB/authtrailctl-completion.bash"

log 'installed binaries and library'

# --- Config templates (never overwrite existing operator config) -------------

install_template_if_absent "$REPO_DIR/config/authtraild.conf" "$CONF_DIR/authtraild.conf" 0600
install_template_if_absent "$REPO_DIR/config/keys.map" "$CONF_DIR/keys.map" 0644
install_template_if_absent "$REPO_DIR/config/redact.conf" "$CONF_DIR/redact.conf" 0644
install_template_if_absent "$REPO_DIR/config/sensitive-commands.conf" "$CONF_DIR/sensitive-commands.conf" 0644
backup_if_exists "$CONF_DIR/authtraild.conf"

append_config_default()
{
    name=$1
    value=$2
    if ! grep -q "^${name}=" "$CONF_DIR/authtraild.conf" 2>/dev/null; then
        migration_tmp=$(mktemp "$CONF_DIR/.authtraild.conf.migrate.XXXXXX")
        cp -p "$CONF_DIR/authtraild.conf" "$migration_tmp"
        printf '%s=%s\n' "$name" "$value" >>"$migration_tmp"
        install -m 0600 -o root -g root "$migration_tmp" "$CONF_DIR/authtraild.conf"
        rm -f "$migration_tmp"
    fi
}

append_config_default AUTH_TRAIL_PURPOSE_ENABLED 1
append_config_default AUTH_TRAIL_PURPOSE_REQUIRED 1
append_config_default AUTH_TRAIL_PURPOSE_MIN_LENGTH 5
append_config_default AUTH_TRAIL_PURPOSE_MAX_LENGTH 500
append_config_default AUTH_TRAIL_PURPOSE_FULLSCREEN 1
append_config_default AUTH_TRAIL_PURPOSE_CLEAR_AFTER 1
append_config_default AUTH_TRAIL_PURPOSE_FAIL_MODE "'closed'"
append_config_default AUTH_TRAIL_SLACK_INCLUDE_PURPOSE 1
append_config_default AUTH_TRAIL_SLACK_PROFILE "'actionable'"
append_config_default AUTH_TRAIL_DATA_DIR "'$DATA_DIR'"
append_config_default AUTH_TRAIL_SLACK_QUEUE_ENABLED 1
append_config_default AUTH_TRAIL_SLACK_QUEUE_MAX 1000
append_config_default AUTH_TRAIL_SLACK_RETRY_MAX 8
chmod 0600 "$CONF_DIR/authtraild.conf"

if [ "$SLACK_WEBHOOK_SUPPLIED" -eq 1 ]; then
    SLACK_ROLLBACK=$(mktemp "$CONF_DIR/.authtraild.conf.pre-slack.XXXXXX")
    cp -p "$CONF_DIR/authtraild.conf" "$SLACK_ROLLBACK"
    config_tmp=$(mktemp "$CONF_DIR/.authtraild.conf.XXXXXX")
    enabled_written=0
    webhook_written=0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        case "$config_line" in
            AUTH_TRAIL_SLACK_ENABLED=*)
                printf '%s\n' 'AUTH_TRAIL_SLACK_ENABLED=1' >>"$config_tmp"
                enabled_written=1
                ;;
            AUTH_TRAIL_SLACK_WEBHOOK_URL=*)
                printf "AUTH_TRAIL_SLACK_WEBHOOK_URL='%s'\n" "$SLACK_WEBHOOK" >>"$config_tmp"
                webhook_written=1
                ;;
            *) printf '%s\n' "$config_line" >>"$config_tmp" ;;
        esac
    done <"$CONF_DIR/authtraild.conf"
    [ "$enabled_written" -eq 1 ] || printf '%s\n' 'AUTH_TRAIL_SLACK_ENABLED=1' >>"$config_tmp"
    [ "$webhook_written" -eq 1 ] || printf "AUTH_TRAIL_SLACK_WEBHOOK_URL='%s'\n" "$SLACK_WEBHOOK" >>"$config_tmp"
    install -m 0600 -o root -g root "$config_tmp" "$CONF_DIR/authtraild.conf"
    rm -f "$config_tmp"
fi

# --- logrotate -----------------------------------------------------------------

backup_if_exists "$LOGROTATE_FILE"
install -m 0644 -o root -g root "$REPO_DIR/logrotate/authtraild" "$LOGROTATE_FILE"
if [ "$LOGROTATE_AVAILABLE" -eq 0 ]; then
    warn "logrotate is not installed - rotation is inactive (install with: $(package_install_command) logrotate)"
fi

# --- systemd unit ----------------------------------------------------------------

backup_if_exists "$SYSTEMD_UNIT"
install -m 0644 -o root -g root "$REPO_DIR/systemd/authtraild.service" "$SYSTEMD_UNIT"

# --- SSH drop-in - validated before anything is reloaded, aborts on failure ----

SSHD_DROPIN_PREVIOUSLY_EXISTED=0
[ -e "$SSHD_DROPIN" ] && SSHD_DROPIN_PREVIOUSLY_EXISTED=1
backup_if_exists "$SSHD_DROPIN"

install -m 0644 -o root -g root "$REPO_DIR/ssh/90-authtraild.conf" "$SSHD_DROPIN"

if sshd -t; then
    log 'sshd configuration validated'
else
    warn 'sshd -t failed with the AuthTrail drop-in in place; restoring previous configuration'
    if [ "$SSHD_DROPIN_PREVIOUSLY_EXISTED" -eq 1 ]; then
        mv -f "${SSHD_DROPIN}.authtrail-bak" "$SSHD_DROPIN"
    else
        rm -f "$SSHD_DROPIN"
    fi
    die 'aborting install: sshd configuration would not have validated (SSH was never reloaded, nothing else was installed after this point)'
fi

# --- auditd rules (only when auditd is actually usable) -------------------------

if [ "$AUDITD_AVAILABLE" -eq 1 ]; then
    install -d -m 0750 -o root -g root /etc/audit/rules.d
    backup_if_exists "$AUDIT_RULES_FILE"
    install -m 0640 -o root -g root "$REPO_DIR/audit/authtraild.rules" "$AUDIT_RULES_FILE"
    if command -v augenrules >/dev/null 2>&1; then
        if augenrules --load >/dev/null 2>&1; then
            log 'auditd rules loaded'
        else
            warn 'augenrules --load failed - see docs/operations.md (common in containers without kernel audit access)'
        fi
    else
        warn 'augenrules not found - auditd rules were installed but not loaded'
    fi
else
    log 'auditd not available - skipping audit rule installation (see docs/operations.md)'
fi

# --- Global Bash command hook, composed with existing prompt hooks ---------------

BASHRC_ROLLBACK=$(mktemp /etc/.bash.bashrc.authtrail.XXXXXX)
if [ -f "$BASHRC_FILE" ]; then
    cp -p "$BASHRC_FILE" "$BASHRC_ROLLBACK"
else
    : >"$BASHRC_ROLLBACK"
fi

if grep -q "$BASH_HOOK_MARK_BEGIN" "$BASHRC_FILE" 2>/dev/null; then
    awk -v b="$BASH_HOOK_MARK_BEGIN" -v e="$BASH_HOOK_MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$BASHRC_FILE" >"${BASHRC_FILE}.authtrail-tmp"
    mv -f "${BASHRC_FILE}.authtrail-tmp" "$BASHRC_FILE"
else
    backup_if_exists "$BASHRC_FILE"
fi

{
    printf '%s\n' "$BASH_HOOK_MARK_BEGIN"
    # shellcheck disable=SC2016 # single quotes intentional - written verbatim for bash to expand later, not install.sh now
    printf 'if [ -n "${BASH_VERSION:-}" ] && [ -f %s/authtrail-bash-hook.sh ]; then\n' "$PREFIX_LIB"
    printf '    . %s/authtrail-bash-hook.sh\n' "$PREFIX_LIB"
    printf 'fi\n'
    # shellcheck disable=SC2016 # single quotes intentional - written verbatim for Bash to expand later
    printf 'if [ -n "${BASH_VERSION:-}" ] && [ -f %s/authtrailctl-completion.bash ]; then\n' "$PREFIX_LIB"
    printf '    . %s/authtrailctl-completion.bash\n' "$PREFIX_LIB"
    printf 'fi\n'
    printf '%s\n' "$BASH_HOOK_MARK_END"
} >>"$BASHRC_FILE"

if ! bash -n "$BASHRC_FILE"; then
    cp -p "$BASHRC_ROLLBACK" "$BASHRC_FILE"
    rm -f "$BASHRC_ROLLBACK"
    die 'the composed /etc/bash.bashrc failed syntax validation; restored the previous file'
fi
rm -f "$BASHRC_ROLLBACK"
log "installed global Bash command hook and atctl/authtrailctl completion into $BASHRC_FILE without removing existing hooks"

# --- Global SSH session hook -----------------------------------------------------

install -m 0755 -o root -g root "$REPO_DIR/src/authtrail-session-hook.sh" /etc/profile.d/91-authtrail-session.sh
log 'installed session hook into /etc/profile.d/91-authtrail-session.sh'

# --- Self-test, activation --------------------------------------------------------

"$PREFIX_SBIN/authtrailctl" verify || die 'configuration self-test failed'
"$PREFIX_SBIN/authtrailctl" index-keys || die 'automatic SSH key indexing failed'
log 'configuration and identity self-tests passed'

systemctl daemon-reload
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || die 'could not reload sshd'

systemctl enable authtraild >/dev/null
if systemctl is-active authtraild >/dev/null 2>&1; then
    systemctl restart authtraild
else
    systemctl start authtraild
fi

attempt=0
while ! systemctl is-active authtraild >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 20 ] || die 'authtraild did not become active'
    sleep 0.25
done

"$PREFIX_SBIN/authtrailctl" purpose-status || die 'session-purpose self-test failed'

if [ "$SLACK_WEBHOOK_SUPPLIED" -eq 1 ]; then
    rm -f "$SLACK_ROLLBACK"
    SLACK_ROLLBACK=''
    log 'Slack configured; the first eligible AuthTrail event will verify delivery'
fi

# --- Summary ------------------------------------------------------------------------

INSTALL_COMPLETE=1
log 'install complete'
"$PREFIX_SBIN/authtrailctl" status
