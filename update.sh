#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$HOME/.nodeboi"

echo -e "${CYAN}Checking for NODEBOI updates...${NC}"

cd "$INSTALL_DIR" || exit 1

# Check for local changes
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${YELLOW}[WARNING]${NC} You have local changes."
    echo "1) Stash and update"
    echo "2) Keep local changes" 
    echo "3) Discard changes"
    read -p "Choice (1-3): " choice
    
    case $choice in
        1) git stash && git pull origin main ;;
        2) exit 0 ;;
        3) git reset --hard HEAD && git pull origin main ;;
    esac
else
    git pull origin main
fi

# Ensure executable
chmod +x "$INSTALL_DIR/nodeboi.sh"

echo -e "${GREEN}✓${NC} Update complete!"
read -p "Press Enter to continue..."
