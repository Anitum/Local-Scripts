#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# CONTINUOUS S3 DOWNLOADER
# ═══════════════════════════════════════════════════════════════════════════════

DOWNLOAD_DIR="./P_downloaded"
S3_BUCKET="anitum-jk-production"
LOCATION="nungambakkam"
MAX_PARALLEL=10
CHECK_INTERVAL=90
LOOKBACK_FILES=20
DOWNLOAD_HISTORY=".download_history.txt"

CHANNELS=()

# ═══════════════════════════════════════════════════════════════════════════════
# PARSE ARGUMENTS
# ═══════════════════════════════════════════════════════════════════════════════

while [[ $# -gt 0 ]]; do
  case $1 in
    --channel)
      channel_str="$2"
      channel_str="${channel_str#[}"
      channel_str="${channel_str%]}"
      IFS=',' read -ra CHANNELS <<< "$channel_str"
      shift 2
      ;;
    --interval)
      CHECK_INTERVAL="$2"
      shift 2
      ;;
    --lookback)
      LOOKBACK_FILES="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--channel '401,701'] [--interval 90] [--lookback 20]"
      exit 1
      ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

log() {
  echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] $*" >&2
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

# Check if file was already downloaded
is_already_downloaded() {
  local s3_key="$1"
  grep -Fxq "$s3_key" "$DOWNLOAD_HISTORY" 2>/dev/null && return 0
  return 1
}

# Mark file as downloaded (thread-safe with flock)
mark_as_downloaded() {
  local s3_key="$1"
  (
    flock -x 200
    echo "$s3_key" >> "$DOWNLOAD_HISTORY"
  ) 200>"${DOWNLOAD_HISTORY}.lock"
}

download_file() {
  local key="$1"
  local filename=$(basename "$key")
  
  # Check history first
  if is_already_downloaded "$key"; then
    return 0
  fi
  
  # Download
  if aws s3 cp "s3://$S3_BUCKET/$key" "$DOWNLOAD_DIR/" --quiet 2>/dev/null; then
    mark_as_downloaded "$key"
    echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] ✓ $filename" >&2
  else
    echo "[$(TZ=Asia/Kolkata date '+%Y-%m-%d %H:%M:%S')] ✗ $filename" >&2
  fi
}

export S3_BUCKET DOWNLOAD_DIR DOWNLOAD_HISTORY
export -f download_file is_already_downloaded mark_as_downloaded

# ═══════════════════════════════════════════════════════════════════════════════
# S3 DISCOVERY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

get_most_recent_year() {
  aws s3 ls "s3://$S3_BUCKET/${LOCATION}/" 2>/dev/null | \
    grep "PRE" | awk '{print $2}' | tr -d '/' | \
    grep '^[0-9]\{4\}$' | sort -rn | head -1 || echo ""
}

get_most_recent_month() {
  local year="$1"
  aws s3 ls "s3://$S3_BUCKET/${LOCATION}/${year}/" 2>/dev/null | \
    grep "PRE" | awk '{print $2}' | tr -d '/' | \
    grep '^[0-9]\{2\}$' | sort -rn | head -1 || echo ""
}

get_most_recent_day() {
  local year="$1"
  local month="$2"
  aws s3 ls "s3://$S3_BUCKET/${LOCATION}/${year}/${month}/" 2>/dev/null | \
    grep "PRE" | awk '{print $2}' | tr -d '/' | \
    grep '^[0-9]\{2\}$' | sort -rn | head -1 || echo ""
}

get_most_recent_hour() {
  local year="$1"
  local month="$2"
  local day="$3"
  aws s3 ls "s3://$S3_BUCKET/${LOCATION}/${year}/${month}/${day}/" 2>/dev/null | \
    grep "PRE" | awk '{print $2}' | tr -d '/' | \
    grep '^[0-9]\{2\}$' | sort -rn | head -1 || echo ""
}

discover_current_location() {
  log "🔍 Discovering current S3 location..."
  
  local year=$(get_most_recent_year)
  [[ -z "$year" ]] && { log "❌ No year found"; return 1; }
  log "  Year: $year"
  
  local month=$(get_most_recent_month "$year")
  [[ -z "$month" ]] && { log "❌ No month found"; return 1; }
  log "  Month: $month"
  
  local day=$(get_most_recent_day "$year" "$month")
  [[ -z "$day" ]] && { log "❌ No day found"; return 1; }
  log "  Day: $day"
  
  local hour=$(get_most_recent_hour "$year" "$month" "$day")
  [[ -z "$hour" ]] && { log "❌ No hour found"; return 1; }
  log "  Hour: $hour"
  
  echo "${year}|${month}|${day}|${hour}"
}

check_next_hour_exists() {
  local year="$1"
  local month="$2"
  local day="$3"
  local hour="$4"
  
  local current_datetime="${year}-${month}-${day} ${hour}:00:00"
  local next_epoch=$(ist_date -d "$current_datetime + 1 hour" +%s 2>/dev/null || echo "")
  
  [[ -z "$next_epoch" ]] && return 1
  
  local next_year=$(ist_date -d "@$next_epoch" +%Y)
  local next_month=$(ist_date -d "@$next_epoch" +%m)
  local next_day=$(ist_date -d "@$next_epoch" +%d)
  local next_hour=$(ist_date -d "@$next_epoch" +%H)
  
  local check=$(aws s3 ls "s3://$S3_BUCKET/${LOCATION}/${next_year}/${next_month}/${next_day}/" 2>/dev/null | grep "PRE ${next_hour}/" || echo "")
  
  if [[ -n "$check" ]]; then
    log "⏭️  Next hour detected: ${next_year}-${next_month}-${next_day} ${next_hour}:00"
    echo "${next_year}|${next_month}|${next_day}|${next_hour}"
    return 0
  fi
  
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN DOWNLOAD FUNCTION
# ═══════════════════════════════════════════════════════════════════════════════

download_recent_files() {
  local year="$1"
  local month="$2"
  local day="$3"
  local hour="$4"
  
  local prefix="${LOCATION}/${year}/${month}/${day}/${hour}/"
  
  log "📥 Checking: s3://$S3_BUCKET/$prefix"
  
  local files=$(aws s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "$prefix" \
    --query "reverse(sort_by(Contents, &LastModified))[:${LOOKBACK_FILES}].Key" \
    --output text 2>/dev/null | tr '\t' '\n' || echo "")
  
  if [[ -z "$files" ]]; then
    log "  No files found"
    return 0
  fi
  
  local file_count=$(echo "$files" | wc -l)
  log "  Found $file_count recent files (lookback window: $LOOKBACK_FILES)"
  
  local to_download=$(mktemp)
  local downloaded_count=0
  local skipped_count=0
  
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    
    # Check if already downloaded
    if is_already_downloaded "$file"; then
      skipped_count=$((skipped_count + 1))
      continue
    fi
    
    # Check channel match
    if ! is_channel_match "$file"; then
      continue
    fi
    
    echo "$file" >> "$to_download"
    downloaded_count=$((downloaded_count + 1))
  done <<< "$files"
  
  log "  Skipped: $skipped_count (already downloaded)"
  log "  New: $downloaded_count"
  
  if [[ $downloaded_count -gt 0 ]]; then
    cat "$to_download" | while IFS= read -r file; do
      echo "$(extract_timestamp "$file")|$file"
    done | sort -t'|' -k1,1 | cut -d'|' -f2 | \
    xargs -I{} -P "$MAX_PARALLEL" bash -c 'download_file "$@"' _ {}
  fi
  
  rm -f "$to_download"
}

# ═══════════════════════════════════════════════════════════════════════════════
# INITIALIZATION
# ═══════════════════════════════════════════════════════════════════════════════

mkdir -p "$DOWNLOAD_DIR"
touch "$DOWNLOAD_HISTORY"

log "═══════════════════════════════════════════════════════════"
log "🔄 Continuous S3 Downloader Started"
log "Bucket: $S3_BUCKET"
log "Location: $LOCATION"
log "Channels: ${CHANNELS[*]:-ALL}"
log "Check interval: ${CHECK_INTERVAL}s"
log "Lookback window: $LOOKBACK_FILES files"
log "Download dir: $DOWNLOAD_DIR"
log "History file: $DOWNLOAD_HISTORY ($(wc -l < "$DOWNLOAD_HISTORY") files tracked)"
log "═══════════════════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════════

cycle=0

location_info=$(discover_current_location)
if [[ -z "$location_info" ]]; then
  log "❌ Failed to discover S3 location. Exiting."
  exit 1
fi

IFS='|' read -r current_year current_month current_day current_hour <<< "$location_info"

log "✅ Starting from: ${current_year}-${current_month}-${current_day} ${current_hour}:00"
log ""

while true; do
  cycle=$((cycle + 1))
  log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log "🔄 Cycle #$cycle"
  log "📍 Current: ${current_year}-${current_month}-${current_day} ${current_hour}:00"
  
  download_recent_files "$current_year" "$current_month" "$current_day" "$current_hour"
  
  next_location=$(check_next_hour_exists "$current_year" "$current_month" "$current_day" "$current_hour" || echo "")
  
  if [[ -n "$next_location" ]]; then
    IFS='|' read -r current_year current_month current_day current_hour <<< "$next_location"
    log "✅ Moved to: ${current_year}-${current_month}-${current_day} ${current_hour}:00"
  else
    log "⏸️  Staying at current hour (next hour not ready yet)"
  fi
  
  log ""
  log "😴 Sleeping for ${CHECK_INTERVAL} seconds..."
  log ""
  sleep "$CHECK_INTERVAL"
done
