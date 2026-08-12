.PHONY: shellcheck test install uninstall

shellcheck:
	shellcheck -s sh src/authtraild src/authtrailctl src/libauthtrail.sh src/authtrail-session-hook.sh src/authtrail-purpose.sh src/authtrail-audit-parser.sh install.sh uninstall.sh tests/*.sh
	shellcheck -s bash src/authtrail-bash-hook.sh src/authtrailctl-completion.bash

test: shellcheck
	for t in tests/test-*.sh; do sh "$$t" || exit 1; done

install:
	./install.sh

uninstall:
	./uninstall.sh
