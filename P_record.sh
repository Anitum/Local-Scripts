#!/bin/bash

: "${RTSP_IP:=$IP}"          # $IP comes from nmap.sh via $GITHUB_ENV
: "${RTSP_USER:?RTSP_USER not set}"   # fail if secret missing
: "${RTSP_PASS:?RTSP_PASS not set}"   # fail if secret missing
: "${RTSP_PORT:=554}"   
RTSP_PORT="554"

# Recording parameters
SEGMENT_TIME=90

# Logging setup
LOG_DIR="logs"
mkdir -p "$LOG_DIR"
MASTER_LOG="$LOG_DIR/master.log"
ERROR_LOG="$LOG_DIR/error.log"

# Function to log messages with timestamp
log_message() {
    local message="$1"
    local log_file="${2:-$MASTER_LOG}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$log_file"
}

# Function to start recording for a single camera
record_camera() {
    local channel=$1
    local camera_log="$LOG_DIR/camera_${channel}.log"
    local camera_error_log="$LOG_DIR/camera_${channel}_error.log"
    local retry_count=0
    local max_retries=3  # Maximum number of quick retries before longer wait
    
    while true; do
        log_message "Starting recording for channel $channel"
        
        # Temporary file for capturing ffmpeg output
        local temp_output=$(mktemp)
        
        # Test RTSP connection before starting ffmpeg
        if ! timeout 5 nc -zv $RTSP_IP $RTSP_PORT 2>/dev/null; then
            log_message "Cannot connect to RTSP server $RTSP_IP:$RTSP_PORT" "$ERROR_LOG"
            sleep 10
            continue
        fi
        
        # Start ffmpeg with full logging
 
        cd "channel$channel"
        
        # Enhanced ffmpeg command with proper timestamp handling
        timeout 3600 ffmpeg -hide_banner \
            -loglevel error \
            -rtsp_transport tcp \
            -buffer_size 4194304 \
            -max_delay 500000 \
            -stimeout 20000000 \
            -analyzeduration 2000000 \
            -probesize 4000000 \
            -fflags +genpts+igndts+discardcorrupt \
            -avoid_negative_ts make_zero \
            -use_wallclock_as_timestamps 1 \
            -thread_queue_size 1024 \
            -i "rtsp://${RTSP_USER}:${RTSP_PASS}@${RTSP_IP}:${RTSP_PORT}/Streaming/Channels/${channel}" \
            -c copy \
            -map 0 \
            -f segment \
            -segment_time ${SEGMENT_TIME} \
            -segment_format mkv \
            -segment_atclocktime 1 \
            -segment_start_number 1 \
            -segment_wrap 0 \
            -reset_timestamps 1 \
            -force_key_frames "expr:gte(t,n_forced*${SEGMENT_TIME})" \
            -break_non_keyframes 0 \
            -strftime 1 \
            -avoid_negative_ts disabled \
            "../channel${channel}_%Y%m%dT%H%M%S.mkv" 2>> "../$camera_error_log"
              
        EXIT_CODE=$?
        
        # Log detailed error information
        if [ $EXIT_CODE -ne 0 ]; then
            local error_msg=$(tail -n 20 "$temp_output")
            log_message "Channel $channel failed with exit code $EXIT_CODE" "$ERROR_LOG"
            log_message "Error details for channel $channel:" "$ERROR_LOG"
            log_message "$error_msg" "$ERROR_LOG"
            log_message "Last 20 lines of ffmpeg output:" "$camera_error_log"
            echo "$error_msg" >> "$camera_error_log"
            
            # Network connection test
            if ! ping -c 1 $RTSP_IP > /dev/null 2>&1; then
                log_message "Network connectivity issue detected with $RTSP_IP" "$ERROR_LOG"
            fi
            
            # RTSP port test
            if ! nc -zv $RTSP_IP $RTSP_PORT 2>/dev/null; then
                log_message "RTSP port $RTSP_PORT is not accessible on $RTSP_IP" "$ERROR_LOG"
            fi
            
            # Adaptive retry delay
            if [ $EXIT_CODE -eq 146 ]; then  # Connection refused/failed
                retry_count=$((retry_count + 1))
                if [ $retry_count -ge $max_retries ]; then
                    log_message "Multiple connection failures for channel $channel. Waiting 60 seconds before next retry." "$ERROR_LOG"
                    sleep 60
                    retry_count=0
                else
                    log_message "Connection failed for channel $channel. Quick retry in 5 seconds." "$ERROR_LOG"
                    sleep 5
                fi
            else
                # Log the specific error message based on exit code
                case $EXIT_CODE in
                    1)
                        log_message "Generic error occurred for channel $channel" "$ERROR_LOG"
                        ;;
                    135)
                        log_message "Connection timed out for channel $channel" "$ERROR_LOG"
                        ;;
                    255)
                        log_message "Authentication failed for channel $channel" "$ERROR_LOG"
                        ;;
                    *)
                        log_message "Unknown error ($EXIT_CODE) occurred for channel $channel" "$ERROR_LOG"
                        ;;
                esac
                sleep 10
                retry_count=0
            fi
        else
            retry_count=0
            sleep 2
        fi
        
        # Clean up temporary file
        rm -f "$temp_output"
        
        # Check if the script is being shut down
        if [ -f "/tmp/stop_recording" ]; then
            log_message "Received stop signal for channel $channel"
            break
        fi
    done
}

# Function to monitor disk space
monitor_disk_space() {
    while true; do
        DISK_USAGE=$(df -h . | awk 'NR==2 {print $5}' | sed 's/%//')
        if [ "$DISK_USAGE" -gt 90 ]; then
            log_message "WARNING: Disk usage is at ${DISK_USAGE}%" "$ERROR_LOG"
        fi
        sleep 300  # Check every 5 minutes
    done
}

# Function to clean old recordings (keeps last 7 days)
clean_old_recordings() {
    while true; do
        log_message "Cleaning recordings older than 7 days..."
        find . -name "channel*_*.mkv" -type f -mtime +7 -exec rm {} \;
        sleep 86400  # Run once per day
    done
}

# Function to monitor processes and log their status
monitor_processes() {
    while true; do
        for i in {1..16}; do
            channel=$(( i * 100 + 1 ))
            PROCESS_COUNT=$(pgrep -f "Channels/${channel}" | wc -l)
            if [ "$PROCESS_COUNT" -eq 0 ]; then
                log_message "WARNING: No recording process found for channel $channel" "$ERROR_LOG"
            fi
        done
        sleep 60  # Check every minute
    done
}

# Function to rotate logs
rotate_logs() {
    while true; do
        sleep 86400  # Run once per day
        for logfile in "$LOG_DIR"/*.log; do
            if [ -f "$logfile" ]; then
                local timestamp=$(date '+%Y%m%d')
                mv "$logfile" "${logfile}.${timestamp}"
                gzip "${logfile}.${timestamp}"
            fi
        done
        log_message "Log rotation completed"
    done
}

# Cleanup function
cleanup() {
    log_message "Stopping all recordings..."
    touch /tmp/stop_recording
    pkill -f "ffmpeg.*Streaming/Channels"
    rm -f /tmp/stop_recording
    log_message "All recordings stopped"
    exit 0
}

# Initial setup
mkdir -p "$LOG_DIR"
for i in {1..16}; do
    channel=$(( i * 100 + 1 ))
    mkdir -p "channel$channel"
done

# Set up trap to catch interrupt signal
trap cleanup SIGINT SIGTERM

# Start monitoring processes
log_message "Starting monitoring processes"
monitor_processes &
monitor_disk_space &
rotate_logs &
clean_old_recordings &

# Start recording for each camera channel
log_message "Starting camera recording processes"
for i in {1..16}; do
    channel=$(( i * 100 + 1 ))
    record_camera $channel &
done

log_message "All recording processes started. Press Ctrl+C to stop all recordings."

# Keep script running and show live logs
tail -f "$MASTER_LOG" "$ERROR_LOG" &


