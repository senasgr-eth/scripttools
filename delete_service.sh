#!/bin/bash

# Prompt for service name
read -p "Enter the name of the service you want to delete: " SERVICE_NAME

# Validate if the service exists
if ! systemctl list-units --type=service | grep -q "$SERVICE_NAME"; then
    echo "Error: Service '$SERVICE_NAME' does not exist."
    exit 1
fi

# First confirmation
read -p "Are you sure you want to delete the service '$SERVICE_NAME' (yes/no)? " CONFIRM_1

if [[ "$CONFIRM_1" != "yes" ]]; then
    echo "Service deletion canceled."
    exit 0
fi

# Second confirmation (double confirmation)
read -p "Are you absolutely sure you want to delete the service '$SERVICE_NAME' (yes/no)? " CONFIRM_2

if [[ "$CONFIRM_2" != "yes" ]]; then
    echo "Service deletion canceled."
    exit 0
fi

# Stop and disable the service
echo "Stopping and disabling the service '$SERVICE_NAME'..."
systemctl stop "$SERVICE_NAME"
systemctl disable "$SERVICE_NAME"

# Remove the systemd service file
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
if [ -f "$SERVICE_FILE" ]; then
    echo "Deleting service file: $SERVICE_FILE"
    rm -f "$SERVICE_FILE"
else
    echo "Error: Service file not found: $SERVICE_FILE"
    exit 1
fi

# Remove the associated start script
START_SCRIPT="/your/app/path/start-$SERVICE_NAME.sh"
if [ -f "$START_SCRIPT" ]; then
    echo "Deleting start script: $START_SCRIPT"
    rm -f "$START_SCRIPT"
else
    echo "Error: Start script not found: $START_SCRIPT"
    exit 1
fi

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "✅ The service '$SERVICE_NAME' has been successfully deleted!"
