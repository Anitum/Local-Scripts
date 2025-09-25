#!/bin/bash

# Create systemd service files for P_fast_upload_monitor.sh and P_record.sh

# 1. Create service file for P_fast_upload_monitor.sh
tee /etc/systemd/system/fast-upload-monitor.service > /dev/null << 'EOF'
[Unit]
Description=Fast Upload Monitor Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=an1tum
Group=an1tum
WorkingDirectory=/home/an1tum
ExecStart=/home/an1tum/P_fast_upload_monitor.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Environment variables (add any needed by your script)
Environment=HOME=/home/an1tum
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# 2. Create service file for P_record.sh
tee /etc/systemd/system/record.service > /dev/null << 'EOF'
[Unit]
Description=Recording Service
After=network.target
Wants=network.target

[Service]
Type=simple
User=an1tum
Group=an1tum
WorkingDirectory=/home/an1tum
ExecStart=/home/an1tum/P_record.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Environment variables (add any needed by your script)
Environment=HOME=/home/an1tum
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# 3. Make the scripts executable (if not already)
chmod +x /home/an1tum/P_fast_upload_monitor.sh
chmod +x /home/an1tum/P_record.sh

# 4. Reload systemd to recognize new service files
systemctl daemon-reload

# 5. Enable services to start automatically on boot
systemctl enable fast-upload-monitor.service
systemctl enable record.service

# 6. Start the services immediately
systemctl start fast-upload-monitor.service
systemctl start record.service


