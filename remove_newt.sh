#!/bin/bash

# Stop and disable the service
sudo systemctl stop newt
sudo systemctl disable newt

# Remove the systemd service file
sudo rm -f /etc/systemd/system/newt.service

# Reload systemd daemon
sudo systemctl daemon-reload

# Remove the newt binary
sudo rm -f /usr/local/bin/newt

# Confirm removal
echo "Newt VPN Client service and binary have been removed."
