#!/bin/sh
# install-platform.sh - platform detection and package guidance shared by installer entry points.

AUTHTRAIL_PLATFORM_FAMILY=''
AUTHTRAIL_PACKAGE_MANAGER=''

detect_supported_platform()
{
    platform_release=${AUTHTRAIL_OS_RELEASE_FILE:-/etc/os-release}
    [ -r "$platform_release" ] || return 1

    platform_id=''
    platform_like=''
    # shellcheck disable=SC1090
    . "$platform_release"
    platform_id=${ID:-}
    platform_like=${ID_LIKE:-}

    case "$platform_id:$platform_like" in
        debian:* | ubuntu:* | *:*debian*)
            AUTHTRAIL_PLATFORM_FAMILY='debian'
            AUTHTRAIL_PACKAGE_MANAGER='apt-get'
            ;;
        fedora:* | rhel:* | centos:* | rocky:* | almalinux:* | ol:* | amzn:* | *:*rhel* | *:*fedora*)
            AUTHTRAIL_PLATFORM_FAMILY='rpm'
            if command -v dnf >/dev/null 2>&1; then
                AUTHTRAIL_PACKAGE_MANAGER='dnf'
            elif command -v yum >/dev/null 2>&1; then
                AUTHTRAIL_PACKAGE_MANAGER='yum'
            else
                AUTHTRAIL_PACKAGE_MANAGER='dnf'
            fi
            ;;
        *) return 1 ;;
    esac
}

package_for_command()
{
    case "$AUTHTRAIL_PLATFORM_FAMILY:$1" in
        *:sshd) printf 'openssh-server' ;;
        debian:ssh-keygen) printf 'openssh-client' ;;
        rpm:ssh-keygen) printf 'openssh-clients' ;;
        *:jq) printf 'jq' ;;
        *:curl) printf 'curl' ;;
        *:git) printf 'git' ;;
        *:bash) printf 'bash' ;;
        *:systemctl | *:journalctl) printf 'systemd' ;;
        debian:logger) printf 'util-linux' ;;
        rpm:logger) printf 'util-linux' ;;
        debian:ps) printf 'procps' ;;
        rpm:ps) printf 'procps-ng' ;;
        *:hostname) printf 'hostname' ;;
        *:find) printf 'findutils' ;;
        debian:awk) printf 'mawk' ;;
        rpm:awk) printf 'gawk' ;;
        debian:getent) printf 'libc-bin' ;;
        rpm:getent) printf 'glibc-common' ;;
        *:sed) printf 'sed' ;;
        *:grep) printf 'grep' ;;
        *) printf 'coreutils' ;;
    esac
}

package_install_command()
{
    printf 'sudo %s install' "$AUTHTRAIL_PACKAGE_MANAGER"
}

slack_transport_required()
{
    slack_supplied=$1
    slack_config=$2
    [ "$slack_supplied" -eq 1 ] && return 0
    [ -r "$slack_config" ] && grep -q '^AUTH_TRAIL_SLACK_ENABLED=1$' "$slack_config"
}

valid_slack_webhook_url()
{
    printf '%s' "$1" | grep -Eq \
        '^https://[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'
}
