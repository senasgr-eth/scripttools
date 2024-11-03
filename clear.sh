#!/bin/bash

# Clear bash history for the current session
history -c
history -w  # Write the changes to the history file

# Remove bash history file for the user
rm -f ~/.bash_history

# Clear any previous session histories in /var/log
sudo rm -f /var/log/wtmp /var/log/btmp /var/log/lastlog

# (Optional) Clear other logs in /var/log
# WARNING: Removing these logs can impact debugging and log retention!
sudo rm -rf /var/log/*.log
sudo rm -rf /var/log/*

# Provide feedback to the user
echo "Bash history and log files have been cleared."
