#!/bin/bash
# lib/manage.sh - Node management and monitoring

# Source dependencies
source "${NODEBOI_LIB}/clients.sh"
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh"

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

    for tool in wget curl openssl ufw; do
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
                ufw) echo -e "${UI_MUTED}  • ufw - firewall management for node security${NC}" ;;
            esac
        done

        [[ "$install_docker" == true ]] && echo -e "${UI_MUTED}  • docker/docker compose v2 - essential for running node containers${NC}"

        echo -e "\n${YELLOW}These tools are necessary for running NODEBOI.${NC}"
        read -p "Would you like to install the missing prerequisites now? [y/n]: " -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo -e "${UI_MUTED}Installing missing tools...${NC}"

            sudo apt update

            if [[ ${#missing_tools[@]} -gt 0 ]]; then
                sudo apt install -y "${missing_tools[@]}"
            fi

            if [[ "$install_docker" == true ]]; then
                echo -e "${UI_MUTED}Installing Docker with Compose v2 (this may take a few minutes)...${NC}"
                sudo apt remove -y docker docker-engine docker.io containerd runc docker compose 2>/dev/null || true
                curl -fsSL https://get.docker.com | sudo sh
                sudo usermod -aG docker $USER
                sudo apt install -y docker compose-plugin
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
            [[ "$install_docker" == true ]] && echo -e "${UI_MUTED}  curl -fsSL https://get.docker.com | sudo sh && sudo apt install -y docker compose-plugin${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✓${NC} ${UI_MUTED}All prerequisites satisfied${NC}"
    fi
}
detect_existing_instances() {
    echo -e "${GREEN}[INFO]${NC} Scanning for existing Ethereum instances..."
    local found=false

    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            echo -e "  Found: ${GREEN}$(basename "$dir")${NC}"
            found=true
        fi
    done

    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "ethnode"; then
        echo -e "  Found running Docker containers"
        found=true
    fi

    [[ "$found" == true ]] && echo -e "${YELLOW}Note: Existing instances detected. Ports will be auto-adjusted.${NC}" || echo "  No existing instances found"
    return $([[ "$found" == true ]] && echo 0 || echo 1)
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

    echo -e "${UI_MUTED}Removing $node_name...${NC}" >&2

    # Stop and remove containers using safe stop
    if [[ -f "$node_dir/compose.yml" ]]; then
        echo -e "${UI_MUTED}  Stopping containers...${NC}" >&2
        safe_docker_stop "$node_name"
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

    # Remove network, directory, and user
    docker network rm "${node_name}-net" 2>/dev/null || true
    [[ -d "$node_dir" ]] && sudo rm -rf "$node_dir"
    id "$node_name" &>/dev/null && sudo userdel -r "$node_name" 2>/dev/null || true

    echo -e "${UI_MUTED}  ✓ $node_name removed successfully${NC}" >&2
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
            remove_node "$node_to_remove"
            echo -e "${GREEN}Node $node_to_remove removed successfully${NC}"
        else
            print_box "Removal cancelled" "info"
        fi
    fi
    
    press_enter
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
    --max-time 2 2>/dev/null)

        if [[ -n "$sync_response" ]] && echo "$sync_response" | grep -q '"result"'; then
            el_check="${GREEN}✓${NC}"
            
            # Get actual running version
            local version_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
                --max-time 2 2>/dev/null)
            if [[ -n "$version_response" ]] && echo "$version_response" | grep -q '"result"'; then
                local client_version=$(echo "$version_response" | grep -o '"result":"[^"]*"' | cut -d'"' -f4)
                if [[ -n "$client_version" ]]; then
                    # Extract version number from client string (e.g., "Reth/v1.6.0" -> "v1.6.0")
                    exec_version=$(echo "$client_version" | grep -o 'v[0-9][0-9.]*' || echo "$client_version" | grep -o '[0-9][0-9.]*')
                fi
            fi
            
            # Check if syncing (result is not false)
            if ! echo "$sync_response" | grep -q '"result":false'; then
                el_sync_status=" (Syncing)"
            elif echo "$sync_response" | grep -q '"result":false'; then
                # Check if actually synced or waiting
                local block_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                    -H "Content-Type: application/json" \
                    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                    --max-time 2 2>/dev/null)

                if echo "$block_response" | grep -q '"result":"0x0"'; then
                    el_sync_status=" (Waiting)"
                else
                    # Synced - don't show status
                    el_sync_status=""
                fi
            fi
        elif curl -s -X POST "http://${check_host}:${el_rpc}" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
            --max-time 2 2>/dev/null | grep -q '"result"'; then
            el_check="${GREEN}✓${NC}"
            el_sync_status=" (Starting)"
        fi

        # Check consensus client health and sync
        local cl_sync_response=$(curl -s "http://${check_host}:${cl_rest}/eth/v1/node/syncing" --max-time 2 2>/dev/null)

        if [[ -n "$cl_sync_response" ]]; then
            cl_check="${GREEN}✓${NC}"
            
            # Get actual running version
            local cl_version_response=$(curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 2 2>/dev/null)
            if [[ -n "$cl_version_response" ]] && echo "$cl_version_response" | grep -q '"data"'; then
                local client_version=$(echo "$cl_version_response" | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
                if [[ -n "$client_version" ]]; then
                    # Extract version number from client string (e.g., "teku/25.6.0" -> "25.6.0")
                    cons_version=$(echo "$client_version" | grep -o 'v[0-9][0-9.]*' || echo "$client_version" | grep -o '[0-9][0-9.]*' | head -1)
                fi
            fi
            
            # Check for various states - prioritize syncing over EL offline
            if echo "$cl_sync_response" | grep -q '"is_syncing":true'; then
                cl_sync_status=" (Syncing)"
            elif echo "$cl_sync_response" | grep -q '"el_offline":true'; then
                # Only show EL Offline if not syncing (indicates real connectivity issue)
                cl_sync_status=" (EL Offline)"
            else
                # Synced or optimistic - don't show status
                cl_sync_status=""
            fi
        elif curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 2 2>/dev/null | grep -q '"data"'; then
            cl_check="${GREEN}✓${NC}"
            cl_sync_status=" (Starting)"
        fi

        # Check MEV-boost health using the configured port
        local mevboost_port=$(grep "MEVBOOST_PORT=" "$node_dir/.env" | cut -d'=' -f2)
        local mevboost_response=""
        if [[ -n "$mevboost_port" ]]; then
            mevboost_response=$(curl -s "http://${check_host}:${mevboost_port}/eth/v1/builder/status" --max-time 2 2>/dev/null)
        fi
        if [[ -n "$mevboost_response" ]]; then
            mevboost_check="${GREEN}✓${NC}"
            # Try to extract MEV-boost version from docker container
            local container_name=$(docker ps --format "table {{.Names}}" | grep "$node_name-mevboost" | head -1)
            if [[ -n "$container_name" ]]; then
                # Extract version from image tag (e.g., flashbots/mev-boost:1.9 -> 1.9)
                mevboost_version=$(docker inspect "$container_name" --format='{{.Config.Image}}' 2>/dev/null | grep -o ':[0-9][0-9.]*$' | cut -c2- || echo "latest")
                [[ -z "$mevboost_version" ]] && mevboost_version="latest"
            fi
        fi
    fi

    # Determine endpoint display based on HOST_IP with NEW indicators
    local endpoint_host="localhost"
    local access_indicator=""

    if [[ "$host_ip" == "127.0.0.1" ]]; then
        endpoint_host="localhost"
        access_indicator=" ${GREEN}[M]${NC}"  # My machine only
    elif [[ "$host_ip" == "0.0.0.0" ]]; then
        # Show actual LAN IP if bound to all interfaces
        endpoint_host=$(hostname -I | awk '{print $1}')
        access_indicator=" ${RED}[A]${NC}"  # All networks
    elif [[ -n "$host_ip" ]]; then
        endpoint_host="$host_ip"
        access_indicator=" ${YELLOW}[L]${NC}"  # Local network
    fi

    # Check for updates - now after we have real versions from APIs
    if [[ "$CHECK_UPDATES" == "true" ]]; then
        local exec_client_lower=$(echo "$exec_client" | tr '[:upper:]' '[:lower:]')
        local cons_client_lower=$(echo "$cons_client" | tr '[:upper:]' '[:lower:]')

        if [[ -n "$exec_client_lower" ]] && [[ "$exec_client_lower" != "unknown" ]]; then
            local latest_exec=$(get_latest_version "$exec_client_lower" 2>/dev/null)
            if [[ -n "$latest_exec" ]] && [[ -n "$exec_version" ]]; then
                local exec_version_normalized=$(normalize_version "$exec_client_lower" "$exec_version")
                local latest_exec_normalized=$(normalize_version "$exec_client_lower" "$latest_exec")
                if [[ "$latest_exec_normalized" != "$exec_version_normalized" ]] && [[ -n "$latest_exec_normalized" ]]; then
                    exec_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi

        if [[ -n "$cons_client_lower" ]] && [[ "$cons_client_lower" != "unknown" ]]; then
            local latest_cons=$(get_latest_version "$cons_client_lower" 2>/dev/null)
            if [[ -n "$latest_cons" ]] && [[ -n "$cons_version" ]]; then
                local cons_version_normalized=$(normalize_version "$cons_client_lower" "$cons_version")
                local latest_cons_normalized=$(normalize_version "$cons_client_lower" "$latest_cons")
                if [[ "$latest_cons_normalized" != "$cons_version_normalized" ]] && [[ -n "$latest_cons_normalized" ]]; then
                    cons_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi

        # Check MEV-boost updates if it's running
        if [[ "$mevboost_check" == "${GREEN}✓${NC}" ]] && [[ "$mevboost_version" != "unknown" ]]; then
            local latest_mevboost=$(get_latest_version "mevboost" 2>/dev/null)
            if [[ -n "$latest_mevboost" ]] && [[ -n "$mevboost_version" ]]; then
                local mevboost_version_normalized=$(normalize_version "mevboost" "$mevboost_version")
                local latest_mevboost_normalized=$(normalize_version "mevboost" "$latest_mevboost")
                if [[ "$latest_mevboost_normalized" != "$mevboost_version_normalized" ]] && [[ -n "$latest_mevboost_normalized" ]]; then
                    mevboost_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi
    fi

    # Display status with sync info and correct endpoints
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} $node_name ($network)$access_indicator"

        # Execution client line
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" \
            "$el_check" "${exec_client}${el_sync_status}" "$exec_version" "$exec_update_indicator" "$endpoint_host" "$el_rpc"

        # Consensus client line
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" \
            "$cl_check" "${cons_client}${cl_sync_status}" "$cons_version" "$cons_update_indicator" "$endpoint_host" "$cl_rest"

        # MEV-boost line (only show if it's running)
        if [[ "$mevboost_check" == "${GREEN}✓${NC}" ]]; then
            printf "     %b %-20s (%s)%b\t     http://%s:%s\n" \
                "$mevboost_check" "MEV-boost" "$mevboost_version" "$mevboost_update_indicator" "$endpoint_host" "$mevboost_port"
        fi
    else
        echo -e "  ${RED}●${NC} $node_name ($network) - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\n" "$exec_client" "$exec_version" "$exec_update_indicator"
        printf "     %-20s (%s)%b\n" "$cons_client" "$cons_version" "$cons_update_indicator"
    fi

    echo
}
print_dashboard() {
    cleanup_version_cache 
    echo -e "${BOLD}Node Status Dashboard${NC}\n====================\n"

    local found=false
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" && -f "$dir/compose.yml" ]]; then
            found=true
            check_node_health "$dir"
        fi
    done

    if [[ "$found" == false ]]; then
        echo -e "${UI_MUTED}  No nodes installed${NC}\n"
    else
        echo -e "${UI_MUTED}─────────────────────────────${NC}"
        echo -e "${UI_MUTED}Legend: ${GREEN}●${NC} ${UI_MUTED}Running${NC} | ${RED}●${NC} ${UI_MUTED}Stopped${NC} | ${GREEN}✓${NC} ${UI_MUTED}Healthy${NC} | ${RED}✗${NC} ${UI_MUTED}Unhealthy${NC} | ${YELLOW}⬆${NC} ${UI_MUTED}Update${NC}"
        echo -e "${UI_MUTED}Access: ${GREEN}[M]${NC} ${UI_MUTED}My machine${NC} | ${YELLOW}[L]${NC} ${UI_MUTED}Local network${NC} | ${RED}[A]${NC} ${UI_MUTED}All networks${NC}"
        echo
    fi
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
                    echo -e "${UI_MUTED}Starting ${nodes[$i]}...${NC}"
                    cd "$HOME/${nodes[$i]}" && docker compose up -d > /dev/null 2>&1
                fi
            done
            print_box "All stopped nodes started" "success"
            
        elif [[ $selection -eq $((total_nodes + 1)) ]]; then
            # Stop all running
            echo -e "\n${UI_MUTED}Stopping all running nodes...${NC}\n"
            for i in "${!nodes[@]}"; do
                if [[ "${node_status[$i]}" == "Running" ]]; then
                    safe_docker_stop "${nodes[$i]}"
                fi
            done
            print_box "All running nodes stopped" "success"
            
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
                        echo -e "\n${YELLOW}Starting $node_name...${NC}"
                        cd "$node_dir" && docker compose up -d > /dev/null 2>&1
                        print_box "$node_name started" "success"
                        ;;
                    1)
                        echo -e "\n${UI_MUTED}Stopping $node_name...${NC}"
                        safe_docker_stop "$node_name"
                        print_box "$node_name stopped" "success"
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

# Enhanced log viewing system
view_logs_menu() {
    while true; do
        local log_options=(
            "View logs for specific node"
            "View logs for all nodes (consolidated)"
            "View logs by service type"
            "Split-screen log viewer (all clients)"
            "Follow logs (live) - specific node"
            "Follow logs (live) - all nodes"
            "Back to manage nodes menu"
        )

        local selection
        if selection=$(fancy_select_menu "Log Viewer" "${log_options[@]}"); then
            case $selection in
                0) view_single_node_logs ;;
                1) view_all_nodes_logs ;;
                2) view_logs_by_service ;;
                3) view_split_screen_logs ;;
                4) follow_single_node_logs ;;
                5) follow_all_nodes_logs ;;
                6) return ;;
            esac
        else
            return
        fi
    done
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
