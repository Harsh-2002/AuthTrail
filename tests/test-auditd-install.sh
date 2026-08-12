#!/bin/sh
# test-auditd-install.sh - auditd is opt-in and disabled installs never reload global rules.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-auditd.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

missing_config="$TMPD/missing.conf"
assert_eq 'fresh install defaults auditd to disabled' 0 \
    "$(auditd_setting_from_config "$missing_config" 0)"
assert_true 'shipped configuration disables auditd' grep -q \
    '^AUTH_TRAIL_AUDITD_ENABLED=0$' "$REPO_DIR/config/authtraild.conf"

conflicting_flags_are_rejected()
{
    "$REPO_DIR/install.sh" --enable-auditd --disable-auditd >/dev/null 2>&1
    [ "$?" -eq 2 ]
}
assert_true 'installer rejects conflicting auditd flags before mutation' conflicting_flags_are_rejected

disabled_config="$TMPD/disabled.conf"
printf '%s\n' 'AUTH_TRAIL_AUDITD_ENABLED=0' >"$disabled_config"
assert_eq 'reads disabled setting' 0 "$(auditd_setting_from_config "$disabled_config" 0)"

enabled_config="$TMPD/enabled.conf"
printf '%s\n' "AUTH_TRAIL_AUDITD_ENABLED='1'" >"$enabled_config"
assert_eq 'reads quoted enabled setting' 1 "$(auditd_setting_from_config "$enabled_config" 0)"

invalid_config="$TMPD/invalid.conf"
printf '%s\n' 'AUTH_TRAIL_AUDITD_ENABLED=yes' >"$invalid_config"
assert_false 'rejects invalid auditd setting' auditd_setting_from_config "$invalid_config" 0

managed_rules="$TMPD/managed.rules"
cp "$REPO_DIR/audit/authtraild.rules" "$managed_rules"
assert_true 'recognizes unmodified AuthTrail rules' authtrail_audit_rules_file_is_managed "$managed_rules"

custom_rules="$TMPD/custom.rules"
cp "$managed_rules" "$custom_rules"
printf '%s\n' '-w /etc/passwd -p wa -k custom-rule' >>"$custom_rules"
assert_false 'does not claim customized audit rules' authtrail_audit_rules_file_is_managed "$custom_rules"

fake_bin="$TMPD/bin"
mkdir "$fake_bin"
command_log="$TMPD/commands.log"
# shellcheck disable=SC2016 # write literal variables into the fake command script
printf '%s\n' '#!/bin/sh' \
    'printf '\''auditctl %s\n'\'' "$*" >>"$AUTHTRAIL_TEST_COMMAND_LOG"' \
    'if [ "$1" = "-l" ]; then exit 0; fi' >"$fake_bin/auditctl"
# shellcheck disable=SC2016 # write literal variables into the fake command script
printf '%s\n' '#!/bin/sh' \
    'printf '\''augenrules %s\n'\'' "$*" >>"$AUTHTRAIL_TEST_COMMAND_LOG"' >"$fake_bin/augenrules"
chmod +x "$fake_bin/auditctl" "$fake_bin/augenrules"
AUTHTRAIL_TEST_COMMAND_LOG=$command_log
export AUTHTRAIL_TEST_COMMAND_LOG

absent_rules="$TMPD/absent.rules"
PATH="$fake_bin:$PATH" disable_authtrail_audit_rules "$absent_rules"
assert_false 'disabled fresh install invokes no audit commands' test -e "$command_log"

PATH="$fake_bin:$PATH" disable_authtrail_audit_rules "$managed_rules"
assert_false 'disabled upgrade removes AuthTrail-managed rule file' test -e "$managed_rules"
assert_contains 'disabled upgrade unloads tagged b64 rule' "$(cat "$command_log")" 'arch=b64'
assert_contains 'disabled upgrade unloads tagged b32 rule' "$(cat "$command_log")" 'arch=b32'
assert_not_contains 'disabled upgrade never reloads global audit configuration' "$(cat "$command_log")" 'augenrules'

assert_false 'disabled install preserves customized audit file' disable_authtrail_audit_rules "$custom_rules"
assert_true 'customized audit file remains byte-present' test -f "$custom_rules"

: >"$command_log"
PATH="$fake_bin:$PATH" load_authtrail_audit_rules
assert_contains 'enabled install adds tagged b64 rule only' "$(cat "$command_log")" 'auditctl -a always,exit -F arch=b64'
assert_contains 'enabled install adds tagged b32 rule only' "$(cat "$command_log")" 'auditctl -a always,exit -F arch=b32'
assert_not_contains 'enabled install never reloads global audit configuration' "$(cat "$command_log")" 'augenrules'

test_summary
