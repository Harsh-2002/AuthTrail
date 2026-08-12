#!/bin/sh
# test-unified-purpose.sh - canonical logging, purpose persistence, and CLI filters.
# shellcheck disable=SC2034 # AUTH_TRAIL_*/EV_* values are consumed by sourced components.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

AUTH_TRAIL_LOG_DIR="$TMPD/log"
AUTH_TRAIL_RUN_DIR="$TMPD/run"
AUTH_TRAIL_HOSTNAME=testhost
AUTH_TRAIL_ENVIRONMENT='test'
AUTH_TRAIL_SLACK_ENABLED=0
AUTH_TRAIL_PURPOSE_ENABLED=1
AUTH_TRAIL_PURPOSE_REQUIRED=1
AUTH_TRAIL_PURPOSE_MIN_LENGTH=5
AUTH_TRAIL_PURPOSE_MAX_LENGTH=500
AUTHTRAIL_LIB="$REPO_DIR/src/libauthtrail.sh"
AUTHTRAIL_SELFTEST=1
# shellcheck disable=SC1090
. "$REPO_DIR/src/authtraild"
# shellcheck disable=SC1090
. "$REPO_DIR/src/authtrailctl"

ensure_log_files
assert_eq 'readable runtime policy exposes fail mode only' 'closed' \
    "$(jq -r '.fail_mode' "$AUTH_TRAIL_RUN_DIR/purpose/policy.json")"
sid=testhost-session-1
atomic_write "$AUTH_TRAIL_RUN_DIR/sessions/$sid" "session_id=$sid
identity=alice@example.com
fingerprint=SHA256:test
auth_method=publickey
login_user=root
source_ip=10.20.30.40
source_port=53281
server_ip=10.20.30.10
server_port=22
tty=/dev/pts/1
sshd_pid=1234
start_epoch=$(epoch_now)
interactive=1
purpose_required=1
purpose_state=pending
purpose=
purpose_recorded_at=
login_slack_sent=0"
atomic_write "$(conn_ip_key 10.20.30.40 53281)" "session_id=$sid"

token=0123456789abcdef0123456789abcdef
query=$(jq -nc --arg token "$token" \
    '{action:"query",token:$token,source_ip:"10.20.30.40",source_port:"53281",tty:"/dev/pts/1"}')
handle_purpose_event "$query"

response_path_file="$AUTH_TRAIL_RUN_DIR/purpose/$token.json"
assert_eq 'purpose query is required' 'required' "$(jq -r '.status' "$response_path_file")"
assert_eq 'purpose query uses existing session' "$sid" "$(jq -r '.session_id' "$response_path_file")"
assert_eq 'required event is canonical JSONL' 'ssh.session.purpose.required' "$(jq -r '.event' "$AUTH_TRAIL_LOG_DIR/events.jsonl")"

# shellcheck disable=SC2016 # Literal command syntax must remain inert purpose text.
literal_purpose='Review $(touch /tmp/authtrail-must-not-run) safely'
submit=$(jq -nc --arg token "$token" --arg purpose "$literal_purpose" \
    '{action:"submit",token:$token,purpose:$purpose}')
handle_purpose_event "$submit"

assert_eq 'purpose submit is acknowledged' 'recorded' "$(jq -r '.status' "$response_path_file")"
assert_eq 'purpose is stored literally' "$literal_purpose" "$(kv_get "$AUTH_TRAIL_RUN_DIR/sessions/$sid" purpose)"
assert_false 'command-like purpose is never executed' test -e /tmp/authtrail-must-not-run
assert_eq 'recorded event is in canonical log' 'ssh.session.purpose.recorded' "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r '.event')"
assert_eq 'environment is present in canonical schema' 'test' "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r '.environment')"

now=$(epoch_now)
kv_set "$AUTH_TRAIL_RUN_DIR/sessions/$sid" start_epoch "$((now - 120))"
kv_set "$AUTH_TRAIL_RUN_DIR/sessions/$sid" access_start_epoch "$((now - 65))"
atomic_write "$(conn_pid_key 1234)" "session_id=$sid"
atomic_write "$AUTH_TRAIL_RUN_DIR/tty/pts_1" "session_id=$sid
current_user=root"
handle_session_close 1234 pam_session_closed
handle_session_close 1234 sshd_process_reaped
end_count=$(jq -Rr 'fromjson? | select(.event == "ssh.session.end") | .event' \
    "$AUTH_TRAIL_LOG_DIR/events.jsonl" | wc -l | tr -d ' ')
assert_eq 'duplicate close observations emit one end event' 1 "$end_count"
end_event=$(jq -Rrc 'fromjson? | select(.event == "ssh.session.end")' \
    "$AUTH_TRAIL_LOG_DIR/events.jsonl")
assert_eq 'end event records active-shell duration' 65 "$(printf '%s' "$end_event" | jq -r .active_duration_seconds)"
assert_eq 'end event retains total connection duration' 120 "$(printf '%s' "$end_event" | jq -r .duration_seconds)"
assert_eq 'end event records observed close source' pam_session_closed "$(printf '%s' "$end_event" | jq -r .closure_source)"
assert_false 'closed session runtime state is removed' test -e "$AUTH_TRAIL_RUN_DIR/sessions/testhost-session-1"

for legacy in authentication sessions commands privilege purpose delivery; do
    assert_false "legacy $legacy log is not created" test -e "$AUTH_TRAIL_LOG_DIR/$legacy.jsonl"
done

printf '%s\n' '{malformed trailing input' >>"$AUTH_TRAIL_LOG_DIR/events.jsonl"
purpose_output=$(tail_events_matching '(.event | startswith("ssh.session.purpose."))' 20)
assert_contains 'purpose filter reads canonical log' "$purpose_output" 'ssh.session.purpose.recorded'
assert_not_contains 'purpose filter ignores malformed input' "$purpose_output" 'malformed'

test_summary
