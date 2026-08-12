#!/bin/sh
# test-sshd-parser.sh - parse_sshd_line() against fixtures/ (real + hand-written sshd journal lines).

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"

AUTHTRAIL_SELFTEST=1
export AUTHTRAIL_SELFTEST
AUTHTRAIL_LIB="$REPO_DIR/src/libauthtrail.sh"
export AUTHTRAIL_LIB
# shellcheck disable=SC1091
. "$REPO_DIR/src/authtraild"

fx="$REPO_DIR/tests/fixtures"

msg=$(cat "$fx/sshd-accepted-publickey.txt")
parse_sshd_line "$msg"
assert_eq 'accepted publickey: result' 'success' "$PARSE_RESULT"
assert_eq 'accepted publickey: method' 'publickey' "$PARSE_METHOD"
assert_eq 'accepted publickey: user' 'root' "$PARSE_USER"
assert_eq 'accepted publickey: ip' '192.168.139.3' "$PARSE_IP"
assert_eq 'accepted publickey: port' '61956' "$PARSE_PORT"
assert_eq 'accepted publickey: key algorithm' 'ED25519' "$PARSE_KEYALG"
assert_eq 'accepted publickey: fingerprint' 'SHA256:hmP2x6VOxL88RWApcl9sauWbSIykheE5+nVuakgcpAs' "$PARSE_FP"

msg=$(cat "$fx/sshd-accepted-password.txt")
parse_sshd_line "$msg"
assert_eq 'accepted password: method' 'password' "$PARSE_METHOD"
assert_eq 'accepted password: user' 'support' "$PARSE_USER"
assert_eq 'accepted password: no fingerprint invented' '' "$PARSE_FP"

msg=$(cat "$fx/sshd-failed-publickey.txt")
parse_sshd_line "$msg"
assert_eq 'failed publickey: result' 'failure' "$PARSE_RESULT"
assert_eq 'failed publickey: user' 'root' "$PARSE_USER"

msg=$(cat "$fx/sshd-failed-password-invaliduser.txt")
parse_sshd_line "$msg"
assert_eq 'invalid user: result' 'failure' "$PARSE_RESULT"
assert_eq 'invalid user: flag set' '1' "$PARSE_INVALID"
assert_eq 'invalid user: username still extracted' 'admin' "$PARSE_USER"
assert_eq 'invalid user: ip parsed' '185.1.2.3' "$PARSE_IP"

msg=$(cat "$fx/sshd-invalid-user.txt")
parse_sshd_line "$msg"
assert_eq 'invalid-user preauth reject: result' 'failure' "$PARSE_RESULT"
assert_eq 'invalid-user preauth reject: flag set' '1' "$PARSE_INVALID"
assert_eq 'invalid-user preauth reject: username extracted' 'scanner' "$PARSE_USER"
assert_eq 'invalid-user preauth reject: ip parsed' '185.1.2.3' "$PARSE_IP"
assert_eq 'invalid-user preauth reject: port parsed' '51236' "$PARSE_PORT"
assert_eq 'invalid-user preauth reject: no method invented' '' "$PARSE_METHOD"

assert_false 'rejects unrelated journal lines' parse_sshd_line 'this is not an sshd auth line'

test_summary
