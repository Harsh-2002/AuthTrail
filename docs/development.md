# Development

Repository development guide covering commands, conventions, tests, and architecture.

## What this is

AuthTrail (`authtraild`) is a lightweight Linux-native SSH access and user-activity audit daemon
for supported Linux distributions with systemd + OpenSSH. It answers who accessed a server, from where, with which
key, as which account, whether they switched accounts (`su`/`sudo`), and what commands they ran —
even under a shared account like `root`. It is explicitly not a SIEM/IDS/firewall/blocker; see
`security.md` for the security boundaries. `product.md` defines current product intent and
user-visible behavior; `contract.md` defines the invariants every implementation must preserve.

Read the root `CLAUDE.md` entry point first for the required documentation order.

## Commands

```sh
./tests/run.sh                      # ShellCheck every script and run the complete unit suite
sh tests/test-json.sh              # run a single test file directly (each is self-contained)
sudo ./install.sh                  # one-command local-only install; reports missing packages without installing them
sudo ./install.sh --slack-webhook='https://hooks.slack.com/services/...'
sudo ./install.sh --enable-auditd      # explicit high-volume process-audit opt-in
sudo ./install.sh --disable-auditd     # no global audit rule load/reload
sudo ./uninstall.sh [--purge]      # uninstall; --purge also deletes logs/config
sudo atctl verify                  # static config/permission checks, no side effects
sudo atctl test-slack              # send one real Slack message with the configured webhook
```

There is no build system or Makefile — everything is POSIX `/bin/sh`, except the explicitly Bash-specific
interactive hook and completion script, and is run directly.
`tests/test-*.sh` source `src/libauthtrail.sh` or `src/authtraild`/`src/authtrailctl` directly
(the executables have an `AUTHTRAIL_SELFTEST=1` guard so sourcing them for their functions
doesn't run `main`) and use the tiny assertion helpers in `tests/test-helper.sh`
(`assert_eq`/`assert_true`/`assert_false`/`assert_contains`/`assert_not_contains`). No external
test framework.

## Coding conventions (non-negotiable, enforced by the spec)

- **POSIX `/bin/sh` only** for everything except `src/authtrail-bash-hook.sh` and
  `src/authtrailctl-completion.bash`, which are intentionally Bash-specific (POSIX has no reliable way to capture literal
  interactive command text; `PROMPT_COMMAND` does). Never introduce bashisms (`[[`, arrays,
  `local`, `${var^^}`, process substitution) outside that one file.
- **Comments are single-line only** — no multi-line comment blocks/headers. Put longer design
  rationale in `architecture.md` instead of inline.
- **JSON is always built with `jq`**, never by string-concatenating shell variables (section 28
  of the spec). `build_event_json()` in `src/libauthtrail.sh` is the one canonical event builder;
  callers set `EV_*` variables and call `emit_event`, they don't hand-build JSON.
- **No `eval`**, even on trusted-looking input — `validate_config()` explicitly avoids dynamic
  variable indirection so a reviewer never has to trust it. Never `eval` an audited command.
- **`IFS=<tab>` is unsafe for field-splitting** — tab is always "IFS whitespace" to `read`
  regardless of what IFS is set to, so it silently collapses empty leading/consecutive fields.
  Use ASCII 0x1F (`printf '\037'`) as the delimiter for any multi-field `read`, as done throughout
  `src/authtraild`.
- **`sshd -t` must gate every SSH config change** — `install.sh`/`uninstall.sh` never reload sshd
  without validating first, and restore the previous state if validation fails.
- **Identity is never invented** — an unmapped key fingerprint reports `identity: unmapped`, not
  a guess. Unset event fields serialize to JSON `null`, never a placeholder string.
- **Local disk write always happens before Slack is attempted**, and a Slack failure never
  affects SSH/session/command auditing. Every command is logged locally; only a curated subset of
  event types (never every command) goes to Slack, per `slack_enabled_for()` in
  `src/libauthtrail.sh`.
- Use only dummy names/emails (`alice@example.com`, `testhost`, etc.) in code, tests, and docs —
  never real people's names.

## Architecture

Full design writeup, including the two design decisions that aren't obvious from the spec alone
(how a session actually starts, and how privilege transitions are detected), lives in
`architecture.md`. The short version:

- **`src/authtraild`** is the only process that writes to `/run/authtraild/` (sessions/tty/conn/
  failures state) — `authtrail-audit-parser.sh` also writes to the canonical JSONL event log (via the same
  shared `emit_event()`), but never touches `/run/authtraild`. `authtraild` follows
  `journalctl -f -o json` and routes each line three ways: sshd's own auth lines
  (`_SYSTEMD_UNIT` match) parsed by `parse_sshd_line()`; raw `session_init` facts tagged
  `authtrail-session` from the profile.d hook; raw command facts
  tagged `authtrail-command` from the bash hook. A session is created and `ssh.session.start`
  emitted at auth-success time (so non-interactive/SFTP sessions still get a record); the
  profile.d hook's arrival later just attaches a TTY to that session, correlated via the client
  `source_ip:source_port` tuple.
- **`src/authtrail-session-hook.sh`** (installed as `/etc/profile.d/91-authtrail-session.sh`) and
  **`src/authtrail-bash-hook.sh`** (sourced from a guarded block in `/etc/bash.bashrc`) are the
  only components that run inside an operator's own shell. Both are `.`-sourced, never executed,
  so they must never `exit` or change shell options — doing either would break the caller's shell.
  They only ever emit raw facts via `logger`; they never write to `/run/authtraild` directly.
- **`src/authtrail-purpose.sh`** is executed by the session hook only for a real interactive SSH
  terminal. It uses a random-token journal request and a daemon-written acknowledgement; the
  daemon remains the only session-state writer. Unlike the passive hooks, a failed mandatory
  purpose gate intentionally causes the profile hook to end that interactive login shell.
- **Privilege transitions** (`su`/`sudo`) are detected from an *observed* change in the reported
  current user on the next command, not from pattern-matching the `su`/`sudo` command text —
  `sudo -i` specifically needs `find_ancestor_tty_key()` in `src/authtraild` because Debian's
  default `Defaults use_pty` gives the sudo'd shell a brand-new TTY.
- **`src/libauthtrail.sh`** is shared by `authtraild`, `atctl`/`authtrailctl`, and
  `authtrail-audit-parser.sh`. It intentionally does not use `set -e` (it's sourced into a
  long-running daemon loop where one failed substitution must not kill the process); every
  fallible call checks its own exit status.
- Config templates in `config/` are installed once and never overwritten by a re-install if the
  target already exists (`install_template_if_absent()` in `install.sh`) — a customized webhook
  or key registry must survive `install.sh` being re-run.
- `auditd` (`audit/authtraild.rules`, `src/authtrail-audit-parser.sh`) is a separate, local-only,
  opt-in evidence layer, not part of the real-time event flow. The installer policy helpers live
  in `src/install-auditd.sh`; disabled installs must never load or globally reload rules. It needs kernel audit access
  that most containers (including the project's own LXC test node) don't have.
- `/var/log/authtraild/events.jsonl` is the only persistent application log. CLI category views
  filter its `event` field; legacy category files are preserved but never appended.
- `atctl` is the primary human-facing CLI and defaults to concise human output. `authtrailctl`
  remains compatible; `--json` and recent-view `--jsonl` are explicit structured modes.
- Slack payloads are persisted root-only under `/var/lib/authtraild/slack-queue` and delivered by
  the daemon worker, never synchronously on the canonical event-ingestion path.

## Testing notes

Real behavior here depends heavily on live OpenSSH/PAM/sudo/bash quirks that unit tests alone
won't catch (see `operations.md`'s "Bugs found and fixed" section for concrete examples: a
missing `-c` flag on `jq -n` silently broke the JSONL format, wrong file permissions silently
broke command capture for non-root users, `sudo -i`'s pty reassignment silently broke identity
attribution). When changing anything in the event pipeline, session correlation, or the hooks,
prefer verifying against a real host over trusting the unit tests alone.
