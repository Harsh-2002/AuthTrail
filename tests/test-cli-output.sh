#!/bin/sh
# Human-first CLI and explicit structured modes.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
AUTHTRAIL_SELFTEST=1
AUTHTRAIL_LIB="$REPO_DIR/src/libauthtrail.sh"
. "$REPO_DIR/src/authtrailctl"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM
AUTH_TRAIL_LOG_DIR="$TMPD/log"
AUTH_TRAIL_RUN_DIR="$TMPD/run"
mkdir -p "$AUTH_TRAIL_LOG_DIR" "$AUTH_TRAIL_RUN_DIR/sessions" "$AUTH_TRAIL_RUN_DIR/tty"
sid=testhost-session-1
long_identity='root@very-long-operator-name.example.com'
cat >"$AUTH_TRAIL_LOG_DIR/events.jsonl" <<JSON
{"event":"ssh.auth.success","timestamp":"2026-08-12T10:00:00+00:00","hostname":"testhost","session_id":"$sid","identity":"$long_identity","login_user":"root","source_ip":"10.0.0.1","auth_method":"publickey"}
{"event":"ssh.session.start","timestamp":"2026-08-12T10:00:00+00:00","hostname":"testhost","session_id":"$sid","identity":"$long_identity","login_user":"root","source_ip":"10.0.0.1","auth_method":"publickey"}
{"event":"ssh.session.purpose.recorded","timestamp":"2026-08-12T10:00:05+00:00","hostname":"testhost","session_id":"$sid","identity":"$long_identity","login_user":"root","purpose":"CHG-42 deploy release"}
{"event":"command.executed","timestamp":"2026-08-12T10:00:10+00:00","hostname":"testhost","session_id":"$sid","current_user":"root","command":"systemctl status api","exit_code":0}
JSON
now=$(epoch_now)
cat >"$AUTH_TRAIL_RUN_DIR/sessions/$sid" <<STATE
session_id=$sid
identity=$long_identity
login_user=root
source_ip=10.0.0.1
tty=/dev/pts/1
purpose=CHG-42 deploy release
access_start_epoch=$((now - 65))
STATE
cat >"$AUTH_TRAIL_RUN_DIR/tty/pts_1" <<STATE
current_user=root
STATE

COLUMNS=140
wide_sessions=$(cmd_sessions)
assert_contains 'wide session list keeps aligned header' "$wide_sessions" 'SESSION                              IDENTITY'
assert_contains 'wide session list shows active duration' "$wide_sessions" '1m 5s'
assert_contains 'wide session list safely clips long identity' "$wide_sessions" \
    "$(table_cell "$long_identity" 28)"
assert_not_contains 'wide session list does not overflow long identity' "$wide_sessions" "$long_identity"

COLUMNS=80
compact_sessions=$(cmd_sessions)
assert_contains 'narrow session list uses readable labels' "$compact_sessions" "Session:  $sid"
assert_contains 'narrow session list preserves full identity' "$compact_sessions" "Identity: $long_identity"
assert_contains 'narrow session list combines access context' "$compact_sessions" 'Access:   root -> root from 10.0.0.1'
unset COLUMNS

human=$(cmd_session "$sid")
assert_contains 'human session output has clear status' "$human" 'Status:        ACTIVE'
assert_contains 'human session output has justification once in summary' "$human" 'Justification: CHG-42 deploy release'
assert_contains 'human session output has compact command timeline' "$human" 'root$ systemctl status api [exit 0]'
assert_not_contains 'human session output hides null storage fields' "$human" 'key_algorithm'

valid_json()
{
    printf '%s' "$1" | jq -e . >/dev/null 2>&1
}
json=$(cmd_session --json "$sid")
assert_true 'session --json is valid JSON' valid_json "$json"
assert_eq 'session --json retains complete events' 4 "$(printf '%s' "$json" | jq '.events|length')"

recent=$(cmd_recent_view '((.event? // "") == "command.executed")' 20)
assert_contains 'recent human output is event-specific' "$recent" 'root$ systemctl status api'
recent_json=$(cmd_recent_view '((.event? // "") == "command.executed")' --json 20)
assert_eq 'recent --json returns an array' array "$(printf '%s' "$recent_json" | jq -r type)"
recent_jsonl=$(cmd_recent_view '((.event? // "") == "command.executed")' --jsonl 20)
assert_eq 'recent --jsonl preserves compact event objects' command.executed "$(printf '%s' "$recent_jsonl" | jq -r .event)"

test_summary
