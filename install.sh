#!/bin/bash
# NODEBOI - Ethereum Node Automation (Modular Version)
# Download and run with: curl -sSL https://raw.githubusercontent.com/Cryptizer69/nodeboi/main/installer.sh | bash

set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Cryptizer69/nodeboi/main"
SCRIPT_VERSION="1.0.0"
LIBS_DIR="/tmp/nodeboi_libs"

# Create libs directory
mkdir -p "$LIBS_DIR"

# Download all library modules
download_libs() {
    local libs=("core" "detection" "ui" "docker" "config" "status" "network" "firewall")
    
    echo "Downloading NODEBOI components..."
    for lib in "${libs[@]}"; do
        if curl -sSL "$REPO_URL/lib/${lib}.sh" -o "$LIBS_DIR/${lib}.sh" 2>/dev/null; then
            source "$LIBS_DIR/${lib}.sh"
            echo "  ✓ Loaded: ${lib}.sh"
        else
            echo "  ✗ Failed to download ${lib}.sh"
            exit 1
        fi
    done
}

# Download components
download_libs

# Main setup process with step-by-step guidance
main_setup() {
    print_header
    
    echo -e "${BOLD}Welcome to NODEBOI - Ethereum Node Automation${NC}"
    echo "This installer will guide you through setting up your Ethereum node step by step."
    echo
    read -p "Press Enter to continue..."
    
    # Step 1: System Check
    echo
    echo -e "${CYAN}${BOLD}STEP 1: System Prerequisites${NC}"
    echo "============================"
    check_prerequisites
    
    read -p "Press Enter to continue to instance detection..."
    
    # Step 2: Instance Detection
    echo
    echo -e "${CYAN}${BOLD}STEP 2: Existing Instance Detection${NC}"
    echo "==================================="
    
    GLOBAL_USED_PORTS=()
    if detect_all_ethereum_instances; then
        echo
        echo -e "${YELLOW}Existing Ethereum instances detected on this system.${NC}"
        echo "NODEBOI will automatically avoid port conflicts."
        echo
        read -p "Continue with installation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled by user."
            exit 0
        fi
    fi
    
    read -p "Press Enter to continue to node configuration..."
    
    # Step 3: Node Configuration
    echo
    echo -e "${CYAN}${BOLD}STEP 3: Node Configuration${NC}"
    echo "=========================="
    
    local node_name=$(prompt_node_name)
    echo
    read -p "Press Enter to continue to network selection..."
    
    local network=$(prompt_network)
    echo
    read -p "Press Enter to continue to client selection..."
    
    local exec_info=$(prompt_execution_client_with_version)
    local execution_client=$(echo "$exec_info" | cut -d':' -f1)
    local exec_version=$(echo "$exec_info" | cut -d':' -f2)
    echo
    read -p "Press Enter to continue to consensus client selection..."
    
    local cons_info=$(prompt_consensus_client_with_version)
    local consensus_client=$(echo "$cons_info" | cut -d':' -f1)
    local cons_version=$(echo "$cons_info" | cut -d':' -f2)
    echo
    read -p "Press Enter to continue to port configuration..."
    
    local user_ports=$(prompt_ports "$node_name")
    echo
    
    # Step 4: Final Confirmation
    echo -e "${CYAN}${BOLD}STEP 4: Installation Confirmation${NC}"
    echo "================================="
    echo
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo "Node name: $node_name"
    echo "Network: $network"
    echo "Execution client: $execution_client ($exec_version)"
    echo "Consensus client: $consensus_client ($cons_version)"
    echo "Router ports: $user_ports"
    echo
    
    read -p "Proceed with installation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation cancelled by user."
        exit 0
    fi
    
    # Step 5: Installation Process
    echo
    echo -e "${CYAN}${BOLD}STEP 5: Installation Process${NC}"
    echo "============================"
    echo
    
    echo -e "${YELLOW}Starting installation process...${NC}"
    echo
    
    # Create directories
    local node_dir=$(create_directories "$node_name")
    
    # Create system user
    local uid_gid=$(create_user "$node_name")
    local node_uid=$(echo "$uid_gid" | cut -d':' -f1)
    local node_gid=$(echo "$uid_gid" | cut -d':' -f2)
    
    # Download configuration files
    download_config_files "$node_dir" "$execution_client" "$consensus_client"
    
    # Generate JWT secret
    generate_jwt "$node_dir" "$node_uid" "$node_gid"
    
    # Create and customize .env file
    echo -e "${BOLD}Environment Configuration${NC}"
    echo "========================"
    show_working "Creating environment configuration with your settings" 3
    
    local final_ports=$(create_env_file "$node_dir" "$node_name" "$node_uid" "$node_gid" \
                       "$execution_client" "$consensus_client" "$network" "$user_ports")
    
    # Update versions in .env
    update_client_versions "$node_dir" "$execution_client" "$exec_version" "$consensus_client" "$cons_version"
    
    # Set permissions
    set_permissions "$node_dir" "$node_uid" "$node_gid"
    
    # Configure firewall
    configure_firewall "$user_ports" "$node_name"
    
    # Create convenience scripts
    create_convenience_scripts "$node_dir" "$node_name"
    
    # Install nodeboi command
    create_nodeboi_command
    
    # Wait for services to potentially start
    echo
    echo "Waiting for services to initialize..."
    sleep 3
    
    # Show final status
    show_node_summary
    
    echo
    echo -e "${GREEN}${BOLD}Installation Complete!${NC}"
    echo
    echo "Next steps:"
    echo "1. Forward ports $user_ports in your router"
    echo "2. Start your node: cd $node_dir && docker compose up -d"
    echo "3. Check status: nodeboi info"
    echo
}

# Update node functionality
update_node() {
    echo -e "${CYAN}${BOLD}Update Ethereum Node${NC}"
    echo "===================="
    echo
    
    # List available nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            nodes+=("$(basename "$dir")")
        fi
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No Ethereum nodes found to update."
        return
    fi
    
    echo "Select node to update:"
    select node_name in "${nodes[@]}" "Cancel"; do
        if [[ "$node_name" == "Cancel" ]]; then
            return
        elif [[ -n "$node_name" ]]; then
            break
        fi
    done
    
    local node_dir="$HOME/$node_name"
    
    echo
    show_working "Backing up current configuration" 2
    cp "$node_dir/.env" "$node_dir/.env.backup.$(date +%Y%m%d_%H%M%S)"
    
    echo
    show_working "Stopping node services" 3
    cd "$node_dir" && docker compose down
    
    echo
    show_working "Downloading latest configuration files" 3
    
    # Detect which clients are configured
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" | cut -d'=' -f2)
    local execution_client=""
    local consensus_client=""
    
    [[ "$compose_file" == *"reth"* ]] && execution_client="reth"
    [[ "$compose_file" == *"besu"* ]] && execution_client="besu"
    [[ "$compose_file" == *"nethermind"* ]] && execution_client="nethermind"
    [[ "$compose_file" == *"lodestar"* ]] && consensus_client="lodestar"
    [[ "$compose_file" == *"teku"* ]] && consensus_client="teku"
    [[ "$compose_file" == *"grandine"* ]] && consensus_client="grandine"
    
    download_config_files "$node_dir" "$execution_client" "$consensus_client"
    
    echo
    show_working "Pulling latest Docker images" 5
    cd "$node_dir" && docker compose pull
    
    echo
    echo -e "${GREEN}✓${NC} Node $node_name updated successfully!"
    echo
    read -p "Start the updated node now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$node_dir" && docker compose up -d
        echo "Node started. Check logs: cd $node_dir && docker compose logs -f"
    fi
}

# Remove node functionality
remove_node() {
    echo -e "${CYAN}${BOLD}Remove Ethereum Node${NC}"
    echo "===================="
    echo
    
    # List available nodes with status
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            local status=$(get_node_status "$node_name")
            nodes+=("$node_name ($status)")
        fi
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No Ethereum nodes found to remove."
        return
    fi
    
    echo "Select node to remove:"
    select node_entry in "${nodes[@]}" "Cancel"; do
        if [[ "$node_entry" == "Cancel" ]]; then
            return
        elif [[ -n "$node_entry" ]]; then
            break
        fi
    done
    
    local node_name=$(echo "$node_entry" | cut -d' ' -f1)
    local node_dir="$HOME/$node_name"
    
    echo
    echo -e "${RED}${BOLD}⚠ WARNING ⚠${NC}"
    echo "This will permanently delete:"
    echo "  - Node directory: $node_dir"
    echo "  - All blockchain data"
    echo "  - Docker containers and volumes"
    echo "  - System user: $node_name"
    echo
    read -p "Type 'DELETE' to confirm: " confirmation
    
    if [[ "$confirmation" != "DELETE" ]]; then
        echo "Removal cancelled."
        return
    fi
    
    echo
    show_working "Stopping and removing Docker containers" 3
    cd "$node_dir" 2>/dev/null && docker compose down -v
    
    show_working "Removing system user" 2
    sudo userdel "$node_name" 2>/dev/null || true
    
    show_working "Removing firewall rules" 2
    remove_firewall_rules "$node_name"
    
    show_working "Deleting node directory" 2
    rm -rf "$node_dir"
    
    echo
    echo -e "${GREEN}✓${NC} Node $node_name removed successfully!"
}

# Main menu system
show_main_menu() {
    while true; do
        clear
        print_header
        
        echo -e "${BOLD}What would you like to do?${NC}"
        echo "======================="
        echo
        echo "1) Launch new ethnode    - Create a new Ethereum node instance"
        echo "2) Update ethnode        - Update existing node to latest versions"
        echo "3) Remove ethnode        - Delete node and cleanup all associated data"
        echo "4) Show status           - Display current status of all nodes"
        echo "5) Exit                  - Quit NODEBOI"
        echo
        
        read -p "Select option (1-5, default: 1): " menu_choice
        menu_choice=${menu_choice:-1}
        
        case $menu_choice in
            1) main_setup; read -p "Press Enter to return to menu..." ;;
            2) update_node; read -p "Press Enter to return to menu..." ;;
            3) remove_node; read -p "Press Enter to return to menu..." ;;
            4) show_node_summary; read -p "Press Enter to return to menu..." ;;
            5) echo "Thanks for using NODEBOI!"; exit 0 ;;
            *) echo -e "${RED}Invalid choice. Please enter 1-5${NC}"; sleep 2 ;;
        esac
    done
}

# Execute main menu
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    show_main_menu
fi
