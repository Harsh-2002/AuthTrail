#!/bin/sh
# install-readiness.sh - bounded daemon readiness wait used by the installer and tests.

wait_for_purpose_runtime()
{
    readiness_cli=$1
    max_attempts=$2
    retry_delay=$3
    readiness_attempt=0

    while ! "$readiness_cli" purpose-status >/dev/null 2>&1; do
        readiness_attempt=$((readiness_attempt + 1))
        [ "$readiness_attempt" -lt "$max_attempts" ] || return 1
        sleep "$retry_delay"
    done
}
