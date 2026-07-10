#!/usr/bin/env bash
#
# health_check.sh - disk, memory, CPU, and service health monitor.
#
# Usage:
#   ./health_check.sh [path-to-config.env]
#
# Defaults to config.env next to this script if no path is given.
# Intended to run every few minutes from cron - see README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    echo "Copy config.example.env to config.env and edit it first." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${DISK_THRESHOLD:?DISK_THRESHOLD not set in $CONFIG_FILE}"
: "${MEMORY_THRESHOLD:?MEMORY_THRESHOLD not set in $CONFIG_FILE}"
: "${CPU_LOAD_THRESHOLD:?CPU_LOAD_THRESHOLD not set in $CONFIG_FILE}"
: "${WEBHOOK_URL:?WEBHOOK_URL not set in $CONFIG_FILE}"
: "${LOG_FILE:?LOG_FILE not set in $CONFIG_FILE}"
: "${STATE_DIR:?STATE_DIR not set in $CONFIG_FILE}"
: "${ALERT_COOLDOWN_SECONDS:=1800}"
: "${SSH_USER:=${USER:-root}}"
: "${SSH_KEY:=$HOME/.ssh/id_rsa}"
: "${SSH_TIMEOUT:=5}"
HOSTS=("${HOSTS[@]:-localhost}")
SERVICES=("${SERVICES[@]:-}")

mkdir -p "$(dirname "$LOG_FILE")" "$STATE_DIR"

# --- logging -----------------------------------------------------

log() {
    local level="$1" message="$2"
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >> "$LOG_FILE"
}

# --- alerting ------------------------------------------------------
# JSON-escape a string without depending on jq.

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

# Send a webhook alert. Sends both "text" (Slack) and "content" (Discord)
# fields so the same payload works against either webhook type.
send_alert() {
    local text="$1"
    local escaped
    escaped="$(json_escape "$text")"
    local payload
    payload="$(printf '{"text":"%s","content":"%s"}' "$escaped" "$escaped")"

    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$WEBHOOK_URL" 2>>"$LOG_FILE")"

    if [[ "$http_code" =~ ^2 ]]; then
        log "INFO" "Webhook alert sent (HTTP $http_code): $text"
    else
        log "ERROR" "Webhook alert failed (HTTP $http_code): $text"
    fi
}

# Alert/cooldown/resolution state is tracked with one file per issue key
# in STATE_DIR, containing the epoch time of the last alert sent.

state_file_for() {
    local key="$1"
    printf '%s/%s' "$STATE_DIR" "$(printf '%s' "$key" | tr -c 'A-Za-z0-9._-' '_')"
}

# Record a check result: always logs, and alerts/resolves through the
# webhook according to the cooldown + resolution rules below.
evaluate() {
    local key="$1" breach="$2" message="$3"
    local state_file
    state_file="$(state_file_for "$key")"

    if [[ "$breach" == "true" ]]; then
        log "BREACH" "$message"
        if [[ ! -f "$state_file" ]]; then
            send_alert "ALERT: $message"
            date +%s > "$state_file"
        else
            local last now
            last="$(cat "$state_file" 2>/dev/null || echo 0)"
            now="$(date +%s)"
            if (( now - last >= ALERT_COOLDOWN_SECONDS )); then
                send_alert "ALERT (still active): $message"
                date +%s > "$state_file"
            fi
        fi
    else
        log "OK" "$message"
        if [[ -f "$state_file" ]]; then
            send_alert "RESOLVED: $message"
            rm -f "$state_file"
        fi
    fi
}

# --- remote execution helper -----------------------------------------

run_on_host() {
    local host="$1" cmd="$2"
    if [[ "$host" == "localhost" ]]; then
        bash -c "$cmd"
    else
        ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new \
            -i "$SSH_KEY" "${SSH_USER}@${host}" "$cmd" 2>>"$LOG_FILE"
    fi
}

is_reachable() {
    local host="$1"
    [[ "$host" == "localhost" ]] && return 0
    ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new \
        -i "$SSH_KEY" "${SSH_USER}@${host}" "echo ok" &>/dev/null
}

# --- checks --------------------------------------------------------

check_disk() {
    local host="$1" data
    data="$(run_on_host "$host" "df -P -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | tail -n +2")"
    [[ -z "$data" ]] && return

    while read -r _fs _size _used _avail pcent mount; do
        [[ -z "${pcent:-}" ]] && continue
        pcent="${pcent%\%}"
        local breach="false"
        (( pcent >= DISK_THRESHOLD )) && breach="true"
        evaluate "${host}_disk_${mount}" "$breach" \
            "[$host] disk usage on $mount is ${pcent}% (threshold ${DISK_THRESHOLD}%)"
    done <<< "$data"
}

check_memory() {
    local host="$1" pcent
    pcent="$(run_on_host "$host" "free -m | awk '/^Mem:/{printf \"%.0f\", (\$2-\$7)/\$2*100}'")"
    [[ -z "${pcent:-}" ]] && return

    local breach="false"
    (( pcent >= MEMORY_THRESHOLD )) && breach="true"
    evaluate "${host}_memory" "$breach" \
        "[$host] memory usage is ${pcent}% (threshold ${MEMORY_THRESHOLD}%)"
}

check_cpu() {
    local host="$1" load
    load="$(run_on_host "$host" "cut -d' ' -f1 /proc/loadavg")"
    [[ -z "${load:-}" ]] && return

    local breach="false"
    if awk -v l="$load" -v t="$CPU_LOAD_THRESHOLD" 'BEGIN{exit !(l+0 >= t+0)}'; then
        breach="true"
    fi
    evaluate "${host}_cpu" "$breach" \
        "[$host] 1-minute load average is $load (threshold ${CPU_LOAD_THRESHOLD})"
}

check_services() {
    local host="$1"
    local svc
    for svc in "${SERVICES[@]}"; do
        [[ -z "$svc" ]] && continue
        local status
        status="$(run_on_host "$host" "systemctl is-active '$svc' 2>/dev/null")"
        local breach="false"
        [[ "$status" != "active" ]] && breach="true"
        evaluate "${host}_svc_${svc}" "$breach" \
            "[$host] service '$svc' is ${status:-unknown} (expected active)"
    done
}

# --- main ------------------------------------------------------------

main() {
    log "INFO" "==== health check run started ===="

    local host
    for host in "${HOSTS[@]}"; do
        if ! is_reachable "$host"; then
            evaluate "${host}_unreachable" "true" "host $host is unreachable via SSH"
            continue
        fi
        evaluate "${host}_unreachable" "false" "host $host is reachable"

        check_disk "$host"
        check_memory "$host"
        check_cpu "$host"
        check_services "$host"
    done

    log "INFO" "==== health check run completed ===="
}

main
