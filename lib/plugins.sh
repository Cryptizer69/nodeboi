#!/bin/bash
# lib/plugins.sh - Plugin service management (parallel to install.sh/manage.sh)

# Plugin registry with metadata
declare -gA PLUGIN_INFO=(
    ["ssv"]="SSV Network Operator:Single node validator infrastructure"
    ["vero"]="Vero Monitor:Multi-node monitoring dashboard"
    ["web3signer"]="Web3Signer:Remote signing service"
)

# Get next instance number for plugin type
get_next_plugin_instance() {
    local plugin_type=$1
    local num=1
    while [[ -d "$HOME/${plugin_type}${num}" ]]; do
        ((num++))
    done
    echo $num
}

# Discover installed plugin services
discover_plugin_services() {
    local plugin_dirs=()
    
    # Look for known plugin patterns
    for pattern in ssv-* vero-* web3signer-*; do
        for dir in "$HOME"/$pattern; do
            [[ -d "$dir" && -f "$dir/.env" && -f "$dir/compose.yml" ]] && plugin_dirs+=("$dir")
        done
    done
    
    echo "${plugin_dirs[@]}"
}

# Get plugin type from directory name
get_plugin_type() {
    local dir_name=$1
    [[ "$dir_name" =~ ^ssv ]] && echo "ssv" && return
    [[ "$dir_name" =~ ^vero ]] && echo "vero" && return  
    [[ "$dir_name" =~ ^web3signer ]] && echo "web3signer" && return
    echo "unknown"
}

# Select ethnode for plugin connection
select_ethnode_for_plugin() {
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No ethnodes found. Please install a node first." >&2
        return 1
    fi
    
    echo "Available nodes:" >&2
    for i in "${!nodes[@]}"; do
        local node="${nodes[$i]}"
        local network=$(grep "^NETWORK=" "$HOME/$node/.env" 2>/dev/null | cut -d'=' -f2)
        echo "  $((i+1))) $node ($network)" >&2
    done
    echo >&2
    
    read -p "Select node [1-${#nodes[@]}]: " choice
    
    if [[ $choice -ge 1 && $choice -le ${#nodes[@]} ]]; then
        echo "${nodes[$((choice-1))]}"
        return 0
    else
        return 1
    fi
}

# Copy plugin template files
copy_plugin_template() {
    local plugin_type=$1
    local target_dir=$2
    
    local template_dir="${NODEBOI_HOME}/plugins/templates/${plugin_type}"
    
    # Check if template exists, if not create basic one
    if [[ ! -d "$template_dir" ]]; then
        mkdir -p "$template_dir"
        create_plugin_template "$plugin_type" "$template_dir"
    fi
    
    # Copy template files
    cp "$template_dir"/* "$target_dir/" 2>/dev/null || {
        echo "Warning: No template found for $plugin_type, creating basic compose file" >&2
        create_basic_compose "$plugin_type" "$target_dir/compose.yml"
    }
}

# Create plugin template on the fly
create_plugin_template() {
    local plugin_type=$1
    local template_dir=$2
    
    case "$plugin_type" in
        ssv)
            cat > "$template_dir/compose.yml" << 'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"

services:
  ssv-operator:
    container_name: ${INSTANCE_NAME}
    image: bloxstaking/ssv-node:${SSV_VERSION:-latest}
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    stop_grace_period: 30s
    ports:
      - "${HOST_IP:-}:${SSV_P2P_PORT}:12001/tcp"
      - "${HOST_IP:-}:${SSV_P2P_UDP_PORT}:13001/udp"  
      - "${HOST_IP:-}:${SSV_METRICS_PORT}:15000/tcp"
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - CONFIG_PATH=/data/config.yaml
      - DB_PATH=/data/db
    networks:
      default:
        aliases:
          - ssv
    <<: *logging
    command: |
      start --BaseDataPath /data 
      --BeaconNodeAddr ${BEACON_NODE}
      --ExecutionNodeAddr ${EXECUTION_NODE}  
      --OperatorKey ${SSV_OPERATOR_KEY}
      --MetricsAPIPort 15000

networks:
  default:
    external: true
    name: ${TARGET_NODE_NETWORK}
EOF
            ;;
            
        vero)
            cat > "$template_dir/compose.yml" << 'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"

services:
  vero:
    container_name: ${INSTANCE_NAME}
    image: externalvalidator/vero:${VERO_VERSION:-latest}
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${HOST_IP:-}:${VERO_PORT}:8080"
      - "${HOST_IP:-}:${VERO_METRICS_PORT}:9090"
    volumes:
      - ./data:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - BEACON_NODES=${BEACON_NODES}
    networks:
      - monitoring
    <<: *logging

networks:
  monitoring:
    name: ${INSTANCE_NAME}-net
    driver: bridge
EOF
            ;;
            
        web3signer)
            cat > "$template_dir/compose.yml" << 'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"

services:
  web3signer:
    container_name: ${INSTANCE_NAME}
    image: consensys/web3signer:${WEB3SIGNER_VERSION:-latest}
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${HOST_IP:-}:${WEB3SIGNER_PORT}:9000"
    volumes:
      - ./data:/data
      - ./keys:/keys:ro
      - /etc/localtime:/etc/localtime:ro
    networks:
      default:
        aliases:
          - web3signer
    <<: *logging
    command: |
      --config-file=/data/config.yaml
      eth2

networks:
  default:
    external: true
    name: ${TARGET_NODE_NETWORK}
EOF
            ;;
    esac
}

# Install SSV operator
install_ssv() {
    echo -e "\n${CYAN}${BOLD}Install SSV Operator${NC}\n===================="
    
    # Get instance name
    local default_name="ssv$(get_next_plugin_instance "ssv")"
    read -p "Enter SSV instance name (default: $default_name): " instance_name
    instance_name=${instance_name:-$default_name}
    
    if [[ -d "$HOME/$instance_name" ]]; then
        echo "Error: $instance_name already exists" >&2
        press_enter
        return 1
    fi
    
    # Select target node
    echo
    local target_node=$(select_ethnode_for_plugin)
    [[ -z "$target_node" ]] && return 1
    
    # Get node details
    local node_dir="$HOME/$target_node"
    local cl_rest=$(grep "^CL_REST_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local el_rpc=$(grep "^EL_RPC_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local network=$(grep "^NETWORK=" "$node_dir/.env" | cut -d'=' -f2)
    
    # Create directory structure
    local ssv_dir="$HOME/$instance_name"
    mkdir -p "$ssv_dir/data"
    
    # Copy template
    copy_plugin_template "ssv" "$ssv_dir"
    
    # Get operator key
    echo
    read -p "Enter your SSV operator private key (or press Enter to add later): " operator_key
    
    # Find available ports
    local used_ports=$(get_all_used_ports)
    local ssv_p2p=$(find_available_port 12001 1 "$used_ports")
    local ssv_udp=$(find_available_port 13001 1 "$used_ports")
    local ssv_metrics=$(find_available_port 15000 1 "$used_ports")
    
    # Generate .env file
    cat > "$ssv_dir/.env" <<EOF
# SSV Operator Configuration
# Generated: $(date)
INSTANCE_NAME=$instance_name
NODE_UID=$(id -u)
NODE_GID=$(id -g)

# Target Node Connection  
TARGET_NODE=$target_node
TARGET_NODE_NETWORK=${target_node}-net
BEACON_NODE=http://${target_node}-consensus:5052
EXECUTION_NODE=http://${target_node}-execution:8545

# SSV Configuration
SSV_VERSION=latest
SSV_NETWORK=$network
SSV_OPERATOR_KEY=${operator_key:-YOUR_OPERATOR_KEY_HERE}

# Network Binding
HOST_IP=127.0.0.1

# Port Configuration
SSV_P2P_PORT=$ssv_p2p
SSV_P2P_UDP_PORT=$ssv_udp  
SSV_METRICS_PORT=$ssv_metrics
EOF
    
    echo
    echo -e "${GREEN}✓ SSV operator installed successfully!${NC}"
    echo "  Location: $ssv_dir"
    echo "  Connected to: $target_node ($network)"
    echo "  P2P Port: $ssv_p2p (remember to forward this)"
    echo
    
    if [[ -z "$operator_key" ]]; then
        echo -e "${YELLOW}⚠ Don't forget to add your operator key to $ssv_dir/.env${NC}"
        echo
    fi
    
    read -p "Start SSV operator now? [y/n]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$ssv_dir"
        docker compose up -d
        echo -e "${GREEN}✓ SSV operator started${NC}"
    else
        echo "To start later: cd $ssv_dir && docker compose up -d"
    fi
    
    press_enter
}

# Install Vero monitor
install_vero() {
    echo -e "\n${CYAN}${BOLD}Install Vero Monitor${NC}\n===================="
    
    # Check if already exists
    if [[ -d "$HOME/vero-monitor" ]]; then
        echo "Vero monitor already installed at $HOME/vero-monitor"
        read -p "Remove existing installation? [y/n]: " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            cd "$HOME/vero-monitor"
            docker compose down -v 2>/dev/null || true
            cd "$HOME"
            rm -rf "$HOME/vero-monitor"
        else
            press_enter
            return
        fi
    fi
    
    # Select nodes to monitor
    echo
    echo "Select nodes to monitor with Vero:"
    local beacon_nodes=""
    local selected_nodes=()
    
    for dir in "$HOME"/ethnode*; do
        [[ ! -d "$dir" ]] && continue
        local node_name=$(basename "$dir")
        local network=$(grep "^NETWORK=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)
        read -p "  Monitor $node_name ($network)? [y/n]: " -r
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            local cl_rest=$(grep "^CL_REST_PORT=" "$dir/.env" | cut -d'=' -f2)
            [[ -n "$beacon_nodes" ]] && beacon_nodes+=","
            # Use container name for internal communication
            beacon_nodes+="http://${node_name}-consensus:5052"
            selected_nodes+=("$node_name")
        fi
    done
    
    if [[ -z "$beacon_nodes" ]]; then
        echo "No nodes selected. Aborting installation."
        press_enter
        return
    fi
    
    # Create directory
    local vero_dir="$HOME/vero-monitor"
    mkdir -p "$vero_dir/data"
    
    # Copy template  
    copy_plugin_template "vero" "$vero_dir"
    
    # Find available ports
    local used_ports=$(get_all_used_ports)
    local vero_port=$(find_available_port 8080 1 "$used_ports")
    local vero_metrics=$(find_available_port 9090 1 "$used_ports")
    
    # Generate .env
    cat > "$vero_dir/.env" <<EOF
# Vero Monitor Configuration
# Generated: $(date)
INSTANCE_NAME=vero-monitor
NODE_UID=$(id -u)
NODE_GID=$(id -g)

# Version
VERO_VERSION=latest

# Monitored Nodes
BEACON_NODES=$beacon_nodes
MONITORED_NODES=${selected_nodes[*]}

# Network Binding  
HOST_IP=127.0.0.1

# Ports
VERO_PORT=$vero_port
VERO_METRICS_PORT=$vero_metrics
EOF
    
    # Add networks to compose file for node access
    for node in "${selected_nodes[@]}"; do
        cat >> "$vero_dir/compose.yml" <<EOF

  # Network connection to $node
  ${node}-net:
    external: true
EOF
    done
    
    echo
    echo -e "${GREEN}✓ Vero monitor installed successfully!${NC}"
    echo "  Location: $vero_dir"
    echo "  Monitoring: ${selected_nodes[*]}"
    echo "  Web UI: http://localhost:$vero_port"
    echo
    
    read -p "Start Vero monitor now? [y/n]: " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$vero_dir"
        docker compose up -d
        echo -e "${GREEN}✓ Vero monitor started${NC}"
        echo "  Access dashboard at: http://localhost:$vero_port"
    else
        echo "To start later: cd $vero_dir && docker compose up -d"
    fi
    
    press_enter
}

# Remove plugin service
remove_plugin() {
    echo -e "\n${CYAN}${BOLD}Remove Plugin Service${NC}\n====================="
    
    # List plugin services
    local plugins=()
    for dir in "$HOME"/{ssv*,vero-monitor,web3signer*}; do
        [[ -d "$dir" && -f "$dir/.env" ]] && plugins+=("$(basename "$dir")")
    done
    
    if [[ ${#plugins[@]} -eq 0 ]]; then
        echo "No plugin services found."
        press_enter
        return
    fi
    
    echo "Select plugin to remove:"
    for i in "${!plugins[@]}"; do
        local plugin="${plugins[$i]}"
        local type=$(get_plugin_type "$plugin")
        echo "  $((i+1))) $plugin (${type})"
    done
    echo "  C) Cancel"
    echo
    
    read -p "Enter choice: " choice
    [[ "${choice^^}" == "C" ]] && return
    
    if [[ $choice -ge 1 && $choice -le ${#plugins[@]} ]]; then
        local plugin_name="${plugins[$((choice-1))]}"
        local plugin_dir="$HOME/$plugin_name"
        
        echo
        echo "Will remove: $plugin_name"
        echo "Directory: $plugin_dir"
        read -p "Are you sure? This cannot be undone! [y/n]: " -r
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Stopping containers..."
            cd "$plugin_dir" 2>/dev/null && docker compose down -v
            
            echo "Removing directory..."
            rm -rf "$plugin_dir"
            
            echo -e "${GREEN}✓ Plugin service removed${NC}"
        else
            echo "Removal cancelled."
        fi
    fi
    
    press_enter
}

# Check plugin health (similar to node health)
check_plugin_health() {
    local plugin_dir=$1
    local plugin_name=$(basename "$plugin_dir")
    local plugin_type=$(get_plugin_type "$plugin_name")
    
    # Check if containers running
    local running=false
    cd "$plugin_dir" 2>/dev/null && \
        docker compose ps --services --filter status=running 2>/dev/null | grep -q . && \
        running=true
    
    if [[ "$running" == true ]]; then
        echo -e "  ${GREEN}●${NC} $plugin_name ($plugin_type)"
        
        # Plugin-specific health checks
        case "$plugin_type" in
            ssv)
                local target=$(grep "^TARGET_NODE=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
                echo "     Connected to: $target"
                ;;
            vero)
                local monitored=$(grep "^MONITORED_NODES=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
                local port=$(grep "^VERO_PORT=" "$plugin_dir/.env" 2>/dev/null | cut -d'=' -f2)
                echo "     Monitoring: $monitored"
                echo "     Dashboard: http://localhost:$port"
                ;;
        esac
    else
        echo -e "  ${RED}●${NC} $plugin_name ($plugin_type) - ${RED}Stopped${NC}"
    fi
}

# Plugin management menu
manage_plugins_menu_OLD() {
    while true; do
        clear
        print_header
        
        echo -e "${BOLD}Plugin Services${NC}\n===============\n"
        
        # Show plugin status
        local found=false
        for dir in "$HOME"/{ssv*,vero-monitor,web3signer*}; do
            if [[ -d "$dir" && -f "$dir/.env" ]]; then
                found=true
                check_plugin_health "$dir"
            fi
        done
        
        [[ "$found" == false ]] && echo "  No plugin services installed"
        
        echo
        echo -e "${BOLD}Plugin Menu${NC}\n==========="
        echo "  1) Install SSV operator"
        echo "  2) Install Vero monitor"
        echo "  3) Manage plugin services"
        echo "  4) Remove plugin service"
        echo "  B) Back to main menu"
        echo
        
        read -p "Select option: " choice
        
        case "$choice" in
            1) install_ssv ;;
            2) install_vero ;;
            3) manage_plugin_services ;;
            4) remove_plugin ;;
            [Bb]) return ;;
            *) echo "Invalid option"; press_enter ;;
        esac
    done
}

# Manage plugin services (start/stop/restart)
manage_plugin_services() {
    echo -e "\n${CYAN}${BOLD}Manage Plugin Services${NC}\n======================"
    
    local plugins=()
    for dir in "$HOME"/{ssv*,vero-monitor,web3signer*}; do
        [[ -d "$dir" && -f "$dir/.env" ]] && plugins+=("$(basename "$dir")")
    done
    
    if [[ ${#plugins[@]} -eq 0 ]]; then
        echo "No plugin services found."
        press_enter
        return
    fi
    
    echo "Select plugin service:"
    for i in "${!plugins[@]}"; do
        local plugin="${plugins[$i]}"
        local status="${RED}Stopped${NC}"
        local plugin_dir="$HOME/$plugin"
        
        # Check if running
        if cd "$plugin_dir" 2>/dev/null && \
           docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
            status="${GREEN}Running${NC}"
        fi
        
        echo -e "  $((i+1))) $plugin [$status]"
    done
    echo "  C) Cancel"
    echo
    
    read -p "Enter choice: " choice
    [[ "${choice^^}" == "C" ]] && return
    
    if [[ $choice -ge 1 && $choice -le ${#plugins[@]} ]]; then
        local plugin_name="${plugins[$((choice-1))]}"
        local plugin_dir="$HOME/$plugin_name"
        
        echo
        echo "Actions for $plugin_name:"
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart"
        echo "  4) View logs"
        echo "  5) Edit configuration"
        echo
        
        read -p "Select action: " action
        
        case "$action" in
            1)
                cd "$plugin_dir" && docker compose up -d
                echo -e "${GREEN}✓ Started${NC}"
                ;;
            2)
                cd "$plugin_dir" && docker compose down
                echo -e "${GREEN}✓ Stopped${NC}"
                ;;
            3)
                cd "$plugin_dir" && docker compose restart
                echo -e "${GREEN}✓ Restarted${NC}"
                ;;
            4)
                cd "$plugin_dir" && docker compose logs --tail=50 -f
                ;;
            5)
                ${EDITOR:-nano} "$plugin_dir/.env"
                echo "Configuration updated. Restart service to apply changes."
                ;;
        esac
    fi
    
    press_enter
}
