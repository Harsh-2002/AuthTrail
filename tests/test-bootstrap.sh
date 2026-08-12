#!/bin/sh
# test-bootstrap.sh - cross-Linux bootstrap and optional Slack transport preflight.

set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/test-helper.sh"
# shellcheck disable=SC1091
. "$REPO_DIR/src/install-platform.sh"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM

write_release()
{
    release_file=$1
    release_id=$2
    release_like=$3
    printf 'ID=%s\nID_LIKE="%s"\n' "$release_id" "$release_like" >"$release_file"
}

rhel_hint_is_valid()
{
    case "$rhel_hint" in
        'sudo dnf install git' | 'sudo yum install git') return 0 ;;
        *) return 1 ;;
    esac
}

debian_release="$TMPD/debian-release"
write_release "$debian_release" debian ''
AUTHTRAIL_OS_RELEASE_FILE=$debian_release
detect_supported_platform
assert_eq 'detects Debian family' debian "$AUTHTRAIL_PLATFORM_FAMILY"
assert_eq 'uses apt-get on Debian' apt-get "$AUTHTRAIL_PACKAGE_MANAGER"
assert_eq 'maps Debian SSH client package' openssh-client "$(package_for_command ssh-keygen)"

ubuntu_release="$TMPD/ubuntu-release"
write_release "$ubuntu_release" ubuntu 'debian'
AUTHTRAIL_OS_RELEASE_FILE=$ubuntu_release
detect_supported_platform
assert_eq 'detects Ubuntu family' debian "$AUTHTRAIL_PLATFORM_FAMILY"

rhel_release="$TMPD/rhel-release"
write_release "$rhel_release" rocky 'rhel fedora'
AUTHTRAIL_OS_RELEASE_FILE=$rhel_release
detect_supported_platform
assert_eq 'detects RHEL family' rpm "$AUTHTRAIL_PLATFORM_FAMILY"
assert_eq 'maps RPM SSH client package' openssh-clients "$(package_for_command ssh-keygen)"
assert_eq 'maps RPM process package' procps-ng "$(package_for_command ps)"
rhel_hint="$(package_install_command) git"
assert_true 'missing Git gets RHEL package-manager guidance' rhel_hint_is_valid

fedora_release="$TMPD/fedora-release"
write_release "$fedora_release" fedora ''
AUTHTRAIL_OS_RELEASE_FILE=$fedora_release
detect_supported_platform
assert_eq 'detects Fedora family' rpm "$AUTHTRAIL_PLATFORM_FAMILY"
fedora_hint="$(package_install_command) git"
assert_eq 'missing Git gets Fedora dnf guidance' 'sudo dnf install git' "$fedora_hint"

unsupported_release="$TMPD/unsupported-release"
write_release "$unsupported_release" alpine ''
AUTHTRAIL_OS_RELEASE_FILE=$unsupported_release
assert_false 'rejects unsupported distribution' detect_supported_platform

AUTHTRAIL_OS_RELEASE_FILE=$debian_release
detect_supported_platform
git_hint=$(PATH=/definitely-not-a-command command -v git >/dev/null 2>&1 || printf '%s git' "$(package_install_command)")
assert_eq 'missing Git gets Debian guidance without invoking a package manager' 'sudo apt-get install git' "$git_hint"

slack_disabled="$TMPD/slack-disabled.conf"
printf '%s\n' 'AUTH_TRAIL_SLACK_ENABLED=0' >"$slack_disabled"
assert_false 'local-only install does not require curl' slack_transport_required 0 "$slack_disabled"
assert_true 'supplied Slack webhook requires curl' slack_transport_required 1 "$slack_disabled"

slack_enabled="$TMPD/slack-enabled.conf"
printf '%s\n' 'AUTH_TRAIL_SLACK_ENABLED=1' >"$slack_enabled"
assert_true 'existing Slack configuration requires curl' slack_transport_required 0 "$slack_enabled"

test_summary
