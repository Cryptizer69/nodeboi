#!/bin/bash
# lib/validator-manager.sh - Validator service installation and management

# Source dependencies
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh"
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"

INSTALL_DIR="$HOME/.nodeboi"


# Interactive key import function
interactive_key_import() {
    echo "✓ Starting key import process..."
    echo
    
    # First, ask for keystore location
    echo "Step 1: Locate your validator keystores"
    echo "======================================="
    echo "🔒 SECURITY RECOMMENDATION: Store keys on USB drive (not on this machine)"
    echo
    echo "Common keystore locations:"
    echo "  - 🔑 USB drive: /media/usb/validator_keys (MOST SECURE)"
    echo "  - 🔑 USB drive: /mnt/validator-usb/validator_keys"
    echo "  - ⚠️  Local: ~/validator_keys (NOT recommended - keys remain on machine)"
    echo "  - 📁 Custom path: /path/to/your/validator_keys"
    echo
    
    local keystore_location
    keystore_location=$(fancy_text_input "Keystore Location" \
        "Enter path to validator keystore directory (USB recommended):" \
        "$HOME/" \
        "")  # Pre-fill with home directory, no password masking
    
    if [[ -z "$keystore_location" ]]; then
        echo "Location cannot be empty. Key import cancelled."
        press_enter
        return 1
    else
        # Expand tilde if present
        keystore_location="${keystore_location/#\~/$HOME}"
        
        # Verify location exists and show immediate feedback
        if [[ ! -d "$keystore_location" ]]; then
            echo "✗ Directory not found: $keystore_location"
            echo "Please check the path and try again."
            press_enter
            return 1
        else
            # Show immediate feedback about keys found
            local keystore_count=$(find "$keystore_location" -name "keystore-*.json" 2>/dev/null | wc -l)
            if [[ "$keystore_count" -eq 0 ]]; then
                echo "✗ No keystore files found in $keystore_location"
                echo "Please check the directory contains keystore-*.json files."
                press_enter
                return 1
            else
                echo -e "${GREEN}✓ Found $keystore_count keystore files in $keystore_location${NC}"
                echo
                press_enter
                
                # Now ask for the keystore password
                echo "Step 2: Enter keystore password"
                echo "================================"
                echo "This password will decrypt your validator keystore files."
                echo
                
                local keystore_password
                keystore_password=$(fancy_text_input "Keystore Password" \
                    "Enter your keystore password:" \
                    "" \
                    "" \
                    true)  # true for password input (masked with asterisks)
                
                if [[ -z "$keystore_password" ]]; then
                    echo "Password cannot be empty. Key import cancelled."
                    press_enter
                    return 1
                else
                    # Update .env file and run import
                    sed -i "s|KEYSTORE_PASSWORD=.*|KEYSTORE_PASSWORD=\"${keystore_password}\"|g" "$HOME/web3signer/.env"
                    
                    local service_dir="$HOME/web3signer"
                    if [[ -f "$service_dir/import-keys.sh" ]]; then
                        echo "Starting key import..."
                        cd "$service_dir"
                        
                        if ./import-keys.sh "$keystore_location"; then
                            echo
                            echo "✓ Key import completed successfully!"
                            echo
                            echo "Restarting Web3signer to recognize new keys..."
                            docker compose down web3signer && docker compose up -d web3signer
                            echo "✓ Web3signer restarted"
                            
                            echo "Refreshing dashboard..."
                            sleep 2  # Give web3signer time to start
                            [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
                            echo "✓ Dashboard refreshed with updated key count"
                            echo
                            echo "Return to main menu?"
                            press_enter
                            return 0
                        else
                            echo
                            echo "✗ Key import failed. Please check the error messages above."
                            press_enter
                            return 1
                        fi
                    else
                        echo "Key import script not found. Please use:"
                        echo "  Manage Web3signer → Key import"
                        press_enter
                        return 1
                    fi
                fi
            fi
        fi
    fi
}

# Install Web3signer (singleton only)
install_web3signer() {
    # Enable strict error handling for transactional installation
    set -eE
    set -o pipefail
    
    local service_dir="$HOME/web3signer"  # Final installation location
    local staging_dir="$HOME/.web3signer-install-$$"  # Temporary staging area
    local installation_success=false
    local debug_mode="${WEB3SIGNER_DEBUG:-false}"  # Set to true for debug output
    
    # Comprehensive error handling - cleanup on ANY failure
    cleanup_failed_installation() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "${RED}✗${NC} Web3signer installation failed"
        echo "Performing complete cleanup..."
        
        # Stop and remove any Docker resources that were created
        if [[ -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
        fi
        
        # Remove any containers by name pattern
        docker ps -aq --filter "name=web3signer" | xargs -r docker rm -f 2>/dev/null || true
        
        # Remove volumes and networks
        docker volume ls -q --filter "name=web3signer" | xargs -r docker volume rm -f 2>/dev/null || true
        docker network ls -q --filter "name=web3signer" | xargs -r docker network rm 2>/dev/null || true
        
        # Remove staging and final directories
        rm -rf "$staging_dir" 2>/dev/null || true
        rm -rf "$service_dir" 2>/dev/null || true
        
        echo "✓ Cleanup completed"
        echo "Installation aborted - no partial installation left behind"
        
        exit $exit_code
    }
    
    # Set error trap
    trap cleanup_failed_installation ERR INT TERM
    
    # Check for existing installation
    if [[ -d "$service_dir" ]]; then
        echo "Web3signer is already installed at $service_dir"
        echo "Please remove it first if you want to reinstall"
        return 1
    fi
    
    # Create staging directory
    mkdir -p "$staging_dir"
    
    # Generate secure PostgreSQL password
    echo "Generating secure PostgreSQL password..."
    local postgres_password
    postgres_password=$(openssl rand -base64 32)
    echo "Generated secure PostgreSQL password"
    
    if [[ -z "$postgres_password" ]]; then
        echo "✗ Failed to generate PostgreSQL password"
        return 1
    fi
    
    # Allocate port for Web3signer using intelligent port management
    echo "Allocating Web3signer port..."
    source "$HOME/.nodeboi/lib/port-manager.sh"
    local web3signer_ports=($(allocate_service_ports "web3signer"))
    if [[ ${#web3signer_ports[@]} -ne 1 ]]; then
        echo "✗ Failed to allocate Web3signer port"
        return 1
    fi
    local web3signer_port="${web3signer_ports[0]}"
    echo "✓ Allocated port ${web3signer_port} for Web3signer"
    
    # Network selection with fancy menu
    local network_options=("Hoodi" "Mainnet")
    local network_selection
    if network_selection=$(fancy_select_menu "Select Network" "${network_options[@]}"); then
        # Validate selection index
        if [[ "$network_selection" -ge 0 && "$network_selection" -lt ${#network_options[@]} ]]; then
            local selected_network="${network_options[$network_selection]}"
            
            # Map display names to actual network values  
            case "$selected_network" in
                "Mainnet") selected_network="mainnet" ;;
                "Hoodi") selected_network="hoodi" ;;
            esac
            
            echo "✓ Using network: ${selected_network}"
        else
            echo "✗ Invalid network selection"
            return 1
        fi
    else
        echo "Network selection cancelled"
        return 1
    fi
    
    # Version selection with fancy menu
    local version_options=("Manually enter version (recommended)" "Use latest version")
    local version_selection
    if version_selection=$(fancy_select_menu "Select Web3signer Version" "${version_options[@]}"); then
        case $version_selection in
            0)
                # Manual version entry
                local web3signer_version
                web3signer_version=$(fancy_text_input "Web3signer Version" \
                    "Enter Web3signer version (e.g., 25.9.0):" \
                    "25.9.0" \
                    "")
                
                if [[ -z "$web3signer_version" ]]; then
                    echo "✗ Version cannot be empty"
                    return 1
                fi
                
                echo -e "${UI_MUTED}✓ Using Web3signer version: ${web3signer_version}${NC}"
                ;;
            1)
                # Use latest
                local web3signer_version="latest"
                echo -e "${UI_MUTED}✓ Using latest Web3signer version${NC}"
                ;;
        esac
    else
        echo "Version selection cancelled"
        return 1
    fi
    
    # Use placeholder values for atomic installation
    # Keystore import will be handled after successful installation
    local keystore_location=""
    local keystore_password=""
    
    # Create all configuration files in staging directory
    echo -e "${UI_MUTED}Creating configuration files...${NC}"
    
    # Ensure staging directory still exists (safety check)
    if [[ ! -d "$staging_dir" ]]; then
        echo -e "${RED}ERROR: Staging directory disappeared${NC}"
        exit 1
    fi
    
    create_web3signer_env_file "$staging_dir" "$postgres_password" "$keystore_password" "$selected_network" "$keystore_location" "$web3signer_port" "$web3signer_version"
    create_web3signer_compose_files "$staging_dir"
    create_web3signer_helper_scripts "$staging_dir"
    
    echo -e "${UI_MUTED}✓ Configuration files created${NC}"
    
    # Prepare for atomic installation (no containers started yet)
    echo -e "${UI_MUTED}Preparing Web3signer configuration...${NC}"
    cd "$staging_dir"
    
    echo -e "${UI_MUTED}Downloading Docker images (this may take a few minutes)...${NC}"
    if docker compose pull 2>&1 | while read line; do echo -e "${UI_MUTED}  $line${NC}"; done; then
        echo -e "${UI_MUTED}✓ Images downloaded successfully${NC}"
    else
        echo "✗ Failed to download Docker images"
        return 1
    fi
    
    echo -e "${UI_MUTED}✓ Configuration prepared for atomic installation${NC}"
    
    # Test if compose file is valid
    if ! docker compose config >/dev/null 2>&1; then
        echo "✗ Docker compose file is invalid!" >&2
        docker compose config 2>&1 | sed 's/^/  Error: /'
        return 1
    fi
    
    # Create web3signer network before starting containers
    echo -e "${UI_MUTED}Creating web3signer network...${NC}"
    if ! docker network ls --format "{{.Name}}" | grep -q "^web3signer-net$"; then
        docker network create web3signer-net >/dev/null 2>&1 || {
            echo "✗ Failed to create web3signer network"
            return 1
        }
        echo -e "${UI_MUTED}✓ Created web3signer-net network${NC}"
    else
        echo -e "${UI_MUTED}✓ web3signer-net network already exists${NC}"
    fi
    
    # Start containers in staging directory for health check
    echo -e "${UI_MUTED}Starting Web3signer containers...${NC}"
    docker compose up -d 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done
    
    # Wait for Web3signer to be ready (non-fatal - container startup is what matters)
    echo -e "${UI_MUTED}Waiting for Web3signer to be ready...${NC}"
    echo -e "${UI_MUTED}  Web3signer should be accessible at: http://localhost:${web3signer_port}/upcheck${NC}"
    
    # Give containers a moment to fully start before health checking
    sleep 5
    
    # Disable error handling for health check (this should be non-fatal)
    set +e
    local attempts=0
    local max_attempts=30  # Increased from 20 to 30 (90 seconds total)
    
    while ! curl -s http://localhost:${web3signer_port}/upcheck >/dev/null 2>&1; do
        sleep 3
        ((attempts++))
        if [[ $attempts -gt $max_attempts ]]; then
            echo -e "${YELLOW}⚠ Web3signer may need more time to fully initialize${NC}"
            echo -e "${UI_MUTED}  This is normal for first-time setup${NC}"
            break
        fi
        echo -e "${UI_MUTED}  Checking Web3signer health... (${attempts}/$max_attempts)${NC}"
    done
    
    if curl -s http://localhost:${web3signer_port}/upcheck >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Web3signer is running and healthy${NC}"
    else
        echo -e "${YELLOW}⚠ Web3signer container started successfully${NC}"
        echo -e "${UI_MUTED}  Service may still be initializing - this is normal${NC}"
    fi
    
    # Re-enable error handling after health check
    set -e
    trap cleanup_failed_installation ERR INT TERM
    
    echo
    
    # ATOMIC MOVE: Configuration complete, now commit the installation
    echo -e "${UI_MUTED}Finalizing installation...${NC}"
    
    # Ensure target doesn't exist (safety check)
    if [[ -d "$service_dir" ]]; then
        rm -rf "$service_dir"
    fi
    
    echo -e "${UI_MUTED}Moving from staging to final location...${NC}"
    
    # This is the atomic operation - either it all succeeds or fails
    mv "$staging_dir" "$service_dir"
    
    # Clean up any running containers from staging (they're now orphaned)
    cd "$service_dir"
    docker compose down 2>/dev/null || true
    
    # Clean up any conflicting containers by name
    echo -e "${UI_MUTED}Cleaning up any existing containers...${NC}"
    docker ps -aq --filter "name=web3signer" | while read id; do 
        [[ -n "$id" ]] && echo -e "${UI_MUTED}Removing container $id${NC}" && docker rm -f "$id" >/dev/null 2>&1
    done
    
    # Mark installation as successful
    installation_success=true
    
    # NOW start containers in final location (after atomic move)
    echo -e "${UI_MUTED}Starting Web3signer services...${NC}"
    
    # Start containers with proper error handling
    if docker compose up -d 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done; then
        echo "✓ Web3signer services started successfully"
        
        # Basic health check (non-fatal)
        echo "Checking service health..."
        sleep 5
        if curl -s http://localhost:${web3signer_port}/upcheck >/dev/null 2>&1; then
            echo "✓ Web3signer is healthy and ready"
        else
            echo "⚠ Web3signer is starting (may take a few moments to be ready)"
        fi
    else
        echo "⚠ Some services may have startup issues"
        echo "Services can be restarted manually with:"
        echo "  cd $service_dir && docker compose up -d"
    fi
    
    echo "✓ Web3signer installation completed successfully!"
    echo "Location: ${service_dir}"
    echo
    
    # Force refresh dashboard to show the new web3signer service
    echo -e "${UI_MUTED}Refreshing dashboard...${NC}"
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        echo -e "${GREEN}✓ Dashboard updated${NC}"
    fi
    echo
    
    # Sync Grafana dashboards if monitoring is installed
    if [[ -d "$HOME/monitoring" ]] && [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Syncing Grafana dashboards...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" && sync_dashboards "$HOME/monitoring/grafana/dashboards"
        echo -e "${GREEN}✓ Grafana dashboards updated${NC}"
        echo
    fi
    
    # Disable error traps - installation completed successfully
    set +eE
    set +o pipefail
    trap - ERR INT TERM
    
    # Ask user about key import
    echo -e "${GREEN}${BOLD}Ready for Key Import${NC}"
    echo "===================="
    echo
    echo "Web3signer is now installed and ready to secure your validator keys."
    echo
    
    local import_options=("Start key import process now" "Import keys later through 'Manage Web3signer → Key import'")
    local import_choice
    if import_choice=$(fancy_select_menu "Do you want to start the key import process?" "${import_options[@]}"); then
        case $import_choice in
            0)
                interactive_key_import
                ;;
            1)
                echo "✓ Key import postponed"
                echo
                echo "To import keys later:"
                echo "  Main Menu → Manage services → Manage Web3signer → Key import"
                press_enter
                ;;
        esac
    else
        echo "Installation completed. You can import keys later through the main menu."
        press_enter
    fi
}

# Install Vero (singleton only) - Atomic Installation
install_vero() {
    # Enable strict error handling for transactional installation
    set -eE
    set -o pipefail
    
    local service_dir="$HOME/vero"  # Final installation location
    local staging_dir="$HOME/.vero-install-$$"  # Temporary staging area  
    local installation_success=false
    
    # Comprehensive error handling - cleanup on ANY failure
    cleanup_failed_vero_installation() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "\n${RED}✗ Vero installation failed${NC}"
        echo -e "${UI_MUTED}Performing complete cleanup...${NC}"
        
        # Stop and remove any Docker resources that were created
        if [[ -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
        fi
        
        # Remove any containers by name pattern
        docker ps -aq --filter "name=vero" | xargs -r docker rm -f 2>/dev/null || true
        
        # Remove volumes and networks
        docker volume ls -q --filter "name=vero" | xargs -r docker volume rm -f 2>/dev/null || true
        docker network ls -q --filter "name=vero" | xargs -r docker network rm 2>/dev/null || true
        
        # Remove staging and final directories
        rm -rf "$staging_dir" 2>/dev/null || true
        rm -rf "$service_dir" 2>/dev/null || true
        
        echo "✓ Cleanup completed"
        echo "Installation aborted - no partial installation left behind"
        
        exit $exit_code
    }
    
    # Set up traps for ALL types of failures
    trap 'cleanup_failed_vero_installation' ERR INT TERM
    
    echo -e "${CYAN}${BOLD}Install Vero Validator${NC}"
    echo "======================="
    echo
    
    # Singleton check
    if [[ -d "$service_dir" ]]; then
        echo -e "${YELLOW}Vero is already installed${NC}"
        echo -e "${UI_MUTED}Only one Vero instance is supported${NC}"
        echo -e "${UI_MUTED}Location: ${service_dir}${NC}"
        press_enter
        return 0
    fi
    
    # Check Web3signer dependency (must exist)
    if [[ ! -d "$HOME/web3signer" || ! -f "$HOME/web3signer/.env" ]]; then
        echo -e "${RED}Web3signer not found!${NC}"
        echo -e "${UI_MUTED}Please install Web3signer first.${NC}"
        press_enter
        return 1
    fi
    
    # Auto-discover available ethnode networks
    local available_ethnodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            
            # Check if nodeboi-net exists (all ethnodes use this network)
            if docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
                available_ethnodes+=("$node_name")
            fi
        fi
    done
    
    if [[ ${#available_ethnodes[@]} -eq 0 ]]; then
        echo -e "${RED}No ethnode networks found!${NC}"
        echo -e "${UI_MUTED}Please install at least one ethnode first.${NC}"
        press_enter
        return 1
    fi
    
    # Clean up any existing installations completely
    echo -e "${UI_MUTED}Ensuring clean installation environment...${NC}"
    
    # Remove any existing Docker resources first
    docker ps -aq --filter "name=vero" | xargs -r docker rm -f 2>/dev/null || true
    docker volume ls -q --filter "name=vero" | xargs -r docker volume rm -f 2>/dev/null || true  
    docker network ls -q --filter "name=vero" | xargs -r docker network rm 2>/dev/null || true
    
    # Remove any existing directories
    rm -rf "$service_dir" "$staging_dir" 2>/dev/null || true
    
    # Create staging directory structure (build everything here first)
    echo -e "${UI_MUTED}Creating staging environment...${NC}"
    mkdir -p "$staging_dir"
    
    echo -e "${GREEN}Found ${#available_ethnodes[@]} ethnode(s):${NC}"
    for ethnode in "${available_ethnodes[@]}"; do
        echo -e "${UI_MUTED}  • $ethnode${NC}"
    done
    echo
    
    # Ask which beacon nodes to connect to
    local selected_ethnodes=()
    
    if [[ ${#available_ethnodes[@]} -eq 1 ]]; then
        echo
        echo -e "${GREEN}Beacon Node Selection${NC}"
        echo "===================="
        echo
        echo "Only one beacon node is available, automatically selecting:"
        echo -e "  ${BLUE}✓ ${available_ethnodes[0]}${NC}"
        echo
        selected_ethnodes=("${available_ethnodes[0]}")
        press_enter
    else
        echo "Select beacon nodes to connect to (space-separated numbers, e.g., '1 3'):"
        for i in "${!available_ethnodes[@]}"; do
            echo "  $((i+1))) ${available_ethnodes[$i]}"
        done
        echo
        echo "Press Enter without typing to select all nodes"
        read -p "Selection: " -a choices
        
        # If no choices provided, select all available nodes
        if [[ ${#choices[@]} -eq 0 ]]; then
            selected_ethnodes=("${available_ethnodes[@]}")
            echo "Selected all available beacon nodes: ${selected_ethnodes[*]}"
        else
            # Process user selections
            for choice in "${choices[@]}"; do
                if [[ $choice -ge 1 && $choice -le ${#available_ethnodes[@]} ]]; then
                    selected_ethnodes+=("${available_ethnodes[$((choice-1))]}")
                fi
            done
            
            if [[ ${#selected_ethnodes[@]} -eq 0 ]]; then
                echo -e "${RED}No valid beacon nodes selected${NC}"
                echo "Please enter numbers between 1 and ${#available_ethnodes[@]}"
                return 1
            fi
        fi
    fi
    
    # Get fee recipient with retry logic
    local fee_recipient
    while true; do
        fee_recipient=$(fancy_text_input "Validator Setup" \
            "⚠️  Important: This fee recipient will be used for ALL validators managed by Vero

This is the Ethereum address that will receive block rewards and MEV payments
from all validators connected to this Vero instance.

Fee recipient address:" \
            "0x0000000000000000000000000000000000000000" \
            "")
        
        # Handle cancellation
        if [[ $? -eq 255 ]]; then
            echo "Installation cancelled"
            return 1
        fi
        
        # Validate fee recipient format
        if [[ "$fee_recipient" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
            # Valid format - break out of loop
            break
        else
            echo -e "${RED}Invalid fee recipient address format${NC}"
            echo -e "${UI_MUTED}Expected format: 0x followed by exactly 40 hexadecimal characters${NC}"
            echo -e "${UI_MUTED}Example: 0x1234567890abcdef1234567890abcdef12345678${NC}"
            echo
            if fancy_confirm "Try again?" "y"; then
                continue
            else
                echo "Installation cancelled"
                return 1
            fi
        fi
    done
    
    # Get graffiti
    local graffiti
    graffiti=$(fancy_text_input "Validator Setup" \
        "Graffiti (optional):" \
        "vero" \
        "")
    
    # Create directory structure
    echo -e "${UI_MUTED}Creating directory structure...${NC}"
    mkdir -p "$service_dir"
    
    # Get network from Web3signer
    local network=$(grep "ETH2_NETWORK=" "$HOME/web3signer/.env" | cut -d'=' -f2)
    
    # Create .env file
    create_vero_env_file "$service_dir" "$network" "$fee_recipient" "$graffiti" "${selected_ethnodes[@]}"
    
    # Create compose file
    create_vero_compose_file "$service_dir" "${selected_ethnodes[@]}"
    
    echo -e "${GREEN}✓ Vero created successfully!${NC}"
    echo -e "${UI_MUTED}Starting Vero validator...${NC}"
    
    # Start Vero automatically after installation
    cd "$service_dir"
    if docker compose up -d; then
        echo -e "${GREEN}✓ Vero started successfully!${NC}"
    else
        echo -e "${YELLOW}⚠ Vero created but failed to start - you can start it manually later${NC}"
    fi
    echo -e "${UI_MUTED}Directory: ${service_dir}${NC}"
    echo -e "${UI_MUTED}Connected to Web3signer: web3signer${NC}"
    echo -e "${UI_MUTED}Connected to beacon nodes: ${selected_ethnodes[*]}${NC}"
    echo -e "${UI_MUTED}Fee recipient: ${fee_recipient}${NC}"
    echo
    
    # Mark installation as successful before dashboard sync
    installation_success=true
    
    # Disable error traps - installation completed successfully
    set +eE
    set +o pipefail
    trap - ERR INT TERM
    
    # Sync Grafana dashboards if monitoring is installed
    if [[ -d "$HOME/monitoring" ]] && [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Syncing Grafana dashboards...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" && sync_dashboards "$HOME/monitoring/grafana/dashboards"
        echo -e "${GREEN}✓ Grafana dashboards updated${NC}"
    fi
    
    # Refresh dashboard cache to show new Vero installation
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}

# Create Web3signer .env file
create_web3signer_env_file() {
    local service_dir="$1"
    local postgres_password="$2"
    local keystore_password="$3"
    local network="$4"
    local keystore_location="$5"
    local web3signer_port="$6"
    local web3signer_version="$7"
    
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    
    cat > "${service_dir}/.env" <<EOF
#=============================================================================
# WEB3SIGNER STACK CONFIGURATION  
#=============================================================================
# Docker network name for container communication
WEB3SIGNER_NETWORK=web3signer

# User mapping (auto-detected)
W3S_UID=${node_uid}
W3S_GID=${node_gid}

#=============================================================================
# API PORT BINDING
#=============================================================================
HOST_BIND_IP=127.0.0.1

#============================================================================
# NODE CONFIGURATION
#============================================================================
# Ethereum network (mainnet, sepolia, Hoodi, or custom URL)
ETH2_NETWORK=${network}

#=============================================================================
# SERVICE CONFIGURATION
#=============================================================================
# PostgreSQL
PG_DOCKER_TAG=16-bookworm
POSTGRES_PORT=5432
POSTGRES_PASSWORD=${postgres_password}

# Web3signer
WEB3SIGNER_VERSION=${web3signer_version}
WEB3SIGNER_PORT=${web3signer_port}
LOG_LEVEL=info
JAVA_OPTS=-Xmx4g

# Keystore configuration
KEYSTORE_PASSWORD=${keystore_password}
KEYSTORE_LOCATION=${keystore_location}

# Migration safety marker
MIGRATION_MARKER_FILE=/var/lib/web3signer/.migration_complete
EOF

    chmod 600 "${service_dir}/.env"
}

# Create Web3signer compose files
create_web3signer_compose_files() {
    local service_dir="$1"
    
    # Main compose file
    cat > "${service_dir}/compose.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  postgres:
    image: postgres:${PG_DOCKER_TAG}
    container_name: web3signer-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: web3signer
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - web3signer
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d web3signer"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    <<: *logging

  web3signer-init:
    image: consensys/web3signer:${WEB3SIGNER_VERSION}
    container_name: web3signer-init
    user: "0:0"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./web3signer_config:/config
      - web3signer_data:/var/lib/web3signer
      - ./docker-entrypoint.sh:/usr/local/bin/docker-entrypoint.sh:ro
    entrypoint: ["/bin/bash", "-c"]
    command: |
      "set -e
      echo 'Initializing Web3signer directories...'
      
      # Create migrations directory first
      mkdir -p /config/migrations
      
      # Extract migrations for Flyway
      cp -r /opt/web3signer/migrations/postgresql/* /config/migrations/ 2>/dev/null || true
      
      # Set up entrypoint
      if [ -f /usr/local/bin/docker-entrypoint.sh ]; then
        cp /usr/local/bin/docker-entrypoint.sh /var/lib/web3signer/docker-entrypoint.sh
        chmod +x /var/lib/web3signer/docker-entrypoint.sh
      fi
      
      # Set proper ownership
      chown -R ${W3S_UID}:${W3S_GID} /var/lib/web3signer
      chown -R ${W3S_UID}:${W3S_GID} /config
      
      echo 'Initialization complete'"
    networks:
      - web3signer

  flyway:
    image: flyway/flyway:10-alpine
    container_name: web3signer-flyway
    depends_on:
      web3signer-init:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy
    volumes:
      - ./web3signer_config/migrations:/flyway/sql:ro
      - web3signer_data:/var/lib/web3signer
    command: >
      -url=jdbc:postgresql://postgres:5432/web3signer
      -user=postgres
      -password=${POSTGRES_PASSWORD}
      -connectRetries=60
      -mixed=true
      migrate
    environment:
      - FLYWAY_PLACEHOLDERS_NETWORK=${ETH2_NETWORK}
    networks:
      - web3signer

  web3signer:
    image: consensys/web3signer:${WEB3SIGNER_VERSION}
    container_name: web3signer
    restart: unless-stopped
    user: "${W3S_UID}:${W3S_GID}"
    depends_on:
      flyway:
        condition: service_completed_successfully
    ports:
      - "${HOST_BIND_IP}:${WEB3SIGNER_PORT}:9000"
    volumes:
      - ./web3signer_config/keystores:/var/lib/web3signer/keystores:ro
      - web3signer_data:/var/lib/web3signer
      - /etc/localtime:/etc/localtime:ro
    environment:
      - JAVA_OPTS=${JAVA_OPTS}
      - ETH2_NETWORK=${ETH2_NETWORK}
    entrypoint: ["/var/lib/web3signer/docker-entrypoint.sh"]
    command: [
      "/opt/web3signer/bin/web3signer",
      "--http-listen-host=0.0.0.0",
      "--http-listen-port=9000",
      "--metrics-enabled",
      "--metrics-host-allowlist=*",
      "--http-host-allowlist=*",
      "--logging=${LOG_LEVEL}",
      "eth2",
      "--keystores-path=/var/lib/web3signer/keystores",
      "--keystores-passwords-path=/var/lib/web3signer/keystores",
      "--key-manager-api-enabled=true",
      "--slashing-protection-db-url=jdbc:postgresql://postgres:5432/web3signer",
      "--slashing-protection-db-username=postgres",
      "--slashing-protection-db-password=${POSTGRES_PASSWORD}",
      "--slashing-protection-pruning-enabled=true"
    ]
    networks:
      - web3signer
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/upcheck"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    labels:
      - metrics.scrape=true
      - metrics.path=/metrics
      - metrics.port=9000
      - metrics.instance=web3signer
      - metrics.network=${ETH2_NETWORK}
    <<: *logging

volumes:
  postgres_data:
    name: web3signer_postgres_data
  web3signer_data:
    name: web3signer_data

networks:
  web3signer:
    external: true
    name: ${WEB3SIGNER_NETWORK}-net
EOF

    # Docker entrypoint script
    create_web3signer_entrypoint_script "$service_dir"
}

# Create Web3signer entrypoint script
create_web3signer_entrypoint_script() {
    local service_dir="$1"
    
    cat > "${service_dir}/docker-entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Safety check for failed migrations
if [ -f /var/lib/web3signer/.migration_fatal_error ]; then
    echo "================================================================"
    echo "ERROR: Previous database migration failed!"
    echo "================================================================"
    echo "This safety marker prevents Web3signer from starting after a"
    echo "failed migration, which could lead to slashing."
    echo ""
    echo "To resolve:"
    echo "1. Check migration logs: docker compose logs flyway"
    echo "2. Fix the underlying database issue"
    echo "3. Remove marker: docker compose exec web3signer-init rm /var/lib/web3signer/.migration_fatal_error"
    echo "4. Retry: docker compose up -d"
    echo "================================================================"
    exit 1
fi

# Handle custom testnet configurations
if [[ "${ETH2_NETWORK}" =~ ^https?:// ]]; then
    echo "Custom testnet detected: ${ETH2_NETWORK}"
    
    # Parse GitHub URL components
    repo=$(awk -F'/tree/' '{print $1}' <<< "${ETH2_NETWORK}")
    branch=$(awk -F'/tree/' '{print $2}' <<< "${ETH2_NETWORK}" | cut -d'/' -f1)
    config_dir=$(awk -F'/tree/' '{print $2}' <<< "${ETH2_NETWORK}" | cut -d'/' -f2-)
    
    echo "Repository: ${repo}"
    echo "Branch: ${branch}"
    echo "Config directory: ${config_dir}"
    
    # Set up sparse checkout for custom network config
    if [ ! -d "/var/lib/web3signer/testnet/${config_dir}" ]; then
        echo "Downloading custom network configuration..."
        mkdir -p /var/lib/web3signer/testnet
        cd /var/lib/web3signer/testnet
        
        # Initialize git and set up sparse checkout
        git init --initial-branch="${branch}"
        git remote add origin "${repo}"
        git config core.sparseCheckout true
        echo "${config_dir}" > .git/info/sparse-checkout
        
        # Pull only the config directory
        git pull origin "${branch}"
        echo "Custom network configuration downloaded"
    else
        echo "Using existing custom network configuration"
    fi
    
    # Point to custom config file
    __network="--network=/var/lib/web3signer/testnet/${config_dir}/config.yaml"
else
    # Standard network (mainnet, Hoodi, sepolia, etc.)
    __network="--network=${ETH2_NETWORK}"
fi

echo "Starting Web3signer with network: ${ETH2_NETWORK}"

# Execute Web3signer with all original arguments plus network config
exec "$@" ${__network}
EOF

    chmod +x "${service_dir}/docker-entrypoint.sh"
}

# Create Web3signer helper scripts
create_web3signer_helper_scripts() {
    local service_dir="$1"
    
    # Import keys script
    cat > "${service_dir}/import-keys.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# Check for jq dependency
if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is not installed"
    echo "Please install jq: sudo apt-get install -y jq"
    exit 1
fi

# Load environment
source ~/.nodeboi/lib/ui.sh 2>/dev/null || true
source ~/web3signer/.env

# Verify password is set
if [[ -z "${KEYSTORE_PASSWORD}" ]]; then
    echo "ERROR: KEYSTORE_PASSWORD not set in .env file"
    echo "Please edit ~/web3signer/.env and set your keystore password"
    exit 1
fi

# Configuration
TARGET_DIR="$HOME/web3signer/web3signer_config/keystores"
BACKUP_DIR="$HOME/web3signer/keystores-backup-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED=$(printf '\033[0;31m')
GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[0;33m')
NC=$(printf '\033[0m')

echo "${GREEN}Web3signer Key Import${NC}"
echo "======================="

# Get keystore source directory
if [ -n "$1" ]; then
    # Use provided argument
    KEYSTORE_SOURCE="$1"
else
    # Prompt for directory
    echo
    echo "🔒 SECURITY RECOMMENDATION: Store keys on USB drive (not on this machine)"
    echo
    echo "Common keystore locations:"
    echo "  - 🔑 USB drive: /media/usb/validator_keys (MOST SECURE)"
    echo "  - 🔑 USB drive: /mnt/validator-usb/validator_keys"
    echo "  - ⚠️  Local: ~/validator_keys (NOT recommended - keys remain on machine)"
    echo "  - 📁 Custom path: /path/to/your/validator_keys"
    echo
    echo "You can start typing from your home directory: $HOME/"
    echo
    read -p "Enter path to validator keystore directory (USB recommended): " KEYSTORE_SOURCE
    
    # Expand tilde if present
    KEYSTORE_SOURCE="${KEYSTORE_SOURCE/#~/$HOME}"
fi

echo
echo "Source: $KEYSTORE_SOURCE"
echo "Target: $TARGET_DIR"

# Verify source exists
if [ ! -d "$KEYSTORE_SOURCE" ]; then
    echo "${RED}ERROR: Source directory not found: $KEYSTORE_SOURCE${NC}"
    echo
    echo "Please check the path and try again."
    echo "Make sure your USB drive is mounted or the directory exists."
    exit 1
fi

# Check for keystores in source
KEYSTORE_COUNT=$(find "$KEYSTORE_SOURCE" -name "keystore-*.json" 2>/dev/null | wc -l)
if [ "$KEYSTORE_COUNT" -eq 0 ]; then
    echo "${RED}ERROR: No keystore files found in $KEYSTORE_SOURCE${NC}"
    exit 1
fi

echo "Found $KEYSTORE_COUNT keystore files to process"

# Backup existing keys if any
if find "$TARGET_DIR" -name "keystore-*.json" 2>/dev/null | grep -q .; then
    echo "${YELLOW}Creating backup of existing keys...${NC}"
    mkdir -p "$BACKUP_DIR"
    cp -r "$TARGET_DIR"/* "$BACKUP_DIR/" 2>/dev/null || true
    echo "Backup created at: $BACKUP_DIR"
fi

# Check for duplicates
echo "Checking for duplicate validators..."
declare -A existing_pubkeys
for keystore in "$TARGET_DIR"/keystore-*.json; do
    [[ -f "$keystore" ]] || continue
    pubkey=$(jq -r '.pubkey' "$keystore" 2>/dev/null || echo "")
    [[ -n "$pubkey" ]] && existing_pubkeys["$pubkey"]=1
done

# Import keystores
imported=0
skipped=0
failed=0

for keystore in "$KEYSTORE_SOURCE"/keystore-*.json; do
    [[ -f "$keystore" ]] || continue
    
    # Validate keystore file
    if ! jq -e . "$keystore" >/dev/null 2>&1; then
        echo "${RED}Invalid JSON in: $(basename "$keystore")${NC}"
        failed=$((failed + 1))
        continue
    fi
    
    pubkey=$(jq -r '.pubkey' "$keystore" 2>/dev/null)
    if [[ -z "$pubkey" || "$pubkey" == "null" ]]; then
        echo "${RED}No pubkey in: $(basename "$keystore")${NC}"
        failed=$((failed + 1))
        continue
    fi
    
    # Check for duplicate
    if [[ -n "${existing_pubkeys[$pubkey]:-}" ]]; then
        echo "${YELLOW}Skipping duplicate: ${pubkey:0:10}...${NC}"
        skipped=$((skipped + 1))
        continue
    fi
    
    # Copy keystore
    cp "$keystore" "$TARGET_DIR/"
    
    # Create password file
    base=$(basename "$keystore" .json)
    echo -n "$KEYSTORE_PASSWORD" > "$TARGET_DIR/${base}.txt"
    
    echo "${GREEN}✓ Imported: ${pubkey:0:10}...${NC}"
    imported=$((imported + 1))
    existing_pubkeys["$pubkey"]=1
done

# Set proper permissions (critical!)
chmod 700 "$TARGET_DIR"
chmod 400 "$TARGET_DIR"/*

echo
echo "========================================="
echo "${GREEN}Import Summary:${NC}"
echo "  Imported: $imported"
echo "  Skipped:  $skipped"
echo "  Failed:   $failed"
echo "========================================="

echo
echo "${GREEN}Key import complete!${NC}"
EOF

    chmod +x "${service_dir}/import-keys.sh"
}

# Create Vero .env file
create_vero_env_file() {
    local service_dir="$1"
    local network="$2"
    local fee_recipient="$3"
    local graffiti="$4"
    shift 4
    local ethnodes=("$@")
    
    # Build beacon node URLs by detecting the actual beacon client
    local beacon_urls=""
    for ethnode in "${ethnodes[@]}"; do
        # Detect beacon client by checking Docker network containers
        local beacon_client=""
        
        # Check which beacon client is running (all ethnodes use nodeboi-net)
        if docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-grandine"; then
            beacon_client="grandine"
        elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lodestar"; then
            beacon_client="lodestar"
        elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lighthouse"; then
            beacon_client="lighthouse"
        elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-teku"; then
            beacon_client="teku"
        else
            # Fallback - assume lodestar for backward compatibility
            beacon_client="lodestar"
        fi
        
        # CRITICAL FIX: Always use port 5052 for internal container communication
        # All consensus clients expose their REST API on port 5052 internally
        if [[ -z "$beacon_urls" ]]; then
            beacon_urls="http://${ethnode}-${beacon_client}:5052"
        else
            beacon_urls="${beacon_urls},http://${ethnode}-${beacon_client}:5052"
        fi
    done
    
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    
    cat > "${service_dir}/.env" <<EOF
# =============================================================================
# VERO VALIDATOR CONFIGURATION
# =============================================================================
# Stack identification
VERO_NETWORK=vero

# User mapping (auto-detected)
VERO_UID=${node_uid}
VERO_GID=${node_gid}

# Network binding for metrics port
HOST_BIND_IP=127.0.0.1

# Ethereum network
ETH2_NETWORK=${network}

# =============================================================================
# CONNECTION CONFIGURATION
# =============================================================================
# Beacon node connections
BEACON_NODE_URLS=${beacon_urls}

# Web3signer connection
WEB3SIGNER_URL=http://web3signer:9000

# Consensus settings - how many beacon nodes must agree on attestation data
# Uncomment and set this value if you have multiple beacon nodes
#ATTESTATION_CONSENSUS_THRESHOLD=1

# =============================================================================
# VALIDATOR CONFIGURATION
# =============================================================================
# Validator settings
FEE_RECIPIENT=${fee_recipient}
GRAFFITI=${graffiti}

# =============================================================================
# SERVICE CONFIGURATION
# =============================================================================
# Vero
VERO_VERSION=v1.2.0
VERO_METRICS_PORT=9010
LOG_LEVEL=INFO
EOF

    chmod 600 "${service_dir}/.env"
}

# Create Vero compose file
create_vero_compose_file() {
    local service_dir="$1"
    shift 1
    local ethnodes=("$@")
    
    cat > "${service_dir}/compose.yml" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  vero:
    image: ghcr.io/serenita-org/vero:\${VERO_VERSION}
    container_name: vero
    restart: unless-stopped
    user: "\${VERO_UID}:\${VERO_GID}"
    environment:
      - LOG_LEVEL=\${LOG_LEVEL}
    ports:
      - "\${HOST_BIND_IP}:\${VERO_METRICS_PORT}:\${VERO_METRICS_PORT}"
    command: [
      "--network=\${ETH2_NETWORK}",
      "--beacon-node-urls=\${BEACON_NODE_URLS}",
      "--remote-signer-url=\${WEB3SIGNER_URL}",
      "--fee-recipient=\${FEE_RECIPIENT}",
      "--graffiti=\${GRAFFITI}",
      "--metrics-address=0.0.0.0",
      "--metrics-port=\${VERO_METRICS_PORT}",
      "--log-level=\${LOG_LEVEL}"
    ]
    networks:
      - nodeboi
      - web3signer
    <<: *logging

networks:
  nodeboi:
    external: true
    name: nodeboi-net
  web3signer:
    external: true
    name: web3signer-net
EOF
}

# Conservative Web3signer update with warnings
update_web3signer() {
    echo -e "${RED}${BOLD}⚠️  WEB3SIGNER UPDATE WARNING ⚠️${NC}"
    echo "=================================="
    echo
    echo -e "${YELLOW}Web3signer updates should ONLY be performed when:${NC}"
    echo -e "${UI_MUTED}  • Critical security vulnerability patches${NC}"
    echo -e "${UI_MUTED}  • Major bug fixes affecting validator operations${NC}"  
    echo -e "${UI_MUTED}  • Official upgrade recommendations from Consensys${NC}"
    echo
    echo -e "${RED}RISKS of updating Web3signer:${NC}"
    echo -e "${UI_MUTED}  • Potential validator key access issues${NC}"
    echo -e "${UI_MUTED}  • Database migration failures${NC}"
    echo -e "${UI_MUTED}  • Slashing protection database corruption${NC}"
    echo -e "${UI_MUTED}  • Extended validator downtime${NC}"
    echo
    
    # Get current version
    local current_version=$(grep "WEB3SIGNER_VERSION=" ~/web3signer/.env | cut -d'=' -f2)
    echo -e "${YELLOW}Current version: ${current_version}${NC}"
    echo
    
    # Triple confirmation required
    if ! fancy_confirm "I understand the risks and have a critical reason to update" "n"; then
        echo -e "${GREEN}Update cancelled - keeping current version${NC}"
        press_enter
        return 0
    fi
    
    if ! fancy_confirm "I have backed up my slashing protection database" "n"; then
        echo -e "${RED}Please backup slashing protection first${NC}"
        echo -e "${UI_MUTED}You can backup with: docker compose exec postgres pg_dump -U postgres web3signer > backup.sql${NC}"
        press_enter
        return 1
    fi
    
    if ! fancy_confirm "FINAL CONFIRMATION: Proceed with Web3signer update?" "n"; then
        echo -e "${GREEN}Update cancelled${NC}"
        press_enter
        return 0
    fi
    
    # Get new version
    local new_version
    new_version=$(fancy_text_input "Web3signer Update" \
        "Enter new version (e.g., 25.7.0):" \
        "" \
        "")
    
    if [[ -z "$new_version" ]]; then
        echo -e "${RED}Version cannot be empty${NC}"
        press_enter
        return 1
    fi
    
    # Update version in .env
    sed -i "s/WEB3SIGNER_VERSION=.*/WEB3SIGNER_VERSION=${new_version}/" ~/web3signer/.env
    
    # Stop, pull, and restart
    echo -e "${UI_MUTED}Stopping Web3signer...${NC}"
    cd ~/web3signer && docker compose stop web3signer
    
    echo -e "${UI_MUTED}Pulling new version...${NC}"
    cd ~/web3signer && docker compose pull web3signer
    
    echo -e "${UI_MUTED}Starting Web3signer with new version...${NC}"
    cd ~/web3signer && docker compose up -d web3signer
    
    # Wait a moment and check health
    sleep 5
    local web3signer_port=$(grep "WEB3SIGNER_PORT=" ~/web3signer/.env | cut -d'=' -f2)
    if curl -s "http://localhost:${web3signer_port}/upcheck" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Web3signer updated successfully to ${new_version}${NC}"
        echo -e "${UI_MUTED}Check logs to verify Web3signer is running correctly:${NC}"
        echo -e "${UI_MUTED}Run: cd ~/web3signer && docker compose logs web3signer${NC}"
    else
        echo -e "${RED}⚠️  Web3signer may have issues - check logs${NC}"
        echo -e "${UI_MUTED}Run: cd ~/web3signer && docker compose logs web3signer${NC}"
    fi
    
    # Refresh dashboard cache to show updated status
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}

# Remove Vero installation
remove_vero() {
    local service_dir="$HOME/vero"
    
    echo -e "${CYAN}${BOLD}Remove Vero${NC}"
    echo "============"
    echo
    echo -e "${YELLOW}⚠️  WARNING: This will completely remove Vero and all its data${NC}"
    echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
    echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
    echo -e "${UI_MUTED}• This action cannot be undone${NC}"
    echo
    
    if [[ ! -d "$service_dir" ]]; then
        echo -e "${RED}Vero is not installed${NC}"
        press_enter
        return 1
    fi
    
    if ! fancy_confirm "Are you sure you want to remove Vero?" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    if ! fancy_confirm "FINAL CONFIRMATION: This will delete all Vero data" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    echo -e "${UI_MUTED}Stopping and removing Vero containers...${NC}"
    if cd "$service_dir" 2>/dev/null; then
        docker compose down -v 2>/dev/null || true
    fi
    
    echo -e "${UI_MUTED}Removing Vero directory...${NC}"
    rm -rf "$service_dir"
    
    echo -e "${GREEN}✓ Vero has been completely removed${NC}"
    
    # Update service connections after Vero removal (DICKS)
    if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Updating service connections...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" 
        docker_intelligent_connecting_kontainer_system --auto
    fi
    
    # Refresh dashboard cache to show updated status
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}

# Remove Web3signer installation (with extra confirmation and key deletion)
remove_web3signer() {
    local service_dir="$HOME/web3signer"
    
    echo -e "${CYAN}${BOLD}Remove Web3signer${NC}"
    echo "=================="
    echo
    echo -e "${RED}⚠️  CRITICAL WARNING: This will completely destroy Web3signer and ALL validator keys${NC}"
    echo -e "${UI_MUTED}• All validator keystores will be permanently deleted${NC}"
    echo -e "${UI_MUTED}• The slashing protection database will be destroyed${NC}"
    echo -e "${UI_MUTED}• This action is IRREVERSIBLE${NC}"
    echo -e "${UI_MUTED}• You will lose access to all your validators${NC}"
    echo
    echo -e "${YELLOW}Only proceed if you have backed up your keys elsewhere!${NC}"
    echo
    
    if [[ ! -d "$service_dir" ]]; then
        echo -e "${RED}Web3signer is not installed${NC}"
        press_enter
        return 1
    fi
    
    # Password verification first
    echo -e "${YELLOW}Please enter your password to confirm identity:${NC}"
    sudo -v
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Password verification failed${NC}"
        press_enter
        return 1
    fi
    
    # Multiple confirmation steps
    if ! fancy_confirm "I understand this will DELETE ALL VALIDATOR KEYS" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    if ! fancy_confirm "I have backed up my keys and slashing protection database" "n"; then
        echo -e "${RED}Please backup your data first${NC}"
        echo -e "${UI_MUTED}Backup keys: docker compose exec web3signer tar czf /tmp/keystores.tar.gz /app/keystores${NC}"
        echo -e "${UI_MUTED}Backup database: docker compose exec postgres pg_dump -U postgres web3signer > backup.sql${NC}"
        press_enter
        return 1
    fi
    
    if ! fancy_confirm "FINAL CONFIRMATION: Permanently delete Web3signer and ALL keys?" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    echo -e "${UI_MUTED}Stopping and removing Web3signer containers...${NC}"
    if cd "$service_dir" 2>/dev/null; then
        # Stop and remove all services with volumes
        docker compose down -v --remove-orphans 2>/dev/null || true
    fi
    
    # Force remove any remaining containers
    echo -e "${UI_MUTED}Cleaning up any remaining containers...${NC}"
    docker ps -a --filter "name=web3signer" --format "{{.ID}}" | while read id; do [[ -n "$id" ]] && echo -e "${UI_MUTED}$id${NC}" && docker rm -f "$id" >/dev/null 2>&1; done
    docker ps -a --filter "name=web3signer-postgres" --format "{{.ID}}" | while read id; do [[ -n "$id" ]] && echo -e "${UI_MUTED}$id${NC}" && docker rm -f "$id" >/dev/null 2>&1; done
    docker ps -a --filter "name=web3signer-flyway" --format "{{.ID}}" | while read id; do [[ -n "$id" ]] && echo -e "${UI_MUTED}$id${NC}" && docker rm -f "$id" >/dev/null 2>&1; done
    docker ps -a --filter "name=web3signer-init" --format "{{.ID}}" | while read id; do [[ -n "$id" ]] && echo -e "${UI_MUTED}$id${NC}" && docker rm -f "$id" >/dev/null 2>&1; done
    
    echo -e "${UI_MUTED}Removing Docker networks...${NC}"
    if docker network rm web3signer-net 2>/dev/null; then
        echo -e "${UI_MUTED}web3signer-net${NC}"
    fi
    
    # Remove all Web3signer-related volumes
    echo -e "${UI_MUTED}Removing all Web3signer volumes...${NC}"
    docker volume ls --filter "name=web3signer" --format "{{.Name}}" | while read vol; do [[ -n "$vol" ]] && echo -e "${UI_MUTED}$vol${NC}" && docker volume rm -f "$vol" >/dev/null 2>&1; done
    
    echo -e "${UI_MUTED}Removing Web3signer directory and ALL keystores...${NC}"
    # Try regular removal first, then use sudo if needed
    if ! rm -rf "$service_dir" 2>/dev/null; then
        echo -e "${YELLOW}Some files require admin permissions to remove${NC}"
        echo -e "${UI_MUTED}You may be prompted for your password...${NC}"
        sudo rm -rf "$service_dir"
    fi
    
    # Remove any docker images to save space
    echo -e "${UI_MUTED}Removing Docker images...${NC}"
    docker image rm consensys/web3signer:latest 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done 2>/dev/null || true
    docker image rm postgres:15 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done 2>/dev/null || true
    docker image rm flyway/flyway:8 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done 2>/dev/null || true
    
    # Clean up any dangling resources
    echo -e "${UI_MUTED}Cleaning up dangling Docker resources...${NC}"
    docker system prune -f --volumes 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done
    
    echo
    echo -e "${GREEN}✓ Web3signer and ALL validator keys have been permanently deleted${NC}"
    echo -e "${YELLOW}Your validator keys are now GONE from this machine${NC}"
    echo -e "${UI_MUTED}If you backed them up, you can restore them by reinstalling Web3signer${NC}"
    
    # Force refresh dashboard to remove the web3signer service
    echo -e "${UI_MUTED}Updating dashboard...${NC}"
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        echo -e "${GREEN}✓ Dashboard updated${NC}"
    fi
    echo
    
    # Update service connections after Web3signer removal (DICKS)
    if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Updating service connections...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" 
        docker_intelligent_connecting_kontainer_system --auto
    fi
    
    # Refresh dashboard cache to show updated status
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}