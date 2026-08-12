# Fixtures

sshd journal-line fixtures used by `test-sshd-parser.sh`.

- `sshd-accepted-publickey.txt` - captured live from `journalctl -u ssh.service`
  on the test node (Debian 13, OpenSSH 10.0p2, `sshd-session[PID]:` format).
  Real, not synthetic.
- `sshd-accepted-password.txt`, `sshd-failed-publickey.txt`,
  `sshd-failed-password-invaliduser.txt`, `sshd-session-closed.txt` - written
  by hand to match the same OpenSSH log format documented in `sshd(8)` /
  observed upstream, then cross-checked against real failure/password lines
  captured on the test node during the Phase 13 test pass (see
  `docs/operations.md` for what was actually observed live).
