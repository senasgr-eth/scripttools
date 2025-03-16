#!/bin/bash

# Prompt user for ID and Secret
read -p "Enter your ID: " NEWT_ID
read -s -p "Enter your Secret: " NEWT_SECRET

# Define endpoint
ENDPOINT="https://app.s3na.xyz"

# Download Newt
wget -O newt "https://github.com/fosrl/newt/releases/download/1.1.1/newt_linux_amd64" && chmod +x ./newt

# Move Newt to /usr/local/bin
sudo mv ./newt /usr/local/bin

# Create systemd service file
SERVICE_FILE="/etc/systemd/system/newt.service"
echo "[Unit]
Description=Newt VPN Client
After=network.target

[Service]
ExecStart=/usr/local/bin/newt --id $NEWT_ID --secret $NEWT_SECRET --endpoint $ENDPOINT
Restart=always
User=root

[Install]
WantedBy=multi-user.target" | sudo tee $SERVICE_FILE

# Reload systemd, enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable newt
sudo systemctl start newt

# Confirm installation
echo "Installation complete. Newt VPN Client service is running."
