#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

REPO_URL="https://github.com/Cryptizer69/nodeboi.git"
INSTALL_DIR="$HOME/.nodeboi"
SCRIPT_VERSION="1.0.0"

# ASCII Art function
print_nodeboi_art() {
    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
    ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗
    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║
    ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║
    ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║
    ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║
    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
EOF
    echo -e "                    ${YELLOW}ETHEREUM NODE AUTOMATION${NC}"
    echo -e "                           ${GREEN}v${SCRIPT_VERSION}${NC}"
    echo ""
}

# Error handler
handle_error() {
    echo -e "\n${RED}[ERROR]${NC} $1" >&2
    exit 1
}

# Check for required commands
check_requirements() {
    local missing_deps=""
    
    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+="git "
    fi
    
    # Check for docker
    if ! command -v docker &> /dev/null; then
        missing_deps+="docker "
    fi
    
    # Check for docker-compose
    if ! command -v docker-compose &> /dev/null; then
        missing_deps+="docker-compose "
    fi
    
    if [[ -n "$missing_deps" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Missing dependencies: ${missing_deps}"
        echo "Installing missing dependencies..."
        
        # Update package list
        sudo apt-get update || handle_error "Failed to update package list"
        
        # Install missing dependencies
        for dep in $missing_deps; do
            echo "Installing $dep..."
            if [[ "$dep" == "docker" ]]; then
                # Docker requires special installation
                curl -fsSL https://get.docker.com -o get-docker.sh
                sudo sh get-docker.sh || handle_error "Failed to install Docker"
                sudo usermod -aG docker $USER
                rm get-docker.sh
            else
                sudo apt-get install -y "$dep" || handle_error "Failed to install $dep"
            fi
        done
        
        echo -e "${GREEN}✓${NC} Dependencies installed successfully"
    fi
}

# Install function
install_nodeboi() {
    echo -e "${CYAN}Installing NODEBOI...${NC}\n"
    
    # Check requirements
    check_requirements
    
    # Check if already installed
    if [[ -d "$INSTALL_DIR" ]]; then
        echo -e "${YELLOW}[WARNING]${NC} NODEBOI appears to be already installed at $INSTALL_DIR"
        read -p "Do you want to reinstall? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 0
        fi
        
        # Backup existing config if it exists
        if [[ -f "$INSTALL_DIR/config.yaml" ]]; then
            echo "Backing up existing configuration..."
            cp "$INSTALL_DIR/config.yaml" "$INSTALL_DIR/config.yaml.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        rm -rf "$INSTALL_DIR"
    fi
    
    # Clone repository
    echo "Downloading NODEBOI from GitHub..."
    git clone "$REPO_URL" "$INSTALL_DIR" || handle_error "Failed to clone repository"
    
    # Make main script executable
    chmod +x "$INSTALL_DIR/nodeboi.sh" || handle_error "Failed to set permissions"
    
    # Create symlink in /usr/local/bin
    echo "Creating system link (requires sudo)..."
    sudo ln -sf "$INSTALL_DIR/nodeboi.sh" /usr/local/bin/nodeboi || handle_error "Failed to create symlink"
    
    # Create update script
    cat > "$INSTALL_DIR/update.sh" << 'UPDATESCRIPT'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="$HOME/.nodeboi"

echo -e "${CYAN}Checking for NODEBOI updates...${NC}"

cd "$INSTALL_DIR" || exit 1

# Check if there are local changes
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${YELLOW}[WARNING]${NC} You have local changes in the NODEBOI directory:"
    git status --short
    echo ""
    echo "Options:"
    echo "1) Stash changes and update (recommended)"
    echo "2) Keep local changes and skip update"
    echo "3) Discard local changes and update"
    read -p "Choose option (1-3): " choice
    
    case $choice in
        1)
            echo "Stashing local changes..."
            git stash push -m "Auto-stash before update $(date +%Y%m%d_%H%M%S)"
            git pull origin main
            echo -e "${YELLOW}Your changes have been stashed. To restore them, run:${NC}"
            echo "cd $INSTALL_DIR && git stash pop"
            ;;
        2)
            echo "Skipping update to preserve local changes."
            exit 0
            ;;
        3)
            echo "Discarding local changes..."
            git reset --hard HEAD
            git pull origin main
            ;;
        *)
            echo "Invalid option. Update cancelled."
            exit 1
            ;;
    esac
else
    # No local changes, safe to pull
    git pull origin main
fi

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} NODEBOI updated successfully!"
    
    # Check if update script itself was updated
    if git diff HEAD~1 HEAD --name-only | grep -q "update.sh"; then
        echo -e "${YELLOW}[INFO]${NC} Update script was modified. Please run 'nodeboi update' again."
    fi
else
    echo -e "${RED}[ERROR]${NC} Update failed. Please check your internet connection and try again."
    exit 1
fi
UPDATESCRIPT
    
    chmod +x "$INSTALL_DIR/update.sh"
    
    # Add update command to main script (if not already there)
    if ! grep -q "update)" "$INSTALL_DIR/nodeboi.sh"; then
        # Add update case to the main script
        sed -i '/case "$1" in/a\    update)\n        $HOME/.nodeboi/update.sh\n        exit 0\n        ;;' "$INSTALL_DIR/nodeboi.sh"
    fi
    
    # Success message
    clear
    print_nodeboi_art
    echo -e "${GREEN}${BOLD}✅ NODEBOI installed successfully!${NC}\n"
    echo -e "${CYAN}Installation location:${NC} $INSTALL_DIR"
    echo -e "${CYAN}Usage:${NC} Just type ${YELLOW}'nodeboi'${NC} from any directory\n"
    echo -e "${CYAN}Commands:${NC}"
    echo -e "  ${YELLOW}nodeboi${NC}           - Show dashboard"
    echo -e "  ${YELLOW}nodeboi install${NC}   - Install a new node"
    echo -e "  ${YELLOW}nodeboi update${NC}    - Update NODEBOI to latest version"
    echo -e "  ${YELLOW}nodeboi status${NC}    - Check node status"
    echo -e "  ${YELLOW}nodeboi help${NC}      - Show all commands\n"
    
    # Check if user needs to re-login for docker group
    if groups | grep -q docker; then
        echo -e "${GREEN}✓${NC} Docker group membership active"
    else
        echo -e "${YELLOW}[IMPORTANT]${NC} You've been added to the docker group."
        echo -e "Please log out and back in for this to take effect, or run:"
        echo -e "  ${CYAN}newgrp docker${NC}"
    fi
}

# Trap Ctrl+C
trap 'handle_error "Installation cancelled by user"' INT TERM

# Run installation
install_nodeboi
