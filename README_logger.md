# Logger Service Setup (systemd)

This guide explains how to run `logger.sh` as a **systemd service** so that it:

* Runs automatically in the background
* Starts on system boot
* Restarts automatically if it crashes
* Can be managed using `systemctl`

---

# 1. Make the Script Executable

Give execute permission to the script.

```bash
chmod +x logger.sh
```

Verify permissions:

```bash
ls -l logger.sh
```

You should see something like:

```
-rwxr-xr-x logger.sh
```

---

# 2. Move the Script to a Standard Location

System services should run from a stable system path.

Move the script to:

```bash
sudo mv logger.sh /usr/bin/network-monitor.sh
```

Verify:

```bash
ls  /usr/bin/network-monitor.sh
```

---

# 3. Create the systemd Service File

Create a new service definition.

```bash
sudo nano /etc/systemd/system/network-monitor.service
```

Add the following configuration:

```ini
[Unit]
Description=Network Monitoring Service
After=network.target

[Service]
ExecStart=network-monitor.sh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

Save and exit.

---

# 4. Reload systemd

Whenever a new service file is created or modified, reload systemd.

```bash
sudo systemctl daemon-reload
```

---

# 5. Start the Service

Start the logger service manually.

```bash
sudo systemctl start network-monitor.service
```

---

# 6. Enable Service at Boot

Enable the service so it runs automatically when the system starts.

```bash
sudo systemctl enable network-monitor.service
```

---

# 7. Check Service Status

Verify the service is running.

```bash
sudo systemctl status network-monitor.service
```

Expected output should contain:

```
Active: active (running)
```

---

# 8. View Service Logs

To view logs produced by the service:

```bash
journalctl -u network-monitor.service
```

To follow logs in real time:

```bash
journalctl -u network-monitor.service -f
```

---

# 9. Stop or Restart the Service

Stop the service:

```bash
sudo systemctl stop network-monitor.service
```

Restart the service:

```bash
sudo systemctl restart network-monitor.service
```

---

# 10. Recommended: Use a Dedicated Log Directory

If the script writes logs, use a dedicated directory.

Example:

```bash
sudo mkdir -p /network_monitor
```

Update your script to write logs there:

```
LOG_DIR="/network_monitor"
```

---

# Summary

Commands for quick reference:

```bash
chmod +x logger.sh
sudo mv logger.sh network-monitor.sh
sudo nano /etc/systemd/system/network-monitor.service
sudo systemctl daemon-reload
sudo systemctl start network-monitor.service
sudo systemctl enable network-monitor.service
sudo systemctl status network-monitor.service
```

After completing these steps, `logger.sh` will run as a fully managed background service.
