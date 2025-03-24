#!/bin/bash

# Update and install necessary packages
echo "Updating package lists..."
sudo apt update
sudo apt install -y curl gnupg

# Install NVM (Node Version Manager)
echo "Installing NVM..."
curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
source ~/.profile

# Install Node.js (LTS and specific version)
echo "Installing Node.js..."
nvm install --lts
nvm install 20.9.0

# Add MongoDB repository and install MongoDB
echo "Adding MongoDB repository..."
curl -fsSL https://pgp.mongodb.com/server-7.0.asc | sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

echo "Updating package lists and installing MongoDB..."
sudo apt update
sudo apt install -y mongodb-org

# Start and enable MongoDB service
echo "Starting and enabling MongoDB..."
sudo systemctl start mongod
sudo systemctl enable mongod

# Configure MongoDB user
echo "Configuring MongoDB user..."
mongosh <<EOF
use explorerdb
db.createUser({
  user: "eiquidus",
  pwd: "Nd^p2d77ceBX!L",
  roles: ["readWrite"]
})
exit
EOF

# Clone the Eiquidus explorer repository
echo "Cloning the Eiquidus explorer repository..."
git clone https://github.com/team-exor/eiquidus explorer

# Install dependencies
echo "Installing dependencies..."
cd explorer && npm install --only=prod

# Copy settings template
echo "Setting up configuration..."
cp ./settings.json.template ./settings.json

echo "Installation completed!"
