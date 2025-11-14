#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# SIMPLE S3 DOWNLOADER
# ═══════════════════════════════════════════════════════════════════════════════

DOWNLOAD_DIR="./P_downloaded"
S3_BUCKET="anitum-jk-production"
LOCATION="nungambakkam"
MAX_PARALLEL=10

START_TIME=""
END_TIME=""
CHANNELS=()

# ═══════════════════════════════════════════════════════════════════════════════
# PARSE ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
  case $1 in
    --start)
      START_TIME="$2"
      shift 2
      ;;
    --end)
      END_TIME="$2"
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
      echo "Usage: $0 [--start 'YYYY-MM-DD HH:MM'] [--end 'YYYY-MM-DD HH:MM'] [--channel '401,701,301']"
      exit 1
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log() {
  echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] $*"
}

ist_date() {
  TZ="Asia/Kolkata" date "$@"
}

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

extract_timestamp() {
  local filename="$1"
  echo "$filename" | grep -oP '\d{8}T\d{6}' || echo "00000000T000000"
}

is_file_in_range() {
  local filename="$1"
  local start_time="$2"
  local end_time="$3"
  
  local file_timestamp=$(extract_timestamp "$filename")
  [[ -z "$file_timestamp" || "$file_timestamp" == "00000000T000000" ]] && return 1
  
  local year="${file_timestamp:0:4}"
  local month="${file_timestamp:4:2}"
  local day="${file_timestamp:6:2}"
  local hour="${file_timestamp:9:2}"
  local minute="${file_timestamp:11:2}"
  local second="${file_timestamp:13:2}"
  
  local file_time="${year}-${month}-${day} ${hour}:${minute}:${second}"
  local file_epoch=$(ist_date -d "$file_time" +%s)
  
  [[ -n "$start_time" ]] && {
    local start_epoch=$(ist_date -d "$start_time:00" +%s)
    [[ $file_epoch -lt $start_epoch ]] && return 1
  }
  
  [[ -n "$end_time" ]] && {
    local end_epoch=$(ist_date -d "$end_time:59" +%s)
    [[ $file_epoch -gt $end_epoch ]] && return 1
  }
  
  return 0
}

download_file() {
  local key="$1"
  local filename=$(basename "$key")
  
  if aws s3 cp "s3://$S3_BUCKET/$key" "$DOWNLOAD_DIR/" --quiet 2>/dev/null; then
    echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] ✓ $filename"
  else
    echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] ✗ $filename"
  fi
}

export S3_BUCKET DOWNLOAD_DIR
export -f download_file

# ═══════════════════════════════════════════════════════════════════════════════
# DETERMINE TIME RANGE
# ═══════════════════════════════════════════════════════════════════════════════

if [[ -z "$START_TIME" && -z "$END_TIME" ]]; then
  echo "Error: Must specify at least --start or --end"
  exit 1
fi

[[ -z "$START_TIME" ]] && START_TIME="2020-01-01 00:00"
[[ -z "$END_TIME" ]] && END_TIME=$(ist_date '+%Y-%m-%d %H:%M')

start_epoch=$(ist_date -d "$START_TIME:00" +%s)
end_epoch=$(ist_date -d "$END_TIME:59" +%s)

log "═══════════════════════════════════════════════════════════"
log "S3 Downloader Started"
log "Bucket: $S3_BUCKET"
log "Location: $LOCATION"
log "Start: $START_TIME"
log "End: $END_TIME"
log "Channels: ${CHANNELS[*]:-ALL}"
log "Download dir: $DOWNLOAD_DIR"
log "═══════════════════════════════════════════════════════════"

mkdir -p "$DOWNLOAD_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# GENERATE HOUR PREFIXES
# ═══════════════════════════════════════════════════════════════════════════════

start_hour=$(ist_date -d "$START_TIME" '+%Y-%m-%d %H:00')
end_hour=$(ist_date -d "$END_TIME" '+%Y-%m-%d %H:00')

start_hour_epoch=$(ist_date -d "$start_hour:00" +%s)
end_hour_epoch=$(ist_date -d "$end_hour:00" +%s)

hour_prefixes=()
step_epoch="$start_hour_epoch"

while [[ "$step_epoch" -le "$end_hour_epoch" ]]; do
  y=$(ist_date -d "@$step_epoch" +%Y)
  m=$(ist_date -d "@$step_epoch" +%m)
  d=$(ist_date -d "@$step_epoch" +%d)
  H=$(ist_date -d "@$step_epoch" +%H)
  hour_prefixes+=("${LOCATION}/${y}/${m}/${d}/${H}/")
  step_epoch=$(( step_epoch + 3600 ))
done

log "Processing ${#hour_prefixes[@]} hour directories"

# ═══════════════════════════════════════════════════════════════════════════════
# LIST FILES AND DOWNLOAD IN PARALLEL
# ═══════════════════════════════════════════════════════════════════════════════

FIFO_DIR=$(mktemp -d)
FIFO="$FIFO_DIR/download_queue"
mkfifo "$FIFO"

# Start downloader workers
download_worker() {
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    download_file "$file"
  done < "$FIFO"
}

for ((i=0; i<MAX_PARALLEL; i++)); do
  download_worker &
done

WORKER_PIDS=$!

# List and feed files to FIFO
{
  for prefix in "${hour_prefixes[@]}"; do
    log "Listing: s3://$S3_BUCKET/$prefix"
    
    aws s3api list-objects-v2 \
      --bucket "$S3_BUCKET" \
      --prefix "$prefix" \
      --query 'Contents[].Key' \
      --output text 2>/dev/null | tr '\t' '\n' | while IFS= read -r file; do
      
      [[ -z "$file" ]] && continue
      
      is_file_in_range "$file" "$START_TIME" "$END_TIME" || continue
      is_channel_match "$file" || continue
      
      echo "$(extract_timestamp "$file")|$file"
    done
  done | sort -t'|' -k1,1 | cut -d'|' -f2
} > "$FIFO" &

LIST_PID=$!

# Wait for listing to complete
wait $LIST_PID

# Close FIFO to signal workers
exec 3>&-

# Wait for all downloads
wait

# Cleanup
rm -rf "$FIFO_DIR"

log "═══════════════════════════════════════════════════════════"
log "Download complete!"
log "═══════════════════════════════════════════════════════════"
