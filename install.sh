# Main setup process
main_setup() {
    print_header
    
    # Detect existing instances first
    local existing_detected=false
    if detect_existing_instances; then
        existing_detected=true
        echo
        log_warn "Existing Ethereum instances detected on this system"
        log_info "The installer will automatically avoid port conflicts"
        echo
        read -p "Continue with installation? (y/N): " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 0
        fi
    fi
    
    echo
    log_info "Starting interactive setup..."
    
    # Get user preferences
    local node_name=$(prompt_node_name)
    local network=$(prompt_network)
    local execution_client=$(prompt_execution_client)
    local consensus_client=$(prompt_consensus_client)
    local user_ports=$(prompt_ports "$node_name")
    
    # Confirm settings
    echo
    echo -e "${BOLD}Configuration Summary${NC}"
    echo "====================="
    echo "Node name: $node_name"
    echo "Network: $network"
    echo "Execution client: $execution_client"
    echo "Consensus client: $consensus_client"
    echo "Router ports (EL P2P/CL P2P/WS): $user_ports"
    echo
    
    read -p "Continue with installation? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
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
    
# Main setup process with step-by-step guidance
main_setup() {
    # Start with NODEBOI ASCII art
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
    local existing_detected=false
    
    if detect_all_ethereum_instances; then
        existing_detected=true
        echo
        echo -e "${YELLOW}Existing Ethereum instances detected on this system.${NC}"
        echo "NODEBOI will automatically avoid port conflicts."
        echo
        if ! tui_yesno "Continue Installation" "Continue with installation?"; then
            echo "Installation cancelled by user."
            exit 0
        fi
    fi
    
    read -p "Press Enter to continue to node configuration..."
    
    # Step 3: Node Configuration
    echo
    echo -e "${CYAN}${BOLD}STEP 3: Node Configuration${NC}"
    echo "=========================="
    
    # Get node name
    local node_name=$(prompt_node_name)
    echo
    read -p "Press Enter to continue to network selection..."
    
    # Get network
    local network=$(prompt_network)
    echo
    read -p "Press Enter to continue to client selection..."
    
    # Get execution client with version
    local exec_info=$(prompt_execution_client_with_version)
    local execution_client=$(echo "$exec_info" | cut -d':' -f1)
    local exec_version=$(echo "$exec_info" | cut -d':' -f2)
    echo
    read -p "Press Enter to continue to consensus client selection..."
    
    # Get consensus client with version
    local cons_info=$(prompt_consensus_client_with_version)
    local consensus_client=$(echo "$cons_info" | cut -d':' -f1)
    local cons_version=$(echo "$cons_info" | cut -d':' -f2)
    echo
    read -p "Press Enter to continue to port configuration..."
    
    # Get port configuration
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
    
    if ! tui_yesno "Final Confirmation" "Proceed with installation using this configuration?"; then
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
    
    local final_ports=$(create_env_file_enhanced "$node_dir" "$node_name" "$node_uid" "$node_gid" \
                       "$execution_client" "$consensus_client" "$network" "$user_ports")
    
    # Update versions in .env file
    sed -i "s/RETH_VERSION=.*/RETH_VERSION=$exec_version/" "$node_dir/.env" 2>/dev/null || true
    sed -i "s/BESU_VERSION=.*/BESU_VERSION=$exec_version/" "$node_dir/.env" 2>/dev/null || true
    sed -i "s/NETHERMIND_VERSION=.*/NETHERMIND_VERSION=$exec_version/" "$node_dir/.env" 2>/dev/null || true
    sed -i "s/LODESTAR_VERSION=.*/LODESTAR_VERSION=$cons_version/" "$node_dir/.env" 2>/dev/null || true
    sed -i "s/TEKU_VERSION=.*/TEKU_VERSION=$cons_version/" "$node_dir/.env" 2>/dev/null || true
    sed -i "s/GRANDINE_VERSION=.*/GRANDINE_VERSION=$cons_version/" "$node_dir/.env" 2>/dev/null || true
    
    echo -e "${GREEN}✓${NC} Environment configured with selected versions"
    echo
    
    # Set permissions
    set_permissions "$node_dir" "$node_uid" "$node_gid"
    
    # Configure firewall
    configure_firewall "$user_ports" "$node_name"
    
    # Parse final port assignments for display
    local el_rpc_port=$(echo "$final_ports" | cut -d':' -f1)
    local ws_port=$(echo "$final_ports" | cut -d':' -f2)
    local cl_rest_port=$(echo "$final_ports" | cut -d':' -f6)
    local el_p2p_port=$(echo "$user_ports" | cut -d':' -f1)
    local cl_p2p_port=$(echo "$user_ports" | cut -d':' -f2)
    
    # Final completion screen
    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
    ██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗      ██████╗ ██████╗ ███╗   ███╗██████╗ ██╗     ███████╗████████╗███████╗██╗
    ██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║     ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝╚══██╔══╝██╔════╝██║
    ██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║     ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗     ██║   █████╗  ██║
    ██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║     ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝     ██║   ██╔══╝  ╚═╝
    ██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗   ██║   ███████╗██╗
    ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝ ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝   ╚══════╝╚═╝
EOF
    echo -e "${NC}"
    echo
    
    # Installation summary
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                                INSTALLATION COMPLETE                               ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${BOLD}Node Configuration:${NC}"
    echo "  Name: $node_name"
    echo "  Network: $network"  
    echo "  Execution: $execution_client ($exec_version)"
    echo "  Consensus: $consensus_client ($cons_version)"
    echo "  Directory: $node_dir"
    echo
    echo -e "${BOLD}Port Assignments:${NC}"
    echo "  EL RPC:     $el_rpc_port (internal)"
    echo "  WebSocket:  $ws_port (router forward recommended)"
    echo "  EL P2P:     $el_p2p_port (router forward required)"
    echo "  CL REST:    $cl_rest_port (internal)"
    echo "  CL P2P:     $cl_p2p_port (router forward required)"
    echo
    echo -e "${BOLD}Router Port Forwarding Required:${NC}"
    echo "  $el_p2p_port (TCP + UDP) - Execution Layer P2P"
    echo "  $cl_p2p_port (TCP + UDP) - Consensus Layer P2P"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                                    NEXT STEPS                                    ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${BOLD}1. Start Your Node:${NC}"
    echo "   cd $node_dir"
    echo "   docker compose up -d"
    echo
    echo -e "${BOLD}2. Monitor Logs:${NC}"
    echo "   docker compose logs -f"
    echo
    echo -e "${BOLD}3. Check Status:${NC}"
    echo "   docker compose ps"
    echo
    echo -e "${YELLOW}${BOLD}Important Notes:${NC}"
    echo "• Initial sync will take several hours to days"
    echo "• Monitor disk space (requires 100GB+ for mainnet)"
    echo "• Forward P2P ports in your router for optimal connectivity"
    echo "• Client versions can be updated in the .env file"
    echo
    echo -e "${GREEN}${BOLD}Your Ethereum node is ready to rock!${NC}"
    echo
    
    # Create convenience scripts
    cat > "$node_dir/start.sh" << EOF
#!/bin/bash
cd "$node_dir"
echo "Starting $node_name..."
docker compose up -d
echo "Node started! Use 'docker compose logs -f' to view logs."
EOF
    chmod +x "$node_dir/start.sh"
    
    cat > "$node_dir/stop.sh" << EOF
#!/bin/bash
cd "$node_dir"
echo "Stopping $node_name..."
docker compose down
echo "Node stopped."
EOF
    chmod +x "$node_dir/stop.sh"
    
# Node status checking functions
check_endpoint_health() {
    local endpoint="$1"
    local timeout="${2:-3}"
    
    if curl -s --connect-timeout "$timeout" --max-time "$timeout" "$endpoint" >/dev/null 2>&1; then
        return 0  # Healthy
    else
        return 1  # Unhealthy
    fi
}

get_node_status() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"
    
    if [[ ! -d "$node_dir" ]]; then
        echo "NOT_FOUND"
        return 1
    fi
    
    # Check if containers are running
    cd "$node_dir" 2>/dev/null || return 1
    local running_containers=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l)
    local total_containers=$(docker compose ps --services 2>/dev/null | wc -l)
    
    if [[ "$running_containers" -eq 0 ]]; then
        echo "OFFLINE"
        return 1
    elif [[ "$running_containers" -lt "$total_containers" ]]; then
        echo "PARTIAL"
        return 1
    else
        echo "ONLINE"
        return 0
    fi
}

get_node_endpoints() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"
    
    if [[ ! -f "$node_dir/.env" ]]; then
        return 1
    fi
    
    # Source the .env file to get port information
    local el_rpc_port=$(grep "EL_RPC_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local el_ws_port=$(grep "EL_WS_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local cl_rest_port=$(grep "CL_REST_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local el_p2p_port=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local cl_p2p_port=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    
    echo "RPC:http://localhost:$el_rpc_port,WS:ws://localhost:$el_ws_port,REST:http://localhost:$cl_rest_port,EL_P2P:$el_p2p_port,CL_P2P:$cl_p2p_port"
}

show_node_summary() {
    echo
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                                  NODEBOI STATUS                                  ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    
    local found_nodes=false
    local total_nodes=0
    local online_nodes=0
    
    # Find all Ethereum nodes
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            found_nodes=true
            ((total_nodes++))
            
            local node_name=$(basename "$dir")
            local status=$(get_node_status "$node_name")
            local endpoints=$(get_node_endpoints "$node_name")
            
            # Parse endpoints
            local rpc_endpoint=$(echo "$endpoints" | cut -d',' -f1 | cut -d':' -f2-)
            local ws_endpoint=$(echo "$endpoints" | cut -d',' -f2 | cut -d':' -f2-)
            local rest_endpoint=$(echo "$endpoints" | cut -d',' -f3 | cut -d':' -f2-)
            local el_p2p_port=$(echo "$endpoints" | cut -d',' -f4 | cut -d':' -f2)
            local cl_p2p_port=$(echo "$endpoints" | cut -d',' -f5 | cut -d':' -f2)
            
            # Display node status
            case "$status" in
                "ONLINE")
                    echo -e "${GREEN}●${NC} ${BOLD}$node_name${NC} - ${GREEN}ONLINE${NC}"
                    ((online_nodes++))
                    ;;
                "PARTIAL")
                    echo -e "${YELLOW}●${NC} ${BOLD}$node_name${NC} - ${YELLOW}PARTIAL${NC}"
                    ;;
                "OFFLINE")
                    echo -e "${RED}●${NC} ${BOLD}$node_name${NC} - ${RED}OFFLINE${NC}"
                    ;;
                *)
                    echo -e "${RED}●${NC} ${BOLD}$node_name${NC} - ${RED}ERROR${NC}"
                    ;;
            esac
            
            # Show endpoint health
            echo "  Endpoints:"
            
            # Check RPC endpoint
            echo -n "    RPC:  $rpc_endpoint "
            if check_endpoint_health "$rpc_endpoint" 2; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
            
            # Check WebSocket (harder to test, so we just show the URL)
            echo -e "    WS:   $ws_endpoint ${BLUE}(configured)${NC}"
            
            # Check REST endpoint
            echo -n "    REST: $rest_endpoint "
            if check_endpoint_health "$rest_endpoint" 2; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
            fi
            
            # Show P2P ports (can't easily test connectivity, just show config)
            echo -e "    P2P:  EL:$el_p2p_port CL:$cl_p2p_port ${BLUE}(router forward required)${NC}"
            
            # Get client info from .env
            local network=$(grep "NETWORK=" "$dir/.env" | cut -d'=' -f2)
            local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)
            local execution_client="unknown"
            local consensus_client="unknown"
            
            if [[ "$compose_file" == *"reth"* ]]; then execution_client="reth"; fi
            if [[ "$compose_file" == *"besu"* ]]; then execution_client="besu"; fi
            if [[ "$compose_file" == *"nethermind"* ]]; then execution_client="nethermind"; fi
            if [[ "$compose_file" == *"lodestar"* ]]; then consensus_client="lodestar"; fi
            if [[ "$compose_file" == *"teku"* ]]; then consensus_client="teku"; fi
            if [[ "$compose_file" == *"grandine"* ]]; then consensus_client="grandine"; fi
            
            echo -e "    Config: $execution_client + $consensus_client on $network"
            echo
        fi
    done
    
    if [[ "$found_nodes" == false ]]; then
        echo -e "${YELLOW}No Ethereum nodes found.${NC}"
        echo "Run the installer to create your first node!"
    else
        echo -e "${BOLD}Summary: $online_nodes/$total_nodes nodes online${NC}"
        echo
        echo -e "${BLUE}Commands:${NC}"
        echo "  Start node:   cd ~/ethnode1 && docker compose up -d"
        echo "  Stop node:    cd ~/ethnode1 && docker compose down"
        echo "  View logs:    cd ~/ethnode1 && docker compose logs -f"
        echo "  Node status:  nodeboi info"
    fi
    
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
}

# Create nodeboi info command
create_nodeboi_command() {
    local install_dir="/usr/local/bin"
    
    show_working "Creating nodeboi command for system-wide access" 2
    
    # Create the nodeboi script
    cat > "/tmp/nodeboi" << 'EOF'
#!/bin/bash

# NODEBOI System Command
# Quick access to node status and management

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

show_help() {
    echo -e "${CYAN}${BOLD}NODEBOI - Ethereum Node Management${NC}"
    echo
    echo "Usage: nodeboi [COMMAND]"
    echo
    echo "Commands:"
    echo "  info      Show status of all nodes and endpoints"
    echo "  install   Run the full installer"
    echo "  help      Show this help message"
    echo
}

case "${1:-info}" in
    "info"|"status")
        # Source the functions from the main script if available
        if [[ -f "$HOME/.nodeboi/functions.sh" ]]; then
            source "$HOME/.nodeboi/functions.sh"
        else
            # Inline the essential functions
            check_endpoint_health() {
                local endpoint="$1"
                local timeout="${2:-3}"
                
                if curl -s --connect-timeout "$timeout" --max-time "$timeout" "$endpoint" >/dev/null 2>&1; then
                    return 0
                else
                    return 1
                fi
            }
            
            get_node_status() {
                local node_name="$1"
                local node_dir="$HOME/$node_name"
                
                if [[ ! -d "$node_dir" ]]; then
                    echo "NOT_FOUND"
                    return 1
                fi
                
                cd "$node_dir" 2>/dev/null || return 1
                local running_containers=$(docker compose ps --services --filter status=running 2>/dev/null | wc -l)
                local total_containers=$(docker compose ps --services 2>/dev/null | wc -l)
                
                if [[ "$running_containers" -eq 0 ]]; then
                    echo "OFFLINE"
                    return 1
                elif [[ "$running_containers" -lt "$total_containers" ]]; then
                    echo "PARTIAL"
                    return 1
                else
                    echo "ONLINE"
                    return 0
                fi
            }
            
            get_node_endpoints() {
                local node_name="$1"
                local node_dir="$HOME/$node_name"
                
                if [[ ! -f "$node_dir/.env" ]]; then
                    return 1
                fi
                
                local el_rpc_port=$(grep "EL_RPC_PORT=" "$node_dir/.env" | cut -d'=' -f2)
                local el_ws_port=$(grep "EL_WS_PORT=" "$node_dir/.env" | cut -d'=' -f2)
                local cl_rest_port=$(grep "CL_REST_PORT=" "$node_dir/.env" | cut -d'=' -f2)
                local el_p2p_port=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
                local cl_p2p_port=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
                
                echo "RPC:http://localhost:$el_rpc_port,WS:ws://localhost:$el_ws_port,REST:http://localhost:$cl_rest_port,EL_P2P:$el_p2p_port,CL_P2P:$cl_p2p_port"
            }
        fi
        
        # Show node status (inline version of show_node_summary)
        echo
        echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${BOLD}                                  NODEBOI STATUS                                  ${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo
        
        local found_nodes=false
        local total_nodes=0
        local online_nodes=0
        
        for dir in "$HOME"/ethnode*; do
            if [[ -d "$dir" && -f "$dir/.env" ]]; then
                found_nodes=true
                ((total_nodes++))
                
                local node_name=$(basename "$dir")
                local status=$(get_node_status "$node_name")
                local endpoints=$(get_node_endpoints "$node_name")
                
                local rpc_endpoint=$(echo "$endpoints" | cut -d',' -f1 | cut -d':' -f2-)
                local ws_endpoint=$(echo "$endpoints" | cut -d',' -f2 | cut -d':' -f2-)
                local rest_endpoint=$(echo "$endpoints" | cut -d',' -f3 | cut -d':' -f2-)
                local el_p2p_port=$(echo "$endpoints" | cut -d',' -f4 | cut -d':' -f2)
                local cl_p2p_port=$(echo "$endpoints" | cut -d',' -f5 | cut -d':' -f2)
                
                case "$status" in
                    "ONLINE")
                        echo -e "${GREEN}●${NC} ${BOLD}$node_name${NC} - ${GREEN}ONLINE${NC}"
                        ((online_nodes++))
                        ;;
                    "PARTIAL")
                        echo -e "${YELLOW}●${NC} ${BOLD}$node_name${NC} - ${YELLOW}PARTIAL${NC}"
                        ;;
                    "OFFLINE")
                        echo -e "${RED}●${NC} ${BOLD}$node_name${NC} - ${RED}OFFLINE${NC}"
                        ;;
                    *)
                        echo -e "${RED}●${NC} ${BOLD}$node_name${NC} - ${RED}ERROR${NC}"
                        ;;
                esac
                
                echo "  Endpoints:"
                echo -n "    RPC:  $rpc_endpoint "
                if check_endpoint_health "$rpc_endpoint" 2; then
                    echo -e "${GREEN}✓${NC}"
                else
                    echo -e "${RED}✗${NC}"
                fi
                
                echo -e "    WS:   $ws_endpoint ${BLUE}(configured)${NC}"
                
                echo -n "    REST: $rest_endpoint "
                if check_endpoint_health "$rest_endpoint" 2; then
                    echo -e "${GREEN}✓${NC}"
                else
                    echo -e "${RED}✗${NC}"
                fi
                
                echo -e "    P2P:  EL:$el_p2p_port CL:$cl_p2p_port ${BLUE}(router forward required)${NC}"
                
                local network=$(grep "NETWORK=" "$dir/.env" | cut -d'=' -f2)
                local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)
                local execution_client="unknown"
                local consensus_client="unknown"
                
                if [[ "$compose_file" == *"reth"* ]]; then execution_client="reth"; fi
                if [[ "$compose_file" == *"besu"* ]]; then execution_client="besu"; fi
                if [[ "$compose_file" == *"nethermind"* ]]; then execution_client="nethermind"; fi
                if [[ "$compose_file" == *"lodestar"* ]]; then consensus_client="lodestar"; fi
                if [[ "$compose_file" == *"teku"* ]]; then consensus_client="teku"; fi
                if [[ "$compose_file" == *"grandine"* ]]; then consensus_client="grandine"; fi
                
                echo -e "    Config: $execution_client + $consensus_client on $network"
                echo
            fi
        done
        
        if [[ "$found_nodes" == false ]]; then
            echo -e "${YELLOW}No Ethereum nodes found.${NC}"
            echo "Run 'nodeboi install' to create your first node!"
        else
            echo -e "${BOLD}Summary: $online_nodes/$total_nodes nodes online${NC}"
            echo
            echo -e "${BLUE}Commands:${NC}"
            echo "  Start node:   cd ~/ethnode1 && docker compose up -d"
            echo "  Stop node:    cd ~/ethnode1 && docker compose down"
            echo "  View logs:    cd ~/ethnode1 && docker compose logs -f"
            echo "  Node status:  nodeboi info"
        fi
        
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        ;;
        
    "install")
        # Re-run the installer
        if command -v curl &> /dev/null; then
            curl -sSL https://raw.githubusercontent.com/yourusername/eth-node-installer/main/install.sh | bash
        elif command -v wget &> /dev/null; then
            wget -O - https://raw.githubusercontent.com/yourusername/eth-node-installer/main/install.sh | bash
        else
            echo "Error: curl or wget required to run installer"
        fi
        ;;
        
    "help"|"-h"|"--help")
        show_help
        ;;
        
    *)
        echo "Unknown command: $1"
        show_help
        exit 1
        ;;
esac
EOF
    
    # Install the command system-wide
    if sudo mv "/tmp/nodeboi" "$install_dir/nodeboi" && sudo chmod +x "$install_dir/nodeboi"; then
        echo -e "${GREEN}✓${NC} 'nodeboi' command installed system-wide"
    else
        echo -e "${YELLOW}⚠${NC} Could not install system-wide, trying user install..."
        mkdir -p "$HOME/.local/bin"
        mv "/tmp/nodeboi" "$HOME/.local/bin/nodeboi"
        chmod +x "$HOME/.local/bin/nodeboi"
        
        # Add to PATH if not already there
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
            echo -e "${BLUE}ℹ${NC} Added $HOME/.local/bin to PATH in .bashrc"
            echo -e "${BLUE}ℹ${NC} Run 'source ~/.bashrc' or start a new terminal session"
        fi
        
        echo -e "${GREEN}✓${NC} 'nodeboi' command installed to user directory"
    fi
}
}
    
    # Installation complete with celebratory display
    echo
    echo -e "${GREEN}${BOLD}"
    cat << 'EOF'
    ██████╗ ██╗   ██╗██╗██╗     ██████╗      ██████╗ ██████╗ ███╗   ███╗██████╗ ██╗     ███████╗████████╗███████╗██╗
    ██╔══██╗██║   ██║██║██║     ██╔══██╗    ██╔════╝██╔═══██╗████╗ ████║██╔══██╗██║     ██╔════╝╚══██╔══╝██╔════╝██║
    ██████╔╝██║   ██║██║██║     ██║  ██║    ██║     ██║   ██║██╔████╔██║██████╔╝██║     █████╗     ██║   █████╗  ██║
    ██╔══██╗██║   ██║██║██║     ██║  ██║    ██║     ██║   ██║██║╚██╔╝██║██╔═══╝ ██║     ██╔══╝     ██║   ██╔══╝  ╚═╝
    ██████╔╝╚██████╔╝██║███████╗██████╔╝    ╚██████╗╚██████╔╝██║ ╚═╝ ██║██║     ███████╗███████╗   ██║   ███████╗██╗
    ╚═════╝  ╚═════╝ ╚═╝╚══════╝╚═════╝      ╚═════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝     ╚══════╝╚══════╝   ╚═╝   ╚══════╝╚═╝
EOF
    echo -e "${NC}"
    echo
    
    # Installation summary with detailed feedback
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                                INSTALLATION SUMMARY                                ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${BOLD}Node Configuration:${NC}"
    echo "  Name: $node_name"
    echo "  Network: $network"  
    echo "  Execution: $execution_client"
    echo "  Consensus: $consensus_client"
    echo "  Directory: $node_dir"
    echo
    echo -e "${BOLD}Port Assignments:${NC}"
    echo "  EL RPC:     $el_rpc_port (internal)"
    echo "  WebSocket:  $ws_port (router forward recommended)"
    echo "  EL P2P:     $el_p2p_port (router forward required)"
    echo "  CL REST:    $cl_rest_port (internal)"
    echo "  CL P2P:     $cl_p2p_port (router forward required)"
    echo
    echo -e "${BOLD}Router Port Forwarding Required:${NC}"
    echo "  $el_p2p_port (TCP + UDP) - Execution Layer P2P"
    echo "  $cl_p2p_port (TCP + UDP) - Consensus Layer P2P"
    echo
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}                                    NEXT STEPS                                    ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo
    echo -e "${BOLD}1. Review Configuration (Optional):${NC}"
    echo "   nano $node_dir/.env"
    echo
    echo -e "${BOLD}2. Start Your Node:${NC}"
    echo "   cd $node_dir"
    echo "   docker compose up -d"
    echo
    echo -e "${BOLD}3. Monitor Logs:${NC}"
    echo "   docker compose logs -f"
    echo
    echo -e "${BOLD}4. Check Status:${NC}"
    echo "   docker compose ps"
    echo
    echo -e "${YELLOW}${BOLD}Important Notes:${NC}"
    echo "• Initial sync will take several hours to days"
    echo "• Monitor disk space (requires 100GB+ for mainnet)"
    echo "• Forward P2P ports in your router for optimal connectivity"
    echo "• Keep your system updated and secure"
    echo
    echo -e "${GREEN}${BOLD}Your Ethereum node is ready to rock! 🚀${NC}"
    echo
    
    # Create a quick start script
    cat > "$node_dir/start.sh" << EOF
#!/bin/bash
cd "$node_dir"
echo "Starting $node_name..."
docker compose up -d
echo "Node started! Use 'docker compose logs -f' to view logs."
EOF
    chmod +x "$node_dir/start.sh"
    
    cat > "$node_dir/stop.sh" << EOF
#!/bin/bash
cd "$node_dir"
echo "Stopping $node_name..."
docker compose down
echo "Node stopped."
EOF
    chmod +x "$node_dir/stop.sh"
    
    echo -e "${GREEN}✓${NC} Created convenience scripts: start.sh and stop.sh"
    echo
}#!/bin/bash

# Ethereum Node Web Installer
# Download and run with: curl -sSL https://raw.githubusercontent.com/yourusername/eth-node-installer/main/install.sh | bash
# Or: wget -O - https://raw.githubusercontent.com/yourusername/eth-node-installer/main/install.sh | bash

set -euo pipefail

# Configuration
REPO_URL="https://raw.githubusercontent.com/Cryptizer69/nodeboi/main"
INSTALL_DIR="$HOME"
SCRIPT_VERSION="1.0.0"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Progress and timing functions
show_step_with_delay() {
    local message="$1"
    local delay="${2:-2}"
    
    echo -e "${BLUE}⚡${NC} $message..."
    sleep "$delay"
    echo -e "${GREEN}✓${NC} Complete"
    echo
}

show_working() {
    local message="$1"
    local work_time="${2:-2}"
    
    echo -n -e "${BLUE}⚡${NC} $message"
    
    # Show spinner for work_time seconds
    local i=0
    local spin='-\|/'
    while [ $i -lt $(($work_time * 4)) ]; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}⚡${NC} $message ${spin:$i:1}"
        sleep 0.25
    done
    
    printf "\r${GREEN}✓${NC} $message... Complete\n"
    echo
}

# Client version information
get_latest_version() {
    local client="$1"
    
    case "$client" in
        "reth") echo "v1.6.0" ;;
        "besu") echo "25.7.0" ;;
        "nethermind") echo "v1.32.4" ;;
        "lodestar") echo "v1.33.0" ;;
        "teku") echo "25.7.1" ;;
        "grandine") echo "1.1.4" ;;
        *) echo "latest" ;;
    esac
}

# Enhanced client selection with version confirmation
prompt_execution_client_with_version() {
    echo
    echo -e "${BOLD}Execution Client Selection${NC}"
    echo "=========================="
    echo "1) reth        - Fast, Rust-based (recommended)"
    echo "2) besu        - Java-based, enterprise features"  
    echo "3) nethermind  - C#-based, Windows friendly"
    echo
    
    while true; do
        read -p "Select execution client (1-3, default: 1): " exec_choice
        exec_choice=${exec_choice:-1}
        
        local client=""
        case $exec_choice in
            1) client="reth"; break ;;
            2) client="besu"; break ;;
            3) client="nethermind"; break ;;
            *) echo -e "${RED}Invalid choice. Please enter 1-3${NC}" ;;
        esac
    done
    
    # Version confirmation
    local latest_version=$(get_latest_version "$client")
    echo
    echo -e "${YELLOW}Version Information:${NC}"
    echo "Latest $client version: $latest_version"
    echo
    echo -e "${YELLOW}⚠ Important:${NC} Always check the official $client GitHub for the latest releases:"
    case "$client" in
        "reth") echo "   https://github.com/paradigmxyz/reth/releases" ;;
        "besu") echo "   https://github.com/hyperledger/besu/releases" ;;
        "nethermind") echo "   https://github.com/NethermindEth/nethermind/releases" ;;
    esac
    echo "   You can adjust the version in the .env file after installation."
    echo
    
    if tui_yesno "Version Confirmation" "Use latest version ($latest_version) for $client?"; then
        echo "$client:$latest_version"
    else
        local custom_version
        custom_version=$(tui_inputbox "Custom Version" "Enter $client version:" "$latest_version")
        echo "$client:$custom_version"
    fi
}

prompt_consensus_client_with_version() {
    echo
    echo -e "${BOLD}Consensus Client Selection${NC}"
    echo "=========================="
    echo "1) lodestar  - TypeScript-based, feature-rich (recommended)"
    echo "2) teku      - Java-based, enterprise features"
    echo "3) grandine  - Rust-based, high performance"
    echo
    
    while true; do
        read -p "Select consensus client (1-3, default: 1): " cons_choice
        cons_choice=${cons_choice:-1}
        
        local client=""
        case $cons_choice in
            1) client="lodestar"; break ;;
            2) client="teku"; break ;;
            3) client="grandine"; break ;;
            *) echo -e "${RED}Invalid choice. Please enter 1-3${NC}" ;;
        esac
    done
    
    # Version confirmation
    local latest_version=$(get_latest_version "$client")
    echo
    echo -e "${YELLOW}Version Information:${NC}"
    echo "Latest $client version: $latest_version"
    echo
    echo -e "${YELLOW}⚠ Important:${NC} Always check the official $client GitHub for the latest releases:"
    case "$client" in
        "lodestar") echo "   https://github.com/ChainSafe/lodestar/releases" ;;
        "teku") echo "   https://github.com/Consensys/teku/releases" ;;
        "grandine") echo "   https://github.com/grandinetech/grandine/releases" ;;
    esac
    echo "   You can adjust the version in the .env file after installation."
    echo
    
    if tui_yesno "Version Confirmation" "Use latest version ($latest_version) for $client?"; then
        echo "$client:$latest_version"
    else
        local custom_version
        custom_version=$(tui_inputbox "Custom Version" "Enter $client version:" "$latest_version")
        echo "$client:$custom_version"
    fi
}

print_header() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                 ETHEREUM NODE INSTALLER                       ║"
    echo "║                     Version $SCRIPT_VERSION                           ║"
    echo "║                                                               ║"
    echo "║  Automated multi-instance Ethereum node setup with Docker    ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should not be run as root"
        exit 1
    fi
}

# Check prerequisites with detailed feedback
check_prerequisites() {
    log_task_start "System prerequisites check"
    
    local missing_tools=()
    
    # Check for required tools
    echo "  Checking required tools..."
    for tool in docker docker-compose wget curl openssl ufw; do
        echo -n "    $tool: "
        if command -v "$tool" &> /dev/null; then
            echo -e "${GREEN}found${NC}"
        else
            echo -e "${RED}missing${NC}"
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_task_error "Prerequisites check" "Missing tools: ${missing_tools[*]}"
        echo
        echo -e "${YELLOW}Installation commands:${NC}"
        echo "Ubuntu/Debian: sudo apt update && sudo apt install -y docker.io docker-compose wget curl openssl ufw"
        echo "CentOS/RHEL: sudo yum install -y docker docker-compose wget curl openssl firewalld"
        exit 1
    fi
    
    # Check Docker daemon
    echo "  Checking Docker daemon..."
    if docker ps &> /dev/null; then
        echo -e "    Docker: ${GREEN}running${NC}"
    else
        log_task_error "Docker check" "Docker daemon not running or permission denied"
        echo
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "1. Start Docker: sudo systemctl start docker"
        echo "2. Add user to docker group: sudo usermod -aG docker $USER"
        echo "3. Logout and login again"
        exit 1
    fi
    
    log_task_success "System prerequisites check"
}

# Comprehensive Ethereum node detection
detect_existing_instances() {
    log_info "Scanning for existing Ethereum node instances..."
    
    local instances=()
    local all_used_ports=()
    
    # Method 1: Scan for directories with Ethereum configs
    log_debug "Checking directories for Ethereum configurations..."
    for dir in "$HOME"/*; do
        if [[ -d "$dir" ]]; then
            local dir_name=$(basename "$dir")
            
            # Check for Ethereum-related files
            if [[ -f "$dir/.env" ]] || [[ -f "$dir/docker-compose.yml" ]] || [[ -f "$dir/compose.yml" ]]; then
                # Look for Ethereum client indicators in config files
                if grep -qE "(reth|besu|nethermind|geth|erigon|lodestar|lighthouse|teku|prysm|nimbus|grandine)" "$dir"/* 2>/dev/null; then
                    instances+=("$dir_name:DIR")
                    log_debug "Found Ethereum config in: $dir_name"
                fi
            fi
        fi
    done
    
    # Method 2: Check running Docker containers
    log_debug "Checking running Docker containers..."
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        local eth_containers=$(docker ps --format "table {{.Names}}\t{{.Image}}" | grep -iE "(reth|besu|nethermind|geth|erigon|lodestar|lighthouse|teku|prysm|nimbus|grandine)" || true)
        
        if [[ -n "$eth_containers" ]]; then
            log_debug "Running Ethereum containers found:"
            echo "$eth_containers" | while read -r container; do
                local container_name=$(echo "$container" | awk '{print $1}')
                local base_name=$(echo "$container_name" | sed 's/-\(reth\|besu\|nethermind\|geth\|erigon\|lodestar\|lighthouse\|teku\|prysm\|nimbus\|grandine\)$//')
                instances+=("$base_name:CONTAINER")
                log_debug "Active container: $container_name (base: $base_name)"
            done
        fi
    fi
    
    # Method 3: Check system users (created by previous installations)
    log_debug "Checking system users..."
    local eth_users=$(getent passwd | grep -E "ethnode|eth-|ethereum" | cut -d':' -f1 || true)
    if [[ -n "$eth_users" ]]; then
        while read -r user; do
            if [[ -n "$user" ]]; then
                instances+=("$user:USER")
                log_debug "Found Ethereum user: $user"
            fi
        done <<< "$eth_users"
    fi
    
    # Method 4: Scan for used ports that Ethereum nodes commonly use
    log_debug "Scanning for Ethereum-related ports in use..."
    local common_ports=(8545 8546 8551 5052 9000 18550 30303)
    for port in "${common_ports[@]}"; do
        local port_range_start=$port
        local port_range_end=$((port + 10))
        
        for ((p=port_range_start; p<=port_range_end; p++)); do
            if netstat -tuln 2>/dev/null | grep -q ":${p} "; then
                # Try to identify what's using this port
                local process_info=$(netstat -tulnp 2>/dev/null | grep ":${p} " | head -1 || true)
                if echo "$process_info" | grep -qE "(docker|containerd)"; then
                    all_used_ports+=("$p")
                    log_debug "Port $p in use (likely Ethereum-related)"
                fi
            fi
        done
    done
    
    # Remove duplicates and clean up instance list
    local unique_instances=($(printf '%s\n' "${instances[@]}" | cut -d':' -f1 | sort -u))
    
    if [[ ${#unique_instances[@]} -gt 0 ]]; then
        log_info "Found existing Ethereum instances: ${unique_instances[*]}"
        echo
        echo "Port usage detected:"
        printf '%s\n' "${all_used_ports[@]}" | sort -n | tr '\n' ' '
        echo
        return 0
    else
        log_info "No existing Ethereum instances found"
        return 1
    fi
}

# Get all ports currently in use by any process
get_all_used_ports() {
    netstat -tuln 2>/dev/null | awk '/LISTEN/ {print $4}' | sed 's/.*://' | sort -n | uniq
}

# Check if a specific port is available
is_port_available() {
    local port=$1
    ! netstat -tuln 2>/dev/null | grep -q ":${port} "
}

# Find next available port starting from a base port
find_next_available_port() {
    local base_port=$1
    local port=$base_port
    
    while ! is_port_available $port; do
        ((port++))
        # Safety check to prevent infinite loop
        if ((port > 65535)); then
            log_error "No available ports found starting from $base_port"
            return 1
        fi
    done
    
    echo $port
}

# Smart port assignment that avoids conflicts
get_available_ports() {
    local node_name="$1"
    local user_el_p2p="$2"
    local user_cl_p2p="$3"
    local user_ws_port="$4"
    
    log_info "Calculating available ports..."
    
    # Extract instance number if following ethnode pattern
    local instance_num=1
    if [[ "$node_name" =~ ethnode([0-9]+) ]]; then
        instance_num="${BASH_REMATCH[1]}"
    fi
    
    # Calculate base ports with offset
    local base_offset=$((instance_num - 1))
    
    # Find available ports, starting from calculated bases
    local el_rpc_port=$(find_next_available_port $((8545 + base_offset)))
    local ee_port=$(find_next_available_port $((8551 + base_offset)))
    local cl_rest_port=$(find_next_available_port $((5052 + base_offset)))
    local mevboost_port=$(find_next_available_port $((18550 + base_offset)))
    
    # Use user-specified ports for P2P and WS (they should have checked these)
    local el_p2p_port="$user_el_p2p"
    local cl_p2p_port="$user_cl_p2p"
    local ws_port="$user_ws_port"
    
    # Calculate dependent ports
    local el_p2p_port_2=$((el_p2p_port + 1))
    local cl_quic_port=$((cl_p2p_port + 1))
    
    # Verify user-specified ports are actually available
    if ! is_port_available "$el_p2p_port"; then
        log_warn "EL P2P port $el_p2p_port is already in use!"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    if ! is_port_available "$cl_p2p_port"; then
        log_warn "CL P2P port $cl_p2p_port is already in use!"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    if ! is_port_available "$ws_port"; then
        log_warn "WebSocket port $ws_port is already in use!"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    log_debug "Assigned ports - RPC:$el_rpc_port WS:$ws_port EE:$ee_port REST:$cl_rest_port"
    
    echo "$el_rpc_port:$ws_port:$ee_port:$el_p2p_port:$el_p2p_port_2:$cl_rest_port:$cl_p2p_port:$cl_quic_port:$mevboost_port"
}

# Get next available instance number
get_next_instance_number() {
    local num=1
    while [[ -d "$HOME/ethnode${num}" ]]; do
        ((num++))
    done
    echo $num
}

# Interactive prompts
prompt_node_name() {
    local default_name="ethnode$(get_next_instance_number)"
    
    echo
    echo -e "${BOLD}Node Configuration${NC}"
    echo "=================="
    
    while true; do
        read -p "Enter node name (default: $default_name): " node_name
        node_name=${node_name:-$default_name}
        
        # Validate name
        if [[ "$node_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            if [[ ! -d "$HOME/$node_name" ]]; then
                break
            else
                log_error "Directory $HOME/$node_name already exists"
            fi
        else
            log_error "Invalid name. Use only letters, numbers, hyphens, and underscores"
        fi
    done
    
    echo "$node_name"
}

prompt_network() {
    echo
    echo "Available Networks:"
    echo "1) hoodi    - Hoodi testnet (recommended for testing)"
    echo "2) mainnet  - Ethereum mainnet (real ETH, higher requirements)"
    
    while true; do
        read -p "Select network (1-2, default: 1): " network_choice
        network_choice=${network_choice:-1}
        
        case $network_choice in
            1) echo "hoodi"; break ;;
            2) echo "mainnet"; break ;;
            *) log_error "Invalid choice. Please enter 1 or 2" ;;
        esac
    done
}

prompt_execution_client() {
    echo
    echo "Available Execution Clients:"
    echo "1) reth        - Fast, Rust-based (recommended)"
    echo "2) besu        - Java-based, enterprise features"
    echo "3) nethermind  - C#-based, Windows friendly"
    
    while true; do
        read -p "Select execution client (1-3, default: 1): " exec_choice
        exec_choice=${exec_choice:-1}
        
        case $exec_choice in
            1) echo "reth"; break ;;
            2) echo "besu"; break ;;
            3) echo "nethermind"; break ;;
            *) log_error "Invalid choice. Please enter 1-3" ;;
        esac
    done
}

prompt_consensus_client() {
    echo
    echo "Available Consensus Clients:"
    echo "1) lodestar  - TypeScript-based, feature-rich (recommended)"
    echo "2) teku      - Java-based, enterprise features"
    echo "3) grandine  - Rust-based, high performance"
    
    while true; do
        read -p "Select consensus client (1-3, default: 1): " cons_choice
        cons_choice=${cons_choice:-1}
        
        case $cons_choice in
            1) echo "lodestar"; break ;;
            2) echo "teku"; break ;;
            3) echo "grandine"; break ;;
            *) log_error "Invalid choice. Please enter 1-3" ;;
        esac
    done
}

prompt_ports() {
    local node_name="$1"
    
    echo
    echo -e "${BOLD}Port Configuration${NC}"
    echo "=================="
    echo "These ports need to be forwarded in your router for optimal P2P connectivity:"
    echo
    
    # Get all currently used ports
    local used_ports=($(get_all_used_ports))
    
    if [[ ${#used_ports[@]} -gt 0 ]]; then
        log_info "Ports currently in use: $(echo "${used_ports[@]}" | tr ' ' ',' | head -c 100)..."
    fi
    
    # Calculate suggested defaults that avoid conflicts
    local instance_num=$(echo "$node_name" | sed 's/ethnode//')
    instance_num=${instance_num:-1}
    
    local suggested_el_p2p=$(find_next_available_port $((30303 + instance_num - 1)))
    local suggested_cl_p2p=$(find_next_available_port $((9000 + (instance_num - 1) * 3)))
    local suggested_ws_port=$(find_next_available_port $((8546 + instance_num - 1)))
    
    echo "Suggested ports (automatically checked for conflicts):"
    echo "  EL P2P: $suggested_el_p2p"
    echo "  CL P2P: $suggested_cl_p2p" 
    echo "  WebSocket: $suggested_ws_port"
    echo
    
    while true; do
        read -p "Execution Layer P2P port (default: $suggested_el_p2p): " el_p2p_port
        el_p2p_port=${el_p2p_port:-$suggested_el_p2p}
        
        if [[ "$el_p2p_port" =~ ^[0-9]+$ ]] && (( el_p2p_port >= 1024 && el_p2p_port <= 65535 )); then
            if ! is_port_available "$el_p2p_port"; then
                log_warn "Port $el_p2p_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    while true; do
        read -p "Consensus Layer P2P port (default: $suggested_cl_p2p): " cl_p2p_port
        cl_p2p_port=${cl_p2p_port:-$suggested_cl_p2p}
        
        if [[ "$cl_p2p_port" =~ ^[0-9]+$ ]] && (( cl_p2p_port >= 1024 && cl_p2p_port <= 65535 )); then
            if ! is_port_available "$cl_p2p_port"; then
                log_warn "Port $cl_p2p_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    while true; do
        read -p "WebSocket port (default: $suggested_ws_port): " ws_port
        ws_port=${ws_port:-$suggested_ws_port}
        
        if [[ "$ws_port" =~ ^[0-9]+$ ]] && (( ws_port >= 1024 && ws_port <= 65535 )); then
            if ! is_port_available "$ws_port"; then
                log_warn "Port $ws_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    echo "$el_p2p_port:$cl_p2p_port:$ws_port"
}

# Download file from GitHub
download_file() {
    local file_path="$1"
    local dest_path="$2"
    local url="${REPO_URL}/${file_path}"
    
    log_debug "Downloading: $url -> $dest_path"
    
    if command -v curl &> /dev/null; then
        curl -sSL "$url" -o "$dest_path" || {
            log_error "Failed to download $file_path"
            return 1
        }
    elif command -v wget &> /dev/null; then
        wget -q "$url" -O "$dest_path" || {
            log_error "Failed to download $file_path"
            return 1
        }
    else
        log_error "Neither curl nor wget available"
        return 1
    fi
}

# Create directory structure
create_directories() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"
    
    log_info "Creating directory structure for $node_name"
    
    mkdir -p "$node_dir"/{data/{execution,consensus},jwt,data/execution/logs}
    
    echo "$node_dir"
}

# Create system user
create_user() {
    local node_name="$1"
    
    log_info "Creating system user: $node_name"
    
    if ! id "$node_name" &>/dev/null; then
        sudo useradd -r -s /bin/false "$node_name"
    fi
    
    local node_uid=$(id -u "$node_name")
    local node_gid=$(id -g "$node_name")
    
    echo "${node_uid}:${node_gid}"
}

# Generate JWT secret
generate_jwt() {
    local node_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    
    log_info "Generating JWT secret"
    
    openssl rand -hex 32 > "$node_dir/jwt/jwtsecret"
    sudo chown "$node_uid:$node_gid" "$node_dir/jwt/jwtsecret"
    chmod 600 "$node_dir/jwt/jwtsecret"
}

# Download and configure files
download_config_files() {
    local node_dir="$1"
    local execution_client="$2"
    local consensus_client="$3"
    
    log_info "Downloading configuration files..."
    
    # Download base files
    download_file "compose.yml" "$node_dir/compose.yml"
    download_file "mevboost.yml" "$node_dir/mevboost.yml"
    
    # Download client-specific files
    download_file "${execution_client}.yml" "$node_dir/${execution_client}.yml"
    download_file "${consensus_client}-cl-only.yml" "$node_dir/${consensus_client}-cl-only.yml"
}

# Configure relay settings based on network
configure_relays() {
    local env_file="$1"
    local network="$2"
    
    log_info "Configuring MEV relays for $network network"
    
    if [[ "$network" == "hoodi" ]]; then
        # Ensure hoodi relays are uncommented and mainnet relays are commented
        sed -i '/# Hoodi relays/,/^$/ {
            /^MEVBOOST_RELAY=.*boost-relay-hoodi/s/^#*//
            /^MEVBOOST_RELAY=.*hoodi\.aestus/s/^#*//
            /^MEVBOOST_RELAY=.*hoodi\.titanrelay/s/^#*//
        }' "$env_file"
        
        sed -i '/# Mainnet relays/,/^$/ {
            /^MEVBOOST_RELAY=/s/^/#/
        }' "$env_file"
        
        # Also comment the multiline mainnet relay if it exists
        sed -i '/^MEVBOOST_RELAY=.*bloxroute\|flashbots\|securerpc\|ultrasound\|agnostic\|titanrelay/ {
            /hoodi/!s/^/#/
        }' "$env_file"
        
    else  # mainnet
        # Comment out hoodi relays, uncomment mainnet relays
        sed -i '/# Hoodi relays/,/^$/ {
            /^MEVBOOST_RELAY=/s/^/#/
        }' "$env_file"
        
        sed -i '/# Mainnet relays/,/^$/ {
            /^#*MEVBOOST_RELAY=/s/^#*//
        }' "$env_file"
        
        # Handle the multiline mainnet relay configuration
        sed -i '/^#*MEVBOOST_RELAY=.*bloxroute\|flashbots\|securerpc\|ultrasound\|agnostic\|titanrelay/ {
            /hoodi/s/^/#/
            /hoodi/!s/^#*//
        }' "$env_file"
    fi
}

# Create and customize .env file
create_env_file() {
    local node_dir="$1"
    local node_name="$2"
    local node_uid="$3"
    local node_gid="$4"
    local execution_client="$5"
    local consensus_client="$6"
    local network="$7"
    local user_ports="$8"
    
    log_info "Creating .env configuration"
    
    # Download template .env file
    download_file "default.env" "$node_dir/.env"
    
    # Parse user-specified ports
    local el_p2p_port=$(echo "$user_ports" | cut -d':' -f1)
    local cl_p2p_port=$(echo "$user_ports" | cut -d':' -f2)
    local ws_port=$(echo "$user_ports" | cut -d':' -f3)
    
    # Get available ports for internal services
    local available_ports=$(get_available_ports "$node_name" "$el_p2p_port" "$cl_p2p_port" "$ws_port")
    
    # Parse calculated ports
    local el_rpc_port=$(echo "$available_ports" | cut -d':' -f1)
    local ee_port=$(echo "$available_ports" | cut -d':' -f3)
    local cl_rest_port=$(echo "$available_ports" | cut -d':' -f6)
    local mevboost_port=$(echo "$available_ports" | cut -d':' -f9)
    local el_p2p_port_2=$((el_p2p_port + 1))
    local cl_quic_port=$((cl_p2p_port + 1))
    
    # Build compose file string
    local compose_files="compose.yml:${execution_client}.yml:${consensus_client}-cl-only.yml:mevboost.yml"
    
    # Replace template variables
    sed -i "s/{{NODE_NAME}}/$node_name/g" "$node_dir/.env"
    sed -i "s/{{NODE_UID}}/$node_uid/g" "$node_dir/.env"
    sed -i "s/{{NODE_GID}}/$node_gid/g" "$node_dir/.env"
    sed -i "s|{{COMPOSE_FILE}}|$compose_files|g" "$node_dir/.env"
    sed -i "s/{{NETWORK}}/$network/g" "$node_dir/.env"
    sed -i "s/{{EL_RPC_PORT}}/$el_rpc_port/g" "$node_dir/.env"
    sed -i "s/{{EL_WS_PORT}}/$ws_port/g" "$node_dir/.env"
    sed -i "s/{{EE_PORT}}/$ee_port/g" "$node_dir/.env"
    sed -i "s/{{EL_P2P_PORT}}/$el_p2p_port/g" "$node_dir/.env"
    sed -i "s/{{EL_P2P_PORT_2}}/$el_p2p_port_2/g" "$node_dir/.env"
    sed -i "s/{{CL_REST_PORT}}/$cl_rest_port/g" "$node_dir/.env"
    sed -i "s/{{CL_P2P_PORT}}/$cl_p2p_port/g" "$node_dir/.env"
    sed -i "s/{{CL_QUIC_PORT}}/$cl_quic_port/g" "$node_dir/.env"
    sed -i "s/{{MEVBOOST_PORT}}/$mevboost_port/g" "$node_dir/.env"
    sed -i "s/{{EXECUTION_ALIAS}}/$node_name/g" "$node_dir/.env"
    sed -i "s/{{CONSENSUS_ALIAS}}/$node_name/g" "$node_dir/.env"
    
    # Configure relays based on network
    configure_relays "$node_dir/.env" "$network"
    
    # Set checkpoint sync URL based on network
    if [[ "$network" == "hoodi" ]]; then
        sed -i "s|{{CHECKPOINT_SYNC_URL}}|https://hoodi.beaconstate.ethstaker.cc/|g" "$node_dir/.env"
    else
        sed -i "s|{{CHECKPOINT_SYNC_URL}}|https://beaconstate.ethstaker.cc/|g" "$node_dir/.env"
    fi
    
    # Store final port assignments for user display
    echo "$el_rpc_port:$ws_port:$ee_port:$el_p2p_port:$el_p2p_port_2:$cl_rest_port:$cl_p2p_port:$cl_quic_port:$mevboost_port"
}

# Set directory permissions
set_permissions() {
    local node_dir="$1"
    local node_uid="$2"
    local node_gid="$3"
    
    log_info "Setting directory permissions"
    
    sudo chown -R "$node_uid:$node_gid" "$node_dir"/{data,jwt}
}

# Configure firewall
configure_firewall() {
    local ports="$1"
    local node_name="$2"
    
    log_info "Configuring firewall rules"
    
    local el_p2p_port=$(echo "$ports" | cut -d':' -f1)
    local cl_p2p_port=$(echo "$ports" | cut -d':' -f2)
    local el_p2p_port_2=$((el_p2p_port + 1))
    local cl_quic_port=$((cl_p2p_port + 1))
    
    sudo ufw allow "$el_p2p_port/tcp" comment "$node_name EL P2P TCP"
    sudo ufw allow "$el_p2p_port/udp" comment "$node_name EL P2P UDP"
    sudo ufw allow "$el_p2p_port_2/udp" comment "$node_name EL P2P2 UDP"
    sudo ufw allow "$cl_p2p_port/tcp" comment "$node_name CL P2P TCP"
    sudo ufw allow "$cl_p2p_port/udp" comment "$node_name CL P2P UDP"
    sudo ufw allow "$cl_quic_port/udp" comment "$node_name CL QUIC UDP"
}

# Main setup process
main_setup() {
    print_header
    
    # Detect existing instances first
    detect_existing_instances
    
    echo
    log_info "Starting interactive setup..."
    
    # Get user preferences
    local node_name=$(prompt_node_name)
    local network=$(prompt_network)
    local execution_client=$(prompt_execution_client)
    local consensus_client=$(prompt_consensus_client)
    local ports=$(prompt_ports "$node_name")
    
    # Confirm settings
    echo
    echo -e "${BOLD}Configuration Summary${NC}"
    echo "====================="
    echo "Node name: $node_name"
    echo "Network: $network"
    echo "Execution client: $execution_client"
    echo "Consensus client: $consensus_client"
    echo "Ports (EL P2P/CL P2P/WS): $ports"
    echo
    
    read -p "Continue with installation? (y/N): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled"
        exit 0
    fi
    
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
    create_env_file "$node_dir" "$node_name" "$node_uid" "$node_gid" \
                   "$execution_client" "$consensus_client" "$network" "$ports"
    
    # Set permissions
    set_permissions "$node_dir" "$node_uid" "$node_gid"
    
    # Configure firewall
    configure_firewall "$ports" "$node_name"
    
    # Installation complete
    echo
    echo -e "${GREEN}${BOLD}✓ Installation Complete!${NC}"
    echo
    echo -e "${BOLD}Next Steps:${NC}"
    echo "1. Review configuration: nano $node_dir/.env"
    echo "2. Start your node: cd $node_dir && docker compose up -d"
    echo "3. View logs: docker compose logs -f"
    echo "4. Forward these ports in your router:"
    echo "   - EL P2P: $(echo "$ports" | cut -d':' -f1) (TCP + UDP)"
    echo "   - CL P2P: $(echo "$ports" | cut -d':' -f2) (TCP + UDP)"
    echo
    echo -e "${YELLOW}⚠️  Important:${NC}"
    echo "- Initial sync can take several hours to days"
    echo "- Monitor disk space (requires 100GB+ for mainnet)"
    echo "- Keep your system updated and secure"
    echo
    echo "Node directory: $node_dir"
}

# Main menu system
show_main_menu() {
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
    
    while true; do
        read -p "Select option (1-5, default: 1): " menu_choice
        menu_choice=${menu_choice:-1}
        
        case $menu_choice in
            1) return 1 ;; # Launch new ethnode
            2) return 2 ;; # Update ethnode
            3) return 3 ;; # Remove ethnode
            4) return 4 ;; # Show status
            5) return 5 ;; # Exit
            *) echo -e "${RED}Invalid choice. Please enter 1-5${NC}" ;;
        esac
    done
}

# Update ethnode function
update_ethnode() {
    echo
    echo -e "${CYAN}${BOLD}ETHNODE UPDATE${NC}"
    echo "==============="
    echo
    
    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            nodes+=($(basename "$dir"))
        fi
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No existing nodes found to update.${NC}"
        read -p "Press Enter to continue..."
        return
    fi
    
    echo "Available nodes to update:"
    for i in "${!nodes[@]}"; do
        echo "$((i+1))) ${nodes[i]}"
    done
    echo
    
    while true; do
        read -p "Select node to update (1-${#nodes[@]}): " node_choice
        if [[ "$node_choice" =~ ^[0-9]+$ ]] && (( node_choice >= 1 && node_choice <= ${#nodes[@]} )); then
            local selected_node="${nodes[$((node_choice-1))]}"
            break
        else
            echo -e "${RED}Invalid choice. Please enter 1-${#nodes[@]}${NC}"
        fi
    done
    
    echo
    echo "Updating $selected_node..."
    echo
    
    # Stop the node
    show_working "Stopping $selected_node containers" 2
    cd "$HOME/$selected_node" && docker compose down >/dev/null 2>&1
    
    # Download latest configurations
    show_working "Downloading latest configuration files" 3
    
    # Backup current .env
    cp ".env" ".env.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Download fresh configs (but preserve .env)
    download_file "compose.yml" "compose.yml"
    download_file "mevboost.yml" "mevboost.yml"
    
    # Get client types from current .env to download correct configs
    local compose_file=$(grep "COMPOSE_FILE=" ".env" | cut -d'=' -f2)
    if [[ "$compose_file" == *"reth"* ]]; then
        download_file "reth.yml" "reth.yml"
    fi
    if [[ "$compose_file" == *"besu"* ]]; then
        download_file "besu.yml" "besu.yml"
    fi
    if [[ "$compose_file" == *"nethermind"* ]]; then
        download_file "nethermind.yml" "nethermind.yml"
    fi
    if [[ "$compose_file" == *"lodestar"* ]]; then
        download_file "lodestar-cl-only.yml" "lodestar-cl-only.yml"
    fi
    if [[ "$compose_file" == *"teku"* ]]; then
        download_file "teku-cl-only.yml" "teku-cl-only.yml"
    fi
    if [[ "$compose_file" == *"grandine"* ]]; then
        download_file "grandine-cl-only.yml" "grandine-cl-only.yml"
    fi
    
    # Pull latest images
    show_working "Pulling latest Docker images" 5
    docker compose pull >/dev/null 2>&1
    
    echo -e "${GREEN}✓${NC} Update completed for $selected_node"
    echo
    echo "The node has been updated but is currently stopped."
    echo "Configuration backup saved as .env.backup.$(date +%Y%m%d_%H%M%S)"
    echo
    
    if tui_yesno "Start Node" "Start $selected_node now?"; then
        show_working "Starting updated node" 3
        docker compose up -d >/dev/null 2>&1
        echo -e "${GREEN}✓${NC} $selected_node started successfully"
    fi
    
    echo
    read -p "Press Enter to continue..."
}

# Main execution
main() {
    # Check if running as root
    if [[ $EUID -eq 0 ]]; then
        echo -e "${RED}This script should not be run as root${NC}"
        exit 1
    fi
    
    # Check prerequisites
    check_prerequisites
    
    # Show main menu and handle user choice
    show_main_menu
    local choice=$?
    
    case $choice in
        1) # Launch new ethnode
            main_setup
            ;;
        2) # Update ethnode
            update_ethnode
            ;;
        3) # Remove ethnode
            remove_ethnode
            ;;
        4) # Show status
            show_node_summary
            read -p "Press Enter to continue..."
            ;;
        5) # Exit
            echo
            echo -e "${CYAN}Thanks for using NODEBOI!${NC}"
            exit 0
            ;;
    esac
    
    # After completing an action, show menu again unless it was a new installation
    if [[ $choice -ne 1 ]]; then
        main
    fi
}

# Run main function
main "$@"
