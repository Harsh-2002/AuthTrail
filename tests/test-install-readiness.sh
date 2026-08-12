#!/bin/sh
# test-install-readiness.sh - installer tolerates delayed purpose runtime initialization.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-readiness.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

AUTH_TRAIL_RUN_DIR="$TMPD/runtime"
mkdir -p "$AUTH_TRAIL_RUN_DIR/purpose"
assert_false 'purpose directory alone is not runtime readiness' purpose_runtime_ready
printf '%s\n' '{"fail_mode":"invalid"}' >"$AUTH_TRAIL_RUN_DIR/purpose/policy.json"
assert_false 'invalid purpose policy is not runtime readiness' purpose_runtime_ready
printf '%s\n' '{"fail_mode":"closed"}' >"$AUTH_TRAIL_RUN_DIR/purpose/policy.json"
assert_true 'valid daemon policy establishes runtime readiness' purpose_runtime_ready

fake_cli="$TMPD/authtrailctl"
counter="$TMPD/counter"
# shellcheck disable=SC2016 # write literal variables into the fake command script
printf '%s\n' '#!/bin/sh' \
    'count=0' \
    '[ ! -f "$AUTHTRAIL_READINESS_COUNTER" ] || count=$(cat "$AUTHTRAIL_READINESS_COUNTER")' \
    'count=$((count + 1))' \
    'printf '\''%s\n'\'' "$count" >"$AUTHTRAIL_READINESS_COUNTER"' \
    '[ "$1" = purpose-status ] || exit 2' \
    '[ "$count" -ge "$AUTHTRAIL_READY_AFTER" ]' >"$fake_cli"
chmod +x "$fake_cli"
AUTHTRAIL_READINESS_COUNTER=$counter
export AUTHTRAIL_READINESS_COUNTER

AUTHTRAIL_READY_AFTER=4
export AUTHTRAIL_READY_AFTER
assert_true 'wait succeeds after delayed runtime initialization' \
    wait_for_purpose_runtime "$fake_cli" 8 0
assert_eq 'wait retried until runtime became ready' 4 "$(cat "$counter")"

rm -f "$counter"
AUTHTRAIL_READY_AFTER=10
export AUTHTRAIL_READY_AFTER
assert_false 'wait fails after bounded timeout' wait_for_purpose_runtime "$fake_cli" 3 0
assert_eq 'timeout performs only configured attempts' 3 "$(cat "$counter")"

test_summary
