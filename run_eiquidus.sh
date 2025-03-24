#!/bin/bash

# Navigate to the explorer directory
cd /root/eiquidus || exit

# Start the explorer in the background
echo "Starting Eiquidus Explorer..."
npm run start &

# Wait for a few seconds to ensure the explorer is running
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

  # Sleep for 60 seconds before the next sync
  sleep 60
done
