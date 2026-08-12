#!/bin/sh
# test-json.sh - build_event_json() schema, null-coercion, and safe escaping.
# shellcheck disable=SC2034 # AUTH_TRAIL_*/EV_* vars below are read by the sourced libauthtrail.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

AUTH_TRAIL_HOSTNAME='testhost'
AUTH_TRAIL_ENVIRONMENT='staging'

EV_EVENT='command.executed'
EV_IDENTITY='alice@example.com'
EV_COMMAND='echo "hello \" world" & <script>'
json=$(build_event_json)
clear_event_vars

assert_eq 'schema_version is 1' '1' "$(printf '%s' "$json" | jq -r '.schema_version')"
assert_eq 'event field round-trips' 'command.executed' "$(printf '%s' "$json" | jq -r '.event')"
assert_eq 'environment field round-trips' 'staging' "$(printf '%s' "$json" | jq -r '.environment')"
assert_eq 'unset field becomes null' 'null' "$(printf '%s' "$json" | jq -r '.session_id')"
assert_eq 'special characters survive as valid JSON' 'echo "hello \" world" & <script>' "$(printf '%s' "$json" | jq -r '.command')"

EV_EVENT='ssh.auth.success'
EV_SOURCE_PORT='53281'
json2=$(build_event_json)
clear_event_vars
assert_eq 'numeric field is a JSON number, not a string' 'number' "$(printf '%s' "$json2" | jq -r '.source_port | type')"

EV_EVENT='ssh.auth.failure_burst'
EV_EXTRA_JSON='{"attempt_count":8,"attempted_users":["root","admin"]}'
json3=$(build_event_json)
clear_event_vars
assert_eq 'EV_EXTRA_JSON fields are merged in' '8' "$(printf '%s' "$json3" | jq -r '.attempt_count')"

test_summary
