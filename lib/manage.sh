#!/bin/bash
# lib/manage.sh - Node management and monitoring

# Source dependencies
source "${NODEBOI_LIB}/clients.sh"

# Configuration
CHECK_UPDATES="${CHECK_UPDATES:-true}"

check_prerequisites() {
    echo -e "${GREEN}[INFO]${NC} Checking system prerequisites"
    local missing_tools=()
    local install_docker=false

    for tool in wget curl openssl ufw; do
        if command -v "$tool" &> /dev/null; then
            echo -e "  $tool: ${GREEN}✓${NC}"
        else
            echo -e "  $tool: ${RED}✗${NC}"
            missing_tools+=("$tool")
        fi
    done

    # Check Docker and Docker Compose v2
    if command -v docker &> /dev/null; then
        echo -e "  docker: ${GREEN}✓${NC}"

        # Check for Docker Compose v2 (comes with Docker)
        if docker compose version &>/dev/null 2>&1; then
            echo -e "  docker compose: ${GREEN}✓${NC}"
        else
            echo -e "  docker compose: ${RED}✗${NC}"
            echo -e "  ${YELLOW}Docker is installed but Compose v2 is missing${NC}"
            install_docker=true
        fi
    else
        echo -e "  docker: ${RED}✗${NC}"
        echo -e "  docker compose: ${RED}✗${NC}"
        install_docker=true
    fi

    # Auto-install missing tools if any
    if [[ ${#missing_tools[@]} -gt 0 ]] || [[ "$install_docker" == true ]]; then
        echo -e "\n${RED}Missing required tools:${NC}"

        for tool in "${missing_tools[@]}"; do
            case $tool in
                wget) echo "  • wget - needed for downloading client binaries" ;;
                curl) echo "  • curl - needed for API calls and version checks" ;;
                openssl) echo "  • openssl - needed for generating JWT secrets" ;;
                ufw) echo "  • ufw - firewall management for node security" ;;
            esac
        done

        [[ "$install_docker" == true ]] && echo "  • docker/docker compose v2 - essential for running node containers"

        echo -e "\n${YELLOW}These tools are necessary for running NODEBOI.${NC}"
        read -p "Would you like to install the missing prerequisites now? [y/n]: " -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "Installing missing tools..."

            sudo apt update

            if [[ ${#missing_tools[@]} -gt 0 ]]; then
                sudo apt install -y "${missing_tools[@]}"
            fi

            if [[ "$install_docker" == true ]]; then
                echo "Installing Docker with Compose v2 (this may take a few minutes)..."
                sudo apt remove -y docker docker-engine docker.io containerd runc docker compose 2>/dev/null || true
                curl -fsSL https://get.docker.com | sudo sh
                sudo usermod -aG docker $USER
                sudo apt install -y docker compose-plugin
                echo -e "${YELLOW}⚠ Important: You'll need to log out and back in for Docker permissions to take effect.${NC}"
                echo "Or run: newgrp docker"
            fi

            echo -e "${GREEN}✓ Prerequisites installed successfully${NC}"

            if [[ "$install_docker" == true ]]; then
                echo -e "${YELLOW}Note: If Docker commands fail, please log out and back in first.${NC}"
            fi
        else
            echo -e "${RED}[ERROR]${NC} Cannot proceed without required tools."
            echo "To install manually, run:"
            echo "  sudo apt update && sudo apt install -y ${missing_tools[*]}"
            [[ "$install_docker" == true ]] && echo "  curl -fsSL https://get.docker.com | sudo sh && sudo apt install -y docker compose-plugin"
            return 1
        fi
    else
        echo -e "${GREEN}✓${NC} All prerequisites satisfied"
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
get_all_used_ports() {
    local used_ports=""

    # Get system ports from netstat/ss
    if command -v ss &>/dev/null; then
        used_ports+=$(ss -tuln 2>/dev/null | awk '/LISTEN/ {print $5}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    else
        used_ports+=$(netstat -tuln 2>/dev/null | awk '/LISTEN/ {print $4}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    fi

    # Get Docker exposed ports - FIXED to handle ranges
    local docker_ports=$(docker ps --format "table {{.Ports}}" 2>/dev/null | tail -n +2)

    # Extract single ports
    used_ports+=" $(echo "$docker_ports" | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"

    # Handle port ranges like 30304-30305
    local ranges=$(echo "$docker_ports" | grep -oE '[0-9]+-[0-9]+' || true)
    if [[ -n "$ranges" ]]; then
        while IFS= read -r range; do
            local start=$(echo "$range" | cut -d'-' -f1)
            local end=$(echo "$range" | cut -d'-' -f2)
            for ((port=start; port<=end; port++)); do
                used_ports+=" $port"
            done
        done <<< "$ranges"
    fi

    # Get ports from all ethnode .env files
    for env_file in "$HOME"/ethnode*/.env; do
        [[ -f "$env_file" ]] || continue
        used_ports+=" $(grep -E '_PORT=' "$env_file" 2>/dev/null | cut -d'=' -f2 | sort -u | tr '\n' ' ')"
    done

    # Remove duplicates and return
    echo "$used_ports" | tr ' ' '\n' | sort -nu | tr '\n' ' '
}
is_port_available() {
    local port=$1
    local used_ports="${2:-}"  # Make second parameter optional with default empty string

    # Check if port is in the used ports list
    [[ -n "$used_ports" ]] && echo " $used_ports " | grep -q " $port " && return 1

    # Double-check with nc (netcat) if available
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 "$port" 2>/dev/null && return 1
    fi

    return 0
}
find_available_port() {
    local base_port=$1
    local increment="${2:-2}"  # Default to 2 if not provided
    local used_ports="${3:-}"  # Default to empty if not provided
    local max_attempts=50

    for ((i=0; i<max_attempts; i++)); do
        local port=$((base_port + (i * increment)))
        if is_port_available "$port" "$used_ports"; then
            echo "$port"
            return 0
        fi
    done

    echo "Error: Could not find available port starting from $base_port" >&2
    return 1
}
verify_ports_available() {
    local node_dir=$1

    if [[ ! -f "$node_dir/.env" ]]; then
        return 0
    fi

    local failed_ports=""
    local used_ports=$(get_all_used_ports)

    # Extract ports from .env
    while IFS='=' read -r key value; do
        if [[ "$key" == *"_PORT"* && -n "$value" ]]; then
            if ! is_port_available "$value" "$used_ports"; then
                failed_ports+=" $value"
            fi
        fi
    done < "$node_dir/.env"

    if [[ -n "$failed_ports" ]]; then
        echo -e "${RED}[ERROR]${NC} These ports are already in use:$failed_ports" >&2
        echo "Please check for conflicting services or other ethnode instances." >&2
        return 1
    fi

    return 0
}
safe_docker_stop() {
    local node_name=$1
    local node_dir="$HOME/$node_name"

    echo "Stopping $node_name..."
    cd "$node_dir" 2>/dev/null || return 1

    # Try graceful stop with 30 second timeout
    if ! timeout 30 docker compose down 2>/dev/null; then
        echo "  Graceful stop failed, forcing stop..."

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

    echo "Removing $node_name..." >&2

    # Stop and remove containers using safe stop
    if [[ -f "$node_dir/compose.yml" ]]; then
        echo "  Stopping containers..." >&2
        safe_docker_stop "$node_name"
    fi

    # Remove any remaining containers
    echo "  Checking for remaining containers..." >&2
    local containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^${node_name}-" || true)
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read container; do
            echo "    Removing container: $container" >&2
            docker rm -f "$container" 2>/dev/null || true
        done
    fi

    # Remove Docker volumes
    echo "  Removing volumes..." >&2
    local volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^${node_name}" || true)
    if [[ -n "$volumes" ]]; then
        echo "$volumes" | while read volume; do
            echo "    Removing volume: $volume" >&2
            docker volume rm -f "$volume" 2>/dev/null || true
        done
    fi

    # Remove network, directory, and user
    docker network rm "${node_name}-net" 2>/dev/null || true
    [[ -d "$node_dir" ]] && sudo rm -rf "$node_dir"
    id "$node_name" &>/dev/null && sudo userdel -r "$node_name" 2>/dev/null || true

    echo "  ✓ $node_name removed successfully" >&2
}
remove_nodes_menu() {
    echo -e "\n${CYAN}${BOLD}Node Removal${NC}\n=============\n"

    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found to remove."
        press_enter
        return
    fi

    echo "Existing nodes:"
    for i in "${!nodes[@]}"; do
        echo "  $((i+1))) ${nodes[$i]}"
    done
    echo "  C) Cancel"
    echo

    read -p "Enter node number to remove, or C to cancel: " choice

    [[ "${choice^^}" == "C" ]] && { echo "Removal cancelled."; return; }

    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_to_remove="${nodes[$((choice-1))]}"

        echo -e "\nWill remove: $node_to_remove\n"
        read -p "Are you sure? This cannot be undone! [y/n]: " -r
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            remove_node "$node_to_remove"
            echo -e "\n${GREEN}✓ Removal complete${NC}"
        else
            echo "Removal cancelled."
        fi
    else
        echo "Invalid selection."
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

    # Check for updates
  if [[ "$CHECK_UPDATES" == "true" ]]; then
    local exec_client_lower=$(echo "$exec_client" | tr '[:upper:]' '[:lower:]')
    local cons_client_lower=$(echo "$cons_client" | tr '[:upper:]' '[:lower:]')

    if [[ -n "$exec_client_lower" ]] && [[ "$exec_client_lower" != "unknown" ]]; then
        local latest_exec=$(get_latest_version "$exec_client_lower" 2>/dev/null)
        if [[ -n "$latest_exec" ]] && [[ -n "$exec_version" ]]; then
            local exec_version_normalized=${exec_version#v}
            local latest_exec_normalized=${latest_exec#v}
            if [[ "$latest_exec_normalized" != "$exec_version_normalized" ]] && [[ -n "$latest_exec_normalized" ]]; then
                # Check if Docker image actually exists before showing arrow
                if [[ "$latest_exec_normalized" != "$exec_version_normalized" ]] && [[ -n "$latest_exec_normalized" ]]; then
                    exec_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi
    fi

    if [[ -n "$cons_client_lower" ]] && [[ "$cons_client_lower" != "unknown" ]]; then
        local latest_cons=$(get_latest_version "$cons_client_lower" 2>/dev/null)
        if [[ -n "$latest_cons" ]] && [[ -n "$cons_version" ]]; then
            local cons_version_normalized=${cons_version#v}
            local latest_cons_normalized=${latest_cons#v}
            if [[ "$latest_cons_normalized" != "$cons_version_normalized" ]] && [[ -n "$latest_cons_normalized" ]]; then
                # Check if Docker image actually exists before showing arrow
                if [[ "$latest_cons_normalized" != "$cons_version_normalized" ]] && [[ -n "$latest_cons_normalized" ]]; then
                    cons_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi
    fi
fi

    # Check container status
    local containers_running=false
    cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q . && containers_running=true

    # Initialize status variables
    local el_check="${RED}✗${NC}"
    local cl_check="${RED}✗${NC}"
    local el_sync_status=""
    local cl_sync_status=""

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
            # Check for various states
            if echo "$cl_sync_response" | grep -q '"el_offline":true'; then
                cl_sync_status=" (EL Offline)"
            elif echo "$cl_sync_response" | grep -q '"is_syncing":true'; then
                cl_sync_status=" (Syncing)"
            elif echo "$cl_sync_response" | grep -q '"is_optimistic":true'; then
                cl_sync_status=" (Optimistic)"
            fi
        elif curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 2 2>/dev/null | grep -q '"data"'; then
            cl_check="${GREEN}✓${NC}"
            cl_sync_status=" (Starting)"
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

    # Display status with sync info and correct endpoints
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} $node_name ($network)$access_indicator"

        # Execution client line
        printf "     %b %-20s (%s)%b\t\thttp://%s:%s\n" \
            "$el_check" "${exec_client}${el_sync_status}" "$exec_version" "$exec_update_indicator" "$endpoint_host" "$el_rpc"

        # Consensus client line
        printf "     %b %-20s (%s)%b\t\thttp://%s:%s\n" \
            "$cl_check" "${cons_client}${cl_sync_status}" "$cons_version" "$cons_update_indicator" "$endpoint_host" "$cl_rest"
    else
        echo -e "  ${RED}●${NC} $node_name ($network) - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\n" "$exec_client" "$exec_version" "$exec_update_indicator"
        printf "     %-20s (%s)%b\n" "$cons_client" "$cons_version" "$cons_update_indicator"
    fi
    echo
}
print_dashboard() {
    echo -e "${BOLD}Node Status Dashboard${NC}\n====================\n"

    local found=false
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            found=true
            check_node_health "$dir"
        fi
    done

    if [[ "$found" == false ]]; then
        echo "  No nodes installed\n"
    else
        echo "─────────────────────────────"
        echo -e "Legend: ${GREEN}●${NC} Running | ${RED}●${NC} Stopped | ${GREEN}✓${NC} Healthy | ${RED}✗${NC} Unhealthy | ${YELLOW}⬆${NC} Update"
        echo -e "Access: ${GREEN}[M]${NC} My machine | ${YELLOW}[L]${NC} Local network | ${RED}[A]${NC} All networks"
        echo
    fi
}

# Print plugin service dashboard
print_plugin_dashboard() {
    # Wrap everything in a subshell to prevent any failures from exiting the main script
    (
        local found_plugins=false
        
        # Check for SSV operators - use find to avoid glob issues
        if [[ -d "$HOME" ]]; then
            while IFS= read -r dir; do
                if [[ -f "$dir/.env" ]]; then
                    if [[ "$found_plugins" == false ]]; then
                        echo -e "${BOLD}Plugin Services${NC}\n===============\n"
                        found_plugins=true
                    fi
                    check_plugin_status "$dir" 2>/dev/null || true
                fi
            done < <(find "$HOME" -maxdepth 1 -type d -name "ssv*" 2>/dev/null || true)
        fi
        
        # Check for Vero monitor
        if [[ -d "$HOME/vero-monitor" && -f "$HOME/vero-monitor/.env" ]]; then
            if [[ "$found_plugins" == false ]]; then
                echo -e "${BOLD}Plugin Services${NC}\n===============\n"
                found_plugins=true
            fi
            check_plugin_status "$HOME/vero-monitor" 2>/dev/null || true
        fi
        
        [[ "$found_plugins" == true ]] && echo
    ) 2>/dev/null || true
    # Function always succeeds
    return 0
}
# Check individual plugin status (simplified)
check_plugin_status() {
    local plugin_dir=$1
    local plugin_name=$(basename "$plugin_dir")
    local plugin_type=""
    
    # Determine plugin type
    [[ "$plugin_name" =~ ^ssv ]] && plugin_type="SSV"
    [[ "$plugin_name" == "vero-monitor" ]] && plugin_type="Vero"
    
    # Check if running
    local status="${RED}●${NC}"
    if cd "$plugin_dir" 2>/dev/null && \
       docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
        status="${GREEN}●${NC}"
    fi
    
    # Display based on type
    case "$plugin_type" in
        SSV)
            local target=$(grep "^TARGET_NODE=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
            echo -e "  $status $plugin_name → $target"
            ;;
        Vero)
            local port=$(grep "^VERO_PORT=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
            local nodes=$(grep "^MONITORED_NODES=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
            echo -e "  $status Vero Monitor (port $port)"
            [[ -n "$nodes" ]] && echo "       Monitoring: $nodes"
            ;;
    esac
}

# Extended node details to show connected plugins
show_node_details_extended() {
    # Call original function
    show_node_details
    
    # Add plugin connections
    echo -e "\n${BOLD}Plugin Connections:${NC}"
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            echo -e "\n  $node_name:"
            
            # Find SSV operators connected to this node
            for ssv_dir in "$HOME"/ssv*; do
                if [[ -f "$ssv_dir/.env" ]]; then
                    local target=$(grep "^TARGET_NODE=" "$ssv_dir/.env" 2>/dev/null | cut -d'=' -f2)
                    if [[ "$target" == "$node_name" ]]; then
                        echo "    • $(basename "$ssv_dir") (SSV operator)"
                    fi
                fi
            done
            
            # Check if monitored by Vero
            if [[ -f "$HOME/vero-monitor/.env" ]]; then
                local monitored=$(grep "^MONITORED_NODES=" "$HOME/vero-monitor/.env" 2>/dev/null | cut -d'=' -f2)
                if [[ "$monitored" == *"$node_name"* ]]; then
                    echo "    • Vero monitor"
                fi
            fi
        fi
    done
    
    press_enter
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
            echo "  Network: $network"
            echo "  Clients: $exec_client / $cons_client"
            echo "  Directory: $dir"

            # Check containers
            if cd "$dir" 2>/dev/null; then
                local services=$(docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | tail -n +2)
                if [[ -n "$services" ]]; then
                    echo "  Services:"
                    while IFS= read -r line; do
                        echo "    $line"
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

            echo "  Endpoints:"
            echo "    Execution RPC:  http://${check_host}:${el_rpc}"
            echo "    Execution WS:   ws://localhost:${el_ws}"
            echo "    Consensus REST: http://${check_host}:${cl_rest}"
            echo "  P2P Ports (need to be forwarded in your router):"
            echo -e "    Execution P2P:  ${YELLOW}${el_p2p}${NC}/TCP+UDP"
            echo -e "    Consensus P2P:  ${YELLOW}${cl_p2p}${NC}/TCP+UDP"
        fi
    done

    press_enter
}
manage_node_state() {
    echo -e "\n${CYAN}${BOLD}Manage Nodes${NC}\n============\n"

    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found."
        press_enter
        return
    fi

    echo "Select node:"
    for i in "${!nodes[@]}"; do
        local node_dir="$HOME/${nodes[$i]}"
        local status="${RED}Stopped${NC}"

        # Check if running
        if cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
            status="${GREEN}Running${NC}"
        fi

        echo -e "  $((i+1))) ${nodes[$i]} [$status]"  # FIXED: Added -e flag here
    done
    echo "  A) Start all stopped nodes"
    echo "  S) Stop all running nodes"
    echo "  C) Cancel"
    echo

    read -p "Enter choice: " choice
    [[ "${choice^^}" == "C" ]] && return

    # Handle "all" options
    if [[ "${choice^^}" == "A" ]]; then
        for node_name in "${nodes[@]}"; do
            local node_dir="$HOME/$node_name"
            if ! (cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .); then
                echo "Starting $node_name..."
                cd "$node_dir" && docker compose up -d
            fi
        done
        echo -e "${GREEN}✓ All stopped nodes started${NC}"
        press_enter
        return
    elif [[ "${choice^^}" == "S" ]]; then
        for node_name in "${nodes[@]}"; do
            if cd "$HOME/$node_name" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
                safe_docker_stop "$node_name"
            fi
        done
        echo -e "${GREEN}✓ All running nodes stopped${NC}"
        press_enter
        return
    fi

    # Handle single node
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_name="${nodes[$((choice-1))]}"
        local node_dir="$HOME/$node_name"

        echo -e "\n${BOLD}Actions for $node_name:${NC}"
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart"
        echo "  4) View logs (live)"
        echo "  5) View logs (last 100 lines)"
        echo "  C) Cancel"
        echo

        read -p "Enter action: " action

        case $action in
            1)
                echo "Starting $node_name..."
                cd "$node_dir" && docker compose up -d
                echo -e "${GREEN}✓ Started${NC}"
                ;;
            2)
                safe_docker_stop "$node_name"
                echo -e "${GREEN}✓ Stopped${NC}"
                ;;
            3)
                echo "Restarting $node_name..."
                safe_docker_stop "$node_name"
                cd "$node_dir" && docker compose up -d
                echo -e "${GREEN}✓ Restarted${NC}"
                ;;
            4)
                echo "Showing live logs (Ctrl+C to exit)..."
                cd "$node_dir" && docker compose logs -f --tail=50
                ;;
            5)
                cd "$node_dir" && docker compose logs --tail=100
                ;;
            *)
                return
                ;;
        esac
    fi

    press_enter
}

update_nodeboi() {
    clear
    print_header
    echo -e "${BOLD}Update NODEBOI${NC}\n==============="
    echo
    echo "This will update NODEBOI to the latest version from GitHub."
    echo
    read -p "Do you want to continue? (y/n): " -r
    echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    # Get current version before update
    local current_version="${SCRIPT_VERSION}"

    # Run the update script
    if [[ -f "$HOME/.nodeboi/update.sh" ]]; then
        bash "$HOME/.nodeboi/update.sh"

        # Get new version from updated file
        # Replace the new_version detection line with:
        local new_version=$(head -20 "$HOME/.nodeboi/nodeboi.sh" | grep -m1 "SCRIPT_VERSION=" | sed 's/.*VERSION=["'\'']*\([^"'\'']*\).*/\1/')

        if [[ "$current_version" != "$new_version" ]]; then
            echo -e "\n${GREEN}✓ NODEBOI updated from v${current_version} to v${new_version}${NC}"
        else
            echo -e "\n${GREEN}✓ NODEBOI is already up to date (v${current_version})${NC}"
        fi

        echo -e "${CYAN}Restarting NODEBOI...${NC}\n"
        sleep 2
        # Restart the script to load new version
        exec "$0"
    else
        echo -e "${RED}[ERROR]${NC} Update script not found at $HOME/.nodeboi/update.sh"
        echo "You may need to reinstall NODEBOI."
        press_enter
    fi
else
    echo "Update cancelled."
    press_enter
fi
}
