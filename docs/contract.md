# Behavioral contract

The behavioral guarantees AuthTrail v1 makes. Any change that violates
one of these is a regression, not a stylistic choice. See `product.md` for the product definition
and `security.md`/`architecture.md` for the reasoning.

## Never

- Never becomes a Fail2Ban/firewall/IP-blocker, SIEM, IDS/IPS, malware scanner, EDR, database,
  web UI, auth provider, SSH bastion, PAM replacement, or session recorder — the explicit
  non-goals in `product.md`. A feature request that pulls this project
  toward any of those is out of scope for v1, regardless of how useful it sounds.
- Never blocks SSH authentication, non-interactive SSH, a command after admission, or an account
  switch. The sole exception is the mandatory interactive session-purpose gate: the login shell
  does not open until purpose is durably recorded, and fail-closed errors end that interactive
  session. Repeated-failure detection remains audit-only.
- Never invents an identity for an unmapped key fingerprint — reports `unmapped`, not a guess.
- Never sends every command to Slack by default (`AUTH_TRAIL_SLACK_COMMAND_ALERTS` default `0`).
- Never reloads sshd without `sshd -t` passing first; restores the previous config on failure.
- Never lets a Slack failure affect SSH, session, or command auditing.
- Never overwrites an existing `authtraild.conf`/`keys.map`/`redact.conf`/`sensitive-commands.conf`
  wholesale on reinstall — migrations append missing defaults and explicit installer parameters
  update only their fields; customized values and key labels survive a re-run.
- Never modifies `authorized_keys` (`atctl index-keys` only reads it; `authtrailctl` is compatible).
- Never prints or logs the Slack webhook URL in full, anywhere.
- Never removes an unrelated `PROMPT_COMMAND` or audit mechanism; AuthTrail composes with string
  and array prompt hooks and restores the prior Bash configuration if validation fails.
- Never installs packages or configures Grafana Alloy.
- Never modifies or removes another project's configuration. AuthTrail changes only its named
  files and guarded blocks, and optional integrations require explicit operator intent.
- Never creates, loads, or globally reloads auditd rules when `AUTH_TRAIL_AUDITD_ENABLED=0`.
  Auditd process-execution capture is opt-in, and disabling it preserves unrelated/custom rules.
- Never uses `eval`, on any value, trusted-looking or not.
- Never builds JSON or a Slack payload by string-concatenating shell variables — always `jq`.

## Always

- The original human identity (from the SSH key fingerprint) stays attached to a session through
  `su`/`sudo`, even as the Linux account changes underneath it.
- Local JSONL + journald write happens before any Slack delivery attempt, for every event.
- `/var/log/authtraild/events.jsonl` is the only persistent AuthTrail application log. Historical
  category files are preserved on upgrade but never receive new events.
- A real interactive SSH session records a valid purpose before its shell opens by default.
- Every command is captured locally when command capture is enabled; only purpose-confirmed
  interactive lifecycle, failure bursts, privilege transitions, and explicitly enabled
  sensitive-command alerts reach Slack by default.
- Unset event fields serialize to JSON `null`, never a placeholder string like `"unknown"`.
- `install.sh`/`uninstall.sh` never risk locking the operator out of SSH.
- Installation succeeds only after bounded verification of daemon-created purpose runtime state;
  systemd's `active` process state alone is not treated as application readiness.

## Environment assumptions

- Debian/Ubuntu, RHEL-family, or Fedora with systemd, OpenSSH server, Bash, and `jq`; `curl` is
  required only when Slack is enabled.
- `authtraild`/`atctl`/`authtrailctl`/`libauthtrail.sh`/`install.sh`/`uninstall.sh` are POSIX `/bin/sh`;
  only `authtrail-bash-hook.sh` and `authtrailctl-completion.bash` are intentionally Bash-specific.
- `auditd` and `logrotate` are optional — their absence must degrade with a warning, never fail
  the install.

## Where this is verified

`tests/test-*.sh` cover the individual functions (`./tests/run.sh`). `operations.md`'s "Test
results" section records what was verified live against a real host. A change touching the event
pipeline, session correlation, or the two shell hooks should be checked against a real host, not
just the unit tests — see `operations.md`'s "Bugs found and fixed" list for why.
