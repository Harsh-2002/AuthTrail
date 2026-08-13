#!/bin/sh
# test-pam-privilege.sh - immediate PAM transitions and managed PAM edits.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-pam.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

pam_file="$TMPD/sudo"
printf '%s\n' '#%PAM-1.0' '@include common-session-noninteractive' >"$pam_file"
pam_file_install_hook "$pam_file" "$TMPD/edit"
assert_true 'PAM hook is installed' pam_file_has_hook "$pam_file"
pam_file_install_hook "$pam_file" "$TMPD/edit"
assert_eq 'PAM hook installation is idempotent' 1 "$(grep -Fxc "$AUTHTRAIL_PAM_LINE" "$pam_file")"
printf '%s\n' "$AUTHTRAIL_PAM_LEGACY_LINE" >>"$pam_file"
pam_file_install_hook "$pam_file" "$TMPD/edit"
assert_false 'legacy non-root PAM hook is removed on upgrade' grep -Fqx "$AUTHTRAIL_PAM_LEGACY_LINE" "$pam_file"
pam_file_remove_hook "$pam_file" "$TMPD/remove"
assert_false 'PAM hook is removed without touching other rules' pam_file_has_hook "$pam_file"
assert_true 'existing PAM content is preserved' grep -Fq '@include common-session-noninteractive' "$pam_file"

AUTHTRAIL_SELFTEST=1
AUTHTRAIL_LIB="$REPO_DIR/src/libauthtrail.sh"
export AUTHTRAIL_SELFTEST AUTHTRAIL_LIB
# shellcheck disable=SC1090
. "$REPO_DIR/src/authtraild"

privilege_fact_process_valid()
{
    return 0
}

AUTH_TRAIL_RUN_DIR="$TMPD/run"
AUTH_TRAIL_LOG_DIR="$TMPD/log"
# shellcheck disable=SC2034 # consumed by sourced Slack helpers when enabled.
AUTH_TRAIL_DATA_DIR="$TMPD/data"
AUTH_TRAIL_HOSTNAME=testhost
AUTH_TRAIL_ENVIRONMENT='test'
AUTH_TRAIL_SLACK_ENABLED=0
mkdir -p "$AUTH_TRAIL_RUN_DIR/sessions" "$AUTH_TRAIL_RUN_DIR/tty" "$AUTH_TRAIL_RUN_DIR/privilege" "$AUTH_TRAIL_LOG_DIR"
sid=testhost-session
sfile="$AUTH_TRAIL_RUN_DIR/sessions/$sid"
tfile="$AUTH_TRAIL_RUN_DIR/tty/$(tty_key /dev/pts/1)"
atomic_write "$sfile" "session_id=$sid
identity=alice@example.com
fingerprint=SHA256:test
login_user=alice
source_ip=192.0.2.10
source_port=50000
tty=/dev/pts/1"
atomic_write "$tfile" "session_id=$sid
identity=alice@example.com
fingerprint=SHA256:test
login_user=alice
current_user=alice
tty=/dev/pts/1
last_command="

sudo_open=$(jq -nc '{action:"open_session",service:"sudo",from_user:"alice",to_user:"root",tty:"/dev/pts/1",command:"/bin/bash",pid:"101"}')
handle_privilege_event "$sudo_open"
assert_eq 'PAM success emits transition immediately' 'alice->root' "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r '.from_user+"->"+.to_user')"
assert_eq 'PAM evidence is explicit' pam "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r .evidence)"
event_count=$(wc -l <"$AUTH_TRAIL_LOG_DIR/events.jsonl" | tr -d ' ')
handle_privilege_event "$sudo_open"
assert_eq 'duplicate PAM open is deduplicated' "$event_count" "$(wc -l <"$AUTH_TRAIL_LOG_DIR/events.jsonl" | tr -d ' ')"

su_open=$(jq -nc '{action:"open_session",service:"su",from_user:"root",to_user:"service",tty:"/dev/pts/1",command:"",pid:"102"}')
handle_privilege_event "$su_open"
assert_eq 'nested transition keeps the correct chain' 'root->service' "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r '.from_user+"->"+.to_user')"

su_close=$(jq -nc '{action:"close_session",service:"su",from_user:"root",to_user:"service",tty:"/dev/pts/1",command:"",pid:"102"}')
handle_privilege_event "$su_close"
assert_eq 'return from nested shell is immediate' 'service->root' "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r '.from_user+"->"+.to_user')"

classify_access_change 'sudo usermod -aG wheel alice'
assert_eq 'identity-management commands are critical changes' identity_or_group "$ACCESS_CHANGE_TYPE"
assert_eq 'identity-management classification is stable' identity_or_group "$ACCESS_CHANGE_TYPE"
classify_access_change 'printf key >> /home/alice/.ssh/authorized_keys'
assert_eq 'authorized_keys writes are critical changes' access_configuration "$ACCESS_CHANGE_TYPE"
assert_eq 'access-file classification is stable' access_configuration "$ACCESS_CHANGE_TYPE"
assert_false 'ordinary reads do not become critical changes' classify_access_change 'cat /etc/ssh/sshd_config'

test_summary
