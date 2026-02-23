#!/bin/bash

LOG_DIR="network_monitor"
INTERVAL=60  #changed to per min logging from 10 seconds logging 
SPEEDTEST_INTERVAL=600   # 10 minutes
LAST_SPEEDTEST=0

mkdir -p "$LOG_DIR"

get_log_file() {
    echo "$LOG_DIR/network_monitor_$(date +%F).log"
}

log() {
    echo "$1" >> "$(get_log_file)"
}

log "===== Network Monitor Service started at $(date) ====="

while true; do
    LOG_FILE="$(get_log_file)"

    log "=============================="
    log "Time: $(date)"

    # added IP DIAGNOSTICS (IPv4 / IPv6)
    
    log "--- IP Address Diagnostics ---"

    # Local IPv4
    IPV4_LOCAL=$(ip -4 addr show scope global | grep inet)
    if [ -n "$IPV4_LOCAL" ]; then
        log "Local IPv4 PRESENT"
        echo "$IPV4_LOCAL" >> "$LOG_FILE"
    else
        log "Local IPv4 MISSING"
    fi

    # Local IPv6
    IPV6_LOCAL=$(ip -6 addr show scope global | grep inet6)
    if [ -n "$IPV6_LOCAL" ]; then
        log "Local IPv6 PRESENT"
        echo "$IPV6_LOCAL" >> "$LOG_FILE"
    else
        log "Local IPv6 MISSING"
    fi

    # Default Routes
    log "--- Default Routes ---"
    ip -4 route show default >> "$LOG_FILE" 2>&1
    ip -6 route show default >> "$LOG_FILE" 2>&1

    # Public IPv4
    PUBLIC_IPV4=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null)
    if [ -n "$PUBLIC_IPV4" ]; then
        log "Public IPv4: $PUBLIC_IPV4"
    else
        log "Public IPv4 UNAVAILABLE"
    fi

    # Public IPv6
    PUBLIC_IPV6=$(curl -6 -s --max-time 5 https://api64.ipify.org 2>/dev/null)
    if [ -n "$PUBLIC_IPV6" ]; then
        log "Public IPv6: $PUBLIC_IPV6"
    else
        log "Public IPv6 UNAVAILABLE"
    fi

    log "--- Ping google.com ---"
    ping -c 3 google.com >> "$LOG_FILE" 2>&1
    ping -c 2 -W 2 8.8.8.8 >> "$LOG_FILE" 2>&1

    log "--- Internet speed ---"
    # timeout 20 speedtest-cli --simple >> "$LOG_FILE" 2>&1 || log "speedtest timed out"
    # I have made a change here to make sure the speed test runs once in 10 mins..
    
    CURRENT_TIME=$(date +%s)

    if (( CURRENT_TIME - LAST_SPEEDTEST >= SPEEDTEST_INTERVAL )); then
        log "--- Internet speed ---"
        timeout 20 speedtest-cli --simple >> "$LOG_FILE" 2>&1 || log "speedtest timed out"
        LAST_SPEEDTEST=$CURRENT_TIME
    fi

    log "--- CPU usage ---"
    top -bn1 | grep "Cpu(s)" >> "$LOG_FILE"

    log "--- Memory usage ---"
    free -h >> "$LOG_FILE"

    log "--- Disk usage ---"
    df -h >> "$LOG_FILE"

    log "--- Disk IO ---"
    iostat -dx 1 1 >> "$LOG_FILE" 2>&1

    log "--- AWS Identity Check (STS, no cost) ---"
    aws sts get-caller-identity >> "$LOG_FILE" 2>&1 || log "AWS STS failed"

    log "--- AWS S3 Endpoint Reachability (no API call) ---"
    curl -s --max-time 5 https://s3.ap-south-1.amazonaws.com >/dev/null \
        && log "S3 endpoint reachable" \
        || log "S3 endpoint unreachable"

    sleep "$INTERVAL"
done
