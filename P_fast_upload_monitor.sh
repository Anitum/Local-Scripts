#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Config
LOG_FILE="upload_monitor.log"
S3_BUCKET="anitum-calb-production"   # bucket only (no trailing slash)
CHECK_INTERVAL=1                   # used only in fallback polling mode
MAX_PARALLEL=6                     # tune this to your CPU / network
RETRY_MAX=5
RETRY_BASE=2                       # seconds, exponential backoff base
LOCATION="kathipara"


if [[ -z "${LOCATION}" ]]; then
  echo "Usage: LOCATION=<prefix> $0   OR   $0 <prefix>"
  echo "Example: LOCATION=ntu $0"
  exit 1
fi

# Ensure AWS CLI configured and in PATH
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
# added to make sure it chooses IPv6 when available and if not, IPv4 is chosen
export AWS_S3_USE_DUALSTACK_ENDPOINT=true

log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────
# Concurrency semaphore (same as before)
init_semaphore() {
  SEM=/tmp/upload_semaphore.$$
  mkfifo "$SEM"
  exec 9<>"$SEM"
  rm "$SEM"
  for ((i=0;i<MAX_PARALLEL;i++)); do printf "%s\n" "token" >&9; done
}
acquire_token() { read -r -u 9 _ || return 1; }
release_token() { printf "%s\n" "token" >&9; }

graceful_shutdown() {
  log_message "Shutting down: waiting for active uploads to finish..."
  shutting_down=1
  wait
  log_message "Shutdown complete"
  exit 0
}
trap graceful_shutdown SIGINT SIGTERM

# ─────────────────────────────────────────────────────────────
# Extract YYYY/MM/DD/HH from filename like: *_YYYYMMDDTHHMMSS*.mkv
# If not present, use current local time.
# Returns 5 values via echo: YEAR MONTH DAY HOUR DEST_BASENAME
build_s3_parts() {
  local file="$1"
  local base
  base="$(basename -- "$file")"

  local ymd="" hms=""
  if [[ "$base" =~ ([0-9]{8})T([0-9]{6}) ]]; then
    ymd="${BASH_REMATCH[1]}"
    hms="${BASH_REMATCH[2]}"
  else
    # Fallback to system time
    ymd="$(date +%Y%m%d)"
    hms="$(date +%H%M%S)"
  fi

  local year="${ymd:0:4}"
  local month="${ymd:4:2}"
  local day="${ymd:6:2}"
  local hour="${hms:0:2}"

  # Prepend location to filename if not already
  local dest_name="$base"
  case "$base" in
    ${LOCATION}_*) : ;;                             # already prefixed
    *) dest_name="${LOCATION}_$base" ;;
  esac

  echo "$year" "$month" "$day" "$hour" "$dest_name"
}

# ─────────────────────────────────────────────────────────────
# Upload with retries to computed key
upload_with_retries() {
  local file="$1"
  read -r YEAR MONTH DAY HOUR DEST_NAME < <(build_s3_parts "$file")

  local key="${LOCATION}/${YEAR}/${MONTH}/${DAY}/${HOUR}/${DEST_NAME}"
  local attempt=0
  while [[ $attempt -le $RETRY_MAX ]]; do
    if aws s3 mv --only-show-errors -- "$file" "s3://${S3_BUCKET}/${key}"; then
      log_message "UPLOAD OK: $file -> s3://${S3_BUCKET}/${key}"
      return 0
    else
      attempt=$((attempt+1))
      if [[ $attempt -gt $RETRY_MAX ]]; then
        log_message "UPLOAD FAILED: $file after $RETRY_MAX attempts (dest s3://${S3_BUCKET}/${key})"
        return 1
      fi
      local sleep_time=$((RETRY_BASE ** attempt))
      log_message "Upload failed for $file, retry #$attempt in ${sleep_time}s (dest s3://${S3_BUCKET}/${key})"
      sleep "$sleep_time"
    fi
  done
}

# ─────────────────────────────────────────────────────────────
# Stability check (same)



is_file_stable() {
  local f="$1"
  [[ ! -f "$f" ]] && return 1

  # Check if file is open (most reliable check)
  if command -v lsof >/dev/null 2>&1; then
    lsof "$f" >/dev/null 2>&1 && return 1
  fi

  # File age check - must be at least 5 seconds old
  local file_mod_time=$(stat -c %Y "$f" 2>/dev/null || echo 0)
  local current_time=$(date +%s)
  local age=$((current_time - file_mod_time))
  [[ $age -lt 5 ]] && return 1

  # Size stability - check twice with 2-second gap
  local s1 s2
  s1=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
  [[ "$s1" -eq 0 ]] && return 1

  sleep 2
  s2=$(stat -c %s -- "$f" 2>/dev/null || echo 0)
  [[ "$s1" -eq "$s2" ]]
}



process_ready_file() {
  local f="$1"
  acquire_token
  (
    if ! is_file_stable "$f"; then
      log_message "File not stable or removed: $f"
      release_token
      exit 0
    fi

    log_message "Starting upload: $f"
    if upload_with_retries "$f"; then
      log_message "Done upload: $f"
    else
      log_message "Giving up upload: $f"
      mv -f -- "$f" "$f.failed" 2>/dev/null || true
    fi
    release_token
  ) &
}

# ─────────────────────────────────────────────────────────────
init_semaphore
log_message "Starting fast MKV upload monitor (location=${LOCATION}, max parallel=${MAX_PARALLEL})"

# inotify mode preferred
if command -v inotifywait >/dev/null 2>&1; then
  inotifywait -m -e close_write -e moved_to --format '%f' . | while read -r filename; do
    case "$filename" in
      *.mkv|*.MKV) process_ready_file "./$filename" ;;
      *) ;;
    esac
  done
else
  log_message "inotifywait not found — polling every ${CHECK_INTERVAL}s"
  while true; do
    for file in ./*.mkv ./*.MKV; do
      [[ -e "$file" ]] || continue
      process_ready_file "$file"
    done
    sleep "$CHECK_INTERVAL"
  done
fi

wait

