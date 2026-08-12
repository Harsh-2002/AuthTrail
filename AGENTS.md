# AGENTS.md

Required repository entry point. Read the documents below in order before changing code, tests,
configuration, or documentation:

1. **`PRODUCT.md`** — product intent, scope, user experience, and current feature definition.
2. **`CONTRACT.md`** — non-negotiable behavioral guarantees. A change must not violate these.
3. **`CLAUDE.md`** — commands, implementation conventions, tests, and code architecture.
4. Read the task-relevant file under **`docs/`**.
5. Read **`DEPLOY.md`** before any production installation, upgrade, or host-side validation.

Do not rely on historical plans. The files above and the tested implementation are the maintained
sources of truth. If they disagree, stop and make the inconsistency explicit rather than choosing
whichever behavior is easiest to implement.

Quick reference (see `CLAUDE.md` for the full picture):

```sh
make test                 # shellcheck + full test suite
sudo ./install.sh         # install
sudo atctl verify         # config/permission sanity check, no side effects
```

Everything here is POSIX `/bin/sh` except `src/authtrail-bash-hook.sh` and
`src/authtrailctl-completion.bash` (intentionally Bash-specific — see `CLAUDE.md`). Comments are
single-line only. JSON is always built with `jq`.
Never `eval`. Use only dummy names (`alice@example.com`, `testhost`) in code/tests/docs, never
real people's names.
