# DNS Guard Supervisor

## Overview

DNS Guard Supervisor is a lightweight monitoring and self-healing Bash service that ensures reliable DNS functionality on Linux systems.

The script continuously monitors:

* Network availability
* Upstream connectivity
* DNS resolver service status
* DNS resolution functionality

When failures are detected, the service automatically attempts recovery actions such as flushing DNS caches or restarting the DNS resolver.

All diagnostic events are logged to a dedicated log file for troubleshooting and monitoring.

---

# Features

* Continuous DNS health monitoring
* Automatic DNS recovery
* Cooldown protection to avoid repeated actions
* Structured logging with detailed diagnostic status
* Runs as a persistent system service
* Minimal system resource usage

---

# File Locations

| Component      | Location                                                                           |
| -------------- | ---------------------------------------------------------------------------------- |
| Main Script    | Location where you place the script (example: `/usr/local/bin/dns_checker_new.sh`) |
| Log File       | `/var/log/surveillance_new.log`                                                    |
| System Service | `/etc/systemd/system/dns_checker_new.service`                                      |

---

# Monitoring Checks

The script performs the following checks every cycle.

### 1. Network Route Check

Verifies the presence of a default route using:

```
ip route
```

If no default route exists, the network is considered unavailable.

---

### 2. Upstream Connectivity Check

Checks external connectivity by pinging:

```
8.8.8.8
```

If the ping fails, the script logs an upstream connectivity failure and skips DNS checks.

---

### 3. DNS Service Check

Verifies that the DNS resolver service is active.

The script checks:

```
systemd-resolved
```

If the service is inactive, the script attempts to restart it automatically.

---

### 4. DNS Resolution Check

Performs a DNS resolution test using:

```
getent hosts google.com
```

If resolution fails, the script attempts recovery actions.

---

# Automatic Recovery Actions

When DNS resolution fails, the script performs the following recovery steps:

1. Flush DNS cache

```
resolvectl flush-caches
```

2. Restart DNS resolver

```
systemctl restart systemd-resolved
```

Each action is logged along with the result.

---

# Logging

All events are written to:

```
/var/log/surveillance_new.log
```

Example log entries:

```
2026-03-13 01:02:14 [DNS] ERROR: DNS_RESOLUTION_FAIL | ACTION:DNS_CACHE_FLUSHED | PING:OK | DNS_SERVICE:OK | DNS_RESOLVE:RECOVERED
```

```
2026-03-13 01:05:20 [DNS] MULTIPLE_ERRORS(2): DNS_SERVICE_DOWN DNS_RESOLUTION_FAIL | ACTION:DNS_SERVICE_RESTARTED | PING:OK | DNS_SERVICE:RECOVERED | DNS_RESOLVE:RECOVERED
```

```
2026-03-13 01:08:10 [DNS] NETWORK_UNAVAILABLE | ROUTE_FAIL
```

Logging occurs only when failures are detected.

---

# Installation

## 1. Copy Script

Place the script in a system location.

Example:

```
sudo cp dns_checker_new.sh /usr/local/bin/
```

---

## 2. Make Script Executable

```
sudo chmod +x /usr/local/bin/dns_checker_new.sh
```

---

## 3. Run the Script

Execute the script once to install and start the service.

```
sudo /usr/local/bin/dns_checker_new.sh
```

The script will automatically:

* Create a system service
* Enable it
* Start it

## 4. Start the service
Run the following scripts:
```
sudo systemctl daemon-reload
sudo systemctl enable dns_checker_new.service
sudo systemctl start dns_checker_new.service
sudo systemctl status dns_checker_new.service
```
---

# Service Information

Service name:

```
dns_checker_new.service
```

Check service status:

```
sudo systemctl status dns_checker_new.service
```

View logs:

```
sudo cat /var/log/surveillance_new.log
```

Follow logs live:

```
sudo tail -f /var/log/surveillance_new.log
```

---

# Uninstalling

To completely remove the service:

## Stop the service

```
sudo systemctl stop dns_checker_new.service
```

## Disable the service

```
sudo systemctl disable dns_checker_new.service
```

## Remove service file

```
sudo rm /etc/systemd/system/dns_checker_new.service
```

## Reload systemd

```
sudo systemctl daemon-reload
```

## Remove the script (optional)

```
sudo rm /usr/local/bin/dns_checker_new.sh
```

---

# Workflow Summary

The monitoring loop runs continuously:

1. Check if network route exists
2. Check upstream connectivity
3. Check DNS service status
4. Test DNS resolution
5. Attempt recovery if failures occur
6. Log diagnostic information if errors are detected
7. Wait 50 seconds before repeating

A cooldown mechanism prevents repeated corrective actions within a short time window.

---

# Requirements

* Linux system with systemd
* `systemd-resolved`
* Bash shell
* Standard networking tools (`ping`, `ip`, `getent`, `resolvectl`)

---

# License

Internal use / project specific.
