#!/bin/bash

# Fast monitor script for uploading completed .mkv files to S3
# Designed for high frequency file processing (~32 files every 90 seconds)
# Immediately uploads completed files and removes them after successful upload

LOG_FILE="upload_monitor.log"
S3_BUCKET="anitum-jk/videos0" (add your bucket)
CHECK_INTERVAL=1  # Check every second for new completed files

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "Starting fast MKV file upload monitor"

# Function to handle file upload and removal
process_file() {
    local file="$1"
    
    # First quick check if file exists and is not being written
    if [ ! -f "$file" ] || lsof "$file" >/dev/null 2>&1; then
        return 1
    fi
    
    # Quick size stability check (half second)
    local size1=$(stat -c %s "$file" 2>/dev/null)
    sleep 0.5
    local size2=$(stat -c %s "$file" 2>/dev/null)
    
    if [ "$size1" != "$size2" ] || [ -z "$size1" ]; then
        return 1
    fi
    
    # File is complete, upload to S3
    log_message "Uploading $file to S3 bucket $S3_BUCKET"
    
    if aws s3 cp "$file" "s3://$S3_BUCKET/" --only-show-errors; then
        log_message "Successfully uploaded $file to S3"
        
        # Remove the file after successful upload
        if rm "$file"; then
            log_message "Removed $file from local storage"
        else
            log_message "Failed to remove $file from local storage"
        fi
        
        return 0
    else
        log_message "Failed to upload $file to S3"
        return 1
    fi
}

while true; do
    # Use find to get all .mkv files, process each one immediately
    find . -maxdepth 1 -name "*.mkv" -type f | while read -r file; do
        # Process each file in a background subshell to handle multiple files concurrently
        (process_file "$file") &
        
        # Limit concurrent processes to avoid overwhelming the system
        # Wait if there are too many background processes
        while [ $(jobs -p | wc -l) -gt 8 ]; do
            sleep 0.2
        done
    done
    
    # Wait for all background jobs to complete
    wait
    
    # Brief pause before next scan
    sleep $CHECK_INTERVAL
done
