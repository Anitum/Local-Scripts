#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

DOWNLOAD_DIR="./P_downloaded"
TIMESTAMP_FILE="last_processed.timestamp"
S3_BUCKET="anitum-jk-production"
LOCATIONS=( "nungambakkam" )
MAX_PARALLEL=10
CHECK_INTERVAL=5

# ═══════════════════════════════════════════════════════════════════════════════
# COMMAND LINE ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════════

START_TIME=""
END_TIME=""
ONE_TIME_MODE=false
CHANNELS=()

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
    --channel)
      channel_str="$2"
      channel_str="${channel_str#[}"
      channel_str="${channel_str%]}"
      IFS=',' read -ra CHANNELS <<< "$channel_str"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--start 'YYYY-MM-DD HH:MM'] [--end 'YYYY-MM-DD HH:MM'] [--channel '401' or --channel '401,701,301']"
      exit 1
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

ist_date() {
  TZ="Asia/Kolkata" date "$@"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CHANNEL FILTERING
# ═══════════════════════════════════════════════════════════════════════════════

is_channel_match() {
  local filename="$1"

  [[ ${#CHANNELS[@]} -eq 0 ]] && return 0

  local file_channel=$(echo "$filename" | grep -oP 'channel\K\d+' || echo "")
  [[ -z "$file_channel" ]] && return 1

  for chan in "${CHANNELS[@]}"; do
    chan=$(echo "$chan" | tr -d ' ')
    [[ "$file_channel" == "$chan" ]] && return 0
  done

  return 1
}

export -f is_channel_match
declare -p CHANNELS > /tmp/channels_array.sh

# ═══════════════════════════════════════════════════════════════════════════════
# FILE PROCESSING
# ═══════════════════════════════════════════════════════════════════════════════

process_file() {
  local key="$1"
  local target_dir="$DOWNLOAD_DIR"
  local filename=$(basename "$key")

  source /tmp/channels_array.sh 2>/dev/null || true

  is_channel_match "$filename" || return 0

  if [[ -f "$target_dir/$filename" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Skipped (exists): $filename"
    return 0
  fi

  mkdir -p "$target_dir"
  if aws s3 cp "s3://$S3_BUCKET/$key" "$target_dir/" --quiet; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Downloaded: $key"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed: $key"
  fi
}

export DOWNLOAD_DIR S3_BUCKET
export -f process_file

# ═══════════════════════════════════════════════════════════════════════════════
# TIME RANGE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════════════

get_hours_to_check() {
  local start_time="$1"
  local end_time="$2"

  local start_hour end_hour
  start_hour=$(ist_date -d "$start_time" '+%Y-%m-%d %H:00')
  end_hour=$(ist_date -d "$end_time" '+%Y-%m-%d %H:00')

  local start_hour_epoch end_hour_epoch
  start_hour_epoch=$(ist_date -d "$start_hour:00" +%s)
  end_hour_epoch=$(ist_date -d "$end_hour:00" +%s)

  local step_epoch="$start_hour_epoch"
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

is_file_in_range() {
  local filename="$1"
  local start_time="$2"
  local end_time="$3"

  local file_timestamp=$(echo "$filename" | grep -oP '\d{8}T\d{6}' || echo "")
  [[ -z "$file_timestamp" ]] && return 1

  local year="${file_timestamp:0:4}"
  local month="${file_timestamp:4:2}"
  local day="${file_timestamp:6:2}"
  local hour="${file_timestamp:9:2}"
  local minute="${file_timestamp:11:2}"
  local second="${file_timestamp:13:2}"

  local file_time="${year}-${month}-${day} ${hour}:${minute}:${second}"

  local file_epoch start_epoch end_epoch
  file_epoch=$(ist_date -d "$file_time" +%s)
  start_epoch=$(ist_date -d "$start_time:00" +%s)
  end_epoch=$(ist_date -d "$end_time:59" +%s)

  [[ $file_epoch -ge $start_epoch && $file_epoch -le $end_epoch ]]
}

extract_timestamp() {
  local filename="$1"
  echo "$filename" | grep -oP '\d{8}T\d{6}' || echo "00000000T000000"
}

timestamp_to_readable() {
  local ts="$1"
  if [[ ${#ts} -eq 15 ]]; then
    local year="${ts:0:4}"
    local month="${ts:4:2}"
    local day="${ts:6:2}"
    local hour="${ts:9:2}"
    local minute="${ts:11:2}"
    echo "${year}-${month}-${day} ${hour}:${minute}"
  else
    echo ""
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

mkdir -p "$DOWNLOAD_DIR"
touch "$TIMESTAMP_FILE"

log "Script started"
log "System TZ: $(date +%Z) | IST: $(ist_date '+%Y-%m-%d %H:%M:%S')"
log "S3: $S3_BUCKET | Locations: ${LOCATIONS[*]}"
log "Channels: ${CHANNELS[*]:-ALL}"

if [[ ! -s "$TIMESTAMP_FILE" ]]; then
  ist_date +"%Y-%m-%d %H:%M" > "$TIMESTAMP_FILE"
  log "Initialized timestamp: $(cat $TIMESTAMP_FILE)"
else
  log "Existing timestamp: $(cat $TIMESTAMP_FILE)"
fi

if [[ -n "$START_TIME" ]]; then
  echo "$START_TIME" > "$TIMESTAMP_FILE"
  log "Override start: $START_TIME"
fi

if [[ "$ONE_TIME_MODE" == "true" ]]; then
  log "Mode: One-time (end: $END_TIME)"
else
  log "Mode: Continuous"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN PROCESSING LOOP
# ═══════════════════════════════════════════════════════════════════════════════

log "Starting processing loop..."
loop_count=0

while true; do
  loop_count=$((loop_count + 1))
  log "═══════════════════════════════════════════════════════════"
  log "Cycle #$loop_count"

  last_processed_time=$(cat "$TIMESTAMP_FILE" | head -n1 | tr -d '\r')
  log "Last processed: $last_processed_time"

  if [[ "$ONE_TIME_MODE" == "true" ]] && [[ -n "$END_TIME" ]]; then
    current_time="$END_TIME"
  else
    current_time=$(ist_date +"%Y-%m-%d %H:%M")
  fi
  log "Current time: $current_time"

  # Check completion for one-time mode
  if [[ "$ONE_TIME_MODE" == "true" ]]; then
    last_epoch=$(ist_date -d "$last_processed_time:00" +%s)
    end_epoch=$(ist_date -d "$END_TIME:00" +%s)
    if [[ $last_epoch -ge $end_epoch ]]; then
      log "Reached end time. Exiting."
      exit 0
    fi
  fi

  # Query S3 for hour prefixes
  log "Querying S3..."
  hour_prefixes=$(get_hours_to_check "$last_processed_time" "$current_time")
  prefix_count=$(echo "$hour_prefixes" | wc -l)
  log "Checking $prefix_count hour-location combinations"

  declare -a temp_files=()
  idx=0

  while read -r loc y m d H; do
    prefix="${loc}/${y}/${m}/${d}/${H}/"
    tmpf=$(mktemp)
    temp_files[$idx]="$tmpf"

    {
      aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "$prefix" \
        --query 'Contents[].Key' \
        --output text 2>/dev/null | tr '\t' '\n' > "$tmpf"
    } &

    idx=$((idx + 1))
  done <<< "$hour_prefixes"

  wait

  # Combine and filter files
  all_files=$(mktemp)
  filtered_files=$(mktemp)

  for f in "${temp_files[@]:-}"; do
    [[ -s "$f" ]] && cat "$f" >> "$all_files"
  done

  total_files=$(wc -l < "$all_files" 2>/dev/null || echo 0)
  log "Total files in hour prefixes: $total_files"

  # Filter by time range and channel
  channel_matched=0
  while IFS= read -r file; do
    if [[ -n "$file" ]] && is_file_in_range "$file" "$last_processed_time" "$current_time"; then
      if is_channel_match "$file"; then
        echo "$file" >> "$filtered_files"
        channel_matched=$((channel_matched + 1))
      fi
    fi
  done < "$all_files"

  filtered_count=$(wc -l < "$filtered_files" 2>/dev/null || echo 0)
  log "Matched files: $filtered_count"

  if [[ $filtered_count -gt 0 ]]; then
    # Sort by timestamp
    sorted_files=$(mktemp)

    while IFS= read -r file; do
      [[ -n "$file" ]] && echo "$(extract_timestamp "$file")|${file}"
    done < "$filtered_files" | sort | cut -d'|' -f2 > "$sorted_files"

    log "Starting downloads (max $MAX_PARALLEL parallel)..."

    cat "$sorted_files" | xargs -I{} -P "$MAX_PARALLEL" bash -c 'process_file "$@"' _ {}

    log "Downloads complete"

    # Update timestamp to last file processed
    last_file=$(tail -1 "$sorted_files")
    last_ts=$(extract_timestamp "$last_file")
    latest_file_time=$(timestamp_to_readable "$last_ts")

    if [[ -n "$latest_file_time" ]]; then
      echo "$latest_file_time" > "$TIMESTAMP_FILE"
      log "Updated timestamp: $latest_file_time"
    fi

    rm -f "$sorted_files"
  else
    log "No new files found"
  fi

  # Cleanup
  rm -f "$all_files" "$filtered_files"
  for f in "${temp_files[@]:-}"; do
    rm -f "$f" 2>/dev/null || true
  done
  unset temp_files

  # Exit check for one-time mode
  if [[ "$ONE_TIME_MODE" == "true" ]]; then
    current_epoch=$(ist_date -d "$(cat $TIMESTAMP_FILE):00" +%s)
    end_epoch=$(ist_date -d "$END_TIME:00" +%s)
    if [[ $current_epoch -gt $end_epoch ]]; then
      log "Processed beyond end time. Exiting."
      exit 0
    fi
  fi

  log "Sleeping ${CHECK_INTERVAL}s..."
  sleep "$CHECK_INTERVAL"
done
