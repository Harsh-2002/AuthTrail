#!/bin/sh
# run.sh - ShellCheck every script, then run the complete unit suite.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

cd "$REPO_DIR"

shellcheck -s sh bootstrap.sh src/authtraild src/authtrailctl src/libauthtrail.sh \
    src/install-platform.sh src/install-auditd.sh src/install-readiness.sh src/install-pam.sh \
    src/authtrail-pam-hook.sh \
    src/authtrail-session-hook.sh src/authtrail-purpose.sh \
    src/authtrail-audit-parser.sh install.sh uninstall.sh tests/*.sh
shellcheck -s bash src/authtrail-bash-hook.sh src/authtrailctl-completion.bash

for test_script in tests/test-*.sh; do
    sh "$test_script"
done
