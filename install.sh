#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color
PINK='\033[38;5;213m'

REPO_URL="https://github.com/Cryptizer69/nodeboi.git"
INSTALL_DIR="$HOME/.nodeboi"
SCRIPT_VERSION="v1.0.12"

# ASCII Art function
print_nodeboi_art() {
    echo -e "${PINK}${BOLD}"
    cat << "EOF"
    ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗
    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║
    ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║
    ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║
    ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║
    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
EOF
    echo -e "${NC}"
    echo -e "                    ${YELLOW}ETHEREUM NODE AUTOMATION${NC}"
    echo -e "                           ${GREEN}${SCRIPT_VERSION}${NC}"
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
        need_docker_compose=true
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
    
    # Create wrapper script instead of symlink (avoids caching issues)
    echo "Creating nodeboi command (requires sudo)..."
    
    # Remove old symlink if it exists
    if [[ -L "/usr/local/bin/nodeboi" ]]; then
        sudo rm /usr/local/bin/nodeboi
    fi
    
    # Create wrapper script
    sudo tee /usr/local/bin/nodeboi > /dev/null << 'EOF' || handle_error "Failed to create command"
#!/bin/bash
# NODEBOI wrapper script - avoids symlink caching issues
exec bash ~/.nodeboi/nodeboi.sh "$@"
EOF
    sudo chmod +x /usr/local/bin/nodeboi || handle_error "Failed to set permissions"
    
    # Create update script
    cat > "$INSTALL_DIR/update.sh" << 'UPDATESCRIPT'
#!/bin/bash

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="$HOME/.nodeboi"

echo -e "${CYAN}Updating NODEBOI...${NC}"

# Check if directory exists
if [[ ! -d "$INSTALL_DIR" ]]; then
    echo -e "${RED}[ERROR]${NC} NODEBOI directory not found at $INSTALL_DIR"
    exit 1
fi

cd "$INSTALL_DIR" || exit 1

# Force update from GitHub - no questions about local changes
echo "Fetching latest version from GitHub..."
git fetch origin

# Reset to match GitHub exactly
git reset --hard origin/main

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}✓${NC} Successfully pulled latest changes"
else
    echo -e "${RED}[ERROR]${NC} Failed to pull from GitHub"
    echo "Please check your internet connection and try again."
    read -p "Press Enter to continue..."
    exit 1
fi

# Make sure script is executable
chmod +x "$INSTALL_DIR/nodeboi.sh"

# Check if old symlink exists and needs to be replaced with wrapper
if [[ -L "/usr/local/bin/nodeboi" ]]; then
    echo -e "${YELLOW}Converting old symlink to wrapper script...${NC}"
    sudo rm /usr/local/bin/nodeboi
    
    # Create wrapper script
    sudo tee /usr/local/bin/nodeboi > /dev/null << 'WRAPPER'
#!/bin/bash
# NODEBOI wrapper script - avoids symlink caching issues
exec bash ~/.nodeboi/nodeboi.sh "$@"
WRAPPER
    
    sudo chmod +x /usr/local/bin/nodeboi
    echo -e "${GREEN}✓${NC} Wrapper script created"
fi

# Update docker-compose references to docker compose v2
if grep -q "docker-compose" "$INSTALL_DIR/nodeboi.sh" 2>/dev/null; then
    echo "Updating Docker Compose references to v2..."
    sed -i 's/docker-compose/docker compose/g' "$INSTALL_DIR/nodeboi.sh"
fi

# Show version info
CURRENT_VERSION=$(grep -oP 'v\d+\.\d+\.\d+' "$INSTALL_DIR/nodeboi.sh" | head -1)
if [[ -n "$CURRENT_VERSION" ]]; then
    echo -e "${GREEN}✓${NC} NODEBOI updated to version ${CYAN}${CURRENT_VERSION}${NC}"
else
    echo -e "${GREEN}✓${NC} NODEBOI updated successfully!"
fi

echo ""
echo -e "${GREEN}Update complete!${NC}"
echo ""
read -p "Press Enter to return to menu..."
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
