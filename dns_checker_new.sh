#!/bin/bash

# --- Auto-elevate if not root ---
if [[ $EUID -ne 0 ]]; then
    echo "Elevating privileges with sudo..."
    exec sudo "$0" "$@"
fi

#---log setup ---
LOG_FILE="/var/log/surveillance_new.log"
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

network_available() {

    # check default route
    if ! ip route | grep -q default; then
        return 1
    fi

    return 0
}


dns_guard() {

    CURRENT=$(date +%s)

    if (( CURRENT - LAST_ACTION < COOLDOWN )); then
        return
    fi

    ERROR_COUNT=0
    ERROR_LIST=""
    ACTION="NONE"

    PING_STATUS="OK"
    DNS_SERVICE_STATUS="OK"
    DNS_RESOLVE_STATUS="OK"

    # ---- Upstream Connectivity ----
    if ! silent ping -c1 -W1 8.8.8.8; then
        PING_STATUS="FAIL"
        ERROR_LIST+="UPSTREAM_UNREACHABLE "
        ((ERROR_COUNT++))
    fi

    # ---- If Network Is Down, Skip DNS Checks ----
    if [[ "$PING_STATUS" == "FAIL" ]]; then

        log_event "PING:$PING_STATUS"

        LAST_ACTION=$CURRENT
        return
    fi


    # ---- DNS Service Check ----
    if ! systemctl is-active --quiet systemd-resolved; then

        DNS_SERVICE_STATUS="FAIL"
        ERROR_LIST+="DNS_SERVICE_DOWN "
        ((ERROR_COUNT++))

        silent systemctl restart systemd-resolved
        sleep 2

        if systemctl is-active --quiet systemd-resolved; then
            DNS_SERVICE_STATUS="RECOVERED"
            ACTION="DNS_SERVICE_RESTARTED"
        else
            ACTION="DNS_SERVICE_RESTART_FAILED"
        fi
    fi


    # ---- DNS Resolution Test ----
    if ! silent getent hosts google.com; then

        DNS_RESOLVE_STATUS="FAIL"
        ERROR_LIST+="DNS_RESOLUTION_FAIL "
        ((ERROR_COUNT++))

        silent resolvectl flush-caches
        sleep 2

        if silent getent hosts google.com; then
            DNS_RESOLVE_STATUS="RECOVERED"
            ACTION="DNS_CACHE_FLUSHED"

        else
            silent systemctl restart systemd-resolved
            sleep 2

            if silent getent hosts google.com; then
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

        LAST_ACTION=$CURRENT
    fi
}


make_permanent() {
    SERVICE_NAME="dns_checker_new.service"
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

while true; do

    if network_available; then
        dns_guard
    else
        CURRENT=$(date +%s)

        if (( CURRENT - LAST_ACTION >= COOLDOWN )); then
            log_event "NETWORK_UNAVAILABLE | ROUTE_FAIL"
            LAST_ACTION=$CURRENT
        fi
    fi

    sleep 50
done
