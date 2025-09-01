#!/bin/bash
# NODEBOI Quick Installer

echo "Installing NODEBOI..."

# Download directory
INSTALL_DIR="$HOME/nodeboi"

# Clean previous installation
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Download all files
echo "Downloading files..."
BASE_URL="https://raw.githubusercontent.com/Cryptizer69/nodeboi/main"
wget -q "$BASE_URL/nodeboi.sh"
wget -q "$BASE_URL/default.env"
wget -q "$BASE_URL/compose.yml"
wget -q "$BASE_URL/besu.yml"
wget -q "$BASE_URL/reth.yml"
wget -q "$BASE_URL/nethermind.yml"
wget -q "$BASE_URL/lodestar-cl-only.yml"
wget -q "$BASE_URL/teku-cl-only.yml"
wget -q "$BASE_URL/grandine-cl-only.yml"
wget -q "$BASE_URL/mevboost.yml"

# Make executable
chmod +x nodeboi.sh

# Create global command (accessible from anywhere)
sudo ln -sf "$INSTALL_DIR/nodeboi.sh" /usr/local/bin/nodeboi

echo "✅ NODEBOI installed successfully!"
echo ""
echo "Usage: just type 'nodeboi' from anywhere"
