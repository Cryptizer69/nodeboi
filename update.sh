#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$HOME/.nodeboi"

echo -e "${CYAN}Updating NODEBOI...${NC}"

cd "$INSTALL_DIR" || exit 1

# Gewoon forceer de update
git fetch origin
git reset --hard origin/main

# Maak uitvoerbaar
chmod +x "$INSTALL_DIR/nodeboi.sh"

echo -e "${GREEN}✓${NC} NODEBOI updated to latest version!"
read -p "Press Enter to continue..."
