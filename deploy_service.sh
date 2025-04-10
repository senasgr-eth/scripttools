#!/bin/bash

# Function to check if a command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Ensure node and npm are available
if ! command_exists node || ! command_exists npm; then
    echo "Error: Node.js and npm must be installed."
    exit 1
fi

# Prompt for the number of applications
read -p "How many applications do you want to run? " APP_COUNT

# Validate input
if ! [[ "$APP_COUNT" =~ ^[0-9]+$ ]]; then
    echo "Error: Please enter a valid number."
    exit 1
fi

# Create arrays to store application details
declare -a APP_NAMES
declare -a APP_PATHS
declare -a APP_COMMANDS

# Get user input for each application
for (( i=1; i<=APP_COUNT; i++ ))
do
    echo ""
    read -p "Enter the name for application #$i (e.g., eiquidus): " APP_NAME

    # Validate path and keep asking until a valid one is provided
    while true; do
        read -p "Enter the working directory for $APP_NAME: " APP_PATH
        if [ -d "$APP_PATH" ]; then
            break
        else
            echo "Error: Directory $APP_PATH does not exist! Please enter a valid path."
        fi
    done

    # Special handling for Eiquidus
    if [[ "$APP_NAME" == "eiquidus" ]]; then
        echo "Detected Eiquidus setup. Using special command set..."
        APP_COMMAND="npm run start"
    else
        read -p "Enter the command to run $APP_NAME: " APP_COMMAND
    fi

    # Store inputs
    APP_NAMES[$i]="$APP_NAME"
    APP_PATHS[$i]="$APP_PATH"
    APP_COMMANDS[$i]="$APP_COMMAND"
done

# Loop through each application and create scripts/services
for (( i=1; i<=APP_COUNT; i++ ))
do
    APP_NAME="${APP_NAMES[$i]}"
    APP_PATH="${APP_PATHS[$i]}"
    APP_COMMAND="${APP_COMMANDS[$i]}"
    
    # Define script and service paths
    START_SCRIPT="$APP_PATH/start-$APP_NAME.sh"
    SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"

    echo ""
    echo "Creating start script for $APP_NAME..."

    # Special handling for Eiquidus
    if [[ "$APP_NAME" == "eiquidus" ]]; then
        cat > "$START_SCRIPT" <<EOL
#!/bin/bash

# Load NVM if available
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"

# Navigate to Eiquidus directory
cd $APP_PATH || exit

# Start Eiquidus Explorer
echo "Starting Eiquidus Explorer..."
npm run start &

# Wait a few seconds to ensure the explorer is running
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
    else
        # Default start script for other applications
        cat > "$START_SCRIPT" <<EOL
#!/bin/bash

# Load NVM if available
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"

# Change to the app directory
cd $APP_PATH || exit

# Start the application in foreground
echo "Starting $APP_NAME..."
exec $APP_COMMAND
EOL
    fi

    # Make the script executable
    chmod +x "$START_SCRIPT"

    echo "Creating systemd service for $APP_NAME..."

    # Generate the systemd service file
    cat > "$SERVICE_FILE" <<EOL
[Unit]
Description=$APP_NAME Auto Start
After=network.target

[Service]
Type=simple
ExecStart=$START_SCRIPT
Restart=always
RestartSec=5
User=root
WorkingDirectory=$APP_PATH
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

    # Enable and start the service
    systemctl daemon-reload
    systemctl enable "$APP_NAME"
    systemctl start "$APP_NAME"

    echo "Deployment for $APP_NAME complete!"
done

echo ""
echo "✅ All applications have been deployed successfully!"
echo "Use 'systemctl status <app_name>' to check each service."
