#!/bin/sh
# Persistent Slack queue behavior without network access.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
. "$REPO_DIR/src/libauthtrail.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM
AUTH_TRAIL_DATA_DIR="$TMPD/data"
AUTH_TRAIL_LOG_DIR="$TMPD/log"
AUTH_TRAIL_SLACK_ENABLED=1
AUTH_TRAIL_SLACK_QUEUE_ENABLED=1
AUTH_TRAIL_SLACK_QUEUE_MAX=10
AUTH_TRAIL_SLACK_RETRY_MAX=3
AUTH_TRAIL_HOSTNAME=testhost
mkdir -p "$AUTH_TRAIL_LOG_DIR"
: >"$AUTH_TRAIL_LOG_DIR/events.jsonl"

payload='{"text":"test"}'
slack_enqueue ssh.session.purpose.recorded event-1 session-1 "$payload"
assert_eq 'enqueue creates one durable item' 1 "$(slack_queue_depth)"
slack_enqueue ssh.session.purpose.recorded event-1 session-1 "$payload"
assert_eq 'event ID makes enqueue idempotent' 1 "$(slack_queue_depth)"
queue_mode=$(stat -c %a "$AUTH_TRAIL_DATA_DIR/slack-queue" 2>/dev/null || \
    stat -f %Lp "$AUTH_TRAIL_DATA_DIR/slack-queue" 2>/dev/null)
assert_eq 'queue directory is root-private mode' 700 "$queue_mode"

slack_http_post()
{
    SLACK_HTTP_CODE=200 SLACK_CURL_STATUS=0 SLACK_RETRY_AFTER=0
    return 0
}
process_slack_queue_once
assert_eq 'successful delivery removes queued item' 0 "$(slack_queue_depth)"
assert_eq 'successful delivery is recorded canonically' slack.delivery.success \
    "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r .event)"

slack_enqueue ssh.session.end event-2 session-1 "$payload"
slack_http_post()
{
    SLACK_HTTP_CODE=429 SLACK_CURL_STATUS=0 SLACK_RETRY_AFTER=7
    return 1
}
before=$(epoch_now)
process_slack_queue_once
retry_file=$(find "$AUTH_TRAIL_DATA_DIR/slack-queue/pending" -type f | sed -n 1p)
assert_eq '429 keeps item queued' 1 "$(slack_queue_depth)"
assert_eq '429 increments attempt count' 1 "$(jq -r .attempts "$retry_file")"
next=$(jq -r .next_attempt_epoch "$retry_file")
assert_true '429 honors Retry-After' test "$next" -ge "$((before + 7))"
rm -f "$retry_file"

slack_enqueue ssh.session.end event-3 session-2 "$payload"
slack_http_post()
{
    SLACK_HTTP_CODE=400 SLACK_CURL_STATUS=0 SLACK_RETRY_AFTER=0
    return 1
}
process_slack_queue_once
assert_eq 'permanent 4xx removes queued item' 0 "$(slack_queue_depth)"
assert_eq 'permanent failure is recorded canonically' slack.delivery.failure \
    "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r .event)"

AUTH_TRAIL_SLACK_QUEUE_MAX=0
assert_false 'full queue rejects new delivery' slack_enqueue ssh.session.end event-4 session-3 "$payload"
assert_eq 'queue overflow is recorded canonically' slack.delivery.dropped \
    "$(tail -n 1 "$AUTH_TRAIL_LOG_DIR/events.jsonl" | jq -r .event)"

test_summary
