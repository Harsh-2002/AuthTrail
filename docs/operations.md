# Operations

## Installation, upgrades, and Slack

Use [deploy.md](deploy.md) for the one-line install command, dependency preflight, upgrade
behavior, Slack activation, validation, rollback, and uninstall. It is the only installation
procedure. This guide covers commands used after a successful deployment.

Check Slack delivery health with `atctl status`. Inspect `slack.delivery.failure` and
`slack.delivery.dropped` events if the queue is not draining. Notification policy is defined in
[product.md](product.md); webhook protection is defined in [security.md](security.md).

## Identity mapping

```sh
sudo atctl index-keys
```

The installer runs this automatically. The command remains available to rescan later. It scans
local accounts' `authorized_keys` files, computes fingerprints, and seeds `keys.map` using
each key's comment as the initial identity label. Never modifies `authorized_keys`. Comments are
not cryptographically trustworthy — correct the identity column in `keys.map` by hand as needed.

## `atctl` reference

`authtrailctl` remains an identical compatibility name for existing automation.

| Command | Purpose |
|---|---|
| `status` | one-screen summary: service state, integrations, Slack queue, log dir, key count |
| `verify` | static config/permission checks, no side effects |
| `test` | `verify` plus a log-directory write check and service-active check |
| `test-slack` | sends one real Slack message using the configured webhook |
| `index-keys` | rebuild `keys.map` from local `authorized_keys` files |
| `sessions` | list active sessions with live current-account |
| `recent* [--json\|--jsonl] [N]` | human event views, formatted JSON, or compact JSONL |
| `purpose-status` | show purpose configuration, emergency-disable state, helper, and runtime readiness |
| `session [--json] [id]` | list active sessions or show one concise session timeline |
| `identity <fingerprint>` | print the identity mapped to a fingerprint, or `unmapped` |

## Bash completion

The installer enables Bash completion for `atctl` and `authtrailctl` directly through its guarded `/etc/bash.bashrc` block;
the separate `bash-completion` package is not required. Start a new Bash shell after installation
and use Tab to complete commands, standard event counts, known key fingerprints, and live or
recent session IDs:

```sh
atctl recent-<Tab>
atctl session <Tab>
atctl identity <Tab>
```

## Logs and session purpose

`/var/log/authtraild/events.jsonl` is the only persistent AuthTrail application log. Category
files left by versions before 1.1 are preserved as historical data but are no longer written or
rotated. Use the `recent-*` commands or `jq` against the `event` field for logical views.

Interactive SSH requires a 5-500 character access purpose before the login shell opens. Purpose
is disabled only through root-controlled configuration or the emergency marker:

```sh
sudo touch /etc/authtraild/disable-purpose
sudo rm /etc/authtraild/disable-purpose
```

The marker is intended for console/recovery use. Non-interactive SSH, SCP, SFTP, rsync, and
automation never enter the purpose gate.

## Known limitations

- **auditd inside containers.** `auditctl`/`ausearch` need `CAP_AUDIT_CONTROL` and a real kernel
  audit netlink socket, which most containers (including the LXC node this project was built and
  tested against) do not expose. `install.sh` detects this and skips loading audit rules with a
  warning rather than failing; `authtrail-audit-parser.sh` no-ops the same way. This layer needs
  validation on a real (non-container) host before being relied on in production.
- **logrotate absence.** If `logrotate` isn't installed, the rotation config is still installed
  but nothing runs it until the package is present.
- **Non-interactive SSH (`ssh host 'cmd'`) and SFTP/SCP.** These don't source `/etc/profile.d`,
  so no TTY is ever known and no `command.executed` events are produced — but the sshd-line
  follower still produces `ssh.auth.success`/`ssh.session.start`/`ssh.session.end` regardless,
  since that path never depends on the shell hook.
- **`bash --noprofile --norc`.** Bypasses the command hook entirely for that subshell — the
  daemon has no way to see commands typed inside it. `auditd`, where usable, is the only
  fallback evidence layer for this case.
- **Multi-line/pasted commands.** The bash hook reads `history 1`'s in-memory text via a
  single-line `read`; a command containing an embedded literal newline may be truncated in the
  captured text. The raw `history` entry itself is unaffected.
- **`PROMPT_COMMAND` composition.** Scalar and Bash-array forms are preserved and AuthTrail is
  prepended once. The installer validates the resulting global Bash configuration before keeping
  it.
- **Command capture overhead.** Every interactive command forks `jq`, `logger`, `tty`, and `id`
  once each via the bash hook — measured at ~3ms per command on the test node (100 iterations,
  0.304s total). Imperceptible for interactive typing.
- **`session closed` PAM line is not reliable inside containers.** On the LXC test node, PTY
  (interactive) sessions sometimes end with `syslogin_perform_logout: logout() returned an error`
  instead of the expected `pam_unix(sshd:session): session closed for user X` line, or with no
  further log line at all — this looks like incomplete utmp/PAM session accounting under LXC, not
  an AuthTrail bug. `authtraild` checks session PIDs every two seconds and starts a five-second
  dead-PID grace period before synthesizing `ssh.session.end`. The grace lets queued command facts
  drain from journald before session end while still cleaning stale state promptly. This also
  protects against network drops and crashes. It needs re-validation on a real host where the PAM
  message is expected to be reliable.
- **`sudo -i`/`sudo -s` get a new pty.** Debian/Ubuntu's default `Defaults use_pty` in sudoers
  means the shell spawned by `sudo -i` runs on a *different* TTY than its parent. `authtraild`
  handles this by walking process ancestry (`ps -o ppid=,tty=`) until it finds an ancestor whose
  TTY is already a known session, then adopts the new TTY into that session lineage — this is
  what makes identity/`login_user` survive `sudo -i` correctly (verified live, see below).

## Test results

### v1.2 validation

Live upgrade validation on `v0` (Debian 13, aarch64 LXC) passed: the full test suite, repeated
idempotent installation, dependency-preflight failure before mutation, sshd validation, automatic
two-key indexing, service/purpose health, real Slack delivery, mandatory full-screen purpose,
short-input rejection, Ctrl+D denial with an aborted event, command capture, nested Bash, `su`
and `sudo -i` without re-prompting, two simultaneous independently-purposed sessions,
non-interactive SSH, SCP, SFTP, canonical event order, and forced log rotation with continued
writes. Legacy category-file checksums remained unchanged after cutover. Rsync could not
be exercised because the test node does not have the optional `rsync` program installed; the SSH
purpose detector is not involved in that missing-command failure. Auditd remains unavailable due
to the LXC kernel boundary described below.

Live pass against the `v0` test node (Debian 13 "trixie", aarch64, LXC container, OpenSSH
10.0p2). All scenarios below were exercised with real SSH connections (not simulated), most via
a forced-PTY session (`ssh -tt`) with paced, piped input to reproduce genuine interactive typing.

| Scenario | Result |
|---|---|
| Shared `root`, two keys, concurrent | **Pass** — distinct identities (`alice@example.com` / `bob@example.com`) correctly attributed from concurrent connections to the same account |
| Same source IP, different keys | **Pass** — identity resolved by key fingerprint, not IP, as required |
| `su support` mid-session | **Pass** — `identity`/`login_user` unchanged; `current_user` tracks root→support→root; both `privilege.transition` events fired correctly |
| `sudo -i` (non-root sudoer) | **Pass after fix** — see the ancestor-walk note above; identity/login_user preserved across the pty change |
| Failed publickey / failed password / nonexistent user | **Pass after fix** — `Invalid user ... from ... port ...` (used for nonexistent OS accounts, no auth method ever attempted) was not originally recognized by the parser; fixed and covered by a new fixture/test |
| Repeated-failure burst (5 attempts) | **Pass** — `ssh.auth.failure_burst` fired with correct `attempt_count`/`attempted_users`, action `audit_only` |
| Special characters in a command (`"`, `\`, `<`, `>`, `&`, newline) | **Pass** — valid JSON throughout, verified with `jq empty` over the whole log |
| SFTP | **Pass** — auth/session records produced with `tty: null`, no command capture, as documented |
| Non-interactive `ssh host 'cmd'` | **Pass** — same as SFTP: auth/session yes, commands no |
| TTY reuse across sessions | **Pass** — state cleaned up between sessions, no cross-attribution |
| Daemon restart mid-session | **Pass** — `/run/authtraild` state is a plain directory, not tied to the daemon's process lifetime, so attribution continues correctly across a restart; only events emitted in the exact stop→start gap are missed (documented, not a misattribution) |
| Slack delivery (real webhook) | **Pass** — `atctl test-slack` plus live event delivery completed with no `slack.delivery.failure` in `events.jsonl`; actionable mode pairs interactive opened/closed cards and suppresses automation lifecycle noise |
| Slack disabled by default after testing | **Pass** — reverted to `AUTH_TRAIL_SLACK_ENABLED=0` as shipped |
| logrotate (`apt-get install` succeeded on this node) | **Pass** — forced rotation produced correctly-owned (`root:root 0640`) fresh files, old content preserved in `.1`, new events continued landing in the fresh file with no reload needed |
| Reboot | **Pass with caveat** — service came back enabled/active with clean `/run` state and logs retained; the LXC runtime's `reboot` did not reset system uptime the way a real host reboot would, so this is a partial validation of true cold-boot behavior |
| Install idempotency / re-run | **Pass** — customized config files untouched on re-install |
| Uninstall | **Pass** — SSH remained reachable throughout, logs/config preserved by default, only the guarded `/etc/bash.bashrc` block was removed, `sshd -t` validated before any reload |
| `auditd` rule loading | **Not testable on this node** — no kernel audit access in the LXC container, as anticipated; needs a real host |

### Bugs found and fixed during this pass

1. **`build_event_json()` used `jq -n` instead of `jq -nc`**, producing pretty-printed multi-line
   JSON that broke the one-object-per-line JSONL format and split single events across multiple
   journald log lines. Fixed.
2. **`authtrail-bash-hook.sh` was installed `0750 root:root`**, so any non-root user's shell
   (e.g. after `su support`) got `Permission denied` sourcing it and lost command capture
   entirely. Fixed to `0755`.
3. **Stale `.bash_history` spuriously logged on every new shell.** Bash runs `PROMPT_COMMAND`
   once before its very first prompt, when `history 1` still reflects the tail of the persisted
   `HISTFILE` from a *previous* session, not anything typed in the new one. Fixed by seeding a
   baseline on the first firing instead of logging it.
4. **`build_sensitive_command_slack_payload` was referenced but never defined** in
   `libauthtrail.sh` — would have crashed with "command not found" the first time a sensitive
   command alert actually fired. Added.
5. **`IFS=<tab>` silently drops empty leading/consecutive fields.** Tab is always "IFS
   whitespace" to `read`, regardless of what IFS is set to, so a field-separated read using tab
   as the delimiter collapses empty fields instead of preserving them. This broke the new
   `Invalid user` sshd-line parsing (empty `method` field) and was present in
   `authtrail-audit-parser.sh` too (empty `exe` field). Both switched to ASCII 0x1F (unit
   separator), which is not IFS whitespace and round-trips empty fields correctly.
6. **`sshd`'s `Invalid user X from IP port P` line (nonexistent OS account, no auth method ever
   attempted) was not recognized by `parse_sshd_line()`** — a very common brute-force/scanning
   pattern went completely uncounted by failure-burst detection. Added as a third recognized
   line format.
7. **`sudo -i`/`sudo -s` lost identity attribution** because Debian's default `Defaults use_pty`
   allocates a new TTY for the sudo'd shell, which the daemon's TTY-keyed session state had no
   way to find. Fixed with the process-ancestry walk described above.
8. **Stale session/TTY state could accumulate indefinitely** if the `session closed` PAM line
   never arrives (observed reliably on this LXC node for PTY sessions). Added a background reaper
   with a five-second dead-PID grace period, plus a
   sweep for orphaned TTY entries (e.g. one adopted via the `sudo -i` ancestor-walk) whose parent
   session has already been reaped.
