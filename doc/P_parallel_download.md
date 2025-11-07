# Video Downloader Script Documentation
## Overview
The video downloader script automatically downloads video files from an S3 bucket in chronological order. It supports both continuous monitoring mode and one-time download mode with precise time range control.
## Prerequisites
- AWS CLI installed and configured with appropriate S3 access permissions
- Bash shell (Linux/Unix environment)
- Internet connectivity to access S3
## Configuration
Edit the script configuration section as needed:
```bash
DOWNLOAD_DIR="./P_downloaded" # Local download directory
TIMESTAMP_FILE="last_processed.timestamp" # Checkpoint file
S3_BUCKET="anitum-jk-production" # S3 bucket name
LOCATIONS=( "nungambakkam" ) # Location prefixes to monitor
MAX_PARALLEL=10 # Maximum concurrent downloads
CHECK_INTERVAL=5 # Seconds between checks (continuous mode)
```
## Usage Modes
### 1. Continuous Mode (Default)
Runs forever, continuously monitoring for new files:
```bash
./4downloader.sh
```
- Starts from the timestamp in `last_processed.timestamp`
- If no timestamp file exists, starts from current time
- Checks for new files every 5 seconds
- Downloads files chronologically across all channels
### 2. One-Time Download with Time Range
Downloads files within a specific time range and exits:
#### Download from specific start to specific end
```bash
./4downloader.sh --start "2025-11-07 10:25" --end "2025-11-07 11:30"
```
#### Download from specific start time to current time
```bash
./4downloader.sh --start "2025-11-07 10:25"
```
#### Download from last checkpoint to specific end time
```bash
./4downloader.sh --end "2025-11-07 11:30"
```
## Time Format
All times must be in **IST (Indian Standard Time)** format: `YYYY-MM-DD HH:MM`
Examples:
- `"2025-11-07 10:25"` (10:25 AM on November 7, 2025)
- `"2025-12-31 23:59"` (11:59 PM on December 31, 2025)
## File Organization
### S3 Structure Expected
Files must be organized in S3 as:
```
s3://bucket-name/location/YYYY/MM/DD/HH/filename.mkv
```
Example: `s3://anitum-jk-production/nungambakkam/2025/11/07/10/nungambakkam_channel101_20251107T102501.mkv`
### Local Download Structure
Files are downloaded to: `./P_downloaded/filename.mkv`
### Filename Format Expected
Video files should follow the naming pattern:
```
location_channelXXX_YYYYMMDDTHHMMss.mkv
```
Example: `nungambakkam_channel101_20251107T102501.mkv`
## Checkpoint System
- The script maintains a checkpoint in `last_processed.timestamp`
- Contains the last processed time in format: `YYYY-MM-DD HH:MM`
- Prevents re-downloading already processed files
- Automatically resumes from last position on restart
## Download Behavior
### Chronological Ordering
Files are downloaded in strict chronological order based on timestamp in filename:
1. All channels for 10:25:01
2. All channels for 10:25:31
3. All channels for 10:26:01
4. And so on...
### Exact Time Filtering
When specifying time ranges, the script filters files precisely:
- `--start "10:25" --end "10:30"` downloads only files timestamped between 10:25:00 and 10:30:59
- No rounding to hour boundaries
### Parallel Downloads
- Downloads up to 10 files simultaneously (configurable)
- Maintains chronological order across parallel streams
## Logging and Output
### Log Format
All log entries include timestamp: `[YYYY-MM-DD HH:MM:SS] Message`
### Key Log Messages
- **Script started**: Initialization and configuration info
- **Check cycle #N**: Beginning of each processing cycle
- **Checking prefix**: S3 folders being scanned
- **Found X files**: Number of files discovered in each folder
- **Files in exact time range**: Files matching time criteria
- **Downloaded**: Individual file download completion
- **Sleeping Xs**: Wait period before next check (continuous mode)
### Sample Output
```
[2025-11-07 10:30:15] Script started
[2025-11-07 10:30:15] System timezone: UTC
[2025-11-07 10:30:15] IST time: 2025-11-07 16:00:15
[2025-11-07 10:30:15] Download directory: ./P_downloaded
[2025-11-07 10:30:15] Override start time: 2025-11-07 10:25
[2025-11-07 10:30:15] One-time mode: will stop at 2025-11-07 10:45
[2025-11-07 10:30:16] Exact time range: [2025-11-07 10:25] to [2025-11-07 10:45]
[2025-11-07 10:30:16] Files in exact time range: 156
[2025-11-07 10:30:16] First 5 files to download:
[2025-11-07 10:30:16] - nungambakkam/2025/11/07/10/nungambakkam_channel101_20251107T102501.mkv (timestamp: 20251107T102501)
[2025-11-07 10:30:16] - nungambakkam/2025/11/07/10/nungambakkam_channel201_20251107T102501.mkv (timestamp: 20251107T102501)
[2025-11-07 10:30:18] Downloaded: nungambakkam/2025/11/07/10/nungambakkam_channel101_20251107T102501.mkv
[2025-11-07 10:30:18] Downloaded: nungambakkam/2025/11/07/10/nungambakkam_channel201_20251107T102501.mkv
```
## Error Handling
### Common Issues and Solutions
#### "No files found"
- Check if S3 bucket name and location prefixes are correct
- Verify files exist in the expected S3 folder structure
- Confirm time range contains actual video files
#### "AWS CLI errors"
- Ensure AWS CLI is installed: `aws --version`
- Verify AWS credentials: `aws s3 ls`
- Check S3 bucket permissions
#### "Permission denied"
- Make script executable: `chmod +x 4downloader.sh`
- Check write permissions for download directory
#### Script stops unexpectedly
- Check available disk space
- Verify network connectivity to S3
- Review error logs above the stopping point
## Testing Scenarios
### Basic Functionality Test
```bash
# Test 5-minute download
./4downloader.sh --start "2025-11-07 10:00" --end "2025-11-07 10:05"
```
### Continuous Mode Test
```bash
# Start continuous monitoring
./4downloader.sh --start "2025-11-07 10:00"
# Let it run for a few minutes, then Ctrl+C to stop
```
### Resume Test
```bash
# Run first batch
./4downloader.sh --start "2025-11-07 10:00" --end "2025-11-07 10:10"
# Check timestamp file
cat last_processed.timestamp
# Resume from where it left off
./4downloader.sh --end "2025-11-07 10:20"
```
### Large Time Range Test
```bash
# Test with several hours of data
./4downloader.sh --start "2025-11-07 08:00" --end "2025-11-07 12:00"
```
## Performance Considerations
- **Network bandwidth**: Higher `MAX_PARALLEL` values increase download speed but consume more bandwidth
- **Disk space**: Monitor available space in download directory
- **S3 costs**: More frequent checks in continuous mode increase S3 API calls
- **Memory usage**: Large time ranges may use more temporary files
## Files Created
- `./P_downloaded/`: Directory containing downloaded video files
- `last_processed.timestamp`: Checkpoint file (do not delete unless intentional reset needed)
- Temporary files in `/tmp/` (automatically cleaned up)
## Stopping the Script
- **Ctrl+C**: Gracefully stops the script in continuous mode
- One-time mode exits automatically when complete
- Safe to restart - will resume from last checkpoint
## Troubleshooting Commands
```bash
# Check script permissions
ls -la 4downloader.sh
# Test AWS connectivity
aws s3 ls s3://anitum-jk-production/nungambakkam/
# Check download directory
ls -la P_downloaded/
# View current checkpoint
cat last_processed.timestamp
# Reset checkpoint (caution: will re-download files)
rm last_processed.timestamp
```