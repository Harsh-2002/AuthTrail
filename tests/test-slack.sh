#!/bin/sh
# test-slack.sh - Block Kit payload shape for each message builder (no network - see docs/operations.md for the live webhook pass).

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

payload_is_valid_json()
{
    printf '%s' "$1" | jq -e . >/dev/null 2>&1
}

nonempty()
{
    [ -n "$1" ] && [ "$1" != 'null' ]
}

sample_event='{"hostname":"testhost","environment":"production","identity":"alice@example.com","login_user":"root","source_ip":"10.20.30.40","auth_method":"publickey","tty":"/dev/pts/0","key_fingerprint":"SHA256:abc","session_id":"testhost-1","timestamp":"2026-08-12T17:20:31+05:30","current_user":"support","from_user":"root","to_user":"support","command":"su support","purpose":"Production maintenance","active_duration_seconds":3725,"duration_seconds":3730,"closure_source":"pam_session_closed","attempt_count":8,"window_seconds":300,"attempted_users":["root","admin"]}'

for builder in build_login_slack_payload build_logout_slack_payload build_failure_slack_payload build_burst_slack_payload build_privilege_slack_payload build_purpose_slack_payload; do
    payload=$("$builder" "$sample_event")
    assert_true "$builder produces valid JSON" payload_is_valid_json "$payload"
    text=$(printf '%s' "$payload" | jq -r '.text')
    assert_true "$builder has a usable text fallback" nonempty "$text"
    blocks_type=$(printf '%s' "$payload" | jq -r '.blocks | type')
    assert_eq "$builder blocks is an array" 'array' "$blocks_type"
done

sensitive_payload=$(build_sensitive_command_slack_payload 'testhost' 'alice@example.com' 'root' '/dev/pts/0' 'useradd evil')
assert_true 'build_sensitive_command_slack_payload produces valid JSON' payload_is_valid_json "$sensitive_payload"

special_event=$(jq -nc '{hostname:"testhost", identity:"weird \" < > & \n name", login_user:"root", source_ip:"1.2.3.4", auth_method:"publickey", tty:"/dev/pts/0"}')
payload=$(build_login_slack_payload "$special_event")
assert_true 'special characters in identity still produce valid JSON (section 43.12)' payload_is_valid_json "$payload"

AUTH_TRAIL_SLACK_PROFILE=actionable
AUTH_TRAIL_SLACK_LOGIN=1
AUTH_TRAIL_SLACK_LOGOUT=1
AUTH_TRAIL_SLACK_FAILURE=1
AUTH_TRAIL_SLACK_FAILURE_BURST=1
AUTH_TRAIL_SLACK_PRIVILEGE=1
AUTH_TRAIL_SLACK_COMMAND_ALERTS=0
AUTH_TRAIL_SLACK_INCLUDE_PURPOSE=1
assert_false 'actionable profile suppresses pre-purpose session start' slack_enabled_for ssh.session.start
assert_true 'actionable profile sends interactive session end when dispatched' slack_enabled_for ssh.session.end
assert_false 'actionable profile suppresses individual auth failure' slack_enabled_for ssh.auth.failure
assert_true 'actionable profile sends a failure burst' slack_enabled_for ssh.auth.failure_burst
assert_true 'actionable profile sends a privilege transition' slack_enabled_for privilege.transition
assert_true 'actionable profile sends a purpose-confirmed session' slack_enabled_for ssh.session.purpose.recorded

AUTH_TRAIL_SLACK_PROFILE=verbose
assert_true 'verbose profile sends session start' slack_enabled_for ssh.session.start
assert_true 'verbose profile sends session end' slack_enabled_for ssh.session.end
assert_true 'verbose profile sends individual auth failure' slack_enabled_for ssh.auth.failure

unsafe_purpose_event=$(jq -nc '{hostname:"testhost", environment:"production", identity:"alice", login_user:"root", source_ip:"1.2.3.4", auth_method:"publickey", session_id:"s1", timestamp:"now", purpose:"Deploy <!channel> & verify <https://example.invalid>"}')
unsafe_payload=$(build_purpose_slack_payload "$unsafe_purpose_event")
assert_eq 'purpose is rendered as plain text, not Slack markup' 'plain_text' "$(printf '%s' "$unsafe_payload" | jq -r '.blocks[] | select(.text.type? == "plain_text") | .text.type')"
assert_false 'fallback text escapes a channel mention' grep -q '<!channel>' <<EOF
$(printf '%s' "$unsafe_payload" | jq -r '.text')
EOF

for builder in build_login_slack_payload build_logout_slack_payload build_burst_slack_payload build_privilege_slack_payload build_purpose_slack_payload; do
    payload=$("$builder" "$sample_event")
    assert_false "$builder omits environment badge" grep -q 'production' <<EOF
$payload
EOF
done
logout_payload=$(build_logout_slack_payload "$sample_event")
assert_contains 'logout payload shows human active duration' "$logout_payload" '1h 2m 5s'
assert_contains 'logout payload retains session correlation' "$logout_payload" 'testhost-1'

test_summary
