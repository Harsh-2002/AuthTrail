# Changelog

## Unreleased

Made auditd process-execution capture explicit opt-in. Fresh installs default to disabled;
`--enable-auditd` and `--disable-auditd` provide supported installer control. Disabled installs
never create, load, or globally reload audit rules, and upgrades/uninstalls remove only unmodified
AuthTrail-owned rules. Explicit enablement adds only AuthTrail's tagged rules without globally
reloading other projects' audit configuration.

## 1.1.0

Unified persistent events in `events.jsonl`; added mandatory interactive SSH session purpose,
one-command dependency-aware installation with optional webhook input, automatic key indexing,
filtered CLI views, and documentation-only Grafana Alloy/Loki integration.

## 1.0.0

Initial release: SSH auth/session/command auditing, shared-account identity attribution via SSH
key fingerprints, privilege-transition detection (`su`/`sudo`), local JSONL + journald logging,
optional Slack Block Kit notifications, auditd process-execution evidence layer,
install.sh/uninstall.sh.
