# AuthTrail

A lightweight, Linux-native audit trail for SSH access on supported Linux servers. It records who
connected, from where, with which key, what they did, account transitions, session purpose, and
when the session closed — including on shared accounts such as `root`.

It is not a SIEM, firewall, or SSH blocker. Interactive SSH requires a recorded business
justification; automation such as Ansible, SCP, SFTP, rsync, and remote commands remains
non-interactive and purpose-free.

## Install from anywhere

Run this single command on a supported server with Git installed:

```sh
sh -c 'if ! command -v git >/dev/null 2>&1; then . /etc/os-release 2>/dev/null || :; case "${ID:-}:${ID_LIKE:-}" in debian:*|ubuntu:*|*:*debian*) hint="sudo apt-get install git" ;; fedora:*|rhel:*|centos:*|rocky:*|almalinux:*|ol:*|amzn:*|*:*rhel*|*:*fedora*) if command -v dnf >/dev/null 2>&1; then hint="sudo dnf install git"; else hint="sudo yum install git"; fi ;; *) hint="install Git using your supported package manager" ;; esac; printf "AuthTrail bootstrap requires Git. %s\\n" "$hint" >&2; exit 1; fi; d=$(mktemp -d) || exit 1; trap "rm -rf \"$d\"" EXIT HUP INT TERM; git clone --depth 1 --branch main https://github.com/Harsh-2002/AuthTrail.git "$d" && sudo "$d/bootstrap.sh" "$@"' authtrail
```

Append `--slack-webhook='https://hooks.slack.com/services/...'` after `authtrail` to enable Slack
in that same command. The first eligible event verifies delivery without adding an installation
test card to the channel. AuthTrail never installs packages. It supports Debian/Ubuntu,
RHEL-family, and Fedora hosts with systemd and OpenSSH; missing prerequisites produce the correct
`apt-get`, `dnf`, or `yum` command before the server is changed.

Requirements: Git, systemd, OpenSSH server, Bash, and `jq`. `curl` is required only when Slack is
enabled; `auditd` and `logrotate` are optional.

## Use

```sh
atctl status
atctl session
atctl recent-auth
atctl recent-commands
atctl recent-purpose
```

`atctl` provides readable output and Bash completion. `authtrailctl` is a compatible long name
for existing scripts. Use `--json` for structured output.

All application events are written once to `/var/log/authtraild/events.jsonl`. Slack delivers
concise opened/closed session cards and selected security events without blocking local auditing.

## Uninstall

```sh
sudo ./uninstall.sh            # preserve logs and configuration
sudo ./uninstall.sh --purge    # remove logs and configuration
```
