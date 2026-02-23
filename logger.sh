#!/bin/bash

LOG_DIR="network_monitor"
INTERVAL=10

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

    log "--- Ping google.com ---"
    ping -c 3 google.com >> "$LOG_FILE" 2>&1
    ping -c 2 -W 2 8.8.8.8 >> "$LOG_FILE" 2>&1

    log "--- Internet speed ---"
    timeout 20 speedtest-cli --simple >> "$LOG_FILE" 2>&1 || log "speedtest timed out"

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
