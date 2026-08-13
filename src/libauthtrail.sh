#!/bin/sh
# libauthtrail.sh - shared POSIX sh library for authtraild / authtrailctl. Sourced only, never executed directly.
# No `set -e` here on purpose: this is sourced into a long-running daemon loop, so every fallible call checks its own status.

CONFIG_FILE=${AUTH_TRAIL_CONFIG_FILE:-/etc/authtraild/authtraild.conf}

AUTH_TRAIL_ENABLED=${AUTH_TRAIL_ENABLED:-1}
AUTH_TRAIL_HOSTNAME=${AUTH_TRAIL_HOSTNAME:-}
AUTH_TRAIL_ENVIRONMENT=${AUTH_TRAIL_ENVIRONMENT:-production}

AUTH_TRAIL_LOG_DIR=${AUTH_TRAIL_LOG_DIR:-/var/log/authtraild}
AUTH_TRAIL_LOG_OWNER=${AUTH_TRAIL_LOG_OWNER:-root}
AUTH_TRAIL_LOG_GROUP=${AUTH_TRAIL_LOG_GROUP:-root}
AUTH_TRAIL_LOG_MODE=${AUTH_TRAIL_LOG_MODE:-0640}

AUTH_TRAIL_RUN_DIR=${AUTH_TRAIL_RUN_DIR:-/run/authtraild}
AUTH_TRAIL_DATA_DIR=${AUTH_TRAIL_DATA_DIR:-/var/lib/authtraild}

AUTH_TRAIL_COMMAND_CAPTURE=${AUTH_TRAIL_COMMAND_CAPTURE:-1}
AUTH_TRAIL_COMMAND_MAX_LEN=${AUTH_TRAIL_COMMAND_MAX_LEN:-8192}
AUTH_TRAIL_REDACT_SECRETS=${AUTH_TRAIL_REDACT_SECRETS:-1}

AUTH_TRAIL_PURPOSE_ENABLED=${AUTH_TRAIL_PURPOSE_ENABLED:-1}
AUTH_TRAIL_PURPOSE_REQUIRED=${AUTH_TRAIL_PURPOSE_REQUIRED:-1}
AUTH_TRAIL_PURPOSE_MIN_LENGTH=${AUTH_TRAIL_PURPOSE_MIN_LENGTH:-5}
AUTH_TRAIL_PURPOSE_MAX_LENGTH=${AUTH_TRAIL_PURPOSE_MAX_LENGTH:-500}
AUTH_TRAIL_PURPOSE_FULLSCREEN=${AUTH_TRAIL_PURPOSE_FULLSCREEN:-1}
AUTH_TRAIL_PURPOSE_CLEAR_AFTER=${AUTH_TRAIL_PURPOSE_CLEAR_AFTER:-1}
AUTH_TRAIL_PURPOSE_FAIL_MODE=${AUTH_TRAIL_PURPOSE_FAIL_MODE:-closed}
AUTH_TRAIL_SLACK_INCLUDE_PURPOSE=${AUTH_TRAIL_SLACK_INCLUDE_PURPOSE:-1}

AUTH_TRAIL_AUDITD_ENABLED=${AUTH_TRAIL_AUDITD_ENABLED:-0}
AUTH_TRAIL_PRIVILEGE_MONITORING=${AUTH_TRAIL_PRIVILEGE_MONITORING:-1}
AUTH_TRAIL_ACCESS_CHANGE_MONITORING=${AUTH_TRAIL_ACCESS_CHANGE_MONITORING:-1}

AUTH_TRAIL_SSH_UNIT=${AUTH_TRAIL_SSH_UNIT:-}

AUTH_TRAIL_FAILURE_BURST_ENABLED=${AUTH_TRAIL_FAILURE_BURST_ENABLED:-1}
AUTH_TRAIL_FAILURE_BURST_WINDOW=${AUTH_TRAIL_FAILURE_BURST_WINDOW:-300}
AUTH_TRAIL_FAILURE_BURST_THRESHOLD=${AUTH_TRAIL_FAILURE_BURST_THRESHOLD:-5}
AUTH_TRAIL_FAILURE_BURST_COOLDOWN=${AUTH_TRAIL_FAILURE_BURST_COOLDOWN:-600}

AUTH_TRAIL_SLACK_ENABLED=${AUTH_TRAIL_SLACK_ENABLED:-0}
AUTH_TRAIL_SLACK_WEBHOOK_URL=${AUTH_TRAIL_SLACK_WEBHOOK_URL:-}
AUTH_TRAIL_SLACK_TIMEOUT=${AUTH_TRAIL_SLACK_TIMEOUT:-5}
AUTH_TRAIL_SLACK_PROFILE=${AUTH_TRAIL_SLACK_PROFILE:-actionable}
AUTH_TRAIL_SLACK_QUEUE_ENABLED=${AUTH_TRAIL_SLACK_QUEUE_ENABLED:-1}
AUTH_TRAIL_SLACK_QUEUE_MAX=${AUTH_TRAIL_SLACK_QUEUE_MAX:-1000}
AUTH_TRAIL_SLACK_RETRY_MAX=${AUTH_TRAIL_SLACK_RETRY_MAX:-8}

AUTH_TRAIL_SLACK_LOGIN=${AUTH_TRAIL_SLACK_LOGIN:-1}
AUTH_TRAIL_SLACK_LOGOUT=${AUTH_TRAIL_SLACK_LOGOUT:-1}
AUTH_TRAIL_SLACK_FAILURE=${AUTH_TRAIL_SLACK_FAILURE:-1}
AUTH_TRAIL_SLACK_FAILURE_BURST=${AUTH_TRAIL_SLACK_FAILURE_BURST:-1}
AUTH_TRAIL_SLACK_PRIVILEGE=${AUTH_TRAIL_SLACK_PRIVILEGE:-1}
AUTH_TRAIL_SLACK_ACCESS_CHANGES=${AUTH_TRAIL_SLACK_ACCESS_CHANGES:-1}
AUTH_TRAIL_SLACK_COMMAND_ALERTS=${AUTH_TRAIL_SLACK_COMMAND_ALERTS:-0}

AUTH_TRAIL_KEY_MAP=${AUTH_TRAIL_KEY_MAP:-/etc/authtraild/keys.map}
AUTH_TRAIL_SENSITIVE_COMMANDS=${AUTH_TRAIL_SENSITIVE_COMMANDS:-/etc/authtraild/sensitive-commands.conf}
AUTH_TRAIL_REDACT_FILE=${AUTH_TRAIL_REDACT_FILE:-/etc/authtraild/redact.conf}

PROGRAM=${PROGRAM:-authtraild}

# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------

log_stderr()
{
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
}

die()
{
    log_stderr "$*"
    exit 1
}

have_cmd()
{
    command -v "$1" >/dev/null 2>&1
}

require_runtime()
{
    missing=''
    for cmd in awk sed grep cut tr date hostname logger journalctl jq curl ssh-keygen ps; do
        if ! have_cmd "$cmd"; then
            missing="${missing}${missing:+ }${cmd}"
        fi
    done
    if [ -n "$missing" ]; then
        die "missing required commands: $missing"
    fi
}

# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

# Refuse configs that aren't root:root 0600/0400 - sourced as root, so a laxer mode could smuggle in a webhook override.
config_owner_and_mode_ok()
{
    cfg=$1
    [ -f "$cfg" ] || return 1

    owner=$(stat -c '%U' "$cfg" 2>/dev/null) || return 1
    mode=$(stat -c '%a' "$cfg" 2>/dev/null) || return 1

    [ "$owner" = 'root' ] || return 1

    case "$mode" in
        600 | 400) return 0 ;;
        *) return 1 ;;
    esac
}

load_config()
{
    if [ -f "$CONFIG_FILE" ]; then
        if ! config_owner_and_mode_ok "$CONFIG_FILE"; then
            die "refusing to load $CONFIG_FILE: must be owned by root with mode 0600 or 0400"
        fi
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi

    if [ -z "$AUTH_TRAIL_HOSTNAME" ]; then
        AUTH_TRAIL_HOSTNAME=$(hostname 2>/dev/null || printf '%s' unknown)
    fi

    validate_config
}

# No eval/indirection here on purpose - each variable is checked by name explicitly.
require_bool()
{
    name=$1
    value=$2
    case "$value" in
        0 | 1) ;;
        *) die "invalid boolean value for $name: '$value' (expected 0 or 1)" ;;
    esac
}

require_number()
{
    name=$1
    value=$2
    case "$value" in
        '' | *[!0-9]*) die "invalid numeric value for $name: '$value'" ;;
    esac
}

validate_config()
{
    require_bool AUTH_TRAIL_ENABLED "$AUTH_TRAIL_ENABLED"
    require_bool AUTH_TRAIL_COMMAND_CAPTURE "$AUTH_TRAIL_COMMAND_CAPTURE"
    require_bool AUTH_TRAIL_REDACT_SECRETS "$AUTH_TRAIL_REDACT_SECRETS"
    require_bool AUTH_TRAIL_PURPOSE_ENABLED "$AUTH_TRAIL_PURPOSE_ENABLED"
    require_bool AUTH_TRAIL_PURPOSE_REQUIRED "$AUTH_TRAIL_PURPOSE_REQUIRED"
    require_bool AUTH_TRAIL_PURPOSE_FULLSCREEN "$AUTH_TRAIL_PURPOSE_FULLSCREEN"
    require_bool AUTH_TRAIL_PURPOSE_CLEAR_AFTER "$AUTH_TRAIL_PURPOSE_CLEAR_AFTER"
    require_bool AUTH_TRAIL_SLACK_INCLUDE_PURPOSE "$AUTH_TRAIL_SLACK_INCLUDE_PURPOSE"
    require_bool AUTH_TRAIL_AUDITD_ENABLED "$AUTH_TRAIL_AUDITD_ENABLED"
    require_bool AUTH_TRAIL_PRIVILEGE_MONITORING "$AUTH_TRAIL_PRIVILEGE_MONITORING"
    require_bool AUTH_TRAIL_ACCESS_CHANGE_MONITORING "$AUTH_TRAIL_ACCESS_CHANGE_MONITORING"
    require_bool AUTH_TRAIL_FAILURE_BURST_ENABLED "$AUTH_TRAIL_FAILURE_BURST_ENABLED"
    require_bool AUTH_TRAIL_SLACK_ENABLED "$AUTH_TRAIL_SLACK_ENABLED"
    require_bool AUTH_TRAIL_SLACK_LOGIN "$AUTH_TRAIL_SLACK_LOGIN"
    require_bool AUTH_TRAIL_SLACK_LOGOUT "$AUTH_TRAIL_SLACK_LOGOUT"
    require_bool AUTH_TRAIL_SLACK_FAILURE "$AUTH_TRAIL_SLACK_FAILURE"
    require_bool AUTH_TRAIL_SLACK_FAILURE_BURST "$AUTH_TRAIL_SLACK_FAILURE_BURST"
    require_bool AUTH_TRAIL_SLACK_PRIVILEGE "$AUTH_TRAIL_SLACK_PRIVILEGE"
    require_bool AUTH_TRAIL_SLACK_ACCESS_CHANGES "$AUTH_TRAIL_SLACK_ACCESS_CHANGES"
    require_bool AUTH_TRAIL_SLACK_COMMAND_ALERTS "$AUTH_TRAIL_SLACK_COMMAND_ALERTS"
    require_bool AUTH_TRAIL_SLACK_QUEUE_ENABLED "$AUTH_TRAIL_SLACK_QUEUE_ENABLED"

    case "$AUTH_TRAIL_SLACK_PROFILE" in
        actionable | verbose) ;;
        *) die "invalid AUTH_TRAIL_SLACK_PROFILE: '$AUTH_TRAIL_SLACK_PROFILE' (expected actionable or verbose)" ;;
    esac

    if [ "$AUTH_TRAIL_SLACK_ENABLED" = '1' ] && \
        ! valid_slack_webhook_url "$AUTH_TRAIL_SLACK_WEBHOOK_URL"; then
        die 'invalid AUTH_TRAIL_SLACK_WEBHOOK_URL (expected HTTPS with a /services/... path)'
    fi

    require_number AUTH_TRAIL_COMMAND_MAX_LEN "$AUTH_TRAIL_COMMAND_MAX_LEN"
    require_number AUTH_TRAIL_PURPOSE_MIN_LENGTH "$AUTH_TRAIL_PURPOSE_MIN_LENGTH"
    require_number AUTH_TRAIL_PURPOSE_MAX_LENGTH "$AUTH_TRAIL_PURPOSE_MAX_LENGTH"
    require_number AUTH_TRAIL_SLACK_TIMEOUT "$AUTH_TRAIL_SLACK_TIMEOUT"
    require_number AUTH_TRAIL_SLACK_QUEUE_MAX "$AUTH_TRAIL_SLACK_QUEUE_MAX"
    require_number AUTH_TRAIL_SLACK_RETRY_MAX "$AUTH_TRAIL_SLACK_RETRY_MAX"
    require_number AUTH_TRAIL_FAILURE_BURST_WINDOW "$AUTH_TRAIL_FAILURE_BURST_WINDOW"
    require_number AUTH_TRAIL_FAILURE_BURST_THRESHOLD "$AUTH_TRAIL_FAILURE_BURST_THRESHOLD"
    require_number AUTH_TRAIL_FAILURE_BURST_COOLDOWN "$AUTH_TRAIL_FAILURE_BURST_COOLDOWN"

    case "$AUTH_TRAIL_LOG_MODE" in
        '' | *[!0-7]*) die "invalid AUTH_TRAIL_LOG_MODE: '$AUTH_TRAIL_LOG_MODE'" ;;
    esac

    case "$AUTH_TRAIL_PURPOSE_FAIL_MODE" in
        closed | open) ;;
        *) die "invalid AUTH_TRAIL_PURPOSE_FAIL_MODE: '$AUTH_TRAIL_PURPOSE_FAIL_MODE'" ;;
    esac

    if [ "$AUTH_TRAIL_PURPOSE_MIN_LENGTH" -gt "$AUTH_TRAIL_PURPOSE_MAX_LENGTH" ]; then
        die 'AUTH_TRAIL_PURPOSE_MIN_LENGTH must not exceed AUTH_TRAIL_PURPOSE_MAX_LENGTH'
    fi
}

# ---------------------------------------------------------------------------
# Time / identifiers
# ---------------------------------------------------------------------------

iso_timestamp()
{
    date +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([0-9]{2})([0-9]{2})$/\1:\2/'
}

epoch_now()
{
    date +%s
}

format_duration()
{
    total=${1:-0}
    case "$total" in '' | *[!0-9]*) total=0 ;; esac
    days=$((total / 86400))
    hours=$(((total % 86400) / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))
    if [ "$days" -gt 0 ]; then
        printf '%dd %dh %dm' "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf '%dh %dm %ds' "$hours" "$minutes" "$seconds"
    elif [ "$minutes" -gt 0 ]; then
        printf '%dm %ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

session_access_epoch()
{
    state_file=$1
    value=$(kv_get "$state_file" access_start_epoch)
    case "$value" in
        '' | *[!0-9]*)
            recorded=$(kv_get "$state_file" purpose_recorded_at)
            [ -n "$recorded" ] || return 1
            value=$(date -d "$recorded" +%s 2>/dev/null) || return 1
            ;;
    esac
    printf '%s' "$value"
}

gen_event_id()
{
    ns=$(date +%N 2>/dev/null)
    case "$ns" in
        '' | N) ns=0 ;;
    esac
    printf '%s-%s-%s-%s' "$AUTH_TRAIL_HOSTNAME" "$(date -u +%Y%m%dT%H%M%S)" "$ns" "$$"
}

gen_session_id()
{
    init_pid=$1
    rand=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ -z "$rand" ]; then
        rand=$(date +%N 2>/dev/null | cut -c1-4)
    fi
    [ -n "$rand" ] || rand=$$
    printf '%s-%s-p%s-%s' "$AUTH_TRAIL_HOSTNAME" "$(date -u +%Y%m%dT%H%M%S)" "$init_pid" "$rand"
}

# ---------------------------------------------------------------------------
# Atomic small-state-file helpers (used under AUTH_TRAIL_RUN_DIR)
# ---------------------------------------------------------------------------

atomic_write()
{
    path=$1
    content=$2
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${dir}/.tmp.XXXXXX") || return 1
    printf '%s\n' "$content" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv -f "$tmp" "$path"
}

kv_get()
{
    path=$1
    key=$2
    [ -f "$path" ] || return 1
    grep "^${key}=" "$path" 2>/dev/null | tail -n1 | cut -d= -f2-
}

kv_set()
{
    path=$1
    key=$2
    value=$3
    dir=$(dirname "$path")
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${dir}/.tmp.XXXXXX") || return 1
    found=0
    if [ -f "$path" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$key="*)
                    if [ "$found" -eq 0 ]; then
                        printf '%s=%s\n' "$key" "$value" >>"$tmp"
                        found=1
                    fi
                    ;;
                *) printf '%s\n' "$line" >>"$tmp" ;;
            esac
        done <"$path"
    fi
    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >>"$tmp"
    fi
    mv -f "$tmp" "$path"
}

tty_key()
{
    printf '%s' "$1" | sed 's#^/dev/##; s#/#_#g'
}

# ---------------------------------------------------------------------------
# Redaction / classification
# ---------------------------------------------------------------------------

redact_command()
{
    text=$1

    if [ "$AUTH_TRAIL_REDACT_SECRETS" != '1' ] || [ ! -f "$AUTH_TRAIL_REDACT_FILE" ]; then
        printf '%s' "$text"
        return 0
    fi

    out=$text
    while IFS= read -r pattern; do
        case "$pattern" in
            '' | '#'*) continue ;;
        esac
        redacted=$(printf '%s' "$out" | sed -E "s/(${pattern})[^[:space:]\"\']*/\\1[REDACTED]/g" 2>/dev/null) && out=$redacted
    done <"$AUTH_TRAIL_REDACT_FILE"

    printf '%s' "$out"
}

truncate_command()
{
    text=$1
    max=$AUTH_TRAIL_COMMAND_MAX_LEN
    len=$(printf '%s' "$text" | wc -c | tr -d ' ')
    if [ "$len" -gt "$max" ] 2>/dev/null; then
        printf '%s' "$text" | cut -c "1-${max}"
    else
        printf '%s' "$text"
    fi
}

is_sensitive_command()
{
    cmd=$1
    [ -f "$AUTH_TRAIL_SENSITIVE_COMMANDS" ] || return 1
    while IFS= read -r pattern; do
        case "$pattern" in
            '' | '#'*) continue ;;
        esac
        case "$cmd" in
            *"$pattern"*) return 0 ;;
        esac
    done <"$AUTH_TRAIL_SENSITIVE_COMMANDS"
    return 1
}

# ---------------------------------------------------------------------------
# Key registry
# ---------------------------------------------------------------------------

# Prints the identity for a "SHA256:..." fingerprint, or "unmapped" - never invents one.
lookup_identity()
{
    fp=$1
    [ -n "$fp" ] || {
        printf 'unmapped'
        return 0
    }
    [ -f "$AUTH_TRAIL_KEY_MAP" ] || {
        printf 'unmapped'
        return 0
    }

    match=$(awk -F'|' -v fp="$fp" '
        $0 ~ /^#/ || $0 == "" { next }
        $1 == fp { print $2; found=1; exit }
        END { if (!found) exit 1 }
    ' "$AUTH_TRAIL_KEY_MAP")

    if [ -n "$match" ]; then
        printf '%s' "$match"
    else
        printf 'unmapped'
    fi
}

# ---------------------------------------------------------------------------
# Log directory / file setup
# ---------------------------------------------------------------------------

ensure_log_files()
{
    mkdir -p "$AUTH_TRAIL_LOG_DIR" || return 1
    chown "${AUTH_TRAIL_LOG_OWNER}:${AUTH_TRAIL_LOG_GROUP}" "$AUTH_TRAIL_LOG_DIR" 2>/dev/null || :
    chmod 0750 "$AUTH_TRAIL_LOG_DIR" 2>/dev/null || :

    f="$AUTH_TRAIL_LOG_DIR/events.jsonl"
    [ -f "$f" ] || : >"$f"
    chown "${AUTH_TRAIL_LOG_OWNER}:${AUTH_TRAIL_LOG_GROUP}" "$f" 2>/dev/null || :
    chmod "$AUTH_TRAIL_LOG_MODE" "$f" 2>/dev/null || :

    mkdir -p "$AUTH_TRAIL_RUN_DIR/sessions" "$AUTH_TRAIL_RUN_DIR/tty" \
        "$AUTH_TRAIL_RUN_DIR/conn" "$AUTH_TRAIL_RUN_DIR/failures" \
        "$AUTH_TRAIL_RUN_DIR/purpose" "$AUTH_TRAIL_RUN_DIR/closing" 2>/dev/null || :
    chmod 0711 "$AUTH_TRAIL_RUN_DIR" 2>/dev/null || :
    chmod 0750 "$AUTH_TRAIL_RUN_DIR/sessions" "$AUTH_TRAIL_RUN_DIR/tty" \
        "$AUTH_TRAIL_RUN_DIR/conn" "$AUTH_TRAIL_RUN_DIR/failures" 2>/dev/null || :
    chmod 0750 "$AUTH_TRAIL_RUN_DIR/closing" 2>/dev/null || :
    chmod 0711 "$AUTH_TRAIL_RUN_DIR/purpose" 2>/dev/null || :
    ensure_slack_queue 2>/dev/null || :
    policy=$(jq -nc --arg fail_mode "$AUTH_TRAIL_PURPOSE_FAIL_MODE" \
        '{fail_mode:$fail_mode}')
    atomic_write "$AUTH_TRAIL_RUN_DIR/purpose/policy.json" "$policy" 2>/dev/null || :
    chmod 0644 "$AUTH_TRAIL_RUN_DIR/purpose/policy.json" 2>/dev/null || :
}

purpose_runtime_ready()
{
    policy_file="$AUTH_TRAIL_RUN_DIR/purpose/policy.json"
    [ -d "$AUTH_TRAIL_RUN_DIR/purpose" ] || return 1
    [ -r "$policy_file" ] || return 1
    jq -e '.fail_mode == "closed" or .fail_mode == "open"' "$policy_file" >/dev/null 2>&1
}

ensure_slack_queue()
{
    mkdir -p "$AUTH_TRAIL_DATA_DIR/slack-queue/pending" \
        "$AUTH_TRAIL_DATA_DIR/slack-queue/processing" || return 1
    chmod 0700 "$AUTH_TRAIL_DATA_DIR" "$AUTH_TRAIL_DATA_DIR/slack-queue" \
        "$AUTH_TRAIL_DATA_DIR/slack-queue/pending" \
        "$AUTH_TRAIL_DATA_DIR/slack-queue/processing" 2>/dev/null || :
}

recover_slack_queue()
{
    ensure_slack_queue || return 1
    for qf in "$AUTH_TRAIL_DATA_DIR"/slack-queue/processing/*; do
        [ -e "$qf" ] || continue
        mv -f "$qf" "$AUTH_TRAIL_DATA_DIR/slack-queue/pending/${qf##*/}" 2>/dev/null || :
    done
}

# Writes one canonical JSON event line and mirrors it to journald before Slack is attempted.
write_event()
{
    event_json=$1
    event_name=$2

    mkdir -p "$AUTH_TRAIL_LOG_DIR" 2>/dev/null || return 1

    printf '%s\n' "$event_json" >>"$AUTH_TRAIL_LOG_DIR/events.jsonl" 2>/dev/null || return 1

    printf '%s\n' "$event_json" | logger -t authtraild -- 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# Canonical event builder (section 11 schema). Callers set EV_* variables, then call emit_event; unset fields become null.
# ---------------------------------------------------------------------------

build_event_json()
{
    jq -nc \
        --argjson schema_version 1 \
        --arg event "${EV_EVENT:-}" \
        --arg event_id "${EV_EVENT_ID:-$(gen_event_id)}" \
        --arg timestamp "$(iso_timestamp)" \
        --arg hostname "$AUTH_TRAIL_HOSTNAME" \
        --arg environment "$AUTH_TRAIL_ENVIRONMENT" \
        --arg session_id "${EV_SESSION_ID:-}" \
        --arg identity "${EV_IDENTITY:-}" \
        --arg key_fingerprint "${EV_FINGERPRINT:-}" \
        --arg key_algorithm "${EV_KEY_ALGORITHM:-}" \
        --arg auth_method "${EV_AUTH_METHOD:-}" \
        --arg source_ip "${EV_SOURCE_IP:-}" \
        --arg source_port "${EV_SOURCE_PORT:-}" \
        --arg server_ip "${EV_SERVER_IP:-}" \
        --arg server_port "${EV_SERVER_PORT:-}" \
        --arg login_user "${EV_LOGIN_USER:-}" \
        --arg current_user "${EV_CURRENT_USER:-}" \
        --arg tty "${EV_TTY:-}" \
        --arg cwd "${EV_CWD:-}" \
        --arg command "${EV_COMMAND:-}" \
        --arg exit_code "${EV_EXIT_CODE:-}" \
        --arg pid "${EV_PID:-}" \
        --arg severity "${EV_SEVERITY:-info}" \
        --arg from_user "${EV_FROM_USER:-}" \
        --arg to_user "${EV_TO_USER:-}" \
        --arg purpose "${EV_PURPOSE:-}" \
        --arg purpose_state "${EV_PURPOSE_STATE:-}" \
        --arg purpose_recorded_at "${EV_PURPOSE_RECORDED_AT:-}" \
        --arg interactive "${EV_INTERACTIVE:-}" \
        --arg purpose_required "${EV_PURPOSE_REQUIRED:-}" \
        --arg reason "${EV_REASON:-}" \
        --arg shell_allowed "${EV_SHELL_ALLOWED:-}" \
        --arg extra "${EV_EXTRA_JSON:-}" \
        '
        def emptynull: if . == "" then null else . end;
        def numnull: if . == "" then null else (tonumber? // null) end;
        {
          schema_version: $schema_version,
          event: $event,
          event_id: $event_id,
          timestamp: $timestamp,
          hostname: $hostname,
          environment: $environment,
          session_id: ($session_id | emptynull),
          identity: ($identity | emptynull),
          key_fingerprint: ($key_fingerprint | emptynull),
          key_algorithm: ($key_algorithm | emptynull),
          auth_method: ($auth_method | emptynull),
          source_ip: ($source_ip | emptynull),
          source_port: ($source_port | numnull),
          server_ip: ($server_ip | emptynull),
          server_port: ($server_port | numnull),
          login_user: ($login_user | emptynull),
          current_user: ($current_user | emptynull),
          tty: ($tty | emptynull),
          cwd: ($cwd | emptynull),
          command: ($command | emptynull),
          exit_code: ($exit_code | numnull),
          pid: ($pid | numnull),
          severity: $severity,
          from_user: ($from_user | emptynull),
          to_user: ($to_user | emptynull),
          purpose: ($purpose | emptynull),
          purpose_state: ($purpose_state | emptynull),
          purpose_recorded_at: ($purpose_recorded_at | emptynull),
          interactive: (if $interactive == "" then null else $interactive == "true" end),
          purpose_required: (if $purpose_required == "" then null else $purpose_required == "true" end),
          reason: ($reason | emptynull),
          shell_allowed: (if $shell_allowed == "" then null else $shell_allowed == "true" end)
        }
        + (if $extra == "" then {} else ($extra | fromjson) end)
        '
}

# Builds, writes, and Slack-dispatches the event, then clears EV_* for the next caller.
emit_event()
{
    event_name=${EV_EVENT:-}
    event_json=$(build_event_json) || {
        clear_event_vars
        return 1
    }

    write_event "$event_json" "$event_name"
    if [ "${EV_NO_SLACK:-0}" != '1' ]; then
        dispatch_slack "$event_name" "$event_json"
    fi

    clear_event_vars
    printf '%s' "$event_json"
}

clear_event_vars()
{
    unset EV_EVENT EV_EVENT_ID EV_SESSION_ID EV_IDENTITY EV_FINGERPRINT EV_KEY_ALGORITHM \
        EV_AUTH_METHOD EV_SOURCE_IP EV_SOURCE_PORT EV_SERVER_IP EV_SERVER_PORT \
        EV_LOGIN_USER EV_CURRENT_USER EV_TTY EV_CWD EV_COMMAND EV_EXIT_CODE \
        EV_PID EV_SEVERITY EV_FROM_USER EV_TO_USER EV_PURPOSE EV_PURPOSE_STATE \
        EV_PURPOSE_RECORDED_AT EV_INTERACTIVE EV_PURPOSE_REQUIRED EV_REASON \
        EV_SHELL_ALLOWED EV_NO_SLACK EV_EXTRA_JSON
}

# ---------------------------------------------------------------------------
# Slack (Block Kit) - section 26/27/28
# ---------------------------------------------------------------------------

slack_http_post()
{
    payload=$1
    SLACK_HTTP_CODE=0
    SLACK_CURL_STATUS=0
    SLACK_RETRY_AFTER=0

    if ! valid_slack_webhook_url "$AUTH_TRAIL_SLACK_WEBHOOK_URL"; then
        SLACK_HTTP_CODE=400
        return 1
    fi

    response_file=$(mktemp) || return 1
    header_file=$(mktemp) || {
        rm -f "$response_file"
        return 1
    }

    SLACK_HTTP_CODE=$(
        printf 'url = "%s"\n' "$AUTH_TRAIL_SLACK_WEBHOOK_URL" | curl \
            --config - \
            --silent \
            --show-error \
            --output "$response_file" \
            --dump-header "$header_file" \
            --write-out '%{http_code}' \
            --max-time "$AUTH_TRAIL_SLACK_TIMEOUT" \
            --header 'Content-Type: application/json' \
            --data "$payload" 2>/dev/null
    )
    SLACK_CURL_STATUS=$?
    retry_value=$(awk 'BEGIN{IGNORECASE=1} /^Retry-After:/ {gsub("\r", "", $2); print $2; exit}' "$header_file" 2>/dev/null)
    case "$retry_value" in '' | *[!0-9]*) ;; *) SLACK_RETRY_AFTER=$retry_value ;; esac

    rm -f "$response_file" "$header_file"

    if [ "$SLACK_CURL_STATUS" -ne 0 ] || [ "$SLACK_HTTP_CODE" -lt 200 ] || [ "$SLACK_HTTP_CODE" -ge 300 ]; then
        return 1
    fi
    return 0
}

valid_slack_webhook_url()
{
    printf '%s' "$1" | grep -Eq \
        '^https://[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+/services/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$'
}

record_slack_delivery()
{
    delivery_event=$1
    original_event=$2
    original_event_id=$3
    original_session_id=$4
    attempts=$5
    reason=$6
    EV_EVENT=$delivery_event
    EV_SESSION_ID=$original_session_id
    case "$delivery_event" in slack.delivery.success) EV_SEVERITY=info ;; *) EV_SEVERITY=warning ;; esac
    EV_EXTRA_JSON=$(jq -nc --arg original_event "$original_event" \
        --arg original_event_id "$original_event_id" --arg attempts "$attempts" \
        --arg reason "$reason" --arg http "$SLACK_HTTP_CODE" --arg curl "$SLACK_CURL_STATUS" \
        '{original_event:$original_event,original_event_id:$original_event_id,
          delivery_attempts:($attempts|tonumber),reason:($reason|select(length>0)//null),
          http_status:($http|tonumber? // null),curl_status:($curl|tonumber? // null)}')
    delivery_json=$(build_event_json) || return 1
    write_event "$delivery_json" "$delivery_event"
    clear_event_vars
}

slack_queue_depth()
{
    depth=0
    for qf in "$AUTH_TRAIL_DATA_DIR"/slack-queue/pending/* \
        "$AUTH_TRAIL_DATA_DIR"/slack-queue/processing/*; do
        [ -e "$qf" ] || continue
        depth=$((depth + 1))
    done
    printf '%s' "$depth"
}

slack_queue_oldest_age()
{
    oldest=0
    for qf in "$AUTH_TRAIL_DATA_DIR"/slack-queue/pending/* \
        "$AUTH_TRAIL_DATA_DIR"/slack-queue/processing/*; do
        [ -f "$qf" ] || continue
        created=$(jq -r '.created_epoch // 0' "$qf" 2>/dev/null)
        case "$created" in '' | *[!0-9]*) continue ;; esac
        if [ "$oldest" -eq 0 ] || [ "$created" -lt "$oldest" ]; then
            oldest=$created
        fi
    done
    if [ "$oldest" -eq 0 ]; then
        printf '0'
    else
        age=$(($(epoch_now) - oldest))
        [ "$age" -ge 0 ] || age=0
        printf '%s' "$age"
    fi
}

slack_enqueue()
{
    original_event=$1
    original_event_id=$2
    original_session_id=$3
    payload=$4
    [ "$AUTH_TRAIL_SLACK_ENABLED" = '1' ] || return 0
    ensure_slack_queue || return 1
    depth=$(slack_queue_depth)
    if [ "$depth" -ge "$AUTH_TRAIL_SLACK_QUEUE_MAX" ]; then
        SLACK_HTTP_CODE=0 SLACK_CURL_STATUS=0
        record_slack_delivery slack.delivery.dropped "$original_event" "$original_event_id" \
            "$original_session_id" 0 queue_full
        return 1
    fi
    created=$(epoch_now)
    safe_id=$(printf '%s' "$original_event_id" | tr -c 'A-Za-z0-9_.-' '_')
    [ -n "$safe_id" ] || safe_id="event-$$-$created"
    for qf in "$AUTH_TRAIL_DATA_DIR"/slack-queue/pending/* \
        "$AUTH_TRAIL_DATA_DIR"/slack-queue/processing/*; do
        [ -f "$qf" ] || continue
        queued_id=$(jq -r '.event_id // empty' "$qf" 2>/dev/null)
        [ "$queued_id" != "$original_event_id" ] || return 0
    done
    created_ns=$(date +%s%N 2>/dev/null)
    case "$created_ns" in *N | '') created_ns="${created}000000000" ;; esac
    path="$AUTH_TRAIL_DATA_DIR/slack-queue/pending/${created_ns}-$$-${safe_id}.json"
    item=$(jq -nc --arg event "$original_event" --arg event_id "$original_event_id" \
        --arg session_id "$original_session_id" --arg created "$created" \
        --argjson payload "$payload" \
        '{event:$event,event_id:$event_id,session_id:($session_id|select(length>0)//null),
          created_epoch:($created|tonumber),attempts:0,next_attempt_epoch:0,payload:$payload}') || return 1
    atomic_write "$path" "$item" || return 1
    chmod 0600 "$path" 2>/dev/null || :
}

process_slack_queue_once()
{
    [ "$AUTH_TRAIL_SLACK_ENABLED" = '1' ] || return 0
    [ "$AUTH_TRAIL_SLACK_QUEUE_ENABLED" = '1' ] || return 0
    ensure_slack_queue || return 0
    pending=$(find "$AUTH_TRAIL_DATA_DIR/slack-queue/pending" -type f -name '*.json' 2>/dev/null | sort | sed -n '1p')
    [ -n "$pending" ] || return 0
    processing="$AUTH_TRAIL_DATA_DIR/slack-queue/processing/${pending##*/}"
    mv "$pending" "$processing" 2>/dev/null || return 0
    item=$(sed -n '1p' "$processing" 2>/dev/null)
    next=$(printf '%s' "$item" | jq -r '.next_attempt_epoch // 0' 2>/dev/null)
    now=$(epoch_now)
    case "$next" in '' | *[!0-9]*) next=0 ;; esac
    if [ "$next" -gt "$now" ]; then
        mv "$processing" "$pending" 2>/dev/null || :
        return 0
    fi
    original_event=$(printf '%s' "$item" | jq -r '.event // "unknown"')
    original_event_id=$(printf '%s' "$item" | jq -r '.event_id // empty')
    original_session_id=$(printf '%s' "$item" | jq -r '.session_id // empty')
    attempts=$(printf '%s' "$item" | jq -r '(.attempts // 0) + 1')
    payload=$(printf '%s' "$item" | jq -c '.payload')
    if slack_http_post "$payload"; then
        rm -f "$processing"
        record_slack_delivery slack.delivery.success "$original_event" "$original_event_id" \
            "$original_session_id" "$attempts" ''
        return 0
    fi

    retry=0
    if [ "$SLACK_CURL_STATUS" -ne 0 ]; then
        retry=1
    elif [ "$SLACK_HTTP_CODE" -eq 408 ] || [ "$SLACK_HTTP_CODE" -eq 429 ] || [ "$SLACK_HTTP_CODE" -ge 500 ]; then
        retry=1
    fi
    if [ "$retry" -eq 1 ] && [ "$attempts" -lt "$AUTH_TRAIL_SLACK_RETRY_MAX" ]; then
        delay=1
        delay_i=0
        while [ "$delay_i" -lt "$attempts" ]; do
            delay=$((delay * 2))
            delay_i=$((delay_i + 1))
        done
        [ "$delay" -le 300 ] || delay=300
        [ "$SLACK_RETRY_AFTER" -le "$delay" ] || delay=$SLACK_RETRY_AFTER
        updated=$(printf '%s' "$item" | jq -c --arg attempts "$attempts" --arg next "$((now + delay))" \
            '.attempts=($attempts|tonumber) | .next_attempt_epoch=($next|tonumber)')
        atomic_write "$pending" "$updated"
        chmod 0600 "$pending" 2>/dev/null || :
        rm -f "$processing"
        return 0
    fi

    reason=permanent_http_failure
    [ "$retry" -eq 0 ] || reason=retry_exhausted
    rm -f "$processing"
    record_slack_delivery slack.delivery.failure "$original_event" "$original_event_id" \
        "$original_session_id" "$attempts" "$reason"
    return 0
}

slack_post()
{
    payload=$1
    [ "$AUTH_TRAIL_SLACK_ENABLED" = '1' ] || return 0
    [ -n "$AUTH_TRAIL_SLACK_WEBHOOK_URL" ] || return 1
    if slack_http_post "$payload"; then
        return 0
    fi
    return 1
}

slack_enabled_for()
{
    # The default profile sends one normal interactive-session notification, only
    # after its purpose is durably recorded. Everything else is security-significant
    # or explicitly opted in. The canonical JSONL stream always keeps every event.
    if [ "$AUTH_TRAIL_SLACK_PROFILE" = 'actionable' ]; then
        case "$1" in
            ssh.session.purpose.recorded)
                [ "$AUTH_TRAIL_SLACK_LOGIN" = '1' ] && [ "$AUTH_TRAIL_SLACK_INCLUDE_PURPOSE" = '1' ]
                ;;
            ssh.session.end) [ "$AUTH_TRAIL_SLACK_LOGOUT" = '1' ] ;;
            ssh.auth.failure_burst) [ "$AUTH_TRAIL_SLACK_FAILURE_BURST" = '1' ] ;;
            privilege.transition) [ "$AUTH_TRAIL_SLACK_PRIVILEGE" = '1' ] ;;
            access.change) [ "$AUTH_TRAIL_SLACK_ACCESS_CHANGES" = '1' ] ;;
            command.executed) [ "$AUTH_TRAIL_SLACK_COMMAND_ALERTS" = '1' ] ;;
            *) return 1 ;;
        esac
        return
    fi

    case "$1" in
        ssh.session.start) [ "$AUTH_TRAIL_SLACK_LOGIN" = '1' ] ;;
        ssh.session.end) [ "$AUTH_TRAIL_SLACK_LOGOUT" = '1' ] ;;
        ssh.auth.failure) [ "$AUTH_TRAIL_SLACK_FAILURE" = '1' ] ;;
        ssh.auth.failure_burst) [ "$AUTH_TRAIL_SLACK_FAILURE_BURST" = '1' ] ;;
        privilege.transition) [ "$AUTH_TRAIL_SLACK_PRIVILEGE" = '1' ] ;;
        access.change) [ "$AUTH_TRAIL_SLACK_ACCESS_CHANGES" = '1' ] ;;
        ssh.session.purpose.recorded) [ "$AUTH_TRAIL_SLACK_LOGIN" = '1' ] && [ "$AUTH_TRAIL_SLACK_INCLUDE_PURPOSE" = '1' ] ;;
        command.executed) [ "$AUTH_TRAIL_SLACK_COMMAND_ALERTS" = '1' ] ;;
        *) return 1 ;;
    esac
}

dispatch_slack()
{
    event_name=$1
    event_json=$2

    [ "$AUTH_TRAIL_SLACK_ENABLED" = '1' ] || return 0
    slack_enabled_for "$event_name" || return 0

    payload=$(build_slack_payload "$event_name" "$event_json") || return 0
    [ -n "$payload" ] || return 0

    original_event_id=$(printf '%s' "$event_json" | jq -r '.event_id // empty')
    original_session_id=$(printf '%s' "$event_json" | jq -r '.session_id // empty')
    if [ "$AUTH_TRAIL_SLACK_QUEUE_ENABLED" = '1' ]; then
        slack_enqueue "$event_name" "$original_event_id" "$original_session_id" "$payload" || :
    else
        slack_post "$payload" || :
    fi
}

build_slack_payload()
{
    event_name=$1
    ej=$2

    case "$event_name" in
        ssh.session.start) build_login_slack_payload "$ej" ;;
        ssh.session.end) build_logout_slack_payload "$ej" ;;
        ssh.auth.failure) build_failure_slack_payload "$ej" ;;
        ssh.auth.failure_burst) build_burst_slack_payload "$ej" ;;
        privilege.transition) build_privilege_slack_payload "$ej" ;;
        access.change) build_access_change_slack_payload "$ej" ;;
        ssh.session.purpose.recorded) build_purpose_slack_payload "$ej" ;;
        *) return 1 ;;
    esac
}

build_test_slack_payload()
{
    jq -nc --arg hostname "$1" '{text: ("AuthTrail connection verified for " + $hostname)}'
}

build_login_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      {
        text: (("SSH session: " + (.identity // "unmapped") + " -> " + (.login_user // "unknown") + "@" + (.hostname // "unknown") + " from " + (.source_ip // "unknown")) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*SSH session opened*"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Identity*\n`" + (.identity // "unmapped") + "`")},
            {type:"mrkdwn", text:("*Account*\n`" + (.login_user // "unknown") + "`")},
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Source*\n`" + (.source_ip // "unknown") + "`")}
          ]},
          {type:"context", elements: [
            {type:"mrkdwn", text: ("Authentication `" + (.auth_method // "unknown") + "` • Session `" + (.session_id // "n/a") + "`")}
          ]}
        ]
      }'
}

build_logout_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      def duration:
        (. // 0 | floor) as $s
        | if $s >= 86400 then "\($s/86400|floor)d \(($s%86400)/3600|floor)h \(($s%3600)/60|floor)m"
          elif $s >= 3600 then "\($s/3600|floor)h \(($s%3600)/60|floor)m \($s%60)s"
          elif $s >= 60 then "\($s/60|floor)m \($s%60)s"
          else "\($s)s" end;
      {
        text: (("SSH session closed: " + (.identity // "unmapped") + " on " + (.hostname // "unknown") + " after " + ((.active_duration_seconds // .duration_seconds // 0)|duration)) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*SSH session closed*"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Identity*\n`" + (.identity // "unmapped") + "`")},
            {type:"mrkdwn", text:("*Account*\n`" + (.login_user // "unknown") + "`")},
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Source*\n`" + (.source_ip // "unknown") + "`")}
          ]},
          {type:"section", text:{type:"plain_text", text:("Justification\n" + (.purpose // "not recorded"))}},
          {type:"context", elements: [
            {type:"mrkdwn", text: ("Active for `" + ((.active_duration_seconds // .duration_seconds // 0)|duration) + "` • Session `" + (.session_id // "n/a") + "`")}
          ]}
        ]
      }'
}

build_failure_slack_payload()
{
    printf '%s' "$1" | jq -c '
      {
        text: ("SSH login failed on " + (.hostname // "unknown")),
        blocks: [
          {type:"header", text:{type:"plain_text", text:"SSH Login Failed"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Attempted account*\n`" + (.login_user // "unknown") + "`")},
            {type:"mrkdwn", text:("*Source*\n`" + (.source_ip // "unknown") + "`")},
            {type:"mrkdwn", text:("*Authentication*\n`" + (.auth_method // "unknown") + "`")}
          ]}
        ]
      }'
}

build_burst_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      {
        text: (("SSH failure burst: " + ((.attempt_count // 0)|tostring) + " attempts from " + (.source_ip // "unknown") + " on " + (.hostname // "unknown")) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*:warning: SSH failure burst*"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Source*\n`" + (.source_ip // "unknown") + "`")},
            {type:"mrkdwn", text:("*Attempts*\n`" + ((.attempt_count // 0)|tostring) + " / " + ((.window_seconds // 0)|tostring) + "s`")},
            {type:"mrkdwn", text:("*Users*\n`" + ((.attempted_users // [])|join(", ")) + "`")}
          ]},
          {type:"context", elements: [
            {type:"mrkdwn", text: "Action: audit only"}
          ]}
        ]
      }'
}

build_privilege_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      {
        text: (("Privilege transition: " + (.identity // "unmapped") + " changed " + (.from_user // "?") + " -> " + (.to_user // "?") + " on " + (.hostname // "unknown")) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*:warning: Privilege transition*"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Identity*\n`" + (.identity // "unmapped") + "`")},
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Account*\n`" + (.from_user // "?") + " → " + (.to_user // "?") + "`")}
          ]},
          {type:"section", text:{type:"plain_text", text:
            (if (.command // "") != "" then "Command\n" + .command
             else "Confirmed by\n" + (.mechanism // "PAM") + " session" end)}},
          {type:"context", elements: [
            {type:"mrkdwn", text: ("Session `" + (.session_id // "n/a") + "`")}
          ]}
        ]
      }'
}

build_access_change_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      {
        text: (("Critical access change by " + (.identity // "unmapped") + " on " + (.hostname // "unknown")) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*:warning: Critical access change*"}},
          {type:"section", fields:[
            {type:"mrkdwn", text:(("*Identity*\n`" + (.identity // "unmapped") + "`") | esc)},
            {type:"mrkdwn", text:(("*Server*\n`" + (.hostname // "unknown") + "`") | esc)},
            {type:"mrkdwn", text:(("*Account*\n`" + (.current_user // .login_user // "unknown") + "`") | esc)},
            {type:"mrkdwn", text:(("*Change*\n`" + (.change_type // "access") + "`") | esc)}
          ]},
          {type:"section", text:{type:"mrkdwn", text:(("*Command*\n```" + (.command // "not available") + "```") | esc)}},
          {type:"context", elements:[{type:"mrkdwn", text:(("Session `" + (.session_id // "unavailable") + "`") | esc)}]}
        ]
      }'
}

build_purpose_slack_payload()
{
    printf '%s' "$1" | jq -c '
      def esc: gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;");
      {
        text: (("SSH session: " + (.identity // "unmapped") + " -> " + (.login_user // "unknown") + "@" + (.hostname // "unknown") + " from " + (.source_ip // "unknown") + " — " + (.purpose // "purpose not supplied")) | esc),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:"*SSH session opened*"}},
          {type:"section", fields: [
            {type:"mrkdwn", text:("*Identity*\n`" + (.identity // "unmapped") + "`")},
            {type:"mrkdwn", text:("*Account*\n`" + (.login_user // "unknown") + "`")},
            {type:"mrkdwn", text:("*Server*\n`" + (.hostname // "unknown") + "`")},
            {type:"mrkdwn", text:("*Source*\n`" + (.source_ip // "unknown") + "`")}
          ]},
          {type:"section", text:{type:"plain_text", text:("Justification\n" + (.purpose // "not supplied"))}},
          {type:"context", elements: [
            {type:"mrkdwn", text:("Authentication `" + (.auth_method // "unknown") + "` • Session `" + (.session_id // "n/a") + "`")}
          ]}
        ]
      }'
}

build_sensitive_command_slack_payload()
{
    hostname_value=$1
    identity_value=$2
    user_value=$3
    tty_value=$4
    command_value=$5

    jq -n \
        --arg server "$hostname_value" \
        --arg identity "${identity_value:-unmapped}" \
        --arg user "$user_value" \
        --arg tty "$tty_value" \
        --arg command "$command_value" \
        '{
          text: ("Sensitive command on " + $server),
          blocks: [
            {type:"header", text:{type:"plain_text", text:"Sensitive Command"}},
            {type:"section", fields: [
              {type:"mrkdwn", text:("*Server*\n`" + $server + "`")},
              {type:"mrkdwn", text:("*Identity*\n`" + $identity + "`")},
              {type:"mrkdwn", text:("*Account*\n`" + $user + "`")},
              {type:"mrkdwn", text:("*TTY*\n`" + $tty + "`")}
            ]},
            {type:"section", text:{type:"mrkdwn", text:("*Command*\n```" + $command + "```")}}
          ]
        }'
}
