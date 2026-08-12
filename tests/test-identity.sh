#!/bin/sh
# test-identity.sh - lookup_identity() against a temporary keys.map. Never invents an identity for an unmapped key.
# shellcheck disable=SC2034 # AUTH_TRAIL_KEY_MAP below is read by the sourced libauthtrail.sh

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/libauthtrail.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

AUTH_TRAIL_KEY_MAP="$TMPD/keys.map"
cat >"$AUTH_TRAIL_KEY_MAP" <<'EOF'
# comment line
SHA256:AAAA|alice@example.com
SHA256:BBBB|bob@example.com
EOF

assert_eq 'maps a known fingerprint' 'alice@example.com' "$(lookup_identity 'SHA256:AAAA')"
assert_eq 'maps a second known fingerprint' 'bob@example.com' "$(lookup_identity 'SHA256:BBBB')"
assert_eq 'unknown fingerprint is unmapped, never invented' 'unmapped' "$(lookup_identity 'SHA256:ZZZZ')"
assert_eq 'empty fingerprint is unmapped' 'unmapped' "$(lookup_identity '')"

AUTH_TRAIL_KEY_MAP="$TMPD/missing.map"
assert_eq 'missing key map file is unmapped, not an error' 'unmapped' "$(lookup_identity 'SHA256:AAAA')"

test_summary
