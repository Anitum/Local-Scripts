#!/bin/bash

# ============================================================
# CONFIG
# ============================================================
LOG_FILE="/var/log/dns_guard.log"        # Fixed typo: gaurd -> guard
INSTALL_PATH="/usr/local/bin/dns_guard.sh"
SERVICE_NAME="dns_checker.service"

COOLDOWN=120                             # Seconds between repeated log entries
POLL_INTERVAL=50                         # Seconds between each check loop
RECOVERY_WAIT=2                          # Seconds to wait after a recovery action
PING_TARGET="8.8.8.8"                   # Upstream connectivity check target
DNS_TEST_HOSTS=("google.com" "cloudflare.com" "github.com")  # Moved into config
MAX_FAILURES=5                           # Consecutive failures before CRITICAL alert
# ============================================================

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Split cooldown tracking: one per context (fixes LAST_ACTION scoping bug)
LAST_DNS_ACTION=0
LAST_NET_LOG=0

CONSECUTIVE_FAILURES=0

# --- Auto-elevate if not root ---
if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

# ---- Dual-log to file AND journald ----
log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DNS] $1" >> "$LOG_FILE"
    logger -t "dns_guard" "$1"
}

silent() {
    "$@" >/dev/null 2>&1
}

network_available() {

    # ---- Check default route ----
    GATEWAY=$(ip route show default | awk '{print $3}' | head -n1)

    if [[ -z "$GATEWAY" ]]; then
        NET_STATUS="NO_DEFAULT_ROUTE"
        return 1
    fi

    # ---- Check gateway ----
    if ! silent ping -c1 -W1 "$GATEWAY"; then
        NET_STATUS="GATEWAY_UNREACHABLE"
        return 1
    fi

    # ---- Check internet (uses config var) ----
    if ! silent ping -c1 -W1 "$PING_TARGET"; then
        NET_STATUS="INTERNET_UNREACHABLE"
        return 1
    fi

    NET_STATUS="NETWORK_OK"
    return 0
}

dns_resolve_ok() {
    for host in "${DNS_TEST_HOSTS[@]}"; do
        if ! silent getent hosts "$host"; then
            return 1
        fi
    done
    return 0
}

dns_guard() {

    CURRENT=$(date +%s)

    # Uses LAST_DNS_ACTION (not LAST_ACTION) — scoping fix
    if (( CURRENT - LAST_DNS_ACTION < COOLDOWN )); then
        return
    fi

    ERROR_COUNT=0
    ERROR_LIST=""
    ACTION="NONE"

    PING_STATUS="OK"
    DNS_SERVICE_STATUS="OK"
    DNS_RESOLVE_STATUS="OK"

    # ---- Upstream Connectivity (uses config var) ----
    if ! silent ping -c1 -W1 "$PING_TARGET"; then
        PING_STATUS="FAIL"
        ERROR_LIST+="INTERNET_UNREACHABLE "
        ((ERROR_COUNT++))
    fi

    # ---- If Network Is Down, Skip DNS Checks ----
    if [[ "$PING_STATUS" == "FAIL" ]]; then
        log_event "PING:$PING_STATUS"
        LAST_DNS_ACTION=$CURRENT
        return
    fi

    # ---- DNS Service Check ----
    if ! systemctl is-active --quiet systemd-resolved; then

        DNS_SERVICE_STATUS="FAIL"
        ERROR_LIST+="DNS_SERVICE_DOWN "
        ((ERROR_COUNT++))

        silent systemctl restart systemd-resolved
        sleep "$RECOVERY_WAIT"

        if systemctl is-active --quiet systemd-resolved; then
            DNS_SERVICE_STATUS="RECOVERED"
            ACTION="DNS_SERVICE_RESTARTED"
        else
            ACTION="DNS_SERVICE_RESTART_FAILED"
        fi
    fi

    # ---- DNS Resolution Test ----
    if ! dns_resolve_ok; then

        DNS_RESOLVE_STATUS="FAIL"
        ERROR_LIST+="DNS_RESOLUTION_FAIL "
        ((ERROR_COUNT++))

        silent resolvectl flush-caches
        sleep "$RECOVERY_WAIT"

        if dns_resolve_ok; then
            DNS_RESOLVE_STATUS="RECOVERED"
            ACTION="DNS_CACHE_FLUSHED"
        else
            silent systemctl restart systemd-resolved
            sleep "$RECOVERY_WAIT"

            if dns_resolve_ok; then
                DNS_RESOLVE_STATUS="RECOVERED"
                ACTION="DNS_RESOLVER_RESTARTED"
            else
                ACTION="DNS_RESOLUTION_STILL_FAILING"
            fi
        fi
    fi

    # ---- Log Only If Errors Occurred ----
    if (( ERROR_COUNT > 0 )); then

        if (( ERROR_COUNT == 1 )); then
            ERROR_TYPE="ERROR"
        else
            ERROR_TYPE="MULTIPLE_ERRORS($ERROR_COUNT)"
        fi

        log_event "$ERROR_TYPE: $ERROR_LIST | ACTION:$ACTION | PING:$PING_STATUS | DNS_SERVICE:$DNS_SERVICE_STATUS | DNS_RESOLVE:$DNS_RESOLVE_STATUS"

        # ---- Failure Escalation ----
        if [[ "$ACTION" == *"FAILING"* || "$ACTION" == *"FAILED"* ]]; then
            ((CONSECUTIVE_FAILURES++))
            if (( CONSECUTIVE_FAILURES >= MAX_FAILURES )); then
                log_event "CRITICAL: DNS has failed $CONSECUTIVE_FAILURES times consecutively. Manual intervention required."
            fi
        else
            CONSECUTIVE_FAILURES=0
        fi

        LAST_DNS_ACTION=$CURRENT
    else
        CONSECUTIVE_FAILURES=0
    fi
}

make_permanent() {
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

    # ---- Copy script to stable install location ----
    if [[ "$(realpath "$0")" != "$INSTALL_PATH" ]]; then
        cp "$(realpath "$0")" "$INSTALL_PATH"
        chmod +x "$INSTALL_PATH"
        echo "Script installed to: $INSTALL_PATH"
    fi

    # ---- Add logrotate config ----
    cat <<EOF > /etc/logrotate.d/dns_guard
$LOG_FILE {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF

    # ---- Create systemd service (only if it doesn't exist) ----
    if [[ ! -f "$SERVICE_PATH" ]]; then
        cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=DNS Guard Supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable "$SERVICE_NAME"
        systemctl start "$SERVICE_NAME"
        echo "Systemd service installed and started: $SERVICE_NAME"
    else
        echo "Service already exists: $SERVICE_NAME"
    fi
}

make_permanent

echo "Done"

# ---- Main supervisor loop (runs indefinitely) ----
while true; do

    if network_available; then
        dns_guard
    else
        CURRENT=$(date +%s)

        # Uses LAST_NET_LOG (not LAST_ACTION) — scoping fix
        if (( CURRENT - LAST_NET_LOG >= COOLDOWN )); then
            log_event "$NET_STATUS"
            LAST_NET_LOG=$CURRENT
        fi
    fi

    sleep "$POLL_INTERVAL"
done
