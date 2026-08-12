# Security notes

## What AuthTrail is not

Not a SIEM, IDS, IPS, firewall, Fail2Ban replacement, malware scanner, EDR, PAM replacement, SSH
bastion, or session-recording tool. It never blocks authentication or non-interactive SSH.
Interactive shells are intentionally held until mandatory purpose is recorded. Repeated
authentication failures are detected and reported (locally and, optionally, to Slack) — never
acted on.

## Local log integrity

`/var/log/authtraild/events.jsonl` and the AuthTrail configuration are not tamper-proof against an
attacker who already has root on the box. A user with unrestricted root access can alter or
delete the local logs, the config, journald's own records, or the AuthTrail binaries themselves.
Do not present these logs as an immutable audit trail without an independent, remote/append-only
sink — that is out of scope for v1.

## Interactive purpose enforcement

Purpose enforcement delays only a genuine interactive SSH login shell. Authentication has
already succeeded, and non-interactive workflows never enter the gate. The default is
fail-closed: an unavailable daemon or failed local write closes that interactive session. A root
operator with console/recovery access can create `/etc/authtraild/disable-purpose` or set
`AUTH_TRAIL_PURPOSE_ENABLED=0`. Purpose text is untrusted, is never sourced or evaluated, and is
encoded with `jq --arg`.

## Webhook protection

The Slack Incoming Webhook URL lives only in `/etc/authtraild/authtraild.conf`, which must be
`root:root 0600` (or `0400`) — `authtraild`/`atctl` refuse to load it otherwise. It is
never written to `/var/log/authtraild/events.jsonl`, never printed by `atctl status` (which
only ever prints "configured"/"not configured"), and never passed to `curl` as a process
argument. The explicit `install.sh --slack-webhook=URL` convenience form can be visible briefly
in process inspection and may remain in the invoking shell's history; use normal shell history
controls and rotate a webhook that has been exposed.

Queued Slack payloads are stored root-only under `/var/lib/authtraild/slack-queue`. They can
contain identity, source, command, and justification data, but never the webhook secret.

## Command redaction is best-effort

`config/redact.conf` redacts common secret-bearing patterns (`Authorization: Bearer`,
`password=`, `token=`, `AWS_SECRET_ACCESS_KEY=`, etc.) before a command is written locally or
sent to Slack. No regex-based redaction can guarantee removal of every secret that might appear
on a command line. Review your command-retention policy before relying on this alone, especially
in a regulated environment.

## No `eval`, no replay

AuthTrail observes commands; it never replays or evaluates them. Every audited string
(username, key comment, command text, cwd, hostname override, TTY) is treated as untrusted and
passed to `jq --arg` for JSON construction rather than concatenated into JSON or Slack payloads
by hand. This is non-negotiable across the codebase.
`validate_config()` in `src/libauthtrail.sh` checks every configuration value against an
explicit allow-list rather than using `eval`/dynamic variable indirection.

## Identity is never invented

An unmapped key fingerprint is reported as `identity: unmapped`, never as a guessed name. Key
comments harvested by `atctl index-keys` are not treated as cryptographically
trustworthy — the fingerprint is always the authoritative identifier; the friendly name is an
administrator-maintained label in `keys.map` that can be corrected at any time.

## SSH configuration changes are always validated

The `sshd_config.d/90-authtraild.conf` drop-in (`LogLevel VERBOSE`, `ExposeAuthInfo yes`) is only
applied after `sshd -t` validates the resulting configuration. `install.sh`/`uninstall.sh` never
reload sshd without that check passing first, and restore the previous state if it fails — see
`docs/operations.md` for the exact failure-mode guarantees.
