#!/bin/bash

LOG_FILE="/var/log/surveillance.log"
LAST_ACTION=0
COOLDOWN=300   # 5 min cooldown

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

# Start DNS supervisor in background
(
    while true; do
        dns_guard
        sleep 120
    done
) &
