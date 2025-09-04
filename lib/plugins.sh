#!/bin/bash
# lib/plugins.sh - Minimal plugin system

# Plugin registry
declare -gA AVAILABLE_PLUGINS=(
    ["ssv"]="SSV Network Operator"
    ["vero"]="Vero Monitoring"
)

# Check if plugins directory exists
init_plugin_system() {
    local plugin_dir="${NODEBOI_HOME}/plugins"
    [[ ! -d "$plugin_dir" ]] && mkdir -p "$plugin_dir"
    
    # Create example plugin files if they don't exist
    if [[ ! -f "$plugin_dir/ssv.yml.example" ]]; then
        create_ssv_template "$plugin_dir/ssv.yml.example"
    fi
}

# Get enabled plugins for a node
get_node_plugins() {
    local node_dir=$1
    local enabled_plugins=()
    
    [[ ! -f "$node_dir/.env" ]] && return
    
    # Check each plugin
    for plugin in "${!AVAILABLE_PLUGINS[@]}"; do
        local enabled_var="${plugin^^}_ENABLED"
        local value=$(grep "^${enabled_var}=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
        [[ "$value" == "true" ]] && enabled_plugins+=("$plugin")
    done
    
    echo "${enabled_plugins[@]}"
}

# Add plugin configuration to .env
configure_plugin_env() {
    local node_dir=$1
    local plugin=$2
    
    case "$plugin" in
        ssv)
            cat >> "$node_dir/.env" << 'EOL'

#============================================================================
# SSV PLUGIN CONFIGURATION
#============================================================================
SSV_ENABLED=false
SSV_OPERATOR_KEY=
SSV_OPERATOR_ID=
SSV_BEACON_NODE=http://consensus:5052
SSV_EXECUTION_NODE=http://execution:8545
SSV_P2P_PORT=12001
SSV_METRICS_PORT=15000
EOL
            ;;
        vero)
            cat >> "$node_dir/.env" << 'EOL'

#============================================================================
# VERO PLUGIN CONFIGURATION  
#============================================================================
VERO_ENABLED=false
VERO_BEACON_NODES=http://consensus:5052
VERO_PORT=8080
VERO_METRICS_PORT=9090
EOL
            ;;
    esac
}

# Create SSV template
create_ssv_template() {
    local file=$1
    cat > "$file" << 'EOL'
# SSV Operator Service
# Add to COMPOSE_FILE to enable: compose.yml:...:plugins/ssv.yml

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"

services:
  ssv-operator:
    container_name: ${NODE_NAME}-ssv
    image: bloxstaking/ssv-node:latest
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${HOST_IP:-}:${SSV_P2P_PORT}:12001/tcp"
      - "${HOST_IP:-}:${SSV_P2P_PORT}:12001/udp"  
      - "${HOST_IP:-}:${SSV_METRICS_PORT}:15000/tcp"
    volumes:
      - ./data/ssv:/data
      - /etc/localtime:/etc/localtime:ro
    environment:
      - BEACON_NODE_ADDR=${SSV_BEACON_NODE}
      - ETH1_ADDR=${SSV_EXECUTION_NODE}
      - OPERATOR_KEY=${SSV_OPERATOR_KEY}
      - DB_PATH=/data/db
      - NETWORK=mainnet
    networks:
      default:
        aliases:
          - ssv
    <<: *logging
EOL
}

# Plugin menu items
show_plugin_menu() {
    local node_dir=$1
    local plugins=($(get_node_plugins "$node_dir"))
    
    if [[ ${#plugins[@]} -eq 0 ]]; then
        echo "  No plugins enabled"
        return
    fi
    
    echo "  Enabled plugins:"
    for plugin in "${plugins[@]}"; do
        echo "    • ${AVAILABLE_PLUGINS[$plugin]}"
    done
}

# Configure plugin during installation
prompt_plugin_configuration() {
    local node_dir=$1
    
    echo -e "\n${CYAN}${BOLD}Plugin Configuration${NC}\n===================="
    echo "Available plugins:"
    echo "  1) SSV Network Operator (validator infrastructure)"
    echo "  2) Vero Monitoring (multi-node dashboard)"
    echo "  S) Skip plugins"
    echo
    
    read -p "Select plugins to enable (e.g., 1,2 or S): " choices
    
    [[ "${choices^^}" == "S" ]] && return
    
    # Parse choices
    IFS=',' read -ra selected <<< "$choices"
    for choice in "${selected[@]}"; do
        case "$choice" in
            1)
                configure_plugin_env "$node_dir" "ssv"
                sed -i "s/SSV_ENABLED=.*/SSV_ENABLED=true/" "$node_dir/.env"
                echo "✓ SSV plugin configured (edit $node_dir/.env to add operator key)"
                ;;
            2)
                configure_plugin_env "$node_dir" "vero"
                sed -i "s/VERO_ENABLED=.*/VERO_ENABLED=true/" "$node_dir/.env"
                echo "✓ Vero plugin configured"
                ;;
        esac
    done
}

# Update compose file chain for plugins
update_compose_chain() {
    local node_dir=$1
    local compose_line=$(grep "^COMPOSE_FILE=" "$node_dir/.env")
    local compose_files="${compose_line#COMPOSE_FILE=}"
    
    # Check and add plugin compose files
    local plugins=($(get_node_plugins "$node_dir"))
    for plugin in "${plugins[@]}"; do
        local plugin_compose="${NODEBOI_HOME}/plugins/${plugin}.yml"
        if [[ -f "$plugin_compose" ]] && [[ "$compose_files" != *"${plugin}.yml"* ]]; then
            compose_files+=":../../plugins/${plugin}.yml"
        fi
    done
    
    sed -i "s|^COMPOSE_FILE=.*|COMPOSE_FILE=${compose_files}|" "$node_dir/.env"
}

# Plugin-specific port allocation
allocate_plugin_ports() {
    local node_dir=$1
    local used_ports=$2
    
    # SSV ports
    if grep -q "^SSV_ENABLED=true" "$node_dir/.env" 2>/dev/null; then
        local ssv_p2p=$(find_available_port 12001 2 "$used_ports")
        local ssv_metrics=$(find_available_port 15000 2 "$used_ports")
        sed -i "s/SSV_P2P_PORT=.*/SSV_P2P_PORT=$ssv_p2p/" "$node_dir/.env"
        sed -i "s/SSV_METRICS_PORT=.*/SSV_METRICS_PORT=$ssv_metrics/" "$node_dir/.env"
    fi
    
    # Vero ports
    if grep -q "^VERO_ENABLED=true" "$node_dir/.env" 2>/dev/null; then
        local vero_port=$(find_available_port 8080 1 "$used_ports")
        local vero_metrics=$(find_available_port 9090 1 "$used_ports")
        sed -i "s/VERO_PORT=.*/VERO_PORT=$vero_port/" "$node_dir/.env"
        sed -i "s/VERO_METRICS_PORT=.*/VERO_METRICS_PORT=$vero_metrics/" "$node_dir/.env"
    fi
}

# Multi-node plugin configuration (for Vero)
configure_multi_node_plugin() {
    local plugin=$1
    
    case "$plugin" in
        vero)
            echo -e "\n${CYAN}Configuring Vero for multiple nodes${NC}"
            local beacon_nodes=""
            
            for dir in "$HOME"/ethnode*; do
                [[ ! -d "$dir" ]] && continue
                local node_name=$(basename "$dir")
                local cl_rest=$(grep "CL_REST_PORT=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)
                
                read -p "Include $node_name in Vero monitoring? [y/n]: " -r
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    [[ -n "$beacon_nodes" ]] && beacon_nodes+=","
                    beacon_nodes+="http://${node_name}-consensus:${cl_rest}"
                fi
            done
            
            echo "VERO_BEACON_NODES=$beacon_nodes"
            # Store this config somewhere global or per-node
            ;;
    esac
}
