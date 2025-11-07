# 📘 **S3 Upload Monitor – Technical & Testing Documentation**

## 1. Overview

This script continuously monitors a local directory for `.mkv` video files and uploads them to an **AWS S3 bucket** in a structured, timestamp-based path format.  
It supports parallel uploads, automatic retries with exponential backoff, and clean shutdown handling.

### Primary use case

Automated upload of CCTV/recorded videos from a local folder to AWS S3, grouped by **location and timestamp**.

---

## 2. Script name and location

**File:** `upload_monitor.sh`

**Dependencies:**

- Linux or macOS environment with bash ≥ 4.0
    
- AWS CLI configured with proper credentials (`aws configure`)
    
- `inotifywait` (from `inotify-tools`) for real-time monitoring  
    → Optional: if missing, script falls back to polling mode
    

---

## 3. Input and configuration

### Environment Variables / CLI Arguments

|Name|Required|Type|Description|Example|
|---|---|---|---|---|
|`LOCATION`|✅|String|Logical prefix for upload grouping. Represents the camera site, channel group, or organization.|`ntu`, `hyderabad_cam`, `officeA`|
|Argument `$1`|Optional|String|Same as `LOCATION` — can be passed as first CLI argument if env var not set.|`./upload_monitor.sh ntu`|
|`S3_BUCKET`|Fixed (in script)|String|Target S3 bucket name (change if needed).|`anitum-jk-production`|
|`MAX_PARALLEL`|Optional|Integer|Max concurrent uploads. Adjust based on system/network capacity.|Default: `6`|
|`RETRY_MAX`|Optional|Integer|Number of retry attempts per file.|Default: `5`|
|`RETRY_BASE`|Optional|Integer|Exponential retry base delay (in seconds).|Default: `2`|
|`CHECK_INTERVAL`|Optional|Integer|Polling interval when `inotifywait` not available.|Default: `1s`|

---

## 4. Folder and File Handling

### 4.1 Input Directory

- Watches **current working directory (`.`)** for `.mkv` or `.MKV` files.
    
- Detects new files on `close_write` or `moved_to` (atomic rename expected).
    

### 4.2 Stability Check

Before uploading:

- File size is measured twice (0.5 seconds apart).
    
- Upload starts **only if file size is stable** and non-zero.
    
- Prevents uploading partially written or open files.
    

### 4.3 Destination S3 Path

Each file is uploaded to:

```
s3://<S3_BUCKET>/<LOCATION>/<YYYY>/<MM>/<DD>/<HH>/<LOCATION>_<original_filename>.mkv
```

#### Example:

Local file:  
`channel902_20250528T064333.mkv`

Run as:  
`LOCATION=ntu ./upload_monitor.sh`

Destination path:

```
s3://anitum-jk-production/ntu/2025/05/28/06/ntu_channel902_20250528T064333.mkv
```

If no timestamp (`YYYYMMDDTHHMMSS`) found in filename, script uses **current system time**.

---

## 5. Upload Behavior

### 5.1 Upload Method

- Uses `aws s3 mv` (upload + delete local file).
    
- Upload is retried with exponential backoff:
    
    - Retry delay = `RETRY_BASE^attempt` seconds  
        e.g. 2, 4, 8, 16, 32 seconds for base=2.
        

### 5.2 Parallel Execution

- Concurrency limited by a **token semaphore** (FIFO).
    
- Default: 6 simultaneous uploads.
    
- Tokens released once upload completes.
    

### 5.3 Failure Handling

|Condition|Behavior|
|---|---|
|Upload success|Local file is deleted. Log entry marked “UPLOAD OK”.|
|File unstable|Skipped and logged as “File not stable or removed”.|
|All retries failed|File renamed to `<filename>.failed` to prevent infinite retries.|
|Interrupted (Ctrl+C / SIGTERM)|Graceful shutdown: waits for all active uploads, logs completion.|

---

## 6. Logs

### Location

`upload_monitor.log` (created in the working directory).

### Format

Each line includes timestamp and message:

```
YYYY-MM-DD HH:MM:SS - <MESSAGE>
```

### Example entries

```
2025-11-07 12:10:03 - Starting fast MKV upload monitor (location=ntu, max parallel=6)
2025-11-07 12:10:17 - Starting upload: ./channel902_20250528T064333.mkv
2025-11-07 12:10:19 - UPLOAD OK: ./channel902_20250528T064333.mkv -> s3://anitum-jk-production/ntu/2025/05/28/06/ntu_channel902_20250528T064333.mkv
```

---

## 7. Testing Checklist

### ✅ **Functional Tests**

|Test|Expected Result|
|---|---|
|Create `.mkv` file in watched dir (small, static)|File uploads successfully and is removed from local disk.|
|Filename with timestamp (e.g., `_20250528T064333.mkv`)|File appears under correct date/hour prefix in S3.|
|Filename **without timestamp**|File uploaded using **current system time** in S3 path.|
|Multiple files created quickly|Parallel uploads happen (limited by `MAX_PARALLEL`).|
|File grows after creation (unstable)|Script logs “File not stable or removed” and retries next loop.|
|Network disconnect mid-upload|Retries up to `RETRY_MAX`, then `.failed` created.|
|SIGINT (Ctrl+C)|Graceful shutdown message logged, ongoing uploads finish cleanly.|

---

### ⚙️ **Performance / Load Tests**

|Scenario|Expected Result|
|---|---|
|100+ `.mkv` files created|Upload concurrency maxes out, others queue; no process crash.|
|Heavy retry load (simulate failure with wrong bucket name)|Exponential backoff visible in logs, retries counted correctly.|
|Run for 24 hours continuously|Stable memory footprint, log grows steadily, no hangups.|

---

### 🔒 **Permission Tests**

|Setup|Expected Result|
|---|---|
|IAM user missing `s3:PutObject`|Log shows upload failure after retries.|
|IAM user missing `s3:DeleteObject`|Upload works, but local file not deleted (AWS CLI error).|
|Incorrect bucket name|Logs show `UPLOAD FAILED`, `.failed` file retained locally.|

---

## 8. Known Limitations / Edge Cases

- Only `.mkv` files are processed. Other formats ignored.
    
- If file timestamp format differs from `YYYYMMDDTHHMMSS`, current time is used.
    
- Script assumes system clock is correct.
    
- No retry for failed `.failed` files (manual intervention required).
    
- Log file can grow indefinitely — rotate logs periodically.
    

---

## 9. Quick Commands for Testers

**Run script (example):**

```bash
LOCATION=ntu ./upload_monitor.sh
```

**Watch logs in real time:**

```bash
tail -f upload_monitor.log
```

**Simulate new file:**

```bash
cp sample.mkv channel902_20250528T064333.mkv
```

**List in S3:**

```bash
aws s3 ls s3://anitum-jk-production/ntu/2025/05/28/06/
```

---

## 10. Expected S3 Hierarchy Example

```
s3://anitum-jk-production/
└── ntu/
    ├── 2025/
    │   ├── 05/
    │   │   ├── 28/
    │   │   │   ├── 06/
    │   │   │   │   ├── ntu_channel902_20250528T064333.mkv
    │   │   │   │   ├── ntu_channel903_20250528T064501.mkv
    │   │   │   │   └── ...
```

---

## 11. Exit Codes

| Code | Meaning                                                 |
| ---- | ------------------------------------------------------- |
| `0`  | Normal exit (or graceful shutdown).                     |
| `1`  | AWS CLI not found / invalid usage (missing `LOCATION`). |
| `2+` | Unexpected internal error (rare).                       |
