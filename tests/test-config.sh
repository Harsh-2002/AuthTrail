#!/bin/sh
# test-config.sh - config ownership/mode gate and validate_config().
# shellcheck disable=SC2034 # AUTH_TRAIL_* vars below are read by the sourced libauthtrail.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

good="$TMPD/good.conf"
: >"$good"
chmod 600 "$good"
if [ "$(id -u)" -eq 0 ]; then
    assert_true 'accepts root-owned 0600 file' config_owner_and_mode_ok "$good"
else
    skip 'accepts root-owned 0600 file (requires root to create a root-owned file)'
fi

bad_mode="$TMPD/bad-mode.conf"
: >"$bad_mode"
chmod 644 "$bad_mode"
assert_false 'rejects world-readable 0644 file' config_owner_and_mode_ok "$bad_mode"

assert_false 'rejects missing file' config_owner_and_mode_ok "$TMPD/does-not-exist.conf"

AUTH_TRAIL_ENABLED=1
AUTH_TRAIL_COMMAND_CAPTURE=1
AUTH_TRAIL_REDACT_SECRETS=1
AUTH_TRAIL_AUDITD_ENABLED=1
AUTH_TRAIL_FAILURE_BURST_ENABLED=1
AUTH_TRAIL_SLACK_ENABLED=0
AUTH_TRAIL_SLACK_PROFILE=actionable
AUTH_TRAIL_SLACK_LOGIN=1
AUTH_TRAIL_SLACK_LOGOUT=1
AUTH_TRAIL_SLACK_FAILURE=1
AUTH_TRAIL_SLACK_FAILURE_BURST=1
AUTH_TRAIL_SLACK_PRIVILEGE=1
AUTH_TRAIL_SLACK_COMMAND_ALERTS=0
AUTH_TRAIL_COMMAND_MAX_LEN=8192
AUTH_TRAIL_SLACK_TIMEOUT=5
AUTH_TRAIL_FAILURE_BURST_WINDOW=300
AUTH_TRAIL_FAILURE_BURST_THRESHOLD=5
AUTH_TRAIL_FAILURE_BURST_COOLDOWN=600
AUTH_TRAIL_LOG_MODE=0640
assert_true 'validate_config accepts a well-formed config' validate_config

AUTH_TRAIL_SLACK_PROFILE=noisy
assert_false 'validate_config rejects an unknown Slack profile' validate_config
AUTH_TRAIL_SLACK_PROFILE=actionable

AUTH_TRAIL_PURPOSE_FAIL_MODE=invalid
assert_false 'validate_config rejects invalid purpose fail mode' validate_config
AUTH_TRAIL_PURPOSE_FAIL_MODE=closed

AUTH_TRAIL_PURPOSE_MIN_LENGTH=501
AUTH_TRAIL_PURPOSE_MAX_LENGTH=500
assert_false 'validate_config rejects inverted purpose lengths' validate_config
AUTH_TRAIL_PURPOSE_MIN_LENGTH=5

AUTH_TRAIL_ENABLED=maybe
assert_false 'validate_config rejects a non-boolean flag' validate_config
AUTH_TRAIL_ENABLED=1

AUTH_TRAIL_COMMAND_MAX_LEN=notanumber
assert_false 'validate_config rejects a non-numeric value' validate_config
AUTH_TRAIL_COMMAND_MAX_LEN=8192

AUTH_TRAIL_LOG_MODE=9999
assert_false 'validate_config rejects an invalid octal log mode' validate_config
AUTH_TRAIL_LOG_MODE=0640

test_summary
