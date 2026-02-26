#!/bin/bash

# --- Auto-elevate if not root ---
if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

#---log setup ---
LOG_FILE="/var/log/surveillance.log"
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

LAST_ACTION=0
COOLDOWN=120  # 2 min cooldown

log_event() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DNS] $1" >> "$LOG_FILE"
}

silent() {
    "$@" >/dev/null 2>&1
}

dns_guard() {

    CURRENT=$(date +%s)

    # Prevent excessive intervention
    if (( CURRENT - LAST_ACTION < COOLDOWN )); then
        return
    fi

    # ---- Network Route Check ----
    if ! ip route | grep -q default; then
        log_event "NETWORK_DOWN - No default route."
        return
    fi

    # ---- Upstream Connectivity Check ----
    if ! silent ping -c1 -W1 8.8.8.8; then
        log_event "UPSTREAM_UNREACHABLE - External network unreachable."
        return
    fi

    # ---- DNS Service Check ----
    if ! systemctl is-active --quiet systemd-resolved; then
        silent systemctl restart systemd-resolved
        sleep 2
        if systemctl is-active --quiet systemd-resolved; then
            log_event "DNS_RESTARTED - systemd-resolved was inactive and restarted."
            LAST_ACTION=$CURRENT
        else
            log_event "DNS_ATTENTION - systemd-resolved failed to restart."
        fi
        return
    fi

    # ---- DNS Resolution Test ----
    if ! silent getent hosts google.com; then

        # Try cache flush
        silent resolvectl flush-caches
        sleep 2

        if silent getent hosts google.com; then
            log_event "DNS_FLUSHED - Cache issue resolved."
            LAST_ACTION=$CURRENT
            return
        fi

        # Try restart
        silent systemctl restart systemd-resolved
        sleep 2

        if silent getent hosts google.com; then
            log_event "DNS_RESTARTED - Resolver failure corrected after restart."
            LAST_ACTION=$CURRENT
        else
            log_event "DNS_ATTENTION - Resolution failing after restart."
        fi
    fi
}


make_permanent() {
    SERVICE_NAME="dns_checker.service"
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"

    # Only create service if it doesn't exist
    if [[ ! -f "$SERVICE_PATH" ]]; then
        cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=DNS Guard Supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(realpath "$0")
Restart=always

[Install]
WantedBy=multi-user.target
EOF

        # Reload systemd and enable/start service
        systemctl daemon-reload
        systemctl enable $SERVICE_NAME
        systemctl start $SERVICE_NAME
        echo "Systemd service installed and started: $SERVICE_NAME"
    else
        echo "Service already exists: $SERVICE_NAME"
    fi
}


make_permanent

echo "Done"

# Start DNS supervisor loop (runs indefinitely)

(
    while true; do
        dns_guard
        sleep 50   # small sleep to reduce CPU usage
    done
) &

