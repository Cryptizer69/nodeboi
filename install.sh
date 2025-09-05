#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.nodeboi"
REPO_URL="https://github.com/Cryptizer69/nodeboi"

echo -e "\033[38;5;240m[*] Preparing Nodeboi...\033[0m"

echo -e "\033[38;5;240m[*] Installing Nodeboi...\033[0m"
rm -rf "$INSTALL_DIR"
git clone -q "$REPO_URL" "$INSTALL_DIR"
cd "$INSTALL_DIR"
git config core.fileMode false 

# Fix permissions (only files that must be executable)
chmod +x "$INSTALL_DIR/nodeboi.sh"
find "$INSTALL_DIR/lib" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;

# Tiny wrapper in /usr/local/bin
sudo tee /usr/local/bin/nodeboi >/dev/null <<'EOW'
#!/usr/bin/env bash
exec "$HOME/.nodeboi/nodeboi.sh" "$@"
EOW
sudo chmod +x /usr/local/bin/nodeboi

# Install systemd service (quiet, no uitleg banners)
SERVICE_FILE="/etc/systemd/system/nodeboi.service"
sudo tee "$SERVICE_FILE" >/dev/null <<'EOS'
[Unit]
Description=Nodeboi CLI
After=network.target

[Service]
ExecStart=%h/.nodeboi/nodeboi.sh
Restart=always
User=%u
WorkingDirectory=%h
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOS

sudo systemctl daemon-reload
sudo systemctl enable --now nodeboi >/dev/null 2>&1 || true

echo
echo -e "\033[38;5;46m[✓] Installation complete.\033[0m"
echo -e "\033[38;5;240mType 'nodeboi' to start the Nodeboi menu at any time.\033[0m"
