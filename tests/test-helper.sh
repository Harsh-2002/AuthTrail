#!/bin/sh
# test-helper.sh - minimal assertion helpers shared by test-*.sh. Not a
# framework, just enough to avoid repeating boilerplate across files.

set -u

TESTS_RUN=0
TESTS_FAILED=0

assert_eq()
{
    label=$1
    expected=$2
    actual=$3

    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        printf '[ OK ] %s\n' "$label"
    else
        printf '[FAIL] %s: expected [%s] got [%s]\n' "$label" "$expected" "$actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# Subshell matters: some functions under test (e.g. validate_config) call die()/exit, which would otherwise kill the whole test script.
assert_true()
{
    label=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if (
        "$@"
    ) >/dev/null 2>&1; then
        printf '[ OK ] %s\n' "$label"
    else
        printf '[FAIL] %s (expected success)\n' "$label"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_false()
{
    label=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if (
        "$@"
    ) >/dev/null 2>&1; then
        printf '[FAIL] %s (expected failure)\n' "$label"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        printf '[ OK ] %s\n' "$label"
    fi
}

skip()
{
    printf '[SKIP] %s\n' "$1"
}

assert_contains()
{
    label=$1
    haystack=$2
    needle=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$haystack" in
        *"$needle"*) printf '[ OK ] %s\n' "$label" ;;
        *)
            printf '[FAIL] %s: expected to find [%s] in [%s]\n' "$label" "$needle" "$haystack"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ;;
    esac
}

assert_not_contains()
{
    label=$1
    haystack=$2
    needle=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    case "$haystack" in
        *"$needle"*)
            printf '[FAIL] %s: found forbidden substring [%s] in [%s]\n' "$label" "$needle" "$haystack"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ;;
        *) printf '[ OK ] %s\n' "$label" ;;
    esac
}

test_summary()
{
    printf '\n%s: %s/%s assertions passed\n' "$0" "$((TESTS_RUN - TESTS_FAILED))" "$TESTS_RUN"
    [ "$TESTS_FAILED" -eq 0 ]
}
