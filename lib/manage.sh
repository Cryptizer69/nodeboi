#!/bin/bash
# lib/manage.sh - Node management and monitoring

# Source dependencies
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null || true
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh" 2>/dev/null || true

# Pre-load monitoring functions to ensure they're always available
for monitoring_path in "${NODEBOI_LIB}/monitoring.sh" "lib/monitoring.sh" "$(dirname "${BASH_SOURCE[0]}")/monitoring.sh" "$HOME/.nodeboi/lib/monitoring.sh"; do
    [[ -f "$monitoring_path" ]] && source "$monitoring_path" 2>/dev/null && break
done

# Configuration
CHECK_UPDATES="${CHECK_UPDATES:-true}"

# Safe log viewer with proper Ctrl+C handling
safe_view_logs() {
    local log_command="$*"
    local log_pid
    
    # Function to kill logs and return
    kill_logs_and_return() {
        echo -e "\n${UI_MUTED}Exiting log view...${NC}"
        [[ -n "$log_pid" ]] && kill "$log_pid" 2>/dev/null
        trap - INT  # Reset trap
        return 0
    }
    
    # Trap SIGINT (Ctrl+C) to cleanup and return to menu
    trap 'kill_logs_and_return' INT
    
    # Start log command in background
    eval "$log_command" &
    log_pid=$!
    
    # Wait for the process
    wait "$log_pid" 2>/dev/null
    
    # Reset trap
    trap - INT
}

check_prerequisites() {
    echo -e "${UI_MUTED}Checking system prerequisites${NC}"
    local missing_tools=()
    local install_docker=false

    for tool in wget curl openssl; do
        if command -v "$tool" &> /dev/null; then
            echo -e "  ${UI_MUTED}$tool: ${GREEN}✓${NC}"
        else
            echo -e "  ${UI_MUTED}$tool: ${RED}✗${NC}"
            missing_tools+=("$tool")
        fi
    done

    # Check Docker and Docker Compose v2
    if command -v docker &> /dev/null; then
        echo -e "  ${UI_MUTED}docker: ${GREEN}✓${NC}"

        # Check for Docker Compose v2 (comes with Docker)
        if docker compose version &>/dev/null 2>&1; then
            echo -e "  ${UI_MUTED}docker compose: ${GREEN}✓${NC}"
        else
            echo -e "  ${UI_MUTED}docker compose: ${RED}✗${NC}"
            echo -e "  ${YELLOW}Docker is installed but Compose v2 is missing${NC}"
            install_docker=true
        fi
    else
        echo -e "  ${UI_MUTED}docker: ${RED}✗${NC}"
        echo -e "  ${UI_MUTED}docker compose: ${RED}✗${NC}"
        install_docker=true
    fi

    # Auto-install missing tools if any
    if [[ ${#missing_tools[@]} -gt 0 ]] || [[ "$install_docker" == true ]]; then
        echo -e "\n${RED}Missing required tools:${NC}"

        for tool in "${missing_tools[@]}"; do
            case $tool in
                wget) echo -e "${UI_MUTED}  • wget - needed for downloading client binaries${NC}" ;;
                curl) echo -e "${UI_MUTED}  • curl - needed for API calls and version checks${NC}" ;;
                openssl) echo -e "${UI_MUTED}  • openssl - needed for generating JWT secrets${NC}" ;;
            esac
        done

        [[ "$install_docker" == true ]] && echo -e "${UI_MUTED}  • docker/docker compose v2 - essential for running node containers${NC}"

        echo -e "\n${YELLOW}These tools are necessary for running NODEBOI.${NC}"
        read -p "Would you like to install the missing prerequisites now? [y/n]: " -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${UI_MUTED}Installing missing tools...${NC}"

            sudo apt update

            if [[ ${#missing_tools[@]} -gt 0 ]]; then
                sudo apt install -y "${missing_tools[@]}"
            fi

            if [[ "$install_docker" == true ]]; then
                echo -e "${UI_MUTED}Setting up Docker with Compose v2...${NC}"
                
                # Check if Ubuntu's docker.io package is installed
                if apt list --installed 2>/dev/null | grep -q "docker.io/"; then
                    echo -e "${UI_MUTED}Detected Ubuntu Docker package, adding Compose v2...${NC}"
                    sudo apt install -y docker-compose-plugin
                    echo -e "${GREEN}✓ Enhanced Ubuntu Docker with Compose v2${NC}"
                elif command -v docker >/dev/null; then
                    echo -e "${UI_MUTED}Detected existing Docker installation, adding Compose v2...${NC}"
                    sudo apt install -y docker-compose-plugin
                    echo -e "${GREEN}✓ Added Compose v2 to existing Docker${NC}"
                else
                    echo -e "${UI_MUTED}Installing official Docker + Compose v2 (this may take a few minutes)...${NC}"
                    curl -fsSL https://get.docker.com | sudo sh
                    sudo apt install -y docker-compose-plugin
                    echo -e "${GREEN}✓ Installed official Docker + Compose v2${NC}"
                fi
                
                # Ensure user is in docker group (safe to run multiple times)
                sudo usermod -aG docker $USER
                echo -e "${YELLOW}⚠ Important: You'll need to log out and back in for Docker permissions to take effect.${NC}"
                echo -e "${UI_MUTED}Or run: newgrp docker${NC}"
            fi

            echo -e "${GREEN}✓ Prerequisites installed successfully${NC}"

            if [[ "$install_docker" == true ]]; then
                echo -e "${YELLOW}Note: If Docker commands fail, please log out and back in first.${NC}"
            fi
        else
            echo -e "${RED}[ERROR]${NC} Cannot proceed without required tools."
            echo -e "${UI_MUTED}To install manually, run:${NC}"
            echo -e "${UI_MUTED}  sudo apt update && sudo apt install -y ${missing_tools[*]}${NC}"
            [[ "$install_docker" == true ]] && echo -e "${UI_MUTED}  sudo apt install -y docker-compose-plugin  # if you have docker.io${NC}"
            [[ "$install_docker" == true ]] && echo -e "${UI_MUTED}  curl -fsSL https://get.docker.com | sudo sh && sudo apt install -y docker-compose-plugin  # for new install${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✓${NC} ${UI_MUTED}All prerequisites satisfied${NC}"
    fi
}


safe_docker_stop() {
    local node_name=$1
    local node_dir="$HOME/$node_name"

    echo -e "${UI_MUTED}Stopping $node_name...${NC}"
    cd "$node_dir" 2>/dev/null || return 1

    # Try graceful stop with 30 second timeout
    if ! timeout 30 docker compose down 2>/dev/null; then
        echo -e "${UI_MUTED}  Graceful stop failed, forcing stop...${NC}"

        # Get container names and force stop
        local containers=$(docker compose ps -q 2>/dev/null)
        if [[ -n "$containers" ]]; then
            echo "$containers" | xargs -r docker kill 2>/dev/null || true
        fi

        # Now try down again to clean up
        docker compose down -v 2>/dev/null || true
    fi

    return 0
}
remove_node() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"

    # Temporarily disable exit on error for cleanup operations
    set +e
    
    echo -e "${UI_MUTED}Removing $node_name...${NC}" >&2

    # Stop and remove containers using docker compose down
    if [[ -f "$node_dir/compose.yml" ]]; then
        echo -e "${UI_MUTED}  Stopping containers...${NC}" >&2
        # Force immediate kill for menu removal (no graceful wait)
        cd "$node_dir" && { 
            local containers=$(docker compose ps -q 2>/dev/null)
            [[ -n "$containers" ]] && echo "$containers" | xargs -r docker kill 2>/dev/null || true
            docker compose down -v 2>/dev/null || true
        }
    fi

    # Remove any remaining containers
    echo -e "${UI_MUTED}  Checking for remaining containers...${NC}" >&2
    local containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^${node_name}-" || true)
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read container; do
            echo -e "${UI_MUTED}    Removing container: $container${NC}" >&2
            docker rm -f "$container" 2>/dev/null || true
        done
    fi

    # Remove Docker volumes
    echo -e "${UI_MUTED}  Removing volumes...${NC}" >&2
    local volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^${node_name}" || true)
    if [[ -n "$volumes" ]]; then
        echo "$volumes" | while read volume; do
            echo -e "${UI_MUTED}    Removing volume: $volume${NC}" >&2
            docker volume rm -f "$volume" 2>/dev/null || true
        done
    fi

    # Remove ethnode from monitoring configuration if monitoring exists
    if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        source "${NODEBOI_LIB}/monitoring.sh"
        remove_ethnode_from_monitoring "$node_name"
        
        # Clean up Grafana dashboards and metric data for this ethnode
        cleanup_removed_ethnode_monitoring "$node_name"
    fi
    
    # Update Vero beacon URLs if Vero exists
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        echo -e "${UI_MUTED}  Updating Vero beacon node configuration...${NC}" >&2
        update_vero_after_ethnode_removal "$node_name"
    fi
    
    # Check if nodeboi-net should be removed (when no other services use it)
    echo -e "${UI_MUTED}  Checking nodeboi-net usage...${NC}" >&2
    manage_nodeboi_network_lifecycle "remove" "$node_name"
    
    # Try to remove directory with multiple fallback methods
    if [[ -d "$node_dir" ]]; then
        # Method 1: Try regular removal first
        if rm -rf "$node_dir" 2>/dev/null; then
            echo -e "${UI_MUTED}    Directory removed${NC}" >&2
        else
            # Method 2: Use Docker container to remove files as root
            echo -e "${UI_MUTED}    Trying Docker cleanup for root-owned files...${NC}" >&2
            if docker run --rm -v "$node_dir":/remove alpine sh -c "rm -rf /remove/* && rm -rf /remove/.* 2>/dev/null || true" 2>/dev/null; then
                # Remove the now-empty directory
                rmdir "$node_dir" 2>/dev/null || rm -rf "$node_dir" 2>/dev/null || true
                echo -e "${UI_MUTED}    Directory cleaned with Docker${NC}" >&2
            else
                # Method 3: Ask for sudo permission upfront
                echo -e "${YELLOW}    Some files require admin permissions to remove${NC}" >&2
                echo -e "${UI_MUTED}    You may be prompted for your password...${NC}" >&2
                if sudo rm -rf "$node_dir" 2>/dev/null; then
                    echo -e "${UI_MUTED}    Directory removed with admin permissions${NC}" >&2
                else
                    echo -e "${YELLOW}    Warning: Could not fully clean directory $node_dir${NC}" >&2
                fi
            fi
        fi
    fi
    
    # No system user cleanup needed - using current user pattern

    echo -e "${UI_MUTED}  ✓ $node_name removed successfully${NC}" >&2
    
    # Re-enable exit on error
    set -e
}
remove_nodes_menu() {
    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        clear
        print_header
        print_box "No nodes found to remove." "warning"
        press_enter
        return
    fi

    # Add cancel option
    local menu_options=("${nodes[@]}" "Cancel")
    
    local selection
    if selection=$(fancy_select_menu "Select Node to Remove" "${menu_options[@]}"); then
        # Check if user selected cancel
        if [[ $selection -eq ${#nodes[@]} ]]; then
            return
        fi
        
        local node_to_remove="${nodes[$selection]}"
        
        if fancy_confirm "Remove $node_to_remove? This cannot be undone!" "n"; then
            echo -e "\n${UI_MUTED}Removing $node_to_remove...${NC}\n"
            
            # Use ULCS for removal
            if remove_ethnode_universal "$node_to_remove"; then
                echo -e "${GREEN}Node $node_to_remove removed successfully via ULCS${NC}"
            else
                echo -e "${RED}Removal failed via ULCS, trying legacy method...${NC}"
                remove_node "$node_to_remove"
                
                # Update network connections after legacy removal
                if [[ -f "${NODEBOI_LIB}/network-manager.sh" ]]; then
                    echo -e "${UI_MUTED}Updating service connections...${NC}"
                    set +e  # Temporarily disable exit on error for network management call
                    source "${NODEBOI_LIB}/network-manager.sh" 
                    manage_service_networks silent > /dev/null 2>&1
                    set -e  # Re-enable exit on error
                    echo -e "${UI_MUTED}Service connections updated.${NC}"
                fi
                
                echo -e "${GREEN}Node $node_to_remove removed successfully${NC}"
            fi
            
            force_refresh_dashboard
            
            # Set flag to return to main menu after ULCS operation
            RETURN_TO_MAIN_MENU=true
        else
            echo -e "${GREEN}Removal cancelled${NC}"
        fi
    fi
    
    press_enter
}

# ULCS-compatible ethnode removal function
remove_ethnode_universal() {
    local node_to_remove="$1"
    
    if [[ -z "$node_to_remove" ]]; then
        echo -e "${RED}Error: Node name required${NC}"
        return 1
    fi
    
    echo -e "${UI_MUTED}Starting ethnode removal via Universal Service Lifecycle System...${NC}"
    
    # Set NODEBOI_LIB if not already set
    local NODEBOI_LIB="${NODEBOI_LIB:-$(dirname "${BASH_SOURCE[0]}")}"
    
    # Call Universal Service Lifecycle System for removal
    if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
        source "${NODEBOI_LIB}/ulcs.sh"
        init_service_flows
        
        echo -e "${UI_MUTED}Removing via ULCS...${NC}"
        if remove_service_universal "$node_to_remove" "true" "false"; then
            echo -e "${GREEN}✓ $node_to_remove removed successfully via ULCS${NC}"
            return 0
        else
            echo -e "${RED}✗ Removal failed via ULCS${NC}"
            return 1
        fi
    else
        echo -e "${RED}✗ Universal Service Lifecycle System not available${NC}"
        return 1
    fi
}

check_node_health() {
    local node_dir=$1
    local node_name=$(basename "$node_dir")

    # Get configuration with whitespace trimming
    local el_rpc=$(grep "EL_RPC_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local cl_rest=$(grep "CL_REST_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local network=$(grep "NETWORK=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local host_ip=$(grep "HOST_IP=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    # Parse client names and versions
    local exec_client="unknown"
    local cons_client="unknown"
    local exec_version=""
    local cons_version=""

    if [[ "$compose_file" == *"reth.yml"* ]]; then
        exec_client="Reth"
        exec_version=$(grep "RETH_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"besu.yml"* ]]; then
        exec_client="Besu"
        exec_version=$(grep "BESU_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"nethermind.yml"* ]]; then
        exec_client="Nethermind"
        exec_version=$(grep "NETHERMIND_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    fi

    if [[ "$compose_file" == *"lodestar-cl-only.yml"* ]]; then
        cons_client="Lodestar"
        cons_version=$(grep "LODESTAR_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"teku-cl-only.yml"* ]]; then
        cons_client="Teku"
        cons_version=$(grep "TEKU_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"grandine-cl-only.yml"* ]]; then
        cons_client="Grandine"
        cons_version=$(grep "GRANDINE_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    fi

    # Initialize update indicators 
    local exec_update_indicator=""
    local cons_update_indicator=""

    # Check container status - check if core services are running
    local containers_running=false
    if cd "$node_dir" 2>/dev/null; then
        # Check if execution and consensus services are running (core services)
        local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
        if echo "$running_services" | grep -q "execution" && echo "$running_services" | grep -q "consensus"; then
            containers_running=true
        fi
    fi

    # Initialize status variables
    local el_check="${RED}✗${NC}"
    local cl_check="${RED}✗${NC}"
    local mevboost_check="${RED}✗${NC}"
    local el_sync_status=""
    local cl_sync_status=""
    local mevboost_version="unknown"

    if [[ "$containers_running" == true ]]; then
        # Check execution client health and sync
        local check_host="localhost"
if [[ "$host_ip" != "127.0.0.1" ]] && [[ -n "$host_ip" ]]; then
    if [[ "$host_ip" == "0.0.0.0" ]]; then
        check_host="localhost"  # Still check localhost when bound to all
    else
        check_host="$host_ip"  # Use the LAN IP for checks
    fi
fi
local sync_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    --max-time 0.5 2>/dev/null)

        if [[ -n "$sync_response" ]] && echo "$sync_response" | grep -q '"result"'; then
            # Get actual running version
            local version_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
                --max-time 0.5 2>/dev/null)
            if [[ -n "$version_response" ]] && echo "$version_response" | grep -q '"result"'; then
                local client_version=$(echo "$version_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
                if [[ -n "$client_version" ]]; then
                    # Extract version number from client string (e.g., "Reth/v1.6.0" -> "v1.6.0")
                    exec_version=$(echo "$client_version" | grep -o 'v[0-9][0-9.]*' || echo "$client_version" | grep -o '[0-9][0-9.]*')
                fi
            fi
            
            # Check for error conditions first
            local peer_count_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' \
                --max-time 0.5 2>/dev/null)
            local peer_count="0"
            if [[ -n "$peer_count_response" ]] && echo "$peer_count_response" | grep -q '"result"'; then
                peer_count=$(echo "$peer_count_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
                # Convert hex to decimal
                peer_count=$((${peer_count:-0x0}))
            fi
            
            # Check if syncing (result is not false)
            if ! echo "$sync_response" | grep -q '"result":false'; then
                el_check="${GREEN}✓${NC}"
                el_sync_status=" (Syncing)"
            elif echo "$sync_response" | grep -q '"result":false'; then
                # Check if actually synced or has issues
                local block_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                    -H "Content-Type: application/json" \
                    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                    --max-time 0.5 2>/dev/null)

                if echo "$block_response" | grep -q '"result":"0x0"'; then
                    el_check="${GREEN}✓${NC}"
                    el_sync_status=" (Waiting)"
                elif [[ $peer_count -eq 0 ]]; then
                    # No peers - this is an error condition
                    el_check="${RED}✗${NC}"
                    el_sync_status=" (No Peers)"
                else
                    # Check if latest block is recent (block timestamp vs current time)
                    local latest_block_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                        -H "Content-Type: application/json" \
                        -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
                        --max-time 0.5 2>/dev/null)
                    
                    if [[ -n "$latest_block_response" ]] && echo "$latest_block_response" | grep -q '"timestamp"'; then
                        local block_timestamp_hex=$(echo "$latest_block_response" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4)
                        local block_timestamp=$((${block_timestamp_hex:-0x0}))
                        local current_timestamp=$(date +%s)
                        local age_seconds=$((current_timestamp - block_timestamp))
                        
                        if [[ $age_seconds -gt 600 ]]; then
                            # Block is more than 10 minutes old - execution client is stuck
                            el_check="${RED}✗${NC}"
                            el_sync_status=" (Stalled)"
                        else
                            # Recent block and has peers - healthy
                            el_check="${GREEN}✓${NC}"
                            el_sync_status=""
                        fi
                    else
                        # Can't get block info - fall back to basic checks
                        local current_block_hex=$(echo "$block_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
                        local current_block=$((${current_block_hex:-0x0}))
                        
                        if [[ $current_block -lt 1000 ]]; then
                            el_check="${RED}✗${NC}"
                            el_sync_status=" (Sync Issue)"
                        else
                            el_check="${GREEN}✓${NC}"
                            el_sync_status=""
                        fi
                    fi
                fi
            fi
        elif curl -s -X POST "http://${check_host}:${el_rpc}" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
            --max-time 0.5 2>/dev/null | grep -q '"result"'; then
            el_check="${GREEN}✓${NC}"
            el_sync_status=" (Starting)"
        fi

        # Check consensus client health and sync
        local cl_sync_response=$(curl -s "http://${check_host}:${cl_rest}/eth/v1/node/syncing" --max-time 0.5 2>/dev/null)
        local cl_health_code=$(curl -s -w "%{http_code}" -o /dev/null "http://${check_host}:${cl_rest}/eth/v1/node/health" --max-time 0.5 2>/dev/null)

        if [[ -n "$cl_sync_response" ]]; then
            # Get actual running version
            local cl_version_response=$(curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 0.5 2>/dev/null)
            if [[ -n "$cl_version_response" ]] && echo "$cl_version_response" | grep -q '"data"'; then
                local client_version=$(echo "$cl_version_response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
                if [[ -n "$client_version" ]]; then
                    # Extract version number from client string (e.g., "teku/25.6.0" -> "25.6.0")
                    cons_version=$(echo "$client_version" | grep -o 'v[0-9][0-9.]*' || echo "$client_version" | grep -o '[0-9][0-9.]*' | head -1)
                fi
            fi
            
            # Check for various states - prioritize syncing over EL offline
            # Also check health endpoint for 206 status (syncing or optimistic)
            if echo "$cl_sync_response" | grep -q '"is_syncing":true' || [[ "$cl_health_code" == "206" ]]; then
                cl_check="${GREEN}✓${NC}"
                cl_sync_status=" (Syncing)"
            elif echo "$cl_sync_response" | grep -q '"el_offline":true'; then
                # EL Offline is an error state - show red cross
                cl_check="${RED}✗${NC}"
                cl_sync_status=" (EL Offline)"
            elif echo "$cl_sync_response" | grep -q '"is_optimistic":true'; then
                # Optimistic state - execution layer behind, show warning
                cl_check="${YELLOW}⚠${NC}"
                cl_sync_status=" (Optimistic)"
            else
                # Fully synced - show green checkmark, no status
                cl_check="${GREEN}✓${NC}"
                cl_sync_status=""
            fi
        elif [[ "$cl_health_code" == "206" ]]; then
            # Health endpoint shows syncing (206) even if syncing endpoint failed
            cl_check="${GREEN}✓${NC}"
            cl_sync_status=" (Syncing)"
        elif curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 0.5 2>/dev/null | grep -q '"data"'; then
            cl_check="${GREEN}✓${NC}"
            cl_sync_status=" (Starting)"
        fi

        # Check MEV-boost health using the configured port
        local mevboost_port=$(grep "MEVBOOST_PORT=" "$node_dir/.env" | cut -d'=' -f2)
        local mevboost_response=""
        if [[ -n "$mevboost_port" ]]; then
            mevboost_response=$(curl -s "http://${check_host}:${mevboost_port}/eth/v1/builder/status" --max-time 0.5 2>/dev/null)
        fi
        if [[ -n "$mevboost_response" ]]; then
            mevboost_check="${GREEN}✓${NC}"
            # Try to extract MEV-boost version from docker container
            local container_name=$(docker ps --format "table {{.Names}}" | grep "$node_name-mevboost" | head -1)
            if [[ -n "$container_name" ]]; then
                # Extract version from image tag (e.g., flashbots/mev-boost:1.9 -> 1.9, flashbots/mev-boost:v1.9 -> v1.9)
                mevboost_version=$(docker inspect "$container_name" --format='{{.Config.Image}}' 2>/dev/null | grep -o ':[v]*[0-9][0-9.]*$' | cut -c2- || echo "latest")
                [[ -z "$mevboost_version" ]] && mevboost_version="latest"
            fi
        fi
    fi

    # Determine endpoint display based on HOST_IP with NEW indicators
    local endpoint_host="localhost"
    local access_indicator=""
    local exec_container_host=""
    local cons_container_host=""

    if [[ "$host_ip" == "127.0.0.1" ]]; then
        # For localhost access, show accessible localhost endpoints
        exec_container_host="localhost"
        cons_container_host="localhost"
        access_indicator=" ${GREEN}[M]${NC}"  # My machine only
    elif [[ "$host_ip" == "0.0.0.0" ]]; then
        # Show actual LAN IP if bound to all interfaces
        endpoint_host=$(hostname -I | awk '{print $1}')
        exec_container_host="$endpoint_host"
        cons_container_host="$endpoint_host"
        access_indicator=" ${RED}[A]${NC}"  # All networks
    elif [[ -n "$host_ip" ]]; then
        endpoint_host="$host_ip"
        exec_container_host="$endpoint_host"
        cons_container_host="$endpoint_host"
        access_indicator=" ${UI_WARNING}[L]${UI_RESET}"  # Local network
    fi

    # Check for updates - now after we have real versions from APIs
    if [[ "$CHECK_UPDATES" == "true" ]]; then
        local exec_client_lower=$(echo "$exec_client" | tr '[:upper:]' '[:lower:]')
        local cons_client_lower=$(echo "$cons_client" | tr '[:upper:]' '[:lower:]')

        # Check updates using unified function
        if [[ -n "$exec_client_lower" ]] && [[ "$exec_client_lower" != "unknown" ]]; then
            exec_update_indicator=$(check_service_update "$exec_client_lower" "$exec_version")
        fi

        if [[ -n "$cons_client_lower" ]] && [[ "$cons_client_lower" != "unknown" ]]; then
            cons_update_indicator=$(check_service_update "$cons_client_lower" "$cons_version")
        fi

        # Check MEV-boost updates if it's running
        if [[ "$mevboost_check" == "${GREEN}✓${NC}" ]] && [[ "$mevboost_version" != "unknown" ]]; then
            mevboost_update_indicator=$(check_service_update "mevboost" "$mevboost_version")
        fi
    fi

    # Display status with sync info and correct endpoints
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} $node_name ($network)$access_indicator"

        # Execution client line
        printf "     %b %-25s (%s)%b\t     http://%s:%s\n" \
            "$el_check" "${exec_client}${el_sync_status}" "$(display_version "$exec_client" "$exec_version")" "$exec_update_indicator" "$exec_container_host" "$el_rpc"

        # Consensus client line
        printf "     %b %-25s (%s)%b\t     http://%s:%s\n" \
            "$cl_check" "${cons_client}${cl_sync_status}" "$(display_version "$cons_client" "$cons_version")" "$cons_update_indicator" "$cons_container_host" "$cl_rest"

        # MEV-boost line (only show if it's running)
        if [[ "$mevboost_check" == "${GREEN}✓${NC}" ]]; then
            printf "     %b %-25s (%s)%b\n" \
                "$mevboost_check" "MEV-boost" "$(display_version "mevboost" "$mevboost_version")" "$mevboost_update_indicator"
        fi
    else
        echo -e "  ${RED}●${NC} $node_name ($network) - ${RED}Stopped${NC}"
        printf "     %-25s (%s)%b\n" "$exec_client" "$(display_version "$exec_client" "$exec_version")" "$exec_update_indicator"
        printf "     %-25s (%s)%b\n" "$cons_client" "$(display_version "$cons_client" "$cons_version")" "$cons_update_indicator"
    fi

    echo
}

# Web3signer health check
check_web3signer_health() {
    local service_dir="$1"
    local service_name=$(basename "$service_dir")
    
    # Get configuration
    local port="7500"  # Web3signer always uses hardcoded port 7500
    local network=$(grep "ETH2_NETWORK=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local version=$(grep "WEB3SIGNER_VERSION=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local host_ip=$(grep "HOST_BIND_IP=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    
    # Check container status
    local containers_running=false
    # Check if web3signer container is running (by name)
    if docker ps --filter name=web3signer --filter status=running --format "{{.Names}}" | grep -q "^web3signer$"; then
        containers_running=true
    fi
    
    # Initialize status variables
    local w3s_check="${RED}✗${NC}"
    local access_indicator="[M]"
    
    # Determine access indicator
    if [[ "$host_ip" == "0.0.0.0" ]]; then
        access_indicator="${RED}[A]${NC}"
    elif [[ "$host_ip" != "127.0.0.1" ]]; then
        access_indicator="${UI_WARNING}[L]${UI_RESET}"
    else
        access_indicator="${GREEN}[M]${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        # Check Web3signer API health
        local check_host="localhost"
        if [[ "$host_ip" != "127.0.0.1" ]] && [[ -n "$host_ip" ]]; then
            if [[ "$host_ip" == "0.0.0.0" ]]; then
                check_host="localhost"
            else
                check_host="$host_ip"
            fi
        fi
        
        if curl -s "http://${check_host}:${port}/upcheck" >/dev/null 2>&1; then
            w3s_check="${GREEN}✓${NC}"
        fi
    fi
    
    # Get keystore count
    local keystore_count="?"
    if [[ "$w3s_check" == "${GREEN}✓${NC}" ]]; then
        local keystores_response=$(curl -s "http://${check_host}:${port}/eth/v1/keystores" 2>/dev/null)
        if [[ -n "$keystores_response" ]] && command -v jq >/dev/null 2>&1; then
            keystore_count=$(echo "$keystores_response" | jq '.data | length' 2>/dev/null || echo "?")
        fi
    fi
    
    # Check for updates if running
    local w3s_update_indicator=""
    if [[ "$containers_running" == true ]] && [[ -n "$version" ]]; then
        w3s_update_indicator=$(check_service_update "web3signer" "$version")
    fi
    
    # Display status
    local status_indicator="${GREEN}●${NC}"
    if [[ "$containers_running" == false ]]; then
        status_indicator="${RED}●${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        echo -e "  $status_indicator web3signer ($network) ${access_indicator}"
        printf "     %b %-25s (%s)%b\n" "$w3s_check" "web3signer" "$(display_version "web3signer" "$version")" "$w3s_update_indicator"
        printf "     %s %-20s\n" "" "$keystore_count active keys"
    else
        echo -e "  ${status_indicator} web3signer (${network}) ${access_indicator}"
        echo -e "     ${RED}● Stopped${NC}"
    fi
    echo
}

# Vero health check  
check_vero_health() {
    local service_dir="$1"
    local service_name=$(basename "$service_dir")
    
    # Get configuration
    local metrics_port=$(grep "VERO_METRICS_PORT=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local network=$(grep "ETH2_NETWORK=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local version=$(grep "VERO_VERSION=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local beacon_urls=$(grep "BEACON_NODE_URLS=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local w3s_url=$(grep "WEB3SIGNER_URL=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local fee_recipient=$(grep "FEE_RECIPIENT=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local bind_ip=$(grep "HOST_BIND_IP=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    
    # Check container status
    local containers_running=false
    if cd "$service_dir" 2>/dev/null; then
        # Check if vero service is running
        if docker compose ps --services --filter status=running 2>/dev/null | grep -q "vero"; then
            containers_running=true
        fi
    fi
    
    # Initialize status variables
    local vero_check="${RED}✗${NC}"
    local access_indicator="[M]"
    
    # Determine access indicator
    if [[ "$bind_ip" == "0.0.0.0" ]]; then
        access_indicator="${RED}[A]${NC}"
    elif [[ "$bind_ip" != "127.0.0.1" ]]; then
        access_indicator="${UI_WARNING}[L]${UI_RESET}"
    else
        access_indicator="${GREEN}[M]${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        # Check Vero metrics endpoint
        if curl -s "http://localhost:${metrics_port}/metrics" >/dev/null 2>&1; then
            vero_check="${GREEN}✓${NC}"
        fi
    fi
    
    # Count beacon nodes (handle empty BEACON_NODE_URLS)
    local beacon_count=0
    if [[ -n "$beacon_urls" && "$beacon_urls" != "" ]]; then
        beacon_count=$(echo "$beacon_urls" | tr ',' '\n' | wc -l)
    fi
    
    # Check for updates if running
    local vero_update_indicator=""
    if [[ "$containers_running" == true ]] && [[ -n "$version" ]]; then
        vero_update_indicator=$(check_service_update "vero" "$version")
    fi
    
    # Display status
    local status_indicator="${GREEN}●${NC}"
    if [[ "$containers_running" == false ]]; then
        status_indicator="${RED}●${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        echo -e "  $status_indicator vero ($network) $access_indicator"
        # Check attestation status from Vero metrics
        local attestation_status="not attesting"
        local attestation_check=$(docker exec vero python -c "
import urllib.request
result = 'NOT_ATTESTING'
try:
    response = urllib.request.urlopen('http://localhost:9010/metrics', timeout=2)
    content = response.read().decode()
    for line in content.split('\n'):
        if line.startswith('vc_published_attestations_total'):
            value = float(line.split()[1])
            if value > 0:
                result = 'ATTESTING'
            break
except:
    pass
print(result)
" 2>/dev/null)
        local attestation_indicator="${RED}✗${NC}"
        if [[ "$attestation_check" == "ATTESTING" ]]; then
            attestation_status="attesting"
            attestation_indicator="${GREEN}✓${NC}"
        fi
        printf "     ${attestation_indicator} %-25s (%s)\n" "$attestation_status" "$(display_version "vero" "$version")"
        printf "     %s %-20s\n" "" "Connected to:"
        
        # Handle case where no beacon nodes are configured
        if [[ $beacon_count -eq 0 ]]; then
            printf "     ${YELLOW}⚠️  No beacon nodes configured${NC}\n"
            printf "     ${UI_MUTED}Install an ethnode first${NC}\n"
        else
            # Parse beacon URLs and check if they're reachable
            local beacon_url_list=$(echo "$beacon_urls" | tr ',' ' ')
            local reachable_count=0
            for url in $beacon_url_list; do
                # Extract the container name and port from the URL (e.g., ethnode1-grandine:5052 from http://ethnode1-grandine:5052)
                local container_name=$(echo "$url" | sed 's|http://||g' | sed 's|:.*||g')
                local port=$(echo "$url" | sed 's|.*:||g')
                local display_name=$(echo "$container_name" | sed 's|-[a-z]*||g')  # ethnode1 from ethnode1-grandine
                
                # Simple check: is the container running and configured?
                local is_healthy=false
                
                # Check if container is running
                if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
                    is_healthy=true
                fi
                
                if [[ "$is_healthy" == "true" ]]; then
                    printf "     ${GREEN}✓${NC} %s\n" "$display_name"
                    ((reachable_count++))
                else
                    printf "     ${RED}✗${NC} %s ${WHITE}(waiting)${NC}\n" "$display_name"
                fi
            done
            
            # Show warning if no beacon nodes are reachable
            if [[ $reachable_count -eq 0 ]]; then
                printf "     ${YELLOW}⚠️  No beacon nodes reachable${NC}\n"
                printf "     ${UI_MUTED}Check beacon node ports and network connectivity${NC}\n"
            fi
        fi
    else
        echo -e "  ${status_indicator} vero (${network}) $access_indicator"
        echo -e "     ${RED}● Stopped${NC}"
        
        # Show warning even when stopped if no beacon nodes configured
        if [[ $beacon_count -eq 0 ]]; then
            printf "     ${YELLOW}⚠️  No beacon nodes configured${NC}\n"
        fi
    fi
    echo
}

# Teku validator health check  
check_teku_validator_health() {
    local service_dir="$1"
    local service_name=$(basename "$service_dir")
    
    # Get configuration
    local metrics_port=$(grep "TEKU_METRICS_PORT=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local network=$(grep "ETH2_NETWORK=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local version=$(grep "TEKU_VERSION=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local beacon_urls=$(grep "BEACON_NODE_URL=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local bind_ip=$(grep "HOST_BIND_IP=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    
    # Default values
    [[ -z "$metrics_port" ]] && metrics_port="8008"
    [[ -z "$bind_ip" ]] && bind_ip="127.0.0.1"
    
    # Check container status
    local containers_running=false
    if cd "$service_dir" 2>/dev/null; then
        # Check if teku-validator service is running
        if docker compose ps --services --filter status=running 2>/dev/null | grep -q "teku-validator"; then
            containers_running=true
        fi
    fi
    
    # Initialize status variables
    local teku_check="${RED}✗${NC}"
    local access_indicator="[M]"
    
    # Determine access indicator
    if [[ "$bind_ip" == "0.0.0.0" ]]; then
        access_indicator="${RED}[A]${NC}"
    elif [[ "$bind_ip" != "127.0.0.1" ]]; then
        access_indicator="${UI_WARNING}[L]${UI_RESET}"
    else
        access_indicator="${GREEN}[M]${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        # Check Teku validator metrics endpoint
        if curl -s "http://localhost:${metrics_port}/metrics" >/dev/null 2>&1; then
            teku_check="${GREEN}✓${NC}"
        fi
    fi
    
    # Check for updates if running
    local teku_update_indicator=""
    if [[ "$containers_running" == true ]] && [[ -n "$version" ]]; then
        teku_update_indicator=$(check_service_update "teku-validator" "$version")
    fi
    
    # Display status
    local status_indicator="${GREEN}●${NC}"
    if [[ "$containers_running" == false ]]; then
        status_indicator="${RED}●${NC}"
    fi
    
    if [[ "$containers_running" == true ]]; then
        echo -e "  $status_indicator teku-validator ($network) $access_indicator"
        # Check beacon node connectivity and sync status to determine validator status
        local reachable_count=0
        local synced_count=0
        local syncing_count=0
        local beacon_url_list=""
        
        # Parse beacon URLs if configured
        if [[ -n "$beacon_urls" && "$beacon_urls" != "" ]]; then
            beacon_url_list=$(echo "$beacon_urls" | tr ',' ' ')
            for url in $beacon_url_list; do
                # Extract the container name and port from the URL
                local container_name=$(echo "$url" | sed 's|http://||g' | sed 's|:.*||g')
                local port=$(echo "$url" | sed 's|.*:||g')
                
                # Check if container is running
                if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
                    ((reachable_count++))
                    
                    # Map internal container port to external host port
                    local host_port=$(docker port "$container_name" "$port/tcp" 2>/dev/null | cut -d':' -f2)
                    if [[ -z "$host_port" ]]; then
                        # Fallback: try the internal port directly (for localhost-bound services)
                        host_port="$port"
                    fi
                    
                    # Check beacon node sync status
                    local sync_status=$(curl -s --max-time 0.5 "http://localhost:${host_port}/eth/v1/node/syncing" 2>/dev/null | jq -r '.data.is_syncing // "unknown"' 2>/dev/null)
                    if [[ "$sync_status" == "false" ]]; then
                        ((synced_count++))
                    elif [[ "$sync_status" == "true" ]]; then
                        ((syncing_count++))
                    fi
                fi
            done
        fi
        
        # Check validator status with comprehensive beacon node dependency checking
        local validator_status="not attesting"
        local validator_indicator="${RED}✗${NC}"
        
        # Check for doppelganger detection first
        local doppelganger_active=$(docker logs teku-validator --tail=10 --since=3m 2>/dev/null | grep -c "Performing doppelganger check" || echo "0")
        local doppelganger_errors=$(docker logs teku-validator --tail=10 --since=3m 2>/dev/null | grep -c "Unable to check validators doppelgangers" || echo "0")
        local liveness_not_enabled=$(docker logs teku-validator --tail=20 --since=5m 2>/dev/null | grep -c "liveness tracking not enabled" || echo "0")
        
        # Check recent logs for published attestations
        local recent_attestation_logs=$(docker logs teku-validator --tail=20 --since=5m 2>/dev/null | grep -c "Published attestation" || echo "0")
        
        # Also check metrics as backup if available
        local metrics_port=$(grep "TEKU_METRICS_PORT=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
        local metrics_check=0
        if [[ -n "$metrics_port" ]]; then
            metrics_check=$(curl -s "http://localhost:${metrics_port}/metrics" 2>/dev/null | grep -c "publish_attestation.*success" || echo "0")
        fi
        
        # Determine status
        if [[ "$recent_attestation_logs" -gt 0 ]] || [[ "$metrics_check" -gt 0 ]]; then
            validator_status="attesting"
            validator_indicator="${GREEN}✓${NC}"
        elif [[ "$doppelganger_active" -gt 0 ]] || [[ "$doppelganger_errors" -gt 0 ]] || [[ "$liveness_not_enabled" -gt 0 ]]; then
            validator_status="not attesting"
            validator_indicator="${RED}✗${NC}"
        else
            validator_status="not attesting"
            validator_indicator="${RED}✗${NC}"
        fi
        
        printf "     ${validator_indicator} %-25s (%s)\n" "$validator_status" "$(display_version "teku-validator" "$version")"
        
        # Show beacon node connection if configured
        if [[ -n "$beacon_urls" && "$beacon_urls" != "" ]]; then
            printf "     %s %-20s\n" "" "Connected to:"
            
            # Display beacon node connection status
            for url in $beacon_url_list; do
                # Extract the container name from the URL (e.g., ethnode1-grandine:5052 from http://ethnode1-grandine:5052)
                local container_name=$(echo "$url" | sed 's|http://||g' | sed 's|:.*||g')
                local port=$(echo "$url" | sed 's|.*:||g')
                
                # Create display name: ethnode1-grandine -> ethnode1-Grandine
                # Split on dash and capitalize the client name part
                local node_part=$(echo "$container_name" | cut -d'-' -f1)
                local client_part=$(echo "$container_name" | cut -d'-' -f2)
                local display_name="$node_part"
                if [[ -n "$client_part" ]]; then
                    # Capitalize first letter of client name
                    local capitalized_client="$(echo "$client_part" | sed 's/^./\U&/')"
                    display_name="$node_part-$capitalized_client"
                fi
                
                # Debug: skip empty URLs
                [[ -z "$display_name" || -z "$container_name" ]] && continue
                
                # Check container status and beacon node health
                local container_status=""
                local beacon_health=""
                
                if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
                    # Container is running, check if beacon API is responsive
                    local api_check=$(curl -s --max-time 0.5 "http://localhost:${port}/eth/v1/node/health" 2>/dev/null)
                    if [[ $? -eq 0 ]]; then
                        # Check sync status
                        local sync_status=$(curl -s --max-time 0.5 "http://localhost:${port}/eth/v1/node/syncing" 2>/dev/null | jq -r '.data.is_syncing // "unknown"' 2>/dev/null)
                        if [[ "$sync_status" == "false" ]]; then
                            container_status="${GREEN}✓${NC}"
                            beacon_health="synced"
                        elif [[ "$sync_status" == "true" ]]; then
                            container_status="${RED}✗${NC}"
                            beacon_health="syncing"
                        else
                            container_status="${GREEN}✓${NC}"
                            beacon_health="ready"
                        fi
                    else
                        container_status="${RED}✗${NC}"
                        beacon_health="starting"
                    fi
                    # Show status text only when NOT attesting and NOT doing doppelganger checks
                    if [[ "$validator_status" == "attesting" ]] || [[ "$doppelganger_active" -gt 0 ]] || [[ "$doppelganger_errors" -gt 0 ]] || [[ "$liveness_not_enabled" -gt 0 ]]; then
                        printf "     %s %s\n" "$container_status" "$display_name"
                    else
                        printf "     %s %s ${UI_MUTED}(%s)${NC}\n" "$container_status" "$display_name" "$beacon_health"
                    fi
                else
                    printf "     ${RED}✗${NC} %s ${UI_MUTED}(not found)${NC}\n" "$display_name"
                fi
            done
        else
            printf "     ${YELLOW}[WARNING] No beacon nodes configured${NC}\n"
        fi
    else
        echo -e "  ${status_indicator} teku-validator (${network}) $access_indicator"
        echo -e "     ${RED}● Stopped${NC}"
    fi
    echo
}

# Fallback functions - only used if real functions from clients.sh aren't available
cleanup_version_cache() { return 0; }

# Only define these if they don't already exist (from clients.sh)
if ! declare -f check_service_update >/dev/null 2>&1; then
    check_service_update() { echo ""; }
fi

if ! declare -f display_version >/dev/null 2>&1; then
    display_version() { echo "${2:-unknown}"; }
fi

# Generate fresh dashboard with health checks
generate_dashboard() {
    # Define colors if not already defined
    [[ -z "$RED" ]] && RED='\033[0;31m'
    [[ -z "$GREEN" ]] && GREEN='\033[0;32m'
    [[ -z "$YELLOW" ]] && YELLOW='\033[0;33m'
    [[ -z "$CYAN" ]] && CYAN='\033[0;36m'
    [[ -z "$BOLD" ]] && BOLD='\033[1m'
    [[ -z "$NC" ]] && NC='\033[0m'
    [[ -z "$UI_MUTED" ]] && UI_MUTED='\033[38;5;240m'
    
    # Monitoring functions should be pre-loaded when manage.sh is sourced
    
    # Keep update checking enabled for dashboard generation
    local original_check_updates="$CHECK_UPDATES"
    # CHECK_UPDATES="false"  # REMOVED: This was disabling all update indicators
    
    cleanup_version_cache 2>/dev/null || true 
    echo -e "${BOLD}NODEBOI Dashboard${NC}\n=================\n"

    local found=false
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" && -f "$dir/compose.yml" ]]; then
            found=true
            check_node_health "$dir"
        fi
    done
    
    # Check for validator services and display them
    local validator_found=false
    
    # Web3signer (singleton)
    if [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/.env" ]]; then
        check_web3signer_health "$HOME/web3signer"
        validator_found=true
        found=true
    fi
    
    # Vero (singleton)
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        check_vero_health "$HOME/vero"
        validator_found=true
        found=true
    fi
    
    # Teku validator (singleton)
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        check_teku_validator_health "$HOME/teku-validator"
        validator_found=true
        found=true
    fi
    
    # Check for monitoring and display it LAST
    if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" && -f "$HOME/monitoring/compose.yml" ]]; then
        # Monitoring functions are pre-loaded, just call them
        if command -v check_monitoring_health &> /dev/null; then
            check_monitoring_health | sed '$d'  # Remove last blank line
        fi
        found=true
    fi
    if [[ "$found" == false ]]; then
        echo -e "${UI_MUTED}  No nodes or services installed${NC}\n"
    else
        echo -e "${UI_MUTED}─────────────────────────────${NC}"
        echo -e "${UI_MUTED}Legend: ${GREEN}●${NC} ${UI_MUTED}Running${NC} | ${RED}●${NC} ${UI_MUTED}Stopped${NC} | ${GREEN}✓${NC} ${UI_MUTED}Healthy${NC} | ${RED}✗${NC} ${UI_MUTED}Unhealthy${NC} | ${YELLOW}⬆${NC}  ${UI_MUTED}Update available${NC}"
        echo -e "${UI_MUTED}Access: ${GREEN}[M]${NC} ${UI_MUTED}My machine${NC} | ${UI_WARNING}[L]${UI_RESET} ${UI_MUTED}Local network${NC} | ${RED}[A]${NC} ${UI_MUTED}All network interfaces${NC}"
    fi
    # Restore original CHECK_UPDATES setting
    CHECK_UPDATES="$original_check_updates"
}

# Dashboard caching system
DASHBOARD_CACHE_FILE="$HOME/.nodeboi/cache/dashboard.cache"
export DASHBOARD_CACHE_LOCK="$HOME/.nodeboi/cache/dashboard.lock"
DASHBOARD_CACHE_DURATION=60   # 1 minute

# Check if dashboard cache is valid
is_dashboard_cache_valid() {
    [[ -f "$DASHBOARD_CACHE_FILE" ]] || return 1
    
    local cache_time=$(stat -c %Y "$DASHBOARD_CACHE_FILE" 2>/dev/null)
    local current_time=$(date +%s)
    
    [[ -n "$cache_time" ]] && [[ $((current_time - cache_time)) -lt $DASHBOARD_CACHE_DURATION ]]
}

# Background dashboard generation (async)
generate_dashboard_background() {
    local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    local lock_file="$DASHBOARD_CACHE_LOCK"
    
    # Check for existing background job
    if [[ -f "$lock_file" ]]; then
        local lock_pid=$(cat "$lock_file" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            return 0  # Background job already running
        else
            rm -f "$lock_file"  # Stale lock file
        fi
    fi
    
    # Start background generation
    {
        echo "$$" > "$lock_file"
        
        # Set working directory to nodeboi home to ensure relative paths work
        cd "$HOME/.nodeboi" 2>/dev/null || return 1
        
        # Ensure NODEBOI_LIB is set correctly
        export NODEBOI_LIB="$HOME/.nodeboi/lib"
        
        # Load ALL required libraries explicitly
        [[ -f "lib/clients.sh" ]] && source "lib/clients.sh" 2>/dev/null || true
        [[ -f "lib/monitoring.sh" ]] && source "lib/monitoring.sh" 2>/dev/null || true
        [[ -f "lib/port-manager.sh" ]] && source "lib/port-manager.sh" 2>/dev/null || true
        
        # Generate dashboard with error handling
        if generate_dashboard > "$cache_file.tmp" 2>/dev/null; then
            # Ensure cache file is not empty
            if [[ -s "$cache_file.tmp" ]]; then
                mv "$cache_file.tmp" "$cache_file"
            else
                echo "NODEBOI Dashboard" > "$cache_file"
                echo "=================" >> "$cache_file"
                echo "" >> "$cache_file"
                echo "  Dashboard generation failed" >> "$cache_file"
                echo "" >> "$cache_file"
                rm -f "$cache_file.tmp"
            fi
        else
            # Fallback if generation fails
            cat > "$cache_file" << 'EOF'
NODEBOI Dashboard
=================

  Dashboard temporarily unavailable

EOF
            rm -f "$cache_file.tmp"
        fi
        
        # Clean up lock
        rm -f "$lock_file"
    } &
    disown  # Detach from shell
}

# Async dashboard cache refresh
refresh_dashboard_cache() {
    local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    mkdir -p "$(dirname "$cache_file")"
    
    # If cache exists and is valid, return immediately and update in background
    if is_dashboard_cache_valid; then
        return 0
    fi
    
    # If cache is stale or missing, start background refresh
    generate_dashboard_background
    
    # Return immediately (don't wait for generation)
    return 0
}

# Print dashboard (ALWAYS uses cache, never regenerates)
print_dashboard() {
    local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file" 2>/dev/null
    else
        echo "NODEBOI Dashboard"
        echo "================="
        echo ""
        echo "  Dashboard not available"
        echo ""
    fi
}

# Force refresh dashboard cache (call this after service state changes)
force_refresh_dashboard() {
    local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    
    # Invalidate current cache by removing it to ensure fresh generation
    rm -f "$cache_file"
    
    # Generate dashboard synchronously for immediate refresh
    generate_dashboard > "$cache_file" 2>/dev/null || true
}



show_node_details() {
    echo -e "\n${CYAN}${BOLD}Detailed Node Status${NC}\n===================="

    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            echo -e "\n${BOLD}$node_name:${NC}"

            # Get configuration
            local network=$(grep "NETWORK=" "$dir/.env" | cut -d'=' -f2)
            local el_rpc=$(grep "EL_RPC_PORT=" "$dir/.env" | cut -d'=' -f2)
            local el_ws=$(grep "EL_WS_PORT=" "$dir/.env" | cut -d'=' -f2)
            local cl_rest=$(grep "CL_REST_PORT=" "$dir/.env" | cut -d'=' -f2)
            local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)

            # Parse clients
            local exec_client="unknown"
            local cons_client="unknown"
    local clients=$(detect_node_clients "$compose_file")
    local exec_client="${clients%:*}"
    local cons_client="${clients#*:}"
            echo -e "${UI_MUTED}  Network: $network${NC}"
            echo -e "${UI_MUTED}  Clients: $exec_client / $cons_client${NC}"
            echo -e "${UI_MUTED}  Directory: $dir${NC}"

            # Check containers
            if cd "$dir" 2>/dev/null; then
                local services=$(docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | tail -n +2)
                if [[ -n "$services" ]]; then
                    echo -e "${UI_MUTED}  Services:${NC}"
                    while IFS= read -r line; do
                        echo -e "${UI_MUTED}    $line${NC}"
                    done <<< "$services"

                    # Check sync status
                    local sync_status=$(curl -s -X POST "http://${check_host}:${el_rpc}" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null | jq -r '.result' 2>/dev/null)

                    if [[ "$sync_status" == "false" ]]; then
                        echo "  Sync: ${GREEN}Synced${NC}"
                    elif [[ -n "$sync_status" && "$sync_status" != "null" ]]; then
                        echo "  Sync: ${YELLOW}Syncing${NC}"
                        local current_block=$(echo "$sync_status" | jq -r '.currentBlock' 2>/dev/null)
                        local highest_block=$(echo "$sync_status" | jq -r '.highestBlock' 2>/dev/null)
                        [[ -n "$current_block" && "$current_block" != "null" ]] && echo "    Progress: $current_block / $highest_block"
                    fi
                else
                    echo "  Status: ${RED}Stopped${NC}"
                fi
            fi

        # Get P2P ports
            local el_p2p=$(grep "EL_P2P_PORT=" "$dir/.env" | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
            local cl_p2p=$(grep "CL_P2P_PORT=" "$dir/.env" | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

            echo -e "${UI_MUTED}  Endpoints:${NC}"
            echo -e "${UI_MUTED}    Execution RPC:  http://${check_host}:${el_rpc}${NC}"
            echo -e "${UI_MUTED}    Execution WS:   ws://localhost:${el_ws}${NC}"
            echo -e "${UI_MUTED}    Consensus REST: http://${check_host}:${cl_rest}${NC}"
            echo -e "${UI_MUTED}  P2P Ports (need to be forwarded in your router):${NC}"
            echo -e "${UI_MUTED}    Execution P2P:  ${YELLOW}${el_p2p}${NC}/TCP+UDP${NC}"
            echo -e "${UI_MUTED}    Consensus P2P:  ${YELLOW}${cl_p2p}${NC}/TCP+UDP${NC}"
        fi
    done

    press_enter
}
manage_node_state() {
    local nodes=()
    local node_status=()
    
    # Get nodes and their status
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            nodes+=("$node_name")
            
            # Check if running
            if cd "$dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
                node_status+=("Running")
            else
                node_status+=("Stopped")
            fi
        fi
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        clear
        print_header
        print_box "No nodes found." "warning"
        press_enter
        return
    fi

    # Create enhanced menu options with status
    local menu_options=()
    for i in "${!nodes[@]}"; do
        local status_color="${RED}"
        [[ "${node_status[$i]}" == "Running" ]] && status_color="${GREEN}"
        menu_options+=("${nodes[$i]} [${node_status[$i]}]")
    done
    menu_options+=("Start all stopped nodes" "Stop all running nodes" "Cancel")

    local selection
    if selection=$(fancy_select_menu "Manage Nodes" "${menu_options[@]}"); then
        local total_nodes=${#nodes[@]}
        
        if [[ $selection -eq $((total_nodes)) ]]; then
            # Start all stopped
            echo -e "\n${YELLOW}Starting all stopped nodes...${NC}\n"
            for i in "${!nodes[@]}"; do
                if [[ "${node_status[$i]}" == "Stopped" ]]; then
                    echo -e "${UI_MUTED}Starting ${nodes[$i]} via ULCS...${NC}"
                    if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
                        source "${NODEBOI_LIB}/ulcs.sh"
                        start_service_universal "${nodes[$i]}" > /dev/null 2>&1
                    else
                        # Fallback to legacy method
                        cd "$HOME/${nodes[$i]}" && docker compose up -d > /dev/null 2>&1
                    fi
                    force_refresh_dashboard
                fi
            done
            echo -e "${GREEN}All stopped nodes started${NC}"
            
        elif [[ $selection -eq $((total_nodes + 1)) ]]; then
            # Stop all running
            echo -e "\n${UI_MUTED}Stopping all running nodes...${NC}\n"
            for i in "${!nodes[@]}"; do
                if [[ "${node_status[$i]}" == "Running" ]]; then
                    echo -e "${UI_MUTED}Stopping ${nodes[$i]} via ULCS...${NC}"
                    if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
                        source "${NODEBOI_LIB}/ulcs.sh"
                        stop_service_universal "${nodes[$i]}" > /dev/null 2>&1
                    else
                        # Fallback to legacy method
                        safe_docker_stop "${nodes[$i]}"
                    fi
                    force_refresh_dashboard
                fi
            done
            echo -e "${GREEN}All running nodes stopped${NC}"
            
        elif [[ $selection -eq $((total_nodes + 2)) ]]; then
            # Cancel
            return
            
        else
            # Individual node selected
            local node_name="${nodes[$selection]}"
            local node_dir="$HOME/$node_name"
            
            local action_options=(
                "Start"
                "Stop"
                "View logs (live)"
                "View logs (last 100 lines)"
                "Cancel"
            )
            
            local action_selection
            if action_selection=$(fancy_select_menu "Actions for $node_name" "${action_options[@]}"); then
                case $action_selection in
                    0)
                        echo -e "\n${YELLOW}Starting $node_name via ULCS...${NC}"
                        if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
                            source "${NODEBOI_LIB}/ulcs.sh"
                            if start_service_universal "$node_name"; then
                                echo -e "${GREEN}$node_name started successfully${NC}"
                            else
                                echo -e "${RED}Failed to start $node_name via ULCS${NC}"
                                return 1
                            fi
                        else
                            echo -e "${RED}ULCS not available - cannot start service${NC}"
                            return 1
                        fi
                        force_refresh_dashboard
                        ;;
                    1)
                        echo -e "\n${UI_MUTED}Stopping $node_name via ULCS...${NC}"
                        if [[ -f "${NODEBOI_LIB}/ulcs.sh" ]]; then
                            source "${NODEBOI_LIB}/ulcs.sh"
                            if stop_service_universal "$node_name"; then
                                echo -e "${GREEN}$node_name stopped successfully${NC}"
                            else
                                echo -e "${RED}Failed to stop $node_name via ULCS${NC}"
                                return 1
                            fi
                        else
                            echo -e "${RED}ULCS not available - cannot stop service${NC}"
                            return 1
                        fi
                        force_refresh_dashboard
                        ;;
                    2)
                        clear
                        print_header
                        print_dashboard
                        echo -e "${BOLD}Live logs for $node_name${NC} (Ctrl+C to exit and return to menu)\n"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        ;;
                    3)
                        clear
                        print_header
                        echo -e "${BOLD}Recent logs for $node_name${NC}\n"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        ;;
                    4)
                        return
                        ;;
                esac
            fi
        fi
    fi

    press_enter
}

update_system() {
    clear
    print_header
    
    echo -e "\n${CYAN}${BOLD}System Update${NC}"
    echo "============="
    echo
    echo "This will update your Linux system packages (apt update && apt upgrade)."
    echo "This may take several minutes depending on available updates."
    echo
    
    local update_options=("Continue with update" "Cancel")
    
    local selection
    if selection=$(fancy_select_menu "System Update" "${update_options[@]}"); then
        case $selection in
            0) # Continue with system update
                clear
                print_header
                        
                echo -e "\n${CYAN}${BOLD}System Update in Progress${NC}"
                    echo "========================="
                    echo
                    
                    echo -e "${CYAN}Step 1/4:${NC} Updating package lists..."
                    if sudo apt-get update 2>&1 | while IFS= read -r line; do
                        echo "  $line"
                    done; then
                        echo -e "${GREEN}  ✓ Package lists updated successfully${NC}\n"
                        
                        echo -e "${CYAN}Step 2/4:${NC} Upgrading packages (dist-upgrade)..."
                        if sudo apt-get dist-upgrade -y 2>&1 | while IFS= read -r line; do
                            echo "  $line"
                        done; then
                            echo -e "${GREEN}  ✓ Packages upgraded successfully${NC}\n"
                            
                            echo -e "${CYAN}Step 3/4:${NC} Removing unused packages..."
                            if sudo apt-get autoremove -y 2>&1 | while IFS= read -r line; do
                                echo "  $line"
                            done; then
                                echo -e "${GREEN}  ✓ Unused packages removed${NC}\n"
                                
                                echo -e "${CYAN}Step 4/4:${NC} Cleaning package cache..."
                                if sudo apt-get autoclean 2>&1 | while IFS= read -r line; do
                                    echo "  $line"
                                done; then
                                    echo -e "${GREEN}  ✓ Package cache cleaned${NC}\n"
                                    echo -e "\n${GREEN}${BOLD}✓ System update completed successfully${NC}\n"
                            
                            # Check if reboot is required
                            if [[ -f /var/run/reboot-required ]]; then
                                echo -e "${YELLOW}${BOLD}Reboot Required:${NC}"
                                echo -e "${UI_MUTED}=================${NC}"
                                if [[ -f /var/run/reboot-required.pkgs ]]; then
                                    echo -e "${UI_MUTED}The following packages require a reboot:${NC}"
                                    cat /var/run/reboot-required.pkgs | while read pkg; do
                                        echo -e "${UI_MUTED}  • $pkg${NC}"
                                    done
                                else
                                    echo -e "${UI_MUTED}System reboot is required to complete the update.${NC}"
                                fi
                                echo
                                
                                print_box "System reboot recommended to complete update" "warning"
                                
                                local reboot_options=("Reboot now" "Reboot later")
                                local reboot_choice
                                if reboot_choice=$(fancy_select_menu "Reboot Required" "${reboot_options[@]}"); then
                                    case $reboot_choice in
                                        0)
                                            echo -e "\n${YELLOW}Rebooting system...${NC}"
                                            sleep 2
                                            sudo reboot
                                            ;;
                                        1)
                                            print_box "Please reboot manually when convenient" "info"
                                            ;;
                                    esac
                                fi
                            else
                                echo -e "${UI_MUTED}System update complete - no reboot required${NC}\n"
                            fi
                        else
                            print_box "Failed to clean package cache" "error"
                        fi
                        else
                            print_box "Failed to remove unused packages" "error"
                        fi
                    else
                        print_box "Package upgrade failed" "error"
                    fi
                else
                    print_box "Failed to update package lists" "error"
                fi
                
                press_enter
                ;;
            1) # Cancel
                return
                ;;
        esac
    else
        return  # User pressed 'q' - go back
    fi
}

update_nodeboi() {
    clear
    print_header
    
    echo -e "\n${CYAN}${BOLD}Update NODEBOI${NC}"
    echo -e "${UI_MUTED}===============${NC}"
    echo
    echo -e "${UI_MUTED}This will update NODEBOI to the latest version from GitHub.${NC}"
    echo
    
    local update_options=("Continue with update" "Cancel")
    
    local selection
    if selection=$(fancy_select_menu "Update NODEBOI" "${update_options[@]}"); then
        case $selection in
            0) # continue with update
                clear
                print_header
                        
                echo -e "\n${CYAN}${BOLD}NODEBOI Update in Progress${NC}"
                echo -e "${UI_MUTED}==========================${NC}"
                echo
                
                cd "$HOME/.nodeboi"
                
                # Always ignore file permission changes
                git config core.fileMode false
                
                echo -e "${CYAN}Updating from GitHub...${NC}"
                if git pull origin main; then
                    print_box "NODEBOI updated successfully" "success"
                    echo -e "\n${UI_MUTED}Restarting NODEBOI...${NC}"
                    sleep 2
                    exec "$0"
                else
                    print_box "Update failed" "error"
                    echo -e "${UI_MUTED}Try reinstalling:${NC}"
                    echo -e "${UI_MUTED}wget -qO- https://raw.githubusercontent.com/Cryptizer69/nodeboi/main/install.sh | bash${NC}"
                    press_enter
                fi
                ;;
            1) # cancel
                return
                ;;
        esac
    else
        return  # User pressed 'q' - go back
    fi
}


# View logs for a specific node
view_single_node_logs() {
    local nodes=($(get_node_list))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_box "No nodes found" "error"
        press_enter
        return
    fi

    local node_options=()
    for node in "${nodes[@]}"; do
        node_options+=("$node")
    done
    node_options+=("Back")

    local selection
    if selection=$(fancy_select_menu "Select Node" "${node_options[@]}"); then
        if [[ $selection -eq ${#node_options[@]}-1 ]]; then
            return
        fi
        
        local selected_node="${nodes[$selection]}"
        local node_dir="$HOME/$selected_node"
        
        if [[ -d "$node_dir" ]]; then
            # Show log options for the selected node
            local log_type_options=(
                "Recent logs (last 100 lines)"
                "Recent logs (last 200 lines)"
                "Error logs only"
                "All logs"
                "Back"
            )
            
            local log_selection
            if log_selection=$(fancy_select_menu "Log Type for $selected_node" "${log_type_options[@]}"); then
                case $log_selection in
                    0)
                        clear
                        print_header
                        echo -e "${BOLD}Recent logs for $selected_node${NC} (last 100 lines)\n"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        ;;
                    1)
                        clear
                        print_header
                        echo -e "${BOLD}Recent logs for $selected_node${NC} (last 200 lines)\n"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        ;;
                    2)
                        clear
                        print_header
                        echo -e "${BOLD}Error logs for $selected_node${NC}\n"
                        cd "$node_dir" && docker compose logs --tail=20 | grep -i "error\|warn\|fail\|panic\|fatal"
                        ;;
                    3)
                        clear
                        print_header
                        echo -e "${BOLD}All logs for $selected_node${NC}\n"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        ;;
                    4)
                        return
                        ;;
                esac
                press_enter
            fi
        fi
    fi
}

# View consolidated logs for all nodes
view_all_nodes_logs() {
    local nodes=($(get_node_list))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_box "No nodes found" "error"
        press_enter
        return
    fi

    local log_options=(
        "Recent logs from all nodes (last 50 lines each)"
        "Error logs from all nodes"
        "Status summary + recent logs"
        "Back"
    )

    local selection
    if selection=$(fancy_select_menu "All Nodes Log View" "${log_options[@]}"); then
        case $selection in
            0)
                clear
                print_header
                echo -e "${BOLD}Recent logs from all nodes${NC} (last 50 lines each)\n"
                for node in "${nodes[@]}"; do
                    local node_dir="$HOME/$node"
                    if [[ -d "$node_dir" ]]; then
                        echo -e "${CYAN}${BOLD}=== $node ===${NC}"
                        cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
                        echo
                    fi
                done
                ;;
            1)
                clear
                print_header
                echo -e "${BOLD}Error logs from all nodes${NC}\n"
                for node in "${nodes[@]}"; do
                    local node_dir="$HOME/$node"
                    if [[ -d "$node_dir" ]]; then
                        echo -e "${CYAN}${BOLD}=== $node (Errors) ===${NC}"
                        local error_logs=$(cd "$node_dir" && docker compose logs | grep -i "error\|warn\|fail\|panic\|fatal")
                        if [[ -n "$error_logs" ]]; then
                            echo "$error_logs"
                        else
                            echo -e "${GREEN}No errors found${NC}"
                        fi
                        echo
                    fi
                done
                ;;
            2)
                clear
                print_header
                echo -e "${BOLD}Node Status Summary + Recent Logs${NC}\n"
                for node in "${nodes[@]}"; do
                    local node_dir="$HOME/$node"
                    if [[ -d "$node_dir" ]]; then
                        echo -e "${CYAN}${BOLD}=== $node ===${NC}"
                        
                        # Show status first
                        if cd "$node_dir" 2>/dev/null; then
                            local services=$(docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | tail -n +2)
                            if [[ -n "$services" ]]; then
                                echo -e "${UI_MUTED}Services:${NC}"
                                while IFS= read -r line; do
                                    echo -e "${UI_MUTED}  $line${NC}"
                                done <<< "$services"
                            fi
                            
                            # Then show recent logs
                            echo -e "\n${UI_MUTED}Recent logs:${NC}"
                            safe_view_logs "docker compose logs -f --tail=20"
                        fi
                        echo
                    fi
                done
                ;;
            3)
                return
                ;;
        esac
        press_enter
    fi
}

# View logs by service type (execution client, consensus client, etc.)
view_logs_by_service() {
    local service_options=(
        "Execution clients (all nodes)"
        "Consensus clients (all nodes)" 
        "All services by type"
        "Back"
    )

    local selection
    if selection=$(fancy_select_menu "View by Service Type" "${service_options[@]}"); then
        case $selection in
            0)
                clear
                print_header
                echo -e "${BOLD}Execution Client Logs (All Nodes)${NC}\n"
                view_service_logs_across_nodes "execution"
                ;;
            1)
                clear
                print_header
                echo -e "${BOLD}Consensus Client Logs (All Nodes)${NC}\n"
                view_service_logs_across_nodes "consensus"
                ;;
            2)
                clear
                print_header
                echo -e "${BOLD}All Services by Type${NC}\n"
                view_all_service_types
                ;;
            3)
                return
                ;;
        esac
        press_enter
    fi
}

# Helper function to view specific service logs across all nodes
view_service_logs_across_nodes() {
    local service_type="$1"
    local nodes=($(get_node_list))
    
    for node in "${nodes[@]}"; do
        local node_dir="$HOME/$node"
        if [[ -d "$node_dir" ]]; then
            echo -e "${CYAN}${BOLD}=== $node ($service_type) ===${NC}"
            
            if cd "$node_dir" 2>/dev/null; then
                # Get service names based on type
                local services=$(docker compose ps --services 2>/dev/null)
                local target_services=""
                
                case $service_type in
                    "execution")
                        target_services=$(echo "$services" | grep -E "geth|erigon|nethermind|besu|reth")
                        ;;
                    "consensus")
                        target_services=$(echo "$services" | grep -E "lighthouse|prysm|teku|nimbus|lodestar")
                        ;;
                esac
                
                if [[ -n "$target_services" ]]; then
                    for service in $target_services; do
                        echo -e "${UI_MUTED}--- $service ---${NC}"
                        safe_view_logs "docker compose logs -f --tail=20 \"$service\" 2>/dev/null" || echo "No logs available"
                    done
                else
                    echo -e "${UI_MUTED}No $service_type services found${NC}"
                fi
            fi
            echo
        fi
    done
}

# View all service types organized
view_all_service_types() {
    local nodes=($(get_node_list))
    
    echo -e "${YELLOW}${BOLD}EXECUTION CLIENTS${NC}"
    echo "=================="
    view_service_logs_across_nodes "execution"
    
    echo -e "${YELLOW}${BOLD}CONSENSUS CLIENTS${NC}"
    echo "=================="
    view_service_logs_across_nodes "consensus"
}

# Follow logs for a specific node (live)
follow_single_node_logs() {
    local nodes=($(get_node_list))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_box "No nodes found" "error"
        press_enter
        return
    fi

    local node_options=()
    for node in "${nodes[@]}"; do
        node_options+=("$node")
    done
    node_options+=("Back")

    local selection
    if selection=$(fancy_select_menu "Follow Logs - Select Node" "${node_options[@]}"); then
        if [[ $selection -eq ${#node_options[@]}-1 ]]; then
            return
        fi
        
        local selected_node="${nodes[$selection]}"
        local node_dir="$HOME/$selected_node"
        
        if [[ -d "$node_dir" ]]; then
            clear
            print_header
            print_dashboard
            echo -e "${BOLD}Live logs for $selected_node${NC} (Ctrl+C to exit and return to menu)\n"
            cd "$node_dir" && safe_view_logs "docker compose logs -f --tail=20"
        fi
    fi
}

# Follow logs for all nodes (live)
follow_all_nodes_logs() {
    local nodes=($(get_node_list))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_box "No nodes found" "error"
        press_enter
        return
    fi

    clear
    print_header
    print_dashboard
    echo -e "${BOLD}Live logs from all nodes${NC} (Ctrl+C to exit and return to menu)\n"
    echo -e "${UI_MUTED}Note: Logs from multiple nodes will be interleaved by timestamp${NC}\n"
    
    # Create a temporary script to follow all logs
    local temp_script=$(mktemp)
    cat > "$temp_script" << 'EOF'
#!/bin/bash
for node_dir in "$HOME"/ethnode*; do
    if [[ -d "$node_dir" && -f "$node_dir/docker-compose.yml" ]]; then
        (
            cd "$node_dir"
            docker compose logs -f --tail=20 2>/dev/null | sed "s/^/$(basename "$node_dir"): /"
        ) &
    fi
done
wait
EOF
    
    chmod +x "$temp_script"
    safe_view_logs "$temp_script"
    rm -f "$temp_script"
}

# Simple log viewer with node selection
view_split_screen_logs() {
    local nodes=($(get_node_list))
    if [[ ${#nodes[@]} -eq 0 ]]; then
        print_box "No nodes found" "error"
        press_enter
        return
    fi

    # Create selection menu
    local node_options=()
    for node in "${nodes[@]}"; do
        node_options+=("$node")
    done
    node_options+=("Back")

    local selection
    if selection=$(fancy_select_menu "Select Node to View Logs" "${node_options[@]}"); then
        if [[ $selection -eq ${#node_options[@]}-1 ]]; then
            return  # Back selected
        fi
        
        local selected_node="${nodes[$selection]}"
        local node_dir="$HOME/$selected_node"
        
        if [[ ! -d "$node_dir" ]]; then
            print_box "$selected_node directory not found" "error"
            press_enter
            return
        fi
        
        cd "$node_dir"
        
        clear
        print_header
        echo -e "${BOLD}Live Logs - $selected_node${NC}"
        echo -e "${UI_MUTED}Press Ctrl+C to exit and return to menu${NC}\n"
        echo -e "${CYAN}Starting live log stream for both execution and consensus clients...${NC}\n"
        
        # Use docker compose logs -f for the selected node
        safe_view_logs "docker compose logs -f --tail=20 execution consensus 2>/dev/null"
    fi
}

# Helper function to get list of available nodes
get_node_list() {
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            nodes+=($(basename "$dir"))
        fi
    done
    echo "${nodes[@]}"
}

# Clean up orphaned Docker networks from removed ethnodes
cleanup_orphaned_networks() {
    echo -e "\n${CYAN}${BOLD}Clean Up Orphaned Networks${NC}"
    echo "============================="
    echo
    echo -e "${UI_MUTED}Scanning for orphaned ethnode networks...${NC}"
    
    local orphaned_networks=()
    local active_networks=()
    
    # Note: Modern ethnodes use shared nodeboi-net, not individual networks
    # Get all ethnode-* networks from Docker (legacy architecture only)
    while IFS= read -r network_name; do
        if [[ "$network_name" =~ ^ethnode[0-9]+-net$ ]]; then
            local node_name="${network_name%-net}"
            local node_dir="$HOME/$node_name"
            
            # Check if corresponding ethnode directory exists (legacy nodes only)
            if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
                active_networks+=("$network_name")
            else
                orphaned_networks+=("$network_name")
            fi
        fi
    done < <(docker network ls --format "{{.Name}}" 2>/dev/null)
    
    echo
    if [[ ${#active_networks[@]} -gt 0 ]]; then
        echo -e "${GREEN}Active networks (will be preserved):${NC}"
        for network in "${active_networks[@]}"; do
            echo -e "${UI_MUTED}  ✓ $network${NC}"
        done
        echo
    fi
    
    if [[ ${#orphaned_networks[@]} -eq 0 ]]; then
        echo -e "${GREEN}✓ No orphaned networks found${NC}"
        echo
        press_enter
        return
    fi
    
    echo -e "${YELLOW}Orphaned networks found (no corresponding ethnode):${NC}"
    for network in "${orphaned_networks[@]}"; do
        echo -e "${UI_MUTED}  • $network${NC}"
    done
    echo
    
    read -p "Remove these orphaned networks? [y/n]: " -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${UI_MUTED}Removing orphaned networks...${NC}"
        for network_name in "${orphaned_networks[@]}"; do
            echo -e "${UI_MUTED}  Removing $network_name...${NC}"
            
            # Disconnect any remaining containers
            local connected_containers=$(docker network inspect "$network_name" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
            if [[ -n "$connected_containers" ]]; then
                for container in $connected_containers; do
                    echo -e "${UI_MUTED}    Disconnecting: $container${NC}"
                    docker network disconnect "$network_name" "$container" 2>/dev/null || true
                done
            fi
            
            # Remove the network
            if docker network rm "$network_name" 2>/dev/null; then
                echo -e "${UI_MUTED}    ✓ $network_name removed${NC}"
            else
                echo -e "${YELLOW}    ⚠ Could not remove $network_name${NC}"
            fi
        done
        echo
        echo -e "${GREEN}✓ Orphaned network cleanup complete${NC}"
    else
        echo -e "${UI_MUTED}Cleanup cancelled${NC}"
    fi
    
    echo
    press_enter
}

# Manage nodeboi-net lifecycle - create when needed, remove when no services use it
manage_nodeboi_network_lifecycle() {
    local action="$1"  # "create" or "remove" 
    local service_name="$2"  # service being added/removed (optional)
    
    case "$action" in
        "create")
            # Ensure nodeboi-net exists
            if ! docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
                echo -e "${UI_MUTED}Creating nodeboi-net for service integration...${NC}" >&2
                docker network create nodeboi-net || {
                    echo -e "${RED}Failed to create nodeboi-net${NC}" >&2
                    return 1
                }
                echo -e "${UI_MUTED}✓ nodeboi-net created${NC}" >&2
            fi
            ;;
        "remove")
            # Check if nodeboi-net should be removed
            if docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
                # Count services using nodeboi-net (excluding the one being removed)
                local connected_containers
                connected_containers=$(docker network inspect "nodeboi-net" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
                
                # Filter out containers from the service being removed
                local other_containers=""
                if [[ -n "$connected_containers" && -n "$service_name" ]]; then
                    for container in $connected_containers; do
                        if [[ "$container" != *"$service_name"* ]]; then
                            other_containers="$other_containers $container"
                        fi
                    done
                fi
                
                # Check for other services using nodeboi-net
                local has_other_ethnodes=false
                local has_monitoring=false
                local has_vero=false
                
                # Check for other ethnodes
                if [[ -n "$service_name" ]]; then
                    for dir in "$HOME"/ethnode*; do
                        if [[ -d "$dir" && -f "$dir/.env" && "$(basename "$dir")" != "$service_name" ]]; then
                            has_other_ethnodes=true
                            break
                        fi
                    done
                else
                    # Check if any ethnodes exist
                    for dir in "$HOME"/ethnode*; do
                        if [[ -d "$dir" && -f "$dir/.env" ]]; then
                            has_other_ethnodes=true
                            break
                        fi
                    done
                fi
                
                # Check for monitoring (if it uses nodeboi-net)
                if [[ -f "$HOME/monitoring/compose.yml" ]] && grep -q "nodeboi-net" "$HOME/monitoring/compose.yml"; then
                    has_monitoring=true
                fi
                
                # Check for Vero (if it uses nodeboi-net)
                if [[ -f "$HOME/vero/compose.yml" ]] && grep -q "nodeboi-net" "$HOME/vero/compose.yml"; then
                    has_vero=true
                fi
                
                # Remove nodeboi-net only if no services use it
                if [[ "$has_other_ethnodes" == false && "$has_monitoring" == false && "$has_vero" == false ]]; then
                    echo -e "${UI_MUTED}  No other services using nodeboi-net, removing...${NC}" >&2
                    
                    # Disconnect any remaining containers
                    if [[ -n "$connected_containers" ]]; then
                        for container in $connected_containers; do
                            docker network disconnect "nodeboi-net" "$container" 2>/dev/null || true
                        done
                        sleep 1
                    fi
                    
                    if docker network rm "nodeboi-net" 2>/dev/null; then
                        echo -e "${UI_MUTED}  ✓ nodeboi-net removed${NC}" >&2
                    else
                        echo -e "${YELLOW}  ⚠ Could not remove nodeboi-net${NC}" >&2
                    fi
                else
                    echo -e "${UI_MUTED}  nodeboi-net kept (used by other services)${NC}" >&2
                fi
            fi
            ;;
    esac
}

# Update Vero beacon URLs after ethnode removal
update_vero_after_ethnode_removal() {
    local removed_node="$1"
    local env_file="$HOME/vero/.env"
    
    # Check if the removed node is currently in Vero's beacon URLs
    if [[ -f "$env_file" ]]; then
        local current_urls=$(grep "BEACON_NODE_URLS=" "$env_file" | cut -d'=' -f2)
        if [[ "$current_urls" == *"$removed_node"* ]]; then
            echo -e "${UI_MUTED}    → Removed ethnode was in Vero's beacon configuration${NC}" >&2
            
            # Get list of remaining ethnode networks
            local remaining_networks=()
            for dir in "$HOME"/ethnode*; do
                if [[ -d "$dir" && -f "$dir/.env" && "$(basename "$dir")" != "$removed_node" ]]; then
                    remaining_networks+=("$(basename "$dir")")
                fi
            done
            
            if [[ ${#remaining_networks[@]} -eq 0 ]]; then
                echo -e "${YELLOW}    → No remaining beacon nodes - Vero may not function${NC}" >&2
                return 1
            fi
            
            # Rebuild beacon URLs using the same logic as validator-manager.sh
            local beacon_urls=""
            for ethnode in "${remaining_networks[@]}"; do
                local beacon_client=""
                
                # Check which beacon client is running in nodeboi-net
                if docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-grandine"; then
                    beacon_client="grandine"
                elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lodestar"; then
                    beacon_client="lodestar"
                elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-lighthouse"; then
                    beacon_client="lighthouse"
                elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${ethnode}-teku"; then
                    beacon_client="teku"
                else
                    echo -e "${YELLOW}    → Warning: No beacon client found for ${ethnode}, skipping${NC}" >&2
                    continue
                fi
                
                # For container-to-container communication, always use internal port 5052
                if [[ -z "$beacon_urls" ]]; then
                    beacon_urls="http://${ethnode}-${beacon_client}:5052"
                else
                    beacon_urls="${beacon_urls},http://${ethnode}-${beacon_client}:5052"
                fi
            done
            
            if [[ -n "$beacon_urls" ]]; then
                # Create backup of original file
                cp "$env_file" "${env_file}.backup" || {
                    echo -e "${RED}    → Error: Failed to create backup of .env file${NC}" >&2
                    return 1
                }
                
                # Update the .env file with safer approach
                local temp_file="$env_file.tmp"
                
                # Use awk for safer file modification
                if awk -v new_urls="$beacon_urls" '
                    /^BEACON_NODE_URLS=/ { print "BEACON_NODE_URLS=" new_urls; next }
                    { print }
                ' "$env_file" > "$temp_file"; then
                    
                    # Validate the temp file was created successfully
                    if [[ -s "$temp_file" ]] && grep -q "^BEACON_NODE_URLS=$beacon_urls" "$temp_file"; then
                        mv "$temp_file" "$env_file"
                        echo -e "${UI_MUTED}    → Updated Vero beacon URLs: $beacon_urls${NC}" >&2
                        
                        # Remove backup on success
                        rm -f "${env_file}.backup"
                        
                        # Restart Vero to apply changes using down/up for full reload
                        (
                            if cd "$HOME/vero" 2>/dev/null; then
                                echo -e "${UI_MUTED}    → Restarting Vero to apply changes...${NC}" >&2
                                docker compose down > /dev/null 2>&1 || true
                                sleep 2
                                docker compose up -d > /dev/null 2>&1 || true
                                [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
                            fi
                        )
                    else
                        echo -e "${RED}    → Error: Failed to validate updated .env file${NC}" >&2
                        # Restore from backup
                        mv "${env_file}.backup" "$env_file" 2>/dev/null || true
                        rm -f "$temp_file"
                        return 1
                    fi
                else
                    echo -e "${RED}    → Error: Failed to update .env file${NC}" >&2
                    # Restore from backup
                    mv "${env_file}.backup" "$env_file" 2>/dev/null || true
                    rm -f "$temp_file"
                    return 1
                fi
            else
                echo -e "${RED}    → Error: No valid beacon nodes found for Vero${NC}" >&2
                return 1
            fi
        else
            echo -e "${UI_MUTED}    → Removed ethnode was not in Vero's configuration${NC}" >&2
        fi
    fi
}

# Clean up monitoring data for removed ethnode
cleanup_removed_ethnode_monitoring() {
    local removed_node="$1"
    
    echo -e "${UI_MUTED}    → Cleaning up monitoring data for $removed_node...${NC}" >&2
    
    # Remove Grafana dashboards for this ethnode
    if [[ -d "$HOME/monitoring" ]] && command -v curl >/dev/null 2>&1; then
        # Check if Grafana is running
        if docker ps --format "{{.Names}}" | grep -q "monitoring-grafana"; then
            # Get Grafana URL from monitoring configuration
            local bind_ip="localhost"
            local grafana_port="3000"
            if [[ -f "$HOME/monitoring/.env" ]]; then
                bind_ip=$(grep "GRAFANA_BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null || echo "localhost")
                grafana_port=$(grep "GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null || echo "3000")
                [[ "$bind_ip" == "127.0.0.1" ]] && bind_ip="localhost"
            fi
            local grafana_url="http://${bind_ip}:${grafana_port}"
            
            # Get admin credentials
            local admin_user="admin"
            local admin_pass="admin"
            if [[ -f "$HOME/monitoring/.env" ]]; then
                admin_pass=$(grep "GF_SECURITY_ADMIN_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2 || echo "admin")
            fi
            
            # Get list of dashboards and remove ones matching the ethnode
            local dashboards=$(curl -s -u "$admin_user:$admin_pass" "$grafana_url/api/search?type=dash-db" 2>/dev/null || echo "[]")
            
            # Look for dashboards with titles containing the removed node name
            if command -v jq >/dev/null 2>&1; then
                echo "$dashboards" | jq -r ".[] | select(.title | test(\"$removed_node\"; \"i\")) | .uid" 2>/dev/null | while read -r uid; do
                    if [[ -n "$uid" ]]; then
                        curl -s -X DELETE -u "$admin_user:$admin_pass" "$grafana_url/api/dashboards/uid/$uid" > /dev/null 2>&1
                        echo -e "${UI_MUTED}      → Removed dashboard for $removed_node${NC}" >&2
                    fi
                done
            fi
        fi
    fi
    
    # Note: Prometheus metric data cleanup would require more complex operations
    # For now, metrics will naturally expire based on retention settings
    echo -e "${UI_MUTED}    → Metric data will expire naturally per retention policy${NC}" >&2
}
