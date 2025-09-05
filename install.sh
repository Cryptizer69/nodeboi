#!/bin/bash
# NODEBOI Installation Script

set -e

NODEBOI_VERSION="v0.3.0"
INSTALL_DIR="$HOME/.nodeboi"
BINARY_PATH="/usr/local/bin/nodeboi"

echo "Installing NODEBOI ${NODEBOI_VERSION}..."

# Check prerequisites
command -v docker >/dev/null 2>&1 || { echo "Error: Docker is required but not installed."; exit 1; }
command -v docker compose >/dev/null 2>&1 || { echo "Error: Docker Compose is required but not installed."; exit 1; }

# Backup existing installation
if [[ -d "$INSTALL_DIR" ]]; then
    echo "Backing up existing installation..."
    mv "$INSTALL_DIR" "${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
fi

# Download and extract
echo "Downloading NODEBOI ${NODEBOI_VERSION}..."
curl -sSL "https://github.com/YOUR_USERNAME/nodeboi/archive/${NODEBOI_VERSION}.tar.gz" | tar -xz -C "$HOME"
mv "$HOME/nodeboi-${NODEBOI_VERSION#v}" "$INSTALL_DIR"

# Make executable
chmod +x "$INSTALL_DIR/nodeboi.sh"

# Create system binary
sudo tee "$BINARY_PATH" > /dev/null <<EOF
#!/usr/bin/env bash
exec "$INSTALL_DIR/nodeboi.sh" "\$@"
EOF

sudo chmod +x "$BINARY_PATH"

echo "✓ NODEBOI ${NODEBOI_VERSION} installed successfully!"
echo "Run 'nodeboi' to get started."