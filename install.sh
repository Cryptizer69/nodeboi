#!/bin/bash
# NODEBOI Installation Script - Simple & Reliable for Ubuntu

set -e

NODEBOI_VERSION="v0.4.0"
INSTALL_DIR="$HOME/.nodeboi"

echo "Installing NODEBOI ${NODEBOI_VERSION}..."

# Check Docker
if ! command -v docker >/dev/null 2>&1; then
    echo "Error: Docker is required but not installed."
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "Error: Docker Compose v2 is required but not installed."
    exit 1
fi

# Remove old installation if exists
[[ -d "$INSTALL_DIR" ]] && rm -rf "$INSTALL_DIR"

# Download and extract
echo "Downloading NODEBOI..."
curl -sSL "https://github.com/Cryptizer69/nodeboi/archive/${NODEBOI_VERSION}.tar.gz" | tar -xz -C "$HOME"
mv "$HOME/nodeboi-${NODEBOI_VERSION#v}" "$INSTALL_DIR"

# Make everything executable
chmod +x "$INSTALL_DIR"/*.sh
chmod +x "$INSTALL_DIR"/lib/*.sh

# Create the nodeboi command
sudo tee /usr/local/bin/nodeboi > /dev/null <<EOF
#!/bin/bash
cd "$INSTALL_DIR" && exec ./nodeboi.sh "\$@"
EOF
sudo chmod +x /usr/local/bin/nodeboi

echo "✓ NODEBOI ${NODEBOI_VERSION} installed successfully!"
echo "Run 'nodeboi' to get started."
