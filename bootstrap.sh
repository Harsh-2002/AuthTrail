#!/bin/sh
# bootstrap.sh - verifies checkout prerequisites, then delegates to the idempotent installer.

set -eu

PROGRAM='bootstrap.sh'
REPO_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-platform.sh"

die()
{
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

preflight_git()
{
    detect_supported_platform || die 'unsupported Linux distribution (supported: Debian/Ubuntu, RHEL-family, Fedora)'
    if ! command -v git >/dev/null 2>&1; then
        printf '%s: Git is required to bootstrap AuthTrail. Install it, then re-run the same command:\n' "$PROGRAM" >&2
        printf '    %s git\n' "$(package_install_command)" >&2
        return 1
    fi
}

main()
{
    preflight_git || exit 1
    exec "$REPO_DIR/install.sh" "$@"
}

if [ "${AUTHTRAIL_SELFTEST:-0}" != '1' ]; then
    main "$@"
fi
