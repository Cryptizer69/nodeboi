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
    local need_docker_compose=false
    
    # Check for git
    if ! command -v git &> /dev/null; then
        missing_deps+="git "
    fi
    
    # Check for docker
    if ! command -v docker &> /dev/null; then
        missing_deps+="docker "
        need_docker_compose=true  # If docker is missing, we'll need to install compose too
    else
        # Docker exists, check for Docker Compose v2 (plugin)
        if ! docker compose version &> /dev/null; then
            echo -e "${YELLOW}[WARNING]${NC} Docker Compose v2 plugin not found"
            need_docker_compose=true
        else
            echo -e "${GREEN}✓${NC} Docker Compose v2 detected: $(docker compose version --short)"
        fi
    fi
    
    if [[ -n "$missing_deps" ]] || [[ "$need_docker_compose" == true ]]; then
        echo -e "${YELLOW}[WARNING]${NC} Missing dependencies: ${missing_deps}"
        
        if [[ "$need_docker_compose" == true ]] && [[ -z "$missing_deps" ]]; then
            echo -e "${YELLOW}[WARNING]${NC} Docker Compose v2 plugin needs to be installed"
        fi
        
        echo "Installing missing dependencies..."
        
        # Update package list
        sudo apt-get update || handle_error "Failed to update package list"
        
        # Install git if missing
        if [[ "$missing_deps" == *"git"* ]]; then
            echo "Installing git..."
            sudo apt-get install -y git || handle_error "Failed to install git"
        fi
        
        # Install Docker and Docker Compose v2 if needed
        if [[ "$missing_deps" == *"docker"* ]]; then
            echo "Installing Docker with Compose v2 plugin..."
            
            # Remove old Docker versions if they exist
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
            
            # Install prerequisites
            sudo apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release || handle_error "Failed to install Docker prerequisites"
            
            # Add Docker's official GPG key
            sudo mkdir -p /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            
            # Set up the repository
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
                $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            
            # Update package index with Docker packages
            sudo apt-get update || handle_error "Failed to update package list with Docker repository"
            
            # Install Docker Engine with Compose plugin
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || handle_error "Failed to install Docker with Compose plugin"
            
            # Add user to docker group
            sudo usermod -aG docker $USER
            
        elif [[ "$need_docker_compose" == true ]]; then
            # Docker exists but Compose v2 plugin is missing
            echo "Installing Docker Compose v2 plugin..."
            
            # Try to install the compose plugin
            sudo apt-get update
            sudo apt-get install -y docker-compose-plugin || {
                # If apt installation fails, try manual installation
                echo "Attempting manual installation of Docker Compose v2..."
                
                # Create CLI plugins directory
                mkdir -p ~/.docker/cli-plugins/
                
                # Download Docker Compose v2
                COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
                curl -SL "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o ~/.docker/cli-plugins/docker-compose
                
                # Make it executable
                chmod +x ~/.docker/cli-plugins/docker-compose
                
                # Verify installation
                if docker compose version &> /dev/null; then
                    echo -e "${GREEN}✓${NC} Docker Compose v2 installed successfully"
                else
                    handle_error "Failed to install Docker Compose v2"
                fi
            }
        fi
        
        echo -e "${GREEN}✓${NC} All dependencies installed successfully"
        
        # Verify Docker Compose v2 is working
        if docker compose version &> /dev/null; then
            echo -e "${GREEN}✓${NC} Docker Compose v2 is ready: $(docker compose version --short)"
        else
            echo -e "${YELLOW}[WARNING]${NC} Docker Compose v2 verification failed. You may need to restart your shell or log out and back in."
        fi
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
    
    # Update any docker-compose references to docker compose in the cloned files
    echo "Updating Docker Compose references to v2..."
    if [[ -f "$INSTALL_DIR/nodeboi.sh" ]]; then
        sed -i 's/docker-compose/docker compose/g' "$INSTALL_DIR/nodeboi.sh"
    fi
    
    # Update any compose files to use the correct version format for v2
    for compose_file in "$INSTALL_DIR"/*.yml "$INSTALL_DIR"/*.yaml "$INSTALL_DIR"/docker-compose.*; do
        if [[ -f "$compose_file" ]]; then
            # Update version to 3.8 if it's using an older version
            sed -i "s/^version: ['\"]2[^'\"]*['\"]/version: '3.8'/g" "$compose_file"
            sed -i "s/^version: ['\"]3\.[0-7]['\"]$/version: '3.8'/g" "$compose_file"
        fi
    done
    
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
    
    # Update docker-compose references to docker compose after update
    echo "Updating Docker Compose references to v2..."
    if [[ -f "$INSTALL_DIR/nodeboi.sh" ]]; then
        sed -i 's/docker-compose/docker compose/g' "$INSTALL_DIR/nodeboi.sh"
    fi
    
    # Check if update script itself was updated
    if git diff HEAD~1 HEAD --name-only | grep -q "update.sh"; then
        echo -e "${YELLOW}[INFO]${NC} Update script was modified. Please run update again if needed."
    fi
    
    echo ""
    read -p "Press Enter to return to menu..."
else
    echo -e "${RED}[ERROR]${NC} Update failed. Please check your internet connection and try again."
    read -p "Press Enter to return to menu..."
    exit 1
fi
UPDATESCRIPT
    
    chmod +x "$INSTALL_DIR/update.sh"
    
    # Installation complete message (brief)
    echo -e "\n${GREEN}✓${NC} NODEBOI installed successfully!"
    
    # Check if user needs to re-login for docker group
    NEED_NEWGRP=false
    if ! groups | grep -q docker; then
        echo -e "${YELLOW}[IMPORTANT]${NC} You've been added to the docker group."
        echo -e "Running newgrp to activate docker permissions..."
        NEED_NEWGRP=true
    fi
    
    # Launch NODEBOI directly
    echo -e "${CYAN}Launching NODEBOI...${NC}\n"
    sleep 1
    
    if [[ "$NEED_NEWGRP" == true ]]; then
        # Run nodeboi in a new group session
        exec newgrp docker <<EOF
nodeboi
EOF
    else
        # Just run nodeboi
        exec nodeboi
    fi
}

# Trap Ctrl+C
trap 'handle_error "Installation cancelled by user"' INT TERM

# Run installation
install_nodeboi
