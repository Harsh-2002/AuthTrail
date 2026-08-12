# AuthTrail

A lightweight, Linux-native audit trail for SSH access on Debian and Ubuntu. It records who
connected, from where, with which key, what they did, account transitions, session purpose, and
when the session closed — including on shared accounts such as `root`.

It is not a SIEM, firewall, or SSH blocker. Interactive SSH requires a recorded business
justification; automation such as Ansible, SCP, SFTP, rsync, and remote commands remains
non-interactive and purpose-free.

## Install

```sh
sudo ./install.sh
sudo ./install.sh --slack-webhook='https://hooks.slack.com/services/...'
```

The first command enables local auditing; the second also enables and validates Slack. AuthTrail
never installs packages. If a prerequisite is missing, it reports every missing command and one
suggested Debian/Ubuntu installation command before changing the server.

Requirements: Debian/Ubuntu, systemd, OpenSSH server, Bash, `jq`, and `curl`. `auditd` and
`logrotate` are optional.

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

## Learn more

- `PRODUCT.md` — product purpose, scope, experience, and current feature definition
- `DEPLOY.md` — production deployment, validation, and rollback runbook
- `docs/operations.md` — operations and troubleshooting
- `docs/security.md` — security boundaries and limitations
- `docs/architecture.md` — event and session design
- `docs/alloy.md` — optional single-file Grafana Alloy/Loki collection
