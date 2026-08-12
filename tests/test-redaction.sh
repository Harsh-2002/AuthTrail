#!/bin/sh
# test-redaction.sh - redact_command(), truncate_command(), is_sensitive_command().
# shellcheck disable=SC2034 # AUTH_TRAIL_* vars below are read by the sourced libauthtrail.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

AUTH_TRAIL_REDACT_SECRETS=1
AUTH_TRAIL_REDACT_FILE="$REPO_DIR/config/redact.conf"
AUTH_TRAIL_SENSITIVE_COMMANDS="$REPO_DIR/config/sensitive-commands.conf"

result=$(redact_command 'curl -H "Authorization: Bearer abc123secret" https://api.example.com')
assert_not_contains 'Bearer token value is redacted' "$result" 'abc123secret'
assert_contains 'redaction marker present for Bearer token' "$result" '[REDACTED]'

result=$(redact_command 'mysql -uroot --password=hunter2 db')
assert_not_contains 'password= value is redacted' "$result" 'hunter2'

result=$(redact_command 'export API_KEY=sk-live-deadbeef')
assert_not_contains 'API_KEY= value is redacted' "$result" 'sk-live-deadbeef'

result=$(redact_command 'export AWS_SECRET_ACCESS_KEY=abcdefghijklmnop')
assert_not_contains 'AWS_SECRET_ACCESS_KEY= value is redacted' "$result" 'abcdefghijklmnop'

result=$(redact_command 'ls -la /var/log')
assert_eq 'commands without secrets pass through unchanged' 'ls -la /var/log' "$result"

AUTH_TRAIL_COMMAND_MAX_LEN=10
result=$(truncate_command 'abcdefghijklmnop')
assert_eq 'long commands are truncated to the configured max length' 'abcdefghij' "$result"
AUTH_TRAIL_COMMAND_MAX_LEN=8192

assert_true 'sudo is classified as sensitive' is_sensitive_command 'sudo -i'
assert_true 'useradd is classified as sensitive' is_sensitive_command 'useradd evil'
assert_false 'ls is not classified as sensitive' is_sensitive_command 'ls -la'

test_summary
