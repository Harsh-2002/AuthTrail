# AuthTrail Product Definition

This document defines what AuthTrail is, who it serves, and the behavior the product must deliver.
It is the maintained product authority. Technical implementation belongs in
`architecture.md`; non-negotiable guarantees belong in `contract.md`; production procedures belong
in `deploy.md` and `operations.md`.

## Product purpose

AuthTrail is a lightweight, Linux-native audit service for SSH access on Debian/Ubuntu,
RHEL-family, and Fedora servers. It
creates a useful answer to five operational questions:

1. Who connected to the server?
2. From where and with which authentication method or key?
3. Which Linux account did they use, including shared accounts such as `root`?
4. Why did a human request interactive access?
5. What commands and account transitions occurred before the session closed?

AuthTrail is designed for DevOps, platform, security, and operations teams that need accountable
SSH access without deploying a bastion, database, web application, or full SIEM collector.

## Product principles

- Installation is one command and requires no follow-up configuration when prerequisites exist;
  the maintained public command is in the [README](../README.md#install-from-anywhere).

- The installer checks dependencies but never installs packages. The bootstrap clones the public
  repository through Git; the installer itself does not download dependencies.
- Local evidence is authoritative. Slack is a concise notification surface, not a log store.
- Human output is understandable without `jq`; structured output remains available for automation.
- Identity follows the SSH key fingerprint through shared accounts and privilege transitions. It is
  never guessed when a fingerprint has no mapping.
- Interactive human access requires a durable business justification before the shell opens.
- Non-interactive SSH remains automation-safe and never displays the justification interface.
- Slack or network failure never delays canonical logging or an already accepted interactive shell.
- AuthTrail composes with existing SSH and shell configuration and validates changes before reload.
- AuthTrail owns only its clearly named files and guarded configuration blocks. Optional host
  integrations are used only when explicitly enabled and never grant AuthTrail ownership of
  another project's configuration.

## Supported platform and dependencies

The supported baseline is Debian/Ubuntu, RHEL-family, or Fedora with systemd, OpenSSH server,
Bash, and `jq`. Git is required for the public bootstrap command; `curl` is required only when
Slack is enabled.
The core shell components use POSIX `/bin/sh`; only interactive Bash command capture and Bash
completion require Bash syntax. `auditd` and `logrotate` are optional capabilities. Auditd is
disabled by default and requires explicit opt-in because global exec auditing can be high-volume.
Grafana Alloy
and Loki are operator-managed integrations, not AuthTrail dependencies.

## Installation experience

A successful installer invocation leaves the service running, SSH integration validated, keys
indexed, completion installed, and the purpose gate ready. Supplying a Slack webhook enables and
tests Slack within that same command. Omitting it leaves Slack off on a fresh install and preserves
the existing Slack state during an upgrade.

Preflight happens before mutation. Missing required commands produce one deduplicated
distribution-specific installation command and a nonzero exit. Missing optional capabilities
produce clear warnings. Existing configuration and administrator-maintained identity labels survive
upgrades.

## Canonical audit data

`/var/log/authtraild/events.jsonl` is the only persistent AuthTrail application log. Every event is
written there exactly once and mirrored to journald before Slack delivery is attempted. Historical
category logs from older versions are preserved but never appended, migrated, or deleted.

Events use a stable JSON schema and an `event` field for logical separation. The stream includes:

- authentication success, failure, and failure bursts;
- session start, purpose state, and session end;
- commands and confirmed privilege transitions;
- auditd evidence when that optional capability is available;
- system lifecycle and Slack delivery health.

The schema includes `hostname`, `environment`, and `event` for low-cardinality Loki labels.
Session ID, identity, source IP, key fingerprint, purpose, and command remain JSON fields rather
than labels.

## Identity and session model

The SSH key fingerprint is the cryptographic identity anchor. `keys.map` associates it with a
human-readable, administrator-controlled label. Automatic indexing reads authorized keys but never
changes them. An unknown mapping is reported as `unmapped`.

Each connection receives an independent session ID and runtime state. Correlation uses the SSH
process, connection tuple, TTY, and session ID as appropriate; identity, account, source address,
or TTY alone is never assumed to be unique. Multiple users and multiple simultaneous sessions for
the same shared account remain isolated.

Session closure is evidence-based and idempotent. `duration_seconds` measures authentication to
closure, while `active_duration_seconds` measures accepted justification to closure. Because a
normal exit, network loss, terminal closure, and killed process can be ambiguous, user-facing text
says “SSH session closed” and records the observed `closure_source` without inventing a reason.

## Interactive access justification

A genuine interactive SSH terminal receives a full-screen, dependency-free justification gate.
It shows server, mapped identity, account, source, and authentication method, then requests:

> Provide a business justification or ticket/change reference for this server access.

The purpose is trimmed, validated as 5–500 characters, treated only as untrusted text, and durably
recorded on the session. After acknowledgement, the display clears and presents a short access
confirmation before the normal prompt. Empty input, abort, disconnect, or persistence failure
closes the interactive session in the default fail-closed mode.

Remote commands, Ansible, SCP, SFTP, rsync, CI/CD, subsystems, automation, nested shells, `su`,
`sudo -i`, and `sudo -s` do not receive a second purpose prompt. Non-interactive connections retain
canonical authentication and session evidence but do not generate interactive Slack lifecycle
cards. A root-controlled emergency marker supports console-led recovery.

## Command and privilege evidence

The system-wide Bash hook records literal interactive command text locally when enabled. It
composes with existing string or array `PROMPT_COMMAND` values and does not replace unrelated
hooks. Command redaction is best-effort and cannot guarantee removal of every secret.

Privilege transitions are emitted only after an observed current-user change, not merely because
a command contains `sudo` or `su`. PAM confirms successful `sudo`/`su` transitions immediately,
including nested and root-to-user changes; the prompt hook is a deduplicated fallback. The
original mapped SSH identity remains immutable while `current_user` reflects the effective account.

Slack also receives a deliberately small set of successful critical access changes: user/group
administration (`useradd`, `userdel`, `usermod`, `groupadd`, `groupdel`, `groupmod`, `passwd`,
`chage`) and mutations targeting `authorized_keys`, `/etc/sudoers*`, `/etc/pam.d`, or `/etc/ssh`.
Routine commands remain local-only.

## Slack notification policy

The default actionable profile sends:

- one opened card after interactive justification is accepted;
- one correlated closed card with active duration;
- aggregated authentication-failure bursts;
- confirmed privilege transitions;
- sensitive-command alerts only when explicitly enabled.

Cards omit the environment badge and redundant timestamps, keep the complete session ID, escape
untrusted text, and emphasize identity, account/server, source, justification, and duration. The
default never sends every authentication failure or command.

Delivery uses a root-only persistent FIFO queue under `/var/lib/authtraild`. Payloads never contain
the webhook URL. Delivery is limited to one post per second, survives daemon restarts, honors
`Retry-After`, retries bounded transient failures, and records success, failure, and dropped events
canonically. Slack failure never blocks ingestion or interactive access after local persistence.

## Operator interface

`atctl` is the primary human-facing command. `authtrailctl` remains an identical compatibility name
for existing scripts. Bash completion is installed for both.

- `atctl status` reports service, integration, identity, and Slack queue health.
- `atctl session` lists active sessions.
- `atctl session <id>` shows a concise summary and chronological timeline.
- `atctl recent-auth`, `recent-commands`, and `recent-purpose` provide readable filtered views.
- `--json` provides formatted structured data; recent commands also support compact `--jsonl`.

Human views remove redundant metadata and null fields. Canonical events remain denormalized so any
record is independently understandable after rotation or remote ingestion.

## Explicit non-goals

AuthTrail is not a SIEM, IDS/IPS, firewall, Fail2Ban replacement, malware scanner, EDR, database,
web UI, authentication provider, SSH bastion, PAM replacement, or terminal/session recorder. It
does not block repeated failures, replace organization retention policy, make local root-owned logs
tamper-proof, or manage Grafana Alloy.

## Definition of production-ready

A production deployment is ready when one installer command completes, `atctl verify` passes,
sshd configuration validates, the service is active, identities are indexed, an interactive test
records purpose and paired lifecycle evidence, non-interactive regressions bypass the UI, concurrent
sessions remain isolated, and Slack is healthy when configured. The full procedure and rollback
requirements are in `deploy.md`.

## Documentation authority

Read documents in this order when making a change:

1. Root `CLAUDE.md` (or its `AGENTS.md` symlink) — repository entry point.
2. `product.md` — product intent, scope, and user-visible behavior.
3. `contract.md` — invariant guarantees that changes must preserve.
4. `development.md` — implementation conventions, commands, and code map.
5. `architecture.md` and `security.md` — technical and security reasoning.
6. `deploy.md` and `operations.md` — production and operational procedures.

Tests describe verified implementation behavior but do not silently redefine the product. If code,
tests, and these documents disagree, stop and resolve the inconsistency explicitly.
