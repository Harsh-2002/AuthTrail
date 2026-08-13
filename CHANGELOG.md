# Changelog

## Unreleased

Added immediate, success-based `sudo`/`su` transition evidence through an AuthTrail-managed
optional PAM session hook. Nested account changes now preserve their exact chain, update runtime
state before the next shell command, and produce one canonical event and Slack alert. Added
high-signal `access.change` alerts for successful identity/group administration and modifications
to SSH, PAM, sudoers, and `authorized_keys` configuration.

Made auditd process-execution capture explicit opt-in. Fresh installs default to disabled;
`--enable-auditd` and `--disable-auditd` provide supported installer control. Disabled installs
never create, load, or globally reload audit rules, and upgrades/uninstalls remove only unmodified
AuthTrail-owned rules. Explicit enablement adds only AuthTrail's tagged rules without globally
reloading other projects' audit configuration.

Fixed an installer readiness race by waiting up to 30 seconds for the daemon-created purpose
runtime policy after systemd reports the service active.

## 1.1.0

Unified persistent events in `events.jsonl`; added mandatory interactive SSH session purpose,
one-command dependency-aware installation with optional webhook input, automatic key indexing,
filtered CLI views, and documentation-only Grafana Alloy/Loki integration.

## 1.0.0

Initial release: SSH auth/session/command auditing, shared-account identity attribution via SSH
key fingerprints, privilege-transition detection (`su`/`sudo`), local JSONL + journald logging,
optional Slack Block Kit notifications, auditd process-execution evidence layer,
install.sh/uninstall.sh.
