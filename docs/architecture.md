# Architecture

## Event flow

```
                         +----------------------+
                         |       OpenSSH        |
                         |        sshd          |
                         +----------+-----------+
                                    |
               auth success/fail    |    SSH session environment
                                    |
                    +---------------+----------------+
                    |                                |
                    v                                v
             systemd journal                  login shell
              (sshd-session lines)         SSH_CONNECTION / SSH_TTY
                    |                                |
                    |                     /etc/profile.d/91-authtrail-session.sh
                    |                     emits raw session_init via logger
                    |                                |
                    +---------------+----------------+
                                    |
                                    v
                           authtraild (journalctl -f -o json follower)
                                    |
                    +---------------+---------------+
                    |               |               |
                    v               v               v
              /run/authtraild   canonical log   journald
              session/tty/conn  events.jsonl    (mirror)
              state                                 |
                    ^                                v
                    |                            Slack (best effort,
        /etc/bash.bashrc fragment                configured events only)
        sources authtrail-bash-hook.sh
        (PROMPT_COMMAND, readable
        commands) -> logger -t authtrail-command
                    |
                    v
             authtraild enriches from
             TTY state, writes command.executed
```

For a real interactive SSH terminal, the session hook invokes `authtrail-purpose.sh` before the
normal prompt. The helper sends a random-token query through journald; only `authtraild` resolves
the existing session, validates and persists the purpose, and writes the acknowledgement under
`/run/authtraild/purpose/`. The helper opens the shell only after that acknowledgement. SCP,
SFTP, remote commands, rsync, and sessions without terminal stdin/stdout never enter this flow.

## Persistent event stream

`/var/log/authtraild/events.jsonl` is the only persistent application log and contains each
canonical event exactly once. The `event` field supplies logical categories; `atctl`
filters this stream for authentication, command, and purpose views. Journald remains a secondary
operational mirror and the transport for raw session, command, and purpose facts. Category files
from releases before 1.1 are historical only and are not changed or appended.

`auditd` (if usable on the host) is a separate, local-only evidence layer — see
`authtrail-audit-parser.sh` and `audit/authtraild.rules`. It is not part of the real-time flow
above; it's run on demand or periodically to backfill `audit.exec` events.

## Design decision: how a session actually starts

The session model needs a hook that reads `SSH_CONNECTION`/`SSH_TTY` and emits a raw fact. Those
variables only exist inside the
user's own login shell, so it has to be a shell-startup hook — not something the daemon can
synthesize purely from sshd's journal line (which has no TTY in it).

Resolution — two independent, complementary paths:

1. **Authoritative path**: `authtraild`'s own journal follower parses sshd's `Accepted ...` line
   directly (section 15) and creates the session record *and* emits `ssh.session.start`
   immediately, with `tty` left `null`. This is what still produces auth/session records for
   non-interactive `ssh host cmd` and SFTP/SCP sessions, which never source `/etc/profile.d`.
2. **Enrichment path**: `/etc/profile.d/91-authtrail-session.sh` fires once per login shell,
   emits `{tty, source_ip, source_port, ...}` via `logger -t authtrail-session`. `authtraild`
   correlates it back to the session created in step 1 using the client `source_ip:source_port`
   tuple — the same value sshd logged and the value the shell sees via `SSH_CONNECTION`, so it's
   safe to use as a natural join key without inventing a new identifier.

`/run/authtraild` is the single authority for session/TTY state; hooks only ever emit raw facts
through `logger` and never write state directly.

## Privilege transition detection

Rather than pattern-matching `su`/`sudo` command text (which can't tell a requested transition
from a successful one), `authtraild` compares the `user` field the bash hook reports on each
command against the `current_user` already stored for that TTY. A mismatch is the actual
confirmed evidence of a successful account switch — it emits `privilege.transition` (with the
previous command attached as context) and updates the TTY state before logging the new
`command.executed`. See `handle_command_event()` in `src/authtraild`.

## Correlating session end

`sshd-session[PID]` is the same PID across a whole login's `Accepted ...` and
`pam_unix(sshd:session): session closed ...` journal lines. `authtraild` keys a second index,
`/run/authtraild/conn/pid_<PID>`, off that PID at auth-success time, so the "session closed" line
can look the session back up and emit `ssh.session.end` with an accurate duration, then clean up
all state for that session (including its TTY entry, which is what makes TTY-reuse safe).
Purpose acceptance stores a second epoch, so session end reports total connection time in
`duration_seconds` and post-justification shell time in `active_duration_seconds`. An atomic
per-session close lock and deterministic end-event ID prevent PAM/PID-reaper races from creating
duplicate end events.

Interactive Slack lifecycle payloads are atomically queued under
`/var/lib/authtraild/slack-queue`; webhook I/O never runs on the journal ingestion path. The
worker sends at most one item per second, retries transient failures, and recovers claimed items
after daemon restart. Queue files contain payloads and correlation metadata, never the webhook.

## Event schema

Every event follows the canonical schema implemented by `build_event_json()` — `schema_version`,
`event`, `event_id`, `timestamp`, `hostname`, `session_id`, `identity`, `key_fingerprint`,
`auth_method`, `source_ip`/`source_port`, `login_user`, `current_user`, `tty`, `cwd`, `command`,
`exit_code`, `pid`, `severity`, plus event-specific fields (`from_user`/`to_user` for
`privilege.transition`, `attempt_count`/`attempted_users` for `ssh.auth.failure_burst`). Unset
fields are always `null`, never an invented placeholder string. See `build_event_json()` in
`src/libauthtrail.sh`.

## State layout

```
/run/authtraild/
├── sessions/<session_id>   canonical, written once at auth-success
├── tty/<tty_key>           live/mutable: current_user, last_command
├── conn/ip_<ip>_<port>     session_id lookup for the session-init hook
├── conn/pid_<sshd_pid>     session_id lookup for session-end correlation
├── failures/<source_ip>    failure-burst counters (window/count/cooldown/users)
└── purpose/<token>.json    short-lived, non-listable request acknowledgement
```

All writes go through `atomic_write()` (temp file + `mv`) to avoid partial reads by concurrent
readers such as `atctl sessions`.
