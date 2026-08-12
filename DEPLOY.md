# Deploying AuthTrail to Production

Follow this runbook when installing or upgrading AuthTrail on a Debian/Ubuntu server with systemd
and OpenSSH.

## Production contract

- Use one installer command. Do not manually copy binaries, edit sshd configuration, run key
  indexing separately, or install packages from inside AuthTrail.
- AuthTrail never installs dependencies. A failed preflight lists all missing commands and one
  suggested `apt-get install` command before making changes.
- Keep a separate console/recovery path available while changing SSH infrastructure.
- Never print, commit, log, or paste a real Slack webhook into tickets or documentation. A webhook
  exposed in terminal history, chat, or logs must be rotated.
- `/var/log/authtraild/events.jsonl` is the only persistent application log and audit source of
  truth. Slack is a notification surface; journald is an operational view.
- Interactive human SSH is fail-closed until a justification is durably recorded. Ansible, remote
  commands, SCP, SFTP, rsync, CI/CD, and other non-interactive SSH bypass the justification UI but
  still produce authentication/session audit evidence.

## 1. Prepare the host

Requirements:

- Debian or Ubuntu with systemd and OpenSSH server
- root/sudo access and an independent recovery path
- Bash, `jq`, and `curl`
- outbound HTTPS access to Slack when Slack notifications are enabled
- optional `auditd` for shell-independent process evidence
- optional `logrotate` for automatic retention management

From the checked-out AuthTrail directory, run the installer directly. It performs the complete
preflight before mutation:

```sh
sudo ./install.sh
```

If required software is absent, review the single suggested Debian/Ubuntu install command, install
those packages through the organization's normal change process, and rerun the same command.
AuthTrail must not invoke `apt`, download packages, or silently weaken a missing requirement.

Before a production rollout, confirm:

- `/etc/ssh/sshd_config` and included files already pass `sudo sshd -t`;
- the host clock and time synchronization are healthy;
- disk retention for `/var/log/authtraild/events.jsonl` meets policy;
- authorized SSH keys have meaningful comments or administrators are ready to correct identity
  labels in `/etc/authtraild/keys.map` after automatic indexing;
- the Slack channel is intended for security/operations lifecycle notifications, not log ingestion.

## 2. Install in one command

Local auditing only:

```sh
sudo ./install.sh
```

Local auditing plus Slack:

```sh
sudo ./install.sh --slack-webhook='https://hooks.slack.com/services/...'
```

The installer must finish with all of the following already complete:

- binaries, `atctl`, Bash completion, hooks, configuration, and systemd unit installed;
- authorized keys indexed without modifying `authorized_keys`;
- sshd configuration validated before reload;
- service enabled, started, and healthy;
- mandatory interactive justification gate ready;
- Slack enabled and tested when a webhook was supplied;
- root-only persistent Slack queue created under `/var/lib/authtraild/slack-queue`.

On an upgrade, omission of `--slack-webhook` preserves the existing Slack state. Supplying a new
webhook validates a real delivery and restores the previous Slack configuration if validation
fails. Existing configuration, identity labels, legacy category logs, and unrelated
`PROMPT_COMMAND` hooks must remain intact.

## 3. Verify before handoff

Run:

```sh
sudo atctl verify
sudo atctl status
sudo atctl purpose-status
sudo sshd -t
sudo systemctl is-active authtraild
```

Expected state:

- service and SSH integration are active;
- command hook and justification gate are enabled;
- key identity count is nonzero when the host has authorized keys;
- Slack reports configured when requested;
- Slack queue is empty or draining and is owned by root with mode `0700`;
- canonical log is `/var/log/authtraild/events.jsonl`.

If Slack is enabled, one intentional validation is allowed:

```sh
sudo atctl test-slack
```

Do not repeatedly test a production channel.

## 4. Perform production acceptance tests

Keep the recovery session open and start a second interactive SSH connection. Confirm that the
enterprise justification screen appears, enter a ticket-based reason such as:

```text
CHG-1042 - validate AuthTrail production deployment
```

Inside the admitted shell:

```sh
atctl session
atctl session <session-id>
```

Confirm the human view clearly shows identity, account/server, source, justification, current
user, active duration, and timeline. Use structured output only when needed:

```sh
atctl session --json <session-id>
atctl recent-auth --json 20
atctl recent-commands --jsonl 20
```

Exit the test shell, wait for the PID-reaper grace period when PAM does not report closure, then
verify:

```sh
atctl session --json <session-id>
atctl recent --json 50
```

Acceptance criteria:

- exactly one `ssh.session.end` exists for the session;
- `duration_seconds` covers authentication to closure;
- `active_duration_seconds` covers justification acceptance to closure;
- `closure_source` reports observed evidence, not an invented reason;
- Slack contains one opened and one closed card with the same full session ID;
- the closed card contains a human duration and no environment badge or redundant timestamp;
- `atctl status` shows the Slack queue drained and a successful recent delivery.

Run non-interactive regressions from another host:

```sh
ssh server.example /bin/true
scp test.txt server.example:/tmp/
sftp server.example
rsync -e ssh test.txt server.example:/tmp/
```

Use only tools already installed in the test environment. These workflows must not show the
justification UI or create interactive lifecycle Slack cards. They must still produce canonical
authentication/start/end evidence. Validate Ansible and deployment automation through the
organization's normal smoke test.

For shared-account or high-concurrency hosts, open two simultaneous interactive sessions and
verify distinct session IDs, independent justifications, accurate durations, and independent
closures. Never correlate concurrent sessions only by identity, account, TTY, or source IP.

## 5. Operate and monitor

Common commands:

```sh
atctl status
atctl sessions
atctl recent-auth
atctl recent-commands
atctl recent-purpose
atctl session <session-id>
journalctl -u authtraild
journalctl -t authtrail-command
journalctl -t authtrail-purpose
```

Use `authtrailctl` only where an existing script already depends on the long compatibility name.
New human documentation and automation should prefer `atctl`.

Monitor:

- free space and rotation of `/var/log/authtraild/events.jsonl`;
- service restarts and `system.start`/`system.stop` events;
- non-empty or aging Slack queue state in `atctl status`;
- `slack.delivery.failure` and `slack.delivery.dropped` events;
- unmapped identities and changes to authorized keys;
- availability of auditd on hosts where shell-independent evidence is required.

Grafana Alloy is operator-managed and must scrape only `events.jsonl`. AuthTrail never installs,
configures, or restarts Alloy. Follow `docs/alloy.md` and promote only low-cardinality labels.

## 6. Failure handling and rollback

- Failed installer preflight: install approved prerequisites and rerun; no AuthTrail mutation
  should have occurred.
- Failed sshd validation: inspect the reported SSH configuration problem. The installer must not
  reload invalid configuration.
- Slack outage: SSH and canonical logging continue. Inspect `atctl status` and filtered delivery
  events; queued payloads retry without containing the webhook secret.
- Emergency justification bypass: from console/recovery access only, use
  `sudo touch /etc/authtraild/disable-purpose`; remove the marker after recovery and record the
  operational reason separately.
- Normal uninstall while preserving evidence/configuration:

  ```sh
  sudo ./uninstall.sh
  ```

- Destructive purge, only with explicit retention approval:

  ```sh
  sudo ./uninstall.sh --purge
  ```

Never purge production logs or configuration merely to fix an installation. Back up required
evidence first and follow the organization's retention and incident procedures.

## Change safety

Installing packages, changing a webhook, modifying a production host, purging data, disabling the
justification gate, or editing an administrator-maintained identity label requires explicit
operator authorization. Never place a real webhook in repository files, command output, test
fixtures, or documentation.

For implementation changes, run `make test`, preserve POSIX `/bin/sh` boundaries, validate sshd
before reload, and perform proportional live SSH regression tests. Record exactly what was tested,
what was skipped, and any environmental limitation such as unavailable auditd or rsync.
