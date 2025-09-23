#!/bin/bash
# lib/validator-manager.sh - Validator service installation and management

# Source dependencies
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh"
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"
[[ -f "${NODEBOI_LIB}/templates.sh" ]] && source "${NODEBOI_LIB}/templates.sh"

INSTALL_DIR="$HOME/.nodeboi"

# Clean up validator network if no validator services are using it
cleanup_validator_network() {
    local validator_services=()
    
    # Check for installed validator services (directories with .env)
    [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]] && validator_services+=("vero")
    [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]] && validator_services+=("teku-validator")  
    [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/.env" ]] && validator_services+=("web3signer")
    
    # Also check for running validator containers (in case directories were removed but containers still exist)
    local running_validators=$(docker ps --format "{{.Names}}" | grep -E "^(vero|teku-validator|web3signer)" || true)
    
    # If no validator services exist and no validator containers running, remove validator-net
    if [[ ${#validator_services[@]} -eq 0 && -z "$running_validators" ]]; then
        if docker network ls --format "{{.Name}}" | grep -q "^validator-net$"; then
            echo -e "${UI_MUTED}Removing orphaned validator-net...${NC}"
            docker network rm validator-net 2>/dev/null || true
        fi
    fi
}

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
            local keystore_count=$(find "$keystore_location" -maxdepth 1 -name "keystore-*.json" 2>/dev/null | wc -l)
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
                            manage_service "restart" "web3signer"
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
    
    # Check for existing installation - look for actual web3signer files
    if [[ -d "$service_dir" ]] && [[ -f "$service_dir/docker-compose.yml" || -f "$service_dir/.env" ]]; then
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
    
    # Streamlined version selection with default
    local default_version=$(get_default_version "web3signer" 2>/dev/null)
    [[ -z "$default_version" ]] && default_version="25.9.0"
    
    local web3signer_version
    web3signer_version=$(fancy_text_input "Web3signer Version" \
        "Enter Web3signer version (e.g., 25.9.0):" \
        "$default_version")
    
    if [[ -z "$web3signer_version" ]]; then
        web3signer_version="$default_version"
        echo -e "${UI_MUTED}✓ Using default Web3signer version: ${web3signer_version}${NC}"
    else
        echo -e "${UI_MUTED}✓ Using Web3signer version: ${web3signer_version}${NC}"
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
    
    # Generate configuration using centralized templates
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    generate_web3signer_env "$staging_dir" "$postgres_password" "$keystore_password" "$selected_network" "$keystore_location" "$web3signer_port" "$web3signer_version" "$node_uid" "$node_gid"
    generate_web3signer_compose "$staging_dir"
    
    # Generate helper scripts (not yet centralized)
    create_web3signer_entrypoint_script "$staging_dir"
    create_web3signer_helper_scripts "$staging_dir"
    
    echo -e "${UI_MUTED}✓ Configuration files created${NC}"
    
    # Prepare for atomic installation (no containers started yet)
    echo -e "${UI_MUTED}Preparing Web3signer configuration...${NC}"
    cd "$staging_dir"
    
    echo -e "${UI_MUTED}Downloading Docker images (this may take a few minutes)...${NC}"
    if docker compose -p web3signer pull 2>&1 | while read line; do echo -e "${UI_MUTED}  $line${NC}"; done; then
        echo -e "${UI_MUTED}✓ Images downloaded successfully${NC}"
    else
        echo "✗ Failed to download Docker images"
        return 1
    fi
    
    echo -e "${UI_MUTED}✓ Configuration prepared for atomic installation${NC}"
    
    # Test if compose file is valid
    if ! docker compose -p web3signer config >/dev/null 2>&1; then
        echo "✗ Docker compose file is invalid!" >&2
        docker compose -p web3signer config 2>&1 | sed 's/^/  Error: /'
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
    
    # Skip starting containers here - will start after atomic move
    
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
    docker compose -p web3signer down 2>/dev/null || true
    
    # Clean up any conflicting containers by name
    echo -e "${UI_MUTED}Cleaning up any existing containers...${NC}"
    docker ps -aq --filter "name=web3signer" | while read id; do 
        [[ -n "$id" ]] && echo -e "${UI_MUTED}Removing container $id${NC}" && docker rm -f "$id" >/dev/null 2>&1
    done
    
    # Mark installation as successful
    installation_success=true
    
    # Start containers via ULCS (after atomic move)
    echo -e "${UI_MUTED}Starting Web3signer containers via ULCS...${NC}"
    if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
        source "${NODEBOI_LIB}/ulcs.sh"
        start_service_universal "web3signer" || {
            echo -e "${YELLOW}Warning: ULCS start failed, using direct docker compose${NC}"
            docker compose -p web3signer up -d 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done
        }
    else
        echo -e "${UI_MUTED}ULCS not available, using direct docker compose${NC}"
        docker compose -p web3signer up -d 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done
    fi
    
    # NOW start containers in final location (after atomic move)
    echo -e "${UI_MUTED}Starting Web3signer services...${NC}"
    
    # Start containers with proper error handling
    if docker compose -p web3signer up -d 2>&1 | while read line; do echo -e "${UI_MUTED}$line${NC}"; done; then
        echo "✓ Web3signer services started successfully"
        
        # Basic health check (non-fatal) - extended wait for key loading
        echo "Checking service health..."
        echo -e "${UI_MUTED}Waiting for Web3signer to fully initialize and load keys...${NC}"
        sleep 10
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
    
    # Refresh monitoring dashboards and Prometheus configuration
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh" && refresh_monitoring_dashboards
    fi
    
    # Disable error traps - installation completed successfully
    set +eE
    set +o pipefail
    trap - ERR INT TERM
    
    # Defensive cleanup: Remove staging directory if it somehow still exists
    # (it shouldn't after mv, but this ensures complete cleanup)
    [[ -d "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
    
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
    
    # Set flag to return to main menu after ULCS operation
    RETURN_TO_MAIN_MENU=true
}

# Install Vero (singleton only) - Atomic Installation
install_vero() {
    
    # CRITICAL SAFETY CHECK: Prevent multiple validators
    if ! check_validator_conflict "vero"; then
        echo "ERROR: Cannot install Vero - validator conflict detected"
        return 1
    fi
    
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
    
    # Singleton check - look for actual Vero files
    if [[ -d "$service_dir" ]] && [[ -f "$service_dir/docker-compose.yml" || -f "$service_dir/.env" ]]; then
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
    
    # Show header only after all checks pass
    echo -e "${CYAN}${BOLD}Install Vero Validator${NC}"
    echo "======================="
    echo
    
    # Auto-discover available ethnode networks
    local available_ethnodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            
            # Check if isolated ethnode network exists
            local ethnode_net="${node_name}-net"
            if docker network ls --format "{{.Name}}" | grep -q "^${ethnode_net}$"; then
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
    
    # Ask which beacon nodes to connect to using fancy menu
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
        # Create menu options with individual nodes + "All beacon nodes"
        local menu_options=()
        for ethnode in "${available_ethnodes[@]}"; do
            menu_options+=("$ethnode")
        done
        menu_options+=("All beacon nodes")
        
        # Ensure UI functions are available
        [[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
        if ! declare -f fancy_select_menu >/dev/null 2>&1; then
            echo "ERROR: fancy_select_menu function not available"
            return 1
        fi
        
        # Show fancy menu for selection
        local selection
        if selection=$(fancy_select_menu "Beacon Node Selection" "${menu_options[@]}"); then
            local selected_option="${menu_options[$selection]}"
            
            if [[ "$selected_option" == "All beacon nodes" ]]; then
                selected_ethnodes=("${available_ethnodes[@]}")
                echo -e "${GREEN}Selected all available beacon nodes: ${selected_ethnodes[*]}${NC}"
            else
                selected_ethnodes=("$selected_option")
                echo -e "${GREEN}Selected beacon node: $selected_option${NC}"
            fi
        else
            echo -e "${UI_MUTED}No selection made${NC}"
            return 1
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
    
    # Build beacon URLs by detecting beacon clients
    local beacon_urls=""
    local web3signer_port="7500"
    for ethnode in "${selected_ethnodes[@]}"; do
        local ethnode_net="${ethnode}-net"
        local beacon_client=""
        
        # Detect which beacon client is running
        if docker network inspect "${ethnode_net}" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-grandine"; then
            beacon_client="grandine"
        elif docker network inspect "${ethnode_net}" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lodestar"; then
            beacon_client="lodestar"
        elif docker network inspect "${ethnode_net}" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lighthouse"; then
            beacon_client="lighthouse"
        elif docker network inspect "${ethnode_net}" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-teku"; then
            beacon_client="teku"
        else
            beacon_client="lodestar"  # Fallback
        fi
        
        # Build beacon URL
        if [[ -n "$beacon_urls" ]]; then
            beacon_urls="${beacon_urls},http://${ethnode}-${beacon_client}:5052"
        else
            beacon_urls="http://${ethnode}-${beacon_client}:5052"
        fi
    done
    
    # Generate configuration using centralized templates
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    generate_vero_env "$service_dir" "$node_uid" "$node_gid" "$network" "$beacon_urls" "$web3signer_port" "$fee_recipient" "$graffiti"
    generate_vero_compose "$service_dir" "${selected_ethnodes[@]}"
    
    echo -e "${GREEN}✓ Vero installed successfully!${NC}"
    echo
    
    # Ask user if they want to start the validator now
    local launch_choice=""
    launch_choice=$(fancy_text_input "Launch Validator" \
        "Do you want to launch Vero validator right now? (y/n):" \
        "" \
        "")
    
    if [[ "$launch_choice" == "y" || "$launch_choice" == "" ]]; then
        echo -e "${UI_MUTED}Starting Vero validator...${NC}"
        
        # Ensure validator-net network exists
        if ! docker network inspect validator-net >/dev/null 2>&1; then
            docker network create validator-net >/dev/null 2>&1
        fi
        
        # Start Vero (safety warning handled by manage_service)
        if manage_service "up" "vero"; then
            echo -e "${GREEN}✓ Vero started successfully!${NC}"
        else
            echo -e "${YELLOW}⚠ Vero created but failed to start - you can start it manually later${NC}"
        fi
    else
        echo -e "${UI_MUTED}Vero validator ready to launch manually from manage menu${NC}"
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
    
    # Defensive cleanup: Remove staging directory if it somehow still exists
    # (it shouldn't after the installation, but this ensures complete cleanup)
    [[ -d "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
    
    # Refresh monitoring dashboards and Prometheus configuration
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh" && refresh_monitoring_dashboards
    fi
    
    # Refresh dashboard cache to show new Vero installation
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}

# Legacy functions removed - using centralized templates directly

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
# source ~/.nodeboi/lib/ui.sh 2>/dev/null || true
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
KEYSTORE_COUNT=$(find "$KEYSTORE_SOURCE" -maxdepth 1 -name "keystore-*.json" 2>/dev/null | wc -l)
if [ "$KEYSTORE_COUNT" -eq 0 ]; then
    echo "${RED}ERROR: No keystore files found in $KEYSTORE_SOURCE${NC}"
    exit 1
fi

echo "Found $KEYSTORE_COUNT keystore files to process"

# Backup existing keys if any
if find "$TARGET_DIR" -maxdepth 1 -name "keystore-*.json" 2>/dev/null | grep -q .; then
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

# Legacy Vero functions removed - using centralized templates directly

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
    local default_version=$(get_latest_version "web3signer" 2>/dev/null)
    [[ -z "$default_version" ]] && default_version="25.9.0"
    
    new_version=$(fancy_text_input "Web3signer Update" \
        "Enter new version (e.g., 25.7.0):" \
        "$default_version")
    
    if [[ -z "$new_version" ]]; then
        echo -e "${RED}Version cannot be empty${NC}"
        press_enter
        return 1
    fi
    
    # Update version in .env
    sed -i "s/WEB3SIGNER_VERSION=.*/WEB3SIGNER_VERSION=${new_version}/" ~/web3signer/.env
    
    # Stop, pull, and restart
    echo -e "${UI_MUTED}Stopping Web3signer...${NC}"
    manage_service "down" "web3signer"
    
    echo -e "${UI_MUTED}Pulling new version...${NC}"
    cd ~/web3signer && docker compose pull web3signer
    
    echo -e "${UI_MUTED}Starting Web3signer with new version...${NC}"
    manage_service "up" "web3signer"
    
    # Wait a moment and check health
    sleep 5
    if curl -s "http://localhost:7500/upcheck" >/dev/null 2>&1; then
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
    
    echo -e "${UI_MUTED}Stopping and removing Vero with full cleanup...${NC}"
    
    # Source our new lifecycle system
    [[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
    
    # Use new lifecycle system if available, fallback to old method
    if declare -f remove_service >/dev/null 2>&1; then
        # New lifecycle system with cleanup hooks
        if remove_service "vero"; then
            # Still need to remove directory and containers (lifecycle handles monitoring cleanup)
            manage_service "down" "vero" 2>/dev/null || true
            rm -rf "$service_dir"
            echo -e "${GREEN}✓ Vero removed successfully with full cleanup${NC}"
        else
            echo -e "${RED}✗ Removal failed - some cleanup may be incomplete${NC}"
        fi
    else
        # Fallback to old method if lifecycle system not available
        echo -e "${YELLOW}⚠ Using fallback removal (cleanup hooks not available)${NC}"
        if [[ -d "$service_dir" ]]; then
            manage_service "down" "vero"
        fi
        rm -rf "$service_dir"
        
        # Clean up orphaned validator network if no validator services remain
        cleanup_validator_network
        
        # Old cleanup methods (less reliable)
        if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
            echo -e "${UI_MUTED}Updating service connections...${NC}"
            source "${NODEBOI_LIB}/monitoring.sh" 
            manage_service_networks "sync" "silent"
        fi
        
        if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
            source "${NODEBOI_LIB}/grafana-dashboard-management.sh" && refresh_monitoring_dashboards
        fi
        
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        
        echo -e "${GREEN}✓ Vero removed (basic cleanup)${NC}"
    fi
    
    press_enter
}

# Remove Teku validator installation  
remove_teku_validator() {
    local service_dir="$HOME/teku-validator"
    
    echo -e "${CYAN}${BOLD}Remove Teku Validator${NC}"
    echo "==================="
    echo
    echo -e "${YELLOW}⚠️  WARNING: This will completely remove Teku validator and all its data${NC}"
    echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
    echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
    echo -e "${UI_MUTED}• This action cannot be undone${NC}"
    echo
    
    if [[ ! -d "$service_dir" ]]; then
        echo -e "${RED}Teku validator is not installed${NC}"
        press_enter
        return 1
    fi
    
    if ! fancy_confirm "Are you sure you want to remove Teku validator?" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    if ! fancy_confirm "FINAL CONFIRMATION: This will delete all Teku validator data" "n"; then
        echo -e "${GREEN}Removal cancelled${NC}"
        press_enter
        return 0
    fi
    
    echo -e "${UI_MUTED}Stopping and removing Teku validator with full cleanup...${NC}"
    
    # Source our new lifecycle system
    [[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
    
    # Use new lifecycle system if available, fallback to old method
    if declare -f remove_service >/dev/null 2>&1; then
        # New lifecycle system with cleanup hooks
        if remove_service "teku-validator"; then
            # Still need to remove directory and containers (lifecycle handles monitoring cleanup)
            manage_service "down" "teku-validator" 2>/dev/null || true
            rm -rf "$service_dir"
            echo -e "${GREEN}✓ Teku validator removed successfully with full cleanup${NC}"
        else
            echo -e "${RED}✗ Removal failed - some cleanup may be incomplete${NC}"
        fi
    else
        # Fallback to old method if lifecycle system not available
        echo -e "${YELLOW}⚠ Using fallback removal (cleanup hooks not available)${NC}"
        if [[ -d "$service_dir" ]]; then
            manage_service "down" "teku-validator"
        fi
        rm -rf "$service_dir"
        
        # Clean up orphaned validator network if no validator services remain
        cleanup_validator_network
        
        # Old cleanup methods (less reliable)
        if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
            echo -e "${UI_MUTED}Updating service connections...${NC}"
            source "${NODEBOI_LIB}/monitoring.sh" 
            manage_service_networks "sync" "silent"
        fi
        
        if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
            source "${NODEBOI_LIB}/grafana-dashboard-management.sh" && refresh_monitoring_dashboards
        fi
        
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        
        echo -e "${GREEN}✓ Teku validator removed (basic cleanup)${NC}"
    fi
    
    press_enter
}

# Safety check: Detect if another validator is already running
check_validator_conflict() {
    local new_validator="$1"
    
    # Check for running validator containers
    local running_validators=()
    
    if docker ps --format "{{.Names}}" | grep -q "^vero$" && [[ "$new_validator" != "vero" ]]; then
        running_validators+=("vero")
    fi
    
    if docker ps --format "{{.Names}}" | grep -q "^teku-validator$" && [[ "$new_validator" != "teku-validator" ]]; then
        running_validators+=("teku-validator")
    fi
    
    if [[ ${#running_validators[@]} -gt 0 ]]; then
        echo "CRITICAL SAFETY ERROR: Another validator is already running: ${running_validators[*]}"
        echo "Running multiple validators simultaneously will result in SLASHING and LOSS of staked ETH!"
        echo "Stop the running validator before installing $new_validator"
        return 1
    fi
    
    # Check for existing installations (directories)
    local existing_installations=()
    
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" && "$new_validator" != "vero" ]]; then
        existing_installations+=("vero")
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" && "$new_validator" != "teku-validator" ]]; then
        existing_installations+=("teku-validator")
    fi
    
    if [[ ${#existing_installations[@]} -gt 0 ]]; then
        echo "WARNING: Another validator is already installed: ${existing_installations[*]}"
        echo "Only one validator should be used at a time to prevent slashing risk"
        echo "Remove the existing validator before installing $new_validator"
        return 1
    fi
    
    return 0
}

# Core Vero installation function for ULCS integration (no UI)
install_vero_core() {
    local service_dir="$1"
    local params="$2"
    
    
    # CRITICAL SAFETY CHECK: Prevent multiple validators
    if ! check_validator_conflict "vero"; then
        echo "ERROR: Cannot install Vero - validator conflict detected"
        return 1
    fi
    
    # Parse parameters (passed as JSON or simple format from ULCS)
    local network="hoodi"  # Default network
    local fee_recipient="0x0000000000000000000000000000000000000000"  # Default fee recipient
    local graffiti="vero"  # Default graffiti
    local selected_ethnodes=("ethnode1")  # Default to ethnode1
    
    # TODO: Parse actual parameters from ULCS when we implement parameter passing
    
    # Get network from Web3signer (same logic as working function)
    if [[ -f "$HOME/web3signer/.env" ]]; then
        network=$(grep "ETH2_NETWORK=" "$HOME/web3signer/.env" | cut -d'=' -f2)
    fi
    
    
    # Build beacon URLs by detecting beacon clients
    local beacon_urls=""
    local web3signer_port="7500"
    for ethnode in "${selected_ethnodes[@]}"; do
        local ethnode_net="${ethnode}-net"
        
        # Build beacon URL (using direct ethnode service name for new installations)
        if [[ -n "$beacon_urls" ]]; then
            beacon_urls="${beacon_urls},http://${ethnode}:5052"
        else
            beacon_urls="http://${ethnode}:5052"
        fi
    done
    
    # Generate configuration using centralized templates
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    generate_vero_env "$service_dir" "$node_uid" "$node_gid" "$network" "$beacon_urls" "$web3signer_port" "$fee_recipient" "$graffiti"
    generate_vero_compose "$service_dir" "${selected_ethnodes[@]}"
    
    return 0
}

# Core Teku validator installation function for ULCS integration (no UI)
install_teku_validator_core() {
    local service_dir="$1"
    local params="$2"
    
    
    # CRITICAL SAFETY CHECK: Prevent multiple validators
    if ! check_validator_conflict "teku-validator"; then
        echo "ERROR: Cannot install Teku validator - validator conflict detected"
        return 1
    fi
    
    # Parse parameters (default values for now)
    local network="hoodi"
    local fee_recipient="0x0000000000000000000000000000000000000000"
    local graffiti="teku-validator"
    local selected_ethnode="ethnode1"
    local selected_beacon_url="http://ethnode1-teku:5052"
    
    # Get current user UID/GID
    local current_uid=$(id -u)
    local current_gid=$(id -g)
    
    # Web3signer uses hardcoded port 7500 (singleton service)
    local web3signer_port="7500"
    
    # Generate templates using centralized functions
    generate_teku_validator_env "$service_dir" "$current_uid" "$current_gid" "$network" "$selected_beacon_url" "$web3signer_port" "$fee_recipient" "$graffiti" "$selected_ethnode"
    generate_teku_validator_compose "$service_dir" "$selected_ethnode"

    # Create data directory
    mkdir -p "$service_dir/data"
    
    return 0
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
    echo -e "${RED}🔒 MAINNET SECURITY WARNING:${NC}"
    echo -e "${YELLOW}• File deletion does NOT guarantee complete key removal${NC}"
    echo -e "${YELLOW}• Keys may remain in filesystem slack space, swap files, or memory dumps${NC}"
    echo -e "${YELLOW}• For maximum security on mainnet: physically destroy the SSD/drive${NC}"
    echo -e "${YELLOW}• Consider this machine permanently compromised for high-value keys${NC}"
    echo
    echo -e "${CYAN}For testnet: software deletion is sufficient${NC}"
    echo -e "${CYAN}For mainnet: physical drive destruction is recommended${NC}"
    echo
    echo -e "${YELLOW}Only proceed if you have the original mnemonic/seed phrase to regenerate these keys if necessary${NC}"
    echo -e "${YELLOW}AND you understand that for mainnet you should physically destroy this SSD afterward${NC}"
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
    
    # Use our new lifecycle system for cleanup
    echo -e "${UI_MUTED}Running comprehensive cleanup with lifecycle system...${NC}"
    
    # Source our new lifecycle system
    [[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
    
    # Use new lifecycle system if available for post-removal cleanup
    if declare -f cleanup_web3signer >/dev/null 2>&1; then
        # New lifecycle system cleanup hooks
        cleanup_web3signer
        echo -e "${GREEN}✓ Comprehensive cleanup completed${NC}"
    else
        # Fallback to old method if lifecycle system not available
        echo -e "${YELLOW}⚠ Using fallback cleanup (lifecycle hooks not available)${NC}"
        
        # Force refresh dashboard to remove the web3signer service
        echo -e "${UI_MUTED}Updating dashboard...${NC}"
        if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
            source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
            echo -e "${GREEN}✓ Dashboard updated${NC}"
        fi
        
        # Update service connections after Web3signer removal (DICKS)
        if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
            echo -e "${UI_MUTED}Updating service connections...${NC}"
            source "${NODEBOI_LIB}/monitoring.sh" 
            manage_service_networks "sync" "silent"
        fi
        
        # Refresh dashboard cache to show updated status
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    fi
    
    press_enter
}

# Select beacon node for Teku validator using fancy menu with connectivity testing
select_beacon_node_for_teku() {
    # Ensure UI functions are available
    [[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
    
    local current_url="${1:-}"  # Optional current URL for "Change" mode
    
    # Auto-discover available consensus clients for beacon node connection
    local available_beacon_nodes=()
    local beacon_node_descriptions=()
    
    echo -e "${UI_MUTED}Testing beacon node connectivity...${NC}" >&2
    
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            
            # Check if it has a consensus client
            if (cd "$dir" && docker compose config --services 2>/dev/null | grep -q "consensus"); then
                # Detect consensus client type
                local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)
                local beacon_client="lodestar"  # default
                local client_display=""
                
                if [[ "$compose_file" == *"grandine"* ]]; then
                    beacon_client="grandine"
                    client_display="Grandine"
                elif [[ "$compose_file" == *"lighthouse"* ]]; then
                    beacon_client="lighthouse"
                    client_display="Lighthouse"
                elif [[ "$compose_file" == *"teku"* ]]; then
                    beacon_client="teku"
                    client_display="Teku"
                elif [[ "$compose_file" == *"lodestar"* ]]; then
                    beacon_client="lodestar"
                    client_display="Lodestar"
                fi
                
                # Check if beacon client container is actually running
                local container_name="${node_name}-${beacon_client}"
                local beacon_url="http://$container_name:5052"
                local status_indicator=""
                local status_text=""
                
                if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
                    status_indicator="✗"
                    status_text="not running"
                    echo -e "${UI_MUTED}  ${node_name} (${client_display}): container not running${NC}" >&2
                else
                    # Check if currently reachable from validator
                    local reachable=false
                    if [[ -d "$HOME/teku-validator" ]]; then
                        local validator_networks=""
                        if docker ps --format "{{.Names}}" | grep -q "^teku-validator$"; then
                            validator_networks=$(docker inspect teku-validator --format '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null || echo "")
                        fi
                        
                        local ethnode_net="${node_name}-net"
                        if echo "$validator_networks" | grep -q "$ethnode_net"; then
                            if timeout 3 docker exec teku-validator curl -s --connect-timeout 2 \
                               "${beacon_url}/eth/v1/node/health" >/dev/null 2>&1; then
                                reachable=true
                            fi
                        fi
                    fi
                    
                    if [[ "$reachable" == "true" ]]; then
                        status_indicator="✓"
                        status_text="reachable"
                        echo -e "${UI_MUTED}  ${node_name} (${client_display}): ✓ reachable${NC}" >&2
                    else
                        status_indicator="○"
                        status_text="available"
                        echo -e "${UI_MUTED}  ${node_name} (${client_display}): ○ available${NC}" >&2
                    fi
                fi
                
                # Add ALL running beacon nodes to the list, regardless of current reachability
                available_beacon_nodes+=("$beacon_url")
                
                # Create description with status and current selection indicator
                if [[ "$beacon_url" == "$current_url" ]]; then
                    beacon_node_descriptions+=("$node_name ($client_display) [CURRENT] $status_indicator $status_text")
                else
                    beacon_node_descriptions+=("$node_name ($client_display) $status_indicator $status_text")
                fi
            fi
        fi
    done
    
    if [[ ${#available_beacon_nodes[@]} -eq 0 ]]; then
        echo
        echo -e "${RED}No beacon nodes found!${NC}"
        echo -e "${UI_MUTED}No ethnode consensus clients are currently running.${NC}"
        echo -e "${UI_MUTED}Please start at least one ethnode with a consensus client first.${NC}"
        return 1
    fi
    
    # For "change beacon node" mode, always show menu even with one option
    # For initial setup, auto-select if only one available
    if [[ ${#available_beacon_nodes[@]} -eq 1 && -z "$current_url" ]]; then
        echo -e "${GREEN}Only one beacon node available: ${beacon_node_descriptions[0]}${NC}" >&2
        echo "${available_beacon_nodes[0]}"
        return 0
    fi
    
    # Add custom URL option
    beacon_node_descriptions+=("Custom beacon node URL...")
    
    # Use fancy menu for selection
    local selection
    local menu_title="Select Beacon Node"
    if [[ -n "$current_url" ]]; then
        menu_title="Change Beacon Node"
    fi
    
    if selection=$(fancy_select_menu "$menu_title" "${beacon_node_descriptions[@]}"); then
        # Check if custom URL option was selected
        if [[ $selection -eq $((${#available_beacon_nodes[@]})) ]]; then
            # Custom URL selected - prompt for input
            local custom_url
            custom_url=$(fancy_text_input "Custom Beacon Node" \
                "Enter custom beacon node URL:" \
                "${current_url:-http://localhost:5052}" \
                "")
            
            if [[ $? -eq 255 ]]; then
                return 1  # User cancelled
            fi
            
            # Basic validation
            if [[ ! "$custom_url" =~ ^https?:// ]]; then
                echo -e "${RED}Invalid URL format. Must start with http:// or https://${NC}"
                return 1
            fi
            
            echo "$custom_url"
            return 0
        else
            # Standard beacon node selected
            echo "${available_beacon_nodes[$selection]}"
            return 0
        fi
    else
        return 1
    fi
}

# Install Teku validator (singleton only) - Full Implementation
install_teku_validator() {
    # CRITICAL SAFETY CHECK: Prevent multiple validators
    if ! check_validator_conflict "teku-validator"; then
        echo "ERROR: Cannot install Teku validator - validator conflict detected"
        return 1
    fi
    
    local service_dir="$HOME/teku-validator"
    local staging_dir="$HOME/.teku-validator-install-$$"
    local installation_success=false
    
    # Atomic cleanup function
    cleanup_failed_teku_installation() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "${RED}✗${NC} Teku validator installation failed"
        echo "Performing complete cleanup..."
        
        # Stop and remove any Docker resources that were created
        if [[ -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
        fi
        
        # Remove staging directory
        if [[ -d "$staging_dir" ]]; then
            echo "Removing staging directory..."
            rm -rf "$staging_dir"
        fi
        
        # Remove final directory if it was partially created
        if [[ -d "$service_dir" ]]; then
            echo "Removing partially created installation..."
            rm -rf "$service_dir"
        fi
        
        echo "Cleanup completed"
        exit $exit_code
    }
    
    # Set error trap for atomic cleanup
    trap cleanup_failed_teku_installation ERR INT TERM
    
    # Singleton check - look for actual Teku files
    if [[ -d "$service_dir" ]] && [[ -f "$service_dir/docker-compose.yml" || -f "$service_dir/.env" ]]; then
        echo -e "${YELLOW}Teku validator is already installed${NC}"
        echo -e "${UI_MUTED}Only one Teku validator instance is supported${NC}"
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
    
    # Show header only after all checks pass
    echo -e "${CYAN}${BOLD}Install Teku Validator${NC}"
    echo "======================"
    echo
    
    # Select beacon node using fancy menu
    echo -e "${UI_MUTED}Detecting available beacon nodes...${NC}"
    local selected_beacon_url
    selected_beacon_url=$(select_beacon_node_for_teku)
    
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}Installation cancelled${NC}"
        press_enter
        return 1
    fi
    
    echo -e "${GREEN}Selected beacon node: ${selected_beacon_url}${NC}"
    
    # Extract ethnode name from beacon URL for network configuration
    # URL format: http://ethnode1-lodestar:5052 -> ethnode1
    local selected_ethnode
    selected_ethnode=$(echo "$selected_beacon_url" | sed 's|http://||' | cut -d'-' -f1)
    echo
    
    # Get fee recipient
    local fee_recipient
    while true; do
        fee_recipient=$(fancy_text_input "Teku Validator Setup" \
            "Fee recipient address (where block rewards go):" \
            "0x0000000000000000000000000000000000000000" \
            "")
        
        if [[ $? -eq 255 ]]; then
            echo "Installation cancelled"
            return 1
        fi
        
        if [[ "$fee_recipient" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
            break
        else
            echo -e "${RED}Invalid fee recipient address format${NC}"
            if ! fancy_confirm "Try again?" "y"; then
                echo "Installation cancelled"
                return 1
            fi
        fi
    done
    
    # Get graffiti
    local graffiti
    graffiti=$(fancy_text_input "Teku Validator Setup" \
        "Graffiti (optional):" \
        "teku-validator" \
        "")
    
    # Create staging directory structure  
    echo -e "${UI_MUTED}Creating directory structure...${NC}"
    mkdir -p "$staging_dir/data"
    
    # Get current user UID/GID
    local current_uid=$(id -u)
    local current_gid=$(id -g)
    
    # Web3signer uses hardcoded port 7500 (singleton service)
    local web3signer_port="7500"
    
    # Create .env file in staging
    echo -e "${UI_MUTED}Creating configuration files...${NC}"
    
    # Use centralized template for consistency
    generate_teku_validator_env "$staging_dir" "$current_uid" "$current_gid" "hoodi" "$selected_beacon_url" "$web3signer_port" "$fee_recipient" "$graffiti" "$selected_ethnode"
    generate_teku_validator_compose "$staging_dir" "$selected_ethnode"
    
    # Set proper permissions on staging
    chmod 755 "$staging_dir"
    chmod 755 "$staging_dir/data"
    
    # ATOMIC MOVE: Configuration complete, now commit the installation
    echo -e "${UI_MUTED}Finalizing installation...${NC}"
    
    # This is the atomic operation - either it all succeeds or fails
    mv "$staging_dir" "$service_dir"
    
    echo -e "${GREEN}✓ Teku validator installed successfully${NC}"
    echo
    
    # Mark installation as successful immediately after atomic move
    # This prevents cleanup if user cancels startup
    installation_success=true
    
    # Disable error traps - installation completed successfully
    set +eE
    set +o pipefail
    trap - ERR INT TERM
    
    # Defensive cleanup: Remove staging directory if it somehow still exists
    # (it shouldn't after mv, but this ensures complete cleanup)
    [[ -d "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
    
    # Ask user if they want to start the validator now
    local launch_choice=""
    launch_choice=$(fancy_text_input "Launch Validator" \
        "Do you want to launch Teku validator right now? (y/n):" \
        "" \
        "")
    
    if [[ "$launch_choice" == "y" || "$launch_choice" == "" ]]; then
        echo -e "${UI_MUTED}Starting Teku validator...${NC}"
        
        # Ensure validator-net network exists
        if ! docker network inspect validator-net >/dev/null 2>&1; then
            docker network create validator-net >/dev/null 2>&1
        fi
        
        # Start Teku (safety warning handled by manage_service)
        if manage_service "up" "teku-validator"; then
            echo -e "${GREEN}✓ Teku validator started successfully!${NC}"
        else
            echo -e "${YELLOW}⚠ Teku installed but failed to start - you can start it manually later${NC}"
        fi
    else
        echo -e "${UI_MUTED}Teku validator ready to launch manually from manage menu${NC}"
    fi
    
    echo
    echo -e "${UI_MUTED}Configuration:${NC}"
    echo -e "${UI_MUTED}  • Beacon node: ${selected_beacon_url}${NC}"
    echo -e "${UI_MUTED}  • Fee recipient: ${fee_recipient}${NC}"
    echo -e "${UI_MUTED}  • Graffiti: ${graffiti}${NC}"
    echo -e "${UI_MUTED}  • Location: ${service_dir}${NC}"
    echo
    # Refresh dashboards
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}
