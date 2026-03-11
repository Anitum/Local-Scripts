# DNS Guard Supervisor

A lightweight **self-healing DNS monitoring script for Linux systems** that automatically detects and attempts to repair DNS resolution issues.

The script continuously monitors the network and DNS resolver status and performs corrective actions when problems are detected.

It also installs itself as a **systemd service**, allowing it to run automatically in the background and start on system boot.

---

# Features

• Monitors system DNS health continuously
• Detects loss of default route
• Detects upstream network connectivity issues
• Detects DNS resolution failures
• Automatically flushes DNS cache
• Automatically restarts `systemd-resolved` if needed
• Logs all actions to a centralized log file
• Installs itself as a persistent **systemd service**

---

# How It Works

The script performs the following checks in a loop:

1. **Network Route Check**

Ensures a default route exists.

```
ip route | grep default
```

If no default route exists, the script logs:

```
NETWORK_DOWN - No default route
```

---

2. **External Connectivity Check**

Tests connectivity to an external IP.

```
ping 8.8.8.8
```

If unreachable:

```
UPSTREAM_UNREACHABLE - External network unreachable
```

---

3. **DNS Resolver Service Check**

Checks whether the resolver service is running.

```
systemctl is-active systemd-resolved
```

If inactive, the script attempts to restart it.

---

4. **DNS Resolution Test**

Attempts to resolve a hostname.

```
getent hosts google.com
```

If resolution fails:

Step 1 → Flush DNS cache

```
resolvectl flush-caches
```

Step 2 → Restart resolver service

```
systemctl restart systemd-resolved
```

If resolution still fails:

```
DNS_ATTENTION - Resolution failing after restart
```

---

# Logging

All events are written to:

```
/var/log/surveillance.log
```

Example log entries:

```
2026-03-11 10:42:12 [DNS] DNS_RESTARTED - systemd-resolved was inactive and restarted
2026-03-11 11:00:05 [DNS] DNS_FLUSHED - Cache issue resolved
2026-03-11 11:10:21 [DNS] UPSTREAM_UNREACHABLE - External network unreachable
```

---

# Installation

## Step 1 — Save the Script

Save the script as:

```
dns_checker.sh
```

---

## Step 2 — Make the Script Executable

```
chmod +x dns_checker.sh
```

---

## Step 3 — Run the Script Once

```
sudo ./dns_checker.sh
```

When executed, the script automatically:

1. Creates a **systemd service**
2. Enables it
3. Starts it

Service name:

```
dns_checker.service
```

---

# Systemd Service

The script automatically installs this service:

```
/etc/systemd/system/dns_checker.service
```

Service configuration:

```
[Unit]
Description=DNS Guard Supervisor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/home/anitum/Local-Scripts/dns_checker.sh # change the location as per the pc
Restart=always

[Install]
WantedBy=multi-user.target
```

---

# Managing the Service

## Check service status

```
sudo systemctl status dns_checker.service
```

---

## Start service

```
sudo systemctl start dns_checker.service
```

---

## Stop service

```
sudo systemctl stop dns_checker.service
```

---

## Restart service

```
sudo systemctl restart dns_checker.service
```

---

## Enable service on boot

```
sudo systemctl enable dns_checker.service
```

---

## Disable service

```
sudo systemctl disable dns_checker.service
```

---

# Viewing Logs

## View log file

```
cat /var/log/surveillance.log
```

---

## Live monitoring

```
tail -f /var/log/surveillance.log
```

---

# Script Behavior

The monitoring loop runs every:

```
50 seconds
```

To prevent repeated restarts, a **cooldown period** is implemented.

Cooldown duration:

```
120 seconds
```

This prevents the script from repeatedly restarting services if DNS issues occur frequently.

---

# Requirements

The following utilities must be available on the system:

```
bash
systemctl
ip
ping
getent
resolvectl
```

These are included in most modern Linux distributions.

---

# Uninstalling

To remove the service:

Stop it first:

```
sudo systemctl stop dns_checker.service
```

Disable it:

```
sudo systemctl disable dns_checker.service
```

Remove service file:

```
sudo rm /etc/systemd/system/dns_checker.service
```

Reload systemd:

```
sudo systemctl daemon-reload
```

Remove the script if desired.

---

# Security Notes

The script runs with **root privileges** because it performs:

• Service restarts
• DNS cache flushing
• Network diagnostics

