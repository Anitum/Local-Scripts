#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Config
DOWNLOAD_DIR="./P_downloaded"
TIMESTAMP_FILE="last_processed.timestamp"
S3_BUCKET="anitum-jk-production"

# List of top-level location prefixes pushed by the uploader
LOCATIONS=( "nungambakkam" )

MAX_PARALLEL=10   # Number of parallel downloads
CHECK_INTERVAL=5  # Seconds between checks

# Command line arguments
START_TIME=""
END_TIME=""
ONE_TIME_MODE=false

# ─────────────────────────────────────────────────────────────
# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --start)
      START_TIME="$2"
      shift 2
      ;;
    --end)
      END_TIME="$2"
      ONE_TIME_MODE=true
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--start 'YYYY-MM-DD HH:MM'] [--end 'YYYY-MM-DD HH:MM']"
      exit 1
      ;;
  esac
done

mkdir -p "$DOWNLOAD_DIR"
touch "$TIMESTAMP_FILE"

# Logging helper
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Always do date math in IST regardless of host TZ
ist_date() {
  TZ="Asia/Kolkata" date "$@"
}

log "Script started"
log "System timezone: $(date +%Z)"
log "IST time: $(ist_date '+%Y-%m-%d %H:%M:%S')"
log "Download directory: $DOWNLOAD_DIR"
log "S3 Bucket: $S3_BUCKET"
log "Locations: ${LOCATIONS[*]}"

# Initialize timestamp file; if empty, start from current IST time
if [[ ! -s "$TIMESTAMP_FILE" ]]; then
  ist_date +"%Y-%m-%d %H:%M" > "$TIMESTAMP_FILE"
  log "Initialized timestamp file with: $(cat $TIMESTAMP_FILE)"
else
  log "Existing timestamp: $(cat $TIMESTAMP_FILE)"
fi

# Override start time if provided
if [[ -n "$START_TIME" ]]; then
  echo "$START_TIME" > "$TIMESTAMP_FILE"
  log "Override start time: $START_TIME"
fi

if [[ "$ONE_TIME_MODE" == "true" ]]; then
  log "One-time mode: will stop at $END_TIME"
else
  log "Continuous mode: will run forever"
fi

# Download one S3 key
process_file() {
  local key="$1"
  local target_dir="$DOWNLOAD_DIR"

  mkdir -p "$target_dir"
  aws s3 cp "s3://$S3_BUCKET/$key" "$target_dir/" --quiet
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Downloaded: $key"
}

export DOWNLOAD_DIR S3_BUCKET
export -f process_file

# Get all hours that need to be checked for the time range
get_hours_to_check() {
  local start_time="$1"   # "YYYY-MM-DD HH:MM"
  local end_time="$2"     # "YYYY-MM-DD HH:MM"

  local start_epoch end_epoch step_epoch
  start_epoch=$(ist_date -d "$start_time:00" +%s)
  end_epoch=$(ist_date   -d "$end_time:00"   +%s)

  # Get the hour boundaries we need to check
  local start_hour_epoch end_hour_epoch
  start_hour_epoch=$(( (start_epoch / 3600) * 3600 ))
  end_hour_epoch=$(( (end_epoch / 3600) * 3600 ))

  step_epoch="$start_hour_epoch"
  while [[ "$step_epoch" -le "$end_hour_epoch" ]]; do
    local y m d H
    y=$(ist_date -d "@$step_epoch" +%Y)
    m=$(ist_date -d "@$step_epoch" +%m)
    d=$(ist_date -d "@$step_epoch" +%d)
    H=$(ist_date -d "@$step_epoch" +%H)
    for loc in "${LOCATIONS[@]}"; do
      printf "%s %s %s %s %s\n" "$loc" "$y" "$m" "$d" "$H"
    done
    step_epoch=$(( step_epoch + 3600 ))
  done
}

# Convert filename timestamp to comparable format and check if it's in range
is_file_in_range() {
  local filename="$1"
  local start_time="$2"  # "YYYY-MM-DD HH:MM"
  local end_time="$3"    # "YYYY-MM-DD HH:MM"
  
  # Extract timestamp from filename: YYYYMMDDTHHMMss
  local file_timestamp=$(echo "$filename" | grep -oP '\d{8}T\d{6}' || echo "")
  if [[ -z "$file_timestamp" ]]; then
    return 1  # Invalid timestamp
  fi
  
  # Convert to comparable format: YYYY-MM-DD HH:MM
  local year="${file_timestamp:0:4}"
  local month="${file_timestamp:4:2}"
  local day="${file_timestamp:6:2}"
  local hour="${file_timestamp:9:2}"
  local minute="${file_timestamp:11:2}"
  
  local file_time="${year}-${month}-${day} ${hour}:${minute}"
  
  # Convert times to epochs for comparison
  local file_epoch start_epoch end_epoch
  file_epoch=$(ist_date -d "$file_time:00" +%s)
  start_epoch=$(ist_date -d "$start_time:00" +%s)
  end_epoch=$(ist_date -d "$end_time:00" +%s)
  
  # Check if file time is in range [start_time, end_time]
  [[ $file_epoch -ge $start_epoch && $file_epoch -le $end_epoch ]]
}

# Extract timestamp from filename for sorting
extract_timestamp() {
  local filename="$1"
  echo "$filename" | grep -oP '\d{8}T\d{6}' || echo "00000000T000000"
}

# Main loop
log "Starting processing loop..."
loop_count=0

while true; do
  loop_count=$((loop_count + 1))
  log "═══════════════════════════════════════════════════════"
  log "Check cycle #$loop_count"
  log "═══════════════════════════════════════════════════════"

  last_processed_time=$(cat "$TIMESTAMP_FILE" | head -n1 | tr -d '\r')
  log "Last processed: $last_processed_time"

  # Determine end time for this cycle
  if [[ "$ONE_TIME_MODE" == "true" ]] && [[ -n "$END_TIME" ]]; then
    current_time="$END_TIME"
    log "Target end time: $current_time"
  else
    current_time=$(ist_date +"%Y-%m-%d %H:%M")
    log "Current IST time: $current_time"
  fi

  # Check if we're done (in one-time mode)
  if [[ "$ONE_TIME_MODE" == "true" ]]; then
    last_epoch=$(ist_date -d "$last_processed_time:00" +%s)
    end_epoch=$(ist_date -d "$END_TIME:00" +%s)
    if [[ $last_epoch -ge $end_epoch ]]; then
      log "Reached end time. Exiting."
      exit 0
    fi
  fi

  log "Exact time range: [$last_processed_time] to [$current_time]"

  # Get all hour prefixes that might contain files in our range
  log "Getting hour prefixes to check..."
  hour_prefixes=$(get_hours_to_check "$last_processed_time" "$current_time")
  prefix_count=$(echo "$hour_prefixes" | wc -l)
  log "Need to check $prefix_count hour-location combinations"

  # Query S3 for each hour prefix
  declare -a temp_files=()
  idx=0

  log "Querying S3 for files in each hour prefix..."
  
  while read -r loc y m d H; do
    prefix="${loc}/${y}/${m}/${d}/${H}/"
    log "  [$((idx+1))/$prefix_count] Checking: $prefix"
    
    tmpf=$(mktemp)
    temp_files[$idx]="$tmpf"
    
    # List files and convert tab-separated output to newlines
    {
      aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "$prefix" \
        --query 'Contents[].Key' \
        --output text 2>/dev/null | tr '\t' '\n' > "$tmpf"
      
      file_count=$(grep -c . "$tmpf" 2>/dev/null || echo 0)
      log "      → $file_count files in hour"
    } &
    
    idx=$((idx + 1))
  done <<< "$hour_prefixes"
  
  log "Waiting for S3 queries to complete..."
  wait
  log "All queries completed"

  # Combine all files and filter by exact time range
  log "Filtering files by exact time range..."
  all_files=$(mktemp)
  filtered_files=$(mktemp)
  > "$all_files"
  > "$filtered_files"
  
  for f in "${temp_files[@]:-}"; do
    if [[ -s "$f" ]]; then
      cat "$f" >> "$all_files"
    fi
  done

  total_files=$(grep -c . "$all_files" 2>/dev/null || echo 0)
  log "Total files found in hour prefixes: $total_files"

  # Filter files to exact time range
  while IFS= read -r file; do
    if [[ -n "$file" ]] && is_file_in_range "$file" "$last_processed_time" "$current_time"; then
      echo "$file" >> "$filtered_files"
    fi
  done < "$all_files"

  filtered_count=$(grep -c . "$filtered_files" 2>/dev/null || echo 0)
  log "Files in exact time range: $filtered_count"

  if [[ $filtered_count -gt 0 ]]; then
    # Sort files by timestamp embedded in filename
    log "Sorting files chronologically by timestamp..."
    sorted_files=$(mktemp)
    
    # Add timestamp prefix for sorting, then sort, then remove prefix
    while IFS= read -r file; do
      if [[ -n "$file" ]]; then
        ts=$(extract_timestamp "$file")
        echo "${ts}|${file}"
      fi
    done < "$filtered_files" | sort | cut -d'|' -f2 > "$sorted_files"
    
    sorted_count=$(grep -c . "$sorted_files" 2>/dev/null || echo 0)
    log "Sorted $sorted_count files"
    
    # Show first few files for verification
    log "First 5 files to download:"
    head -5 "$sorted_files" | while IFS= read -r file; do
      ts=$(extract_timestamp "$file")
      log "  - $file (timestamp: $ts)"
    done
    
    log "Starting downloads (max $MAX_PARALLEL parallel)..."
    cat "$sorted_files" | xargs -I{} -P "$MAX_PARALLEL" bash -c 'process_file "$@"' _ {}
    log "Downloads complete"
    
    rm -f "$sorted_files"
  else
    log "No files found in exact time range"
  fi

  # Cleanup
  rm -f "$all_files" "$filtered_files"
  for f in "${temp_files[@]:-}"; do 
    rm -f "$f" 2>/dev/null || true
  done
  unset temp_files

  # Update timestamp to current time (with minutes)
  if [[ "$ONE_TIME_MODE" == "true" ]]; then
    echo "$END_TIME" > "$TIMESTAMP_FILE"
  else
    ist_date +"%Y-%m-%d %H:%M" > "$TIMESTAMP_FILE"
  fi
  log "Updated timestamp to: $(cat $TIMESTAMP_FILE)"
  
  # Exit if in one-time mode
  if [[ "$ONE_TIME_MODE" == "true" ]]; then
    log "One-time mode complete. Exiting."
    exit 0
  fi
  
  log ""
  log "Sleeping ${CHECK_INTERVAL}s..."
  sleep "$CHECK_INTERVAL"
done

