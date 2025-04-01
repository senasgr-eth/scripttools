#!/bin/bash

# Prompt user for input
read -p "Enter full path to bitcoind daemon (e.g., /root/xbt-core/bitcoind): " DAEMON_PATH
read -p "Enter full path to Eiquidus directory (e.g., /root/eiquidus): " EIQUIDUS_PATH
read -p "Enter a name for the systemd service (e.g., eiquidus): " SERVICE_NAME

# Ensure the paths are valid
if [ ! -f "$DAEMON_PATH" ]; then
    echo "Error: bitcoind binary not found at $DAEMON_PATH"
    exit 1
fi
if [ ! -d "$EIQUIDUS_PATH" ]; then
    echo "Error: Eiquidus directory not found at $EIQUIDUS_PATH"
    exit 1
fi

# Make the start script
START_SCRIPT="$EIQUIDUS_PATH/start-explorer.sh"

echo "Creating start script at $START_SCRIPT..."

cat > "$START_SCRIPT" <<EOL
#!/bin/bash

# Start bitcoind only if not running
if ! pgrep -x "bitcoind" > /dev/null; then
  echo "Starting bitcoind..."
  $DAEMON_PATH -daemon
  sleep 10
else
  echo "bitcoind is already running."
fi

# Navigate to Eiquidus
cd $EIQUIDUS_PATH || exit

# Start the explorer in the background
echo "Starting Eiquidus Explorer..."
npm run start &

# Wait a few seconds for explorer startup
sleep 5

# Infinite loop to sync data periodically
while true; do
  echo "Running sync-blocks..."
  node --stack-size=5000 scripts/sync.js index update

  echo "Running sync-markets..."
  npm run sync-markets

  echo "Running sync-peers..."
  npm run sync-peers

  echo "Running reindex-rich..."
  npm run reindex-rich

  sleep 60
done
EOL

# Make it executable
chmod +x "$START_SCRIPT"

# Create systemd service file
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"

echo "Creating systemd service at $SERVICE_FILE..."

cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=$SERVICE_NAME Auto Start
After=network.target

[Service]
Type=simple
ExecStart=$START_SCRIPT
Restart=always
User=root
WorkingDirectory=$EIQUIDUS_PATH
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd, enable and start the service
echo "Enabling and starting systemd service..."
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"

echo "Deployment complete! Use 'systemctl status $SERVICE_NAME' to check the service."
