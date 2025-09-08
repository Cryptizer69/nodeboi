#!/bin/bash
# lib/monitoring.sh - Monitoring stack management for NODEBOI

# Load dependencies
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"

# Discover NODEBOI Docker networks
discover_nodeboi_networks() {
    local networks=()
    
    # Find all ethnode networks
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            local network_name="${node_name}-net"
            
            # Check if network exists
            if docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"; then
                # Get running containers in this network
                local containers=$(docker ps --filter "network=${network_name}" --format "{{.Names}}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                
                if [[ -n "$containers" ]]; then
                    networks+=("${network_name}:${containers}")
                else
                    networks+=("${network_name}:no running containers")
                fi
            fi
        fi
    done
    
    printf '%s\n' "${networks[@]}"
}

# Generate Prometheus scrape configs for discovered services
# Remove a specific ethnode network from monitoring configuration
remove_ethnode_from_monitoring() {
    local node_name="$1"
    local monitoring_dir="$HOME/monitoring"
    
    # Check if monitoring stack exists
    if [[ ! -d "$monitoring_dir" ]]; then
        return 0  # No monitoring stack, nothing to do
    fi
    
    echo -e "${UI_MUTED}  Removing $node_name from monitoring configuration...${NC}" >&2
    
    # Get current networks that monitoring is connected to
    local current_networks=()
    if [[ -f "$monitoring_dir/compose.yml" ]]; then
        # Extract external networks from compose.yml
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*name:[[:space:]]*(.+)-net$ ]]; then
                local network_name="${BASH_REMATCH[1]}"
                if [[ "$network_name" != "monitoring" && "$network_name" != "$node_name" ]]; then
                    current_networks+=("${network_name}-net")
                fi
            fi
        done < "$monitoring_dir/compose.yml"
    fi
    
    # Regenerate Prometheus config without the removed node
    if [[ ${#current_networks[@]} -gt 0 ]]; then
        echo -e "${UI_MUTED}    Updating Prometheus configuration...${NC}" >&2
        
        # Recreate prometheus.yml without the removed node
        cat > "$monitoring_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
        
        # Add remaining targets
        local prometheus_targets=$(generate_prometheus_targets "${current_networks[@]}")
        echo "$prometheus_targets" >> "$monitoring_dir/prometheus.yml"
        
        # Regenerate monitoring compose.yml with updated networks
        if docker ps -q --filter "name=monitoring-" >/dev/null 2>&1; then
            echo -e "${UI_MUTED}    Updating monitoring configuration to remove ${node_name}-net...${NC}" >&2
            cd "$monitoring_dir" && docker compose down >/dev/null 2>&1 || true
            
            # Get current configuration from .env
            local bind_ip=$(grep "BIND_IP=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
            local grafana_password=$(grep "GRAFANA_PASSWORD=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            # Regenerate the entire compose.yml with remaining networks
            echo -e "${UI_MUTED}    Regenerating compose.yml with remaining networks...${NC}" >&2
            
            # Create new compose.yml (simplified version for network update)
            cat > "$monitoring_dir/compose.yml" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:\${PROMETHEUS_VERSION}
    container_name: monitoring-prometheus
    restart: unless-stopped
    user: "65534:65534"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
      - '--web.external-url=http://localhost:\${PROMETHEUS_PORT}'
    ports:
      - "\${BIND_IP}:\${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - monitoring
EOF

            # Add remaining ethnode networks to services
            for network in "${current_networks[@]}"; do
                echo "      - $network" >> "$monitoring_dir/compose.yml"
            done

            # Continue with rest of compose.yml
            cat >> "$monitoring_dir/compose.yml" <<EOF
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:\${GRAFANA_VERSION}
    container_name: monitoring-grafana
    restart: unless-stopped
    user: "\${NODE_UID}:\${NODE_GID}"
    ports:
      - "\${BIND_IP}:\${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:\${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - monitoring
EOF

            # Add remaining ethnode networks to grafana
            for network in "${current_networks[@]}"; do
                echo "      - $network" >> "$monitoring_dir/compose.yml"
            done

            # Finish compose.yml
            cat >> "$monitoring_dir/compose.yml" <<EOF
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:\${NODE_EXPORTER_VERSION}
    container_name: monitoring-node-exporter
    restart: unless-stopped
    user: "root"
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$|/)'
    ports:
      - "127.0.0.1:\${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - monitoring
    cap_drop:
      - ALL
    cap_add:
      - SYS_TIME
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: monitoring_prometheus_data
  grafana_data:
    name: monitoring_grafana_data

networks:
  monitoring:
    name: monitoring-net
    driver: bridge
EOF

            # Add external network definitions
            for network in "${current_networks[@]}"; do
                cat >> "$monitoring_dir/compose.yml" <<EOF
  $network:
    external: true
    name: $network
EOF
            done

            echo -e "${UI_MUTED}    Restarting monitoring with updated configuration...${NC}" >&2
            docker compose up -d >/dev/null 2>&1 || true
        fi
    else
        echo -e "${UI_MUTED}    No other networks to monitor${NC}" >&2
    fi
}

generate_prometheus_targets() {
    local selected_networks=("$@")
    local prometheus_configs=""
    
    # Always include node-exporter
    prometheus_configs+="  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']

"
    
    # Process each selected network
    for network in "${selected_networks[@]}"; do
        # Extract base node name from network name (e.g., ethnode1-net -> ethnode1)
        local node_name="${network%-net}"
        local node_dir="$HOME/$node_name"
        
        if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
            # Parse client types from compose file
            local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
            local clients=$(detect_node_clients "$compose_file")
            local exec_client="${clients%:*}"
            local cons_client="${clients#*:}"
            
            # Get metrics ports from .env
            if [[ "$exec_client" == "reth" ]]; then
                # Reth uses port 9001 internally, mapped to METRICS_PORT externally
                local exec_port=$(grep "^METRICS_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//')
                [[ -z "$exec_port" ]] && exec_port="9001"
                
                prometheus_configs+="  - job_name: '${node_name}-reth'
    static_configs:
      - targets: ['${node_name}-reth:9001']  # Internal port

"
            elif [[ "$exec_client" == "besu" || "$exec_client" == "nethermind" ]]; then
                # Besu/Nethermind use port 6060
                prometheus_configs+="  - job_name: '${node_name}-${exec_client}'
    static_configs:
      - targets: ['${node_name}-${exec_client}:6060']

"
            fi
            
            # Consensus clients all use port 8008
            if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
                prometheus_configs+="  - job_name: '${node_name}-${cons_client}'
    static_configs:
      - targets: ['${node_name}-${cons_client}:8008']

"
            fi
            
            # Check for MEV-boost
            if docker ps --format "{{.Names}}" | grep -q "^${node_name}-mevboost$"; then
                local mevboost_port=$(grep "^MEVBOOST_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//')
                if [[ -n "$mevboost_port" ]]; then
                    prometheus_configs+="  - job_name: '${node_name}-mevboost'
    static_configs:
      - targets: ['${node_name}-mevboost:${mevboost_port}']

"
                fi
            fi
        fi
    done
    
    echo "$prometheus_configs"
}

# Install monitoring stack
install_monitoring_stack() {
    local preselected_networks=("$@")  # Accept networks as parameters
    echo -e "\n${CYAN}${BOLD}Install Monitoring Stack${NC}"
    echo "========================="
    echo
    echo -e "${UI_MUTED}This will install:${NC}"
    echo -e "${UI_MUTED}  • Prometheus - Metrics collection and storage${NC}"
    echo -e "${UI_MUTED}  • Grafana - Visual dashboards and analytics${NC}"
    echo -e "${UI_MUTED}  • Node Exporter - System metrics (CPU/Memory/Disk)${NC}"
    echo
    
    # Check if already installed
    if [[ -d "$HOME/monitoring" ]]; then
        if [[ ${#preselected_networks[@]} -gt 0 ]]; then
            # Plugin installation - remove silently
            echo -e "${UI_MUTED}Removing existing installation...${NC}"
            cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
            sudo rm -rf "$HOME/monitoring"
        else
            # Manual installation - ask for confirmation
            echo -e "${YELLOW}Monitoring stack already installed${NC}"
            
            if fancy_confirm "Remove existing installation?" "n"; then
                cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
                sudo rm -rf "$HOME/monitoring"
                echo -e "${UI_MUTED}Existing monitoring removed${NC}"
            else
                echo -e "${UI_MUTED}Press Enter to continue...${NC}"
                read -r
                return
            fi
        fi
    fi
    
    # Step 1: Setup directories and user
    echo -e "${UI_MUTED}Setting up directories and user...${NC}"
    mkdir -p ~/monitoring/grafana/provisioning/datasources
    
    # Use current user (eth-docker pattern - no system user needed)
    local NODE_UID=$(id -u)
    local NODE_GID=$(id -g)
    echo -e "${UI_MUTED}  Using current user: UID=${NODE_UID}, GID=${NODE_GID}${NC}"
    
    # Step 2: Get Grafana password
    echo
    local grafana_password
    grafana_password=$(fancy_text_input "Grafana Setup" \
        "Set Grafana admin password (or press Enter for random):" \
        "" \
        "")
    
    if [[ -z "$grafana_password" ]]; then
        # Generate random password
        grafana_password=$(openssl rand -base64 12)
        echo -e "${UI_MUTED}Generated password: ${GREEN}$grafana_password${NC}"
    fi
    
    # Step 3: Network access configuration
    local bind_ip
    if [[ ${#preselected_networks[@]} -gt 0 ]]; then
        # Plugin installation - use 0.0.0.0 automatically
        bind_ip="0.0.0.0"
        echo -e "${UI_MUTED}Setting network access to all networks (0.0.0.0)...${NC}"
    else
        # Manual installation - prompt for choice
        echo
        local access_options=(
            "My machine only (127.0.0.1) - Most secure"
            "Local network access (auto-detect IP)"
            "All networks (0.0.0.0) - Use with caution"
        )
        
        bind_ip="127.0.0.1"
        local access_choice
        if access_choice=$(fancy_select_menu "Monitoring Access Level" "${access_options[@]}"); then
            case $access_choice in
                0) bind_ip="127.0.0.1" ;;
                1) 
                    bind_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
                    echo -e "${UI_MUTED}Using local network IP: $bind_ip${NC}"
                    ;;
                2) 
                    bind_ip="0.0.0.0"
                    echo -e "${YELLOW}⚠ WARNING: Accessible from all networks${NC}"
                    ;;
            esac
        fi
    fi
    
    # Step 4: Auto-discover and connect to all ethnode networks
    echo
    local selected_networks=()
    
    if [[ ${#preselected_networks[@]} -gt 0 ]]; then
        # Use pre-selected networks (from plugin installation)
        echo -e "${UI_MUTED}Using pre-selected networks: ${preselected_networks[*]}${NC}"
        selected_networks=("${preselected_networks[@]}")
    else
        # Auto-discover and prompt for selection
        echo -e "${UI_MUTED}Auto-discovering ethnode networks...${NC}"
        local available_networks=($(discover_nodeboi_networks))
        
        # Auto-select all ethnode networks
        for network_info in "${available_networks[@]}"; do
            local network_name="${network_info%%:*}"
            local containers="${network_info#*:}"
        
        # Only include ethnode networks, not other plugin networks
        if [[ "$network_name" =~ ^ethnode.*-net$ ]]; then
            selected_networks+=("$network_name")
            if [[ "$containers" == "no running containers" ]]; then
                echo -e "${UI_MUTED}  Found: $network_name (stopped)${NC}"
            else
                echo -e "${UI_MUTED}  Found: $network_name [${containers}]${NC}"
            fi
        fi
        done
        
        if [[ ${#selected_networks[@]} -eq 0 ]]; then
            echo -e "${UI_MUTED}  No ethnode networks found. Monitoring will only collect system metrics.${NC}"
        else
            echo -e "${UI_MUTED}  Auto-connecting to: ${selected_networks[*]}${NC}"
        fi
    fi
    
    # Step 5: Find available ports
    echo -e "${UI_MUTED}Allocating ports...${NC}"
    init_port_management >/dev/null 2>&1
    
    local used_ports=$(get_all_used_ports)
    local prometheus_port=$(find_available_port 9090 1 "$used_ports")
    local grafana_port=$(find_available_port 3000 1 "$used_ports") 
    local node_exporter_port=$(find_available_port 9100 1 "$used_ports")
    
    # Step 6: Create .env file
    cat > ~/monitoring/.env <<EOF
#============================================================================
# MONITORING STACK CONFIGURATION
# Generated: $(date)
#============================================================================
COMPOSE_FILE=compose.yml
MONITORING_NAME=monitoring
NODE_UID=${NODE_UID}
NODE_GID=${NODE_GID}

# Monitoring Ports
PROMETHEUS_PORT=${prometheus_port}
GRAFANA_PORT=${grafana_port}
NODE_EXPORTER_PORT=${node_exporter_port}

# Grafana Configuration
GRAFANA_PASSWORD=${grafana_password}

# Monitoring Versions
PROMETHEUS_VERSION=v3.5.0
GRAFANA_VERSION=12.1.0
NODE_EXPORTER_VERSION=v1.9.1

# Network Access
BIND_IP=${bind_ip}

# Connected Networks
MONITORED_NETWORKS="${selected_networks[*]}"
EOF

    # Step 7: Create compose.yml with selected networks
    cat > ~/monitoring/compose.yml <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: ${MONITORING_NAME}-prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    ports:
      - "${BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - monitoring
EOF

    # Add selected networks to prometheus service
    for network in "${selected_networks[@]}"; do
        echo "      - ${network}" | sudo tee -a ~/monitoring/compose.yml > /dev/null
    done

    # Continue with rest of compose.yml
    sudo tee -a ~/monitoring/compose.yml > /dev/null <<'EOF'
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: ${MONITORING_NAME}-grafana
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${BIND_IP}:${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - monitoring
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: ${MONITORING_NAME}-node-exporter
    restart: unless-stopped
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - "127.0.0.1:${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - monitoring
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: ${MONITORING_NAME}_prometheus_data
  grafana_data:
    name: ${MONITORING_NAME}_grafana_data

networks:
  monitoring:
    name: monitoring-net
    driver: bridge
EOF
    
    # Add external networks to compose.yml
    for network in "${selected_networks[@]}"; do
        sudo tee -a ~/monitoring/compose.yml > /dev/null <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done

    # Step 8: Create Prometheus configuration
    echo -e "${UI_MUTED}Generating Prometheus configuration...${NC}"
    
    cat > ~/monitoring/prometheus.yml <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
    
    # Add discovered targets
    local prometheus_targets=$(generate_prometheus_targets "${selected_networks[@]}")
    echo "$prometheus_targets" >> ~/monitoring/prometheus.yml
    
    # Step 9: Create Grafana datasource configuration
    cat > ~/monitoring/grafana/provisioning/datasources/prometheus.yml <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
    
    # Step 10: Set permissions
    echo -e "${UI_MUTED}Setting permissions...${NC}"
    # Ensure proper permissions on directories (already owned by current user)
    chmod 755 ~/monitoring/
    chmod 755 ~/monitoring/grafana/provisioning/
    chmod 755 ~/monitoring/grafana/provisioning/datasources/
    
    # Step 11: Launch monitoring stack
    echo -e "${UI_MUTED}Starting monitoring stack...${NC}"
    cd ~/monitoring
    if docker compose up -d; then
        echo
        sleep 2
        
        # Verify containers are running
        if docker compose ps --services --filter status=running | grep -q prometheus; then
            echo -e "${GREEN}✓ Monitoring stack installed successfully!${NC}"
            echo
            echo -e "${BOLD}Access Information:${NC}"
            echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            
            if [[ "$bind_ip" == "127.0.0.1" ]]; then
                echo -e "Grafana:     ${GREEN}http://localhost:${grafana_port}${NC}"
            else
                echo -e "Grafana:     ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
            fi
            
            echo
            echo -e "${BOLD}Login Credentials:${NC}"
            echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "Username: ${GREEN}admin${NC}"
            echo -e "Password: ${GREEN}${grafana_password}${NC}"
            echo
            echo -e "${UI_MUTED}Import dashboards from Grafana web UI:${NC}"
            echo -e "${UI_MUTED}  • Node Exporter Full: ID 1860${NC}"
            echo -e "${UI_MUTED}  • Reth: ID 22941${NC}"
            echo -e "${UI_MUTED}  • Besu: ID 10273${NC}"
            echo
            echo -e "${YELLOW}💡 Tip: You can view these credentials later in:${NC}"
            echo -e "${UI_MUTED}   Main Menu → Manage services → Manage monitoring → See Grafana login information${NC}"
        else
            echo -e "${RED}Failed to start monitoring stack${NC}"
            docker compose logs --tail=20
        fi
    else
        echo -e "${RED}Failed to launch monitoring stack${NC}"
    fi
    
    press_enter
}

# View Grafana credentials
view_grafana_credentials() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Grafana Access Information${NC}"
    echo "=========================="
    
    local bind_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local grafana_port=$(grep "^GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local grafana_password=$(grep "^GRAFANA_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local prometheus_port=$(grep "^PROMETHEUS_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    
    echo
    echo -e "${BOLD}URLs:${NC}"
    if [[ "$bind_ip" == "127.0.0.1" ]]; then
        echo -e "  Grafana:    ${GREEN}http://localhost:${grafana_port}${NC}"
    elif [[ "$bind_ip" == "0.0.0.0" ]]; then
        local actual_ip=$(hostname -I | awk '{print $1}')
        echo -e "  Grafana:    ${GREEN}http://${actual_ip}:${grafana_port}${NC}"
    else
        echo -e "  Grafana:    ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
    fi
    
    echo
    echo -e "${BOLD}Credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}${grafana_password}${NC}"
    
    # Refresh dashboard to show monitoring stack
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache

    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Change monitoring network access level
change_monitoring_access_level() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Change Network Access Level${NC}"
    echo "==========================="
    
    local current_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    echo -e "\nCurrent setting: ${GREEN}$current_ip${NC}"
    
    local access_options=(
        "My machine only (127.0.0.1)"
        "Local network access (auto-detect IP)"
        "All networks (0.0.0.0)"
        "Cancel"
    )
    
    local new_ip=""
    local access_choice
    if access_choice=$(fancy_select_menu "Select New Access Level" "${access_options[@]}"); then
        case $access_choice in
            0) new_ip="127.0.0.1" ;;
            1) 
                new_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
                echo -e "${UI_MUTED}Detected local IP: $new_ip${NC}"
                ;;
            2) 
                new_ip="0.0.0.0"
                echo -e "${YELLOW}⚠ WARNING: This will make monitoring accessible from all networks${NC}"
                ;;
            3) return ;;
        esac
    else
        return
    fi
    
    if [[ -n "$new_ip" && "$new_ip" != "$current_ip" ]]; then
        sed -i "s/^BIND_IP=.*/BIND_IP=${new_ip}/" "$HOME/monitoring/.env"
        echo -e "${UI_MUTED}Restarting monitoring stack...${NC}"
        cd "$HOME/monitoring"
        docker compose restart
        echo -e "${GREEN}✓ Access level changed to: $new_ip${NC}"
    fi
    
    press_enter
}

# Update monitored networks
update_monitoring_networks() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Update Monitored Networks${NC}"
    echo "========================"
    
    # Get current monitored networks
    local current_networks=$(grep "^MONITORED_NETWORKS=" "$HOME/monitoring/.env" | cut -d'=' -f2 | tr -d '"')
    echo -e "\nCurrently monitoring: ${GREEN}${current_networks}${NC}"
    
    # Discover available networks
    echo -e "\n${UI_MUTED}Discovering Docker networks...${NC}"
    local available_networks=($(discover_nodeboi_networks))
    
    if [[ ${#available_networks[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No NODEBOI networks found${NC}"
        press_enter
        return
    fi
    
    # Display available networks
    local network_options=()
    local network_names=()
    
    for network_info in "${available_networks[@]}"; do
        local network_name="${network_info%%:*}"
        local containers="${network_info#*:}"
        network_names+=("$network_name")
        
        # Check if already monitored
        local status=""
        if echo " $current_networks " | grep -q " $network_name "; then
            status=" [MONITORED]"
        fi
        
        if [[ "$containers" == "no running containers" ]]; then
            network_options+=("$network_name (stopped)$status")
        else
            if [[ ${#containers} -gt 40 ]]; then
                containers="${containers:0:37}..."
            fi
            network_options+=("$network_name [$containers]$status")
        fi
    done
    
    echo
    echo -e "${BOLD}Select networks to monitor:${NC}"
    echo -e "${UI_MUTED}Currently monitored networks are marked${NC}"
    echo
    
    for i in "${!network_options[@]}"; do
        echo -e "  $((i+1))) ${network_options[$i]}"
    done
    echo -e "  A) Select all"
    echo -e "  C) Cancel"
    echo
    
    read -p "Enter numbers separated by spaces: " selections
    
    [[ "${selections,,}" == "c" ]] && return
    
    local selected_networks=()
    if [[ "${selections,,}" == "a" ]]; then
        selected_networks=("${network_names[@]}")
    else
        for num in $selections; do
            if [[ $num -ge 1 && $num -le ${#network_names[@]} ]]; then
                selected_networks+=("${network_names[$((num-1))]}")
            fi
        done
    fi
    
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No networks selected${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${UI_MUTED}Updating configuration...${NC}"
    
    # Update .env (use sudo since files are owned by monitoring user)
    sudo sed -i "s/^MONITORED_NETWORKS=.*/MONITORED_NETWORKS=\"${selected_networks[*]}\"/" "$HOME/monitoring/.env"
    
    # Regenerate compose.yml networks section
    cd "$HOME/monitoring"
    
    # Remove old network definitions (everything after "networks:" at root level)
    sudo sed -i '/^networks:/,$d' compose.yml
    
    # Add networks section (use sudo since files are owned by monitoring user)
    sudo tee -a compose.yml > /dev/null <<EOF
networks:
  monitoring:
    name: monitoring-net
    driver: bridge
EOF
    
    for network in "${selected_networks[@]}"; do
        sudo tee -a compose.yml > /dev/null <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done
    
    # Regenerate Prometheus config
    echo -e "${UI_MUTED}Regenerating Prometheus configuration...${NC}"
    
    sudo tee prometheus.yml > /dev/null <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
    
    local prometheus_targets=$(generate_prometheus_targets "${selected_networks[@]}")
    echo "$prometheus_targets" | sudo tee -a prometheus.yml > /dev/null
    
    # Restart stack
    echo -e "${UI_MUTED}Restarting monitoring stack...${NC}"
    docker compose down
    docker compose up -d
    
    echo -e "${GREEN}✓ Monitoring configuration updated${NC}"
    echo -e "${UI_MUTED}Now monitoring: ${selected_networks[*]}${NC}"
    
    press_enter
}

# Remove monitoring stack
remove_monitoring_stack() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Remove Monitoring Stack${NC}"
    echo "======================="
    
    echo -e "${UI_MUTED}Stopping monitoring containers...${NC}"
    cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
    
    echo -e "${UI_MUTED}Removing monitoring network...${NC}"
    docker network rm monitoring-net 2>/dev/null || true
    
    echo -e "${UI_MUTED}Removing monitoring files...${NC}"
    # Use sudo for files that might be owned by the old monitoring user
    if ! rm -rf "$HOME/monitoring" 2>/dev/null; then
        sudo rm -rf "$HOME/monitoring"
    fi
    
    # No system user cleanup needed - using current user
    
    echo -e "${GREEN}✅ Monitoring stack removed successfully${NC}"
    
    # Refresh dashboard cache to remove monitoring from display
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache
    
    press_enter
}



# Network Management Interface - Clean and Simple
manage_monitoring_networks() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    # Define colors for this function (don't redeclare UI_MUTED if it exists)
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local CYAN='\033[0;36m'
    local BOLD='\033[1m'
    local NC='\033[0m'
    local PINK='\033[38;5;213m'
    [[ -z "$UI_MUTED" ]] && UI_MUTED='\033[38;5;240m'
    
    # Load required libraries for dashboard functionality
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" 2>/dev/null
    [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null
    
    # Clear initialization flags for fresh start
    unset TEMP_SELECTED_NETWORKS
    unset TEMP_STATE_INITIALIZED
    
    while true; do
        clear
        
        # Print header
        echo -e "${PINK}${BOLD}"
        echo "      ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗"
        echo "      ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║"
        echo "      ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║"
        echo "      ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║"
        echo "      ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║"
        echo "      ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝"
        echo -e "${NC}"
        echo -e "                      ${CYAN}ETHEREUM NODE AUTOMATION${NC}"
        echo -e "                             ${YELLOW}v0.3.1${NC}"
        echo
        
        # Show dashboard if available
        if declare -f print_dashboard >/dev/null; then
            print_dashboard
            echo
        else
            echo -e "${BOLD}NODEBOI Dashboard${NC}"
            echo -e "${BOLD}=================${NC}"
            echo
        fi
        
        echo -e "${CYAN}${BOLD}🔗 Docker Network Connections${NC}"
        echo -e "${CYAN}${BOLD}==============================${NC}"
        echo
        echo -e "${UI_MUTED}Networks available for monitoring connection:${NC}"
        echo
        
        # Find all available ethnode networks
        local available_networks=()
        for dir in "$HOME"/ethnode*; do
            if [[ -d "$dir" && -f "$dir/.env" ]]; then
                local node_name=$(basename "$dir")
                local network_name="${node_name}-net"
                
                # Check if network exists and has running containers
                if docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"; then
                    local containers=$(docker ps --filter "network=${network_name}" --format "{{.Names}}" | wc -l)
                    if [[ $containers -gt 0 ]]; then
                        available_networks+=("${network_name}:${containers}")
                    fi
                fi
            fi
        done
        
        if [[ ${#available_networks[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No running ethnode networks found${NC}"
            echo -e "${UI_MUTED}Start some ethnode instances first${NC}"
            echo
            press_enter
            return
        fi
        
        # Get currently connected networks from compose.yml
        local current_networks=""
        if [[ -f "$HOME/monitoring/compose.yml" ]]; then
            # Extract external network names from compose.yml
            current_networks=$(grep -A1 "external: true" "$HOME/monitoring/compose.yml" | grep "name:" | awk '{print $2}' | tr '\n' ' ')
        fi
        
        # Initialize temporary selection state with current compose.yml state (only on first loop)
        if [[ -z "$TEMP_SELECTED_NETWORKS" && -z "$TEMP_STATE_INITIALIZED" ]]; then
            TEMP_SELECTED_NETWORKS="$current_networks"
            TEMP_STATE_INITIALIZED="true"
        fi
        
        # Display available networks with current selection status
        for i in "${!available_networks[@]}"; do
            local network_info="${available_networks[$i]}"
            local network_name="${network_info%%:*}"
            local node_name="${network_name%-net}"
            local service_count="${network_info#*:}"
            
            # Check if currently selected in temporary state
            local checkbox="[ ]"
            if [[ -n "$TEMP_SELECTED_NETWORKS" ]] && echo " $TEMP_SELECTED_NETWORKS " | grep -q " $network_name "; then
                checkbox="[x]"
            fi
            
            echo -e "  $((i+1))) $checkbox $node_name ($service_count services)"
        done
        
        echo
        echo -e "${BOLD}Actions:${NC}"
        echo -e "  Enter numbers to toggle networks (e.g., '1' to toggle ethnode1, '1 2' for both)"
        echo -e "  A) Select all networks"
        echo -e "  D) Deselect all networks"
        echo -e "  S) Save current selection"
        echo -e "  Q) Back to monitoring menu"
        echo
        
        read -p "Your choice: " choice
        
        case "$choice" in
            [1-9]*)
                # Toggle networks: each number toggles that network on/off
                local current_selection=()
                if [[ -n "$TEMP_SELECTED_NETWORKS" ]]; then
                    read -ra current_selection <<< "$TEMP_SELECTED_NETWORKS"
                fi
                
                # Process each number in the input
                for num in $choice; do
                    if [[ $num =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#available_networks[@]} ]]; then
                        local network_name="${available_networks[$((num-1))]%%:*}"
                        
                        # Check if network is already selected
                        local found=false
                        local new_selection=()
                        
                        for selected in "${current_selection[@]}"; do
                            if [[ "$selected" == "$network_name" ]]; then
                                found=true
                                # Skip this network (remove it)
                            else
                                new_selection+=("$selected")
                            fi
                        done
                        
                        # If not found, add it
                        if [[ "$found" == false ]]; then
                            new_selection+=("$network_name")
                        fi
                        
                        current_selection=("${new_selection[@]}")
                    fi
                done
                
                # Update temporary selection
                TEMP_SELECTED_NETWORKS="${current_selection[*]}"
                
                if [[ ${#current_selection[@]} -eq 0 ]]; then
                    echo -e "${UI_MUTED}No networks selected${NC}"
                else
                    local node_names=()
                    for network in "${current_selection[@]}"; do
                        node_names+=("${network%-net}")
                    done
                    echo -e "${GREEN}Selected: ${node_names[*]}${NC}"
                fi
                sleep 1
                ;;
                
            [Aa])
                # Select all networks
                local all_networks=()
                for network_info in "${available_networks[@]}"; do
                    all_networks+=("${network_info%%:*}")
                done
                TEMP_SELECTED_NETWORKS="${all_networks[*]}"
                echo -e "${GREEN}All networks selected${NC}"
                sleep 1
                ;;
                
            [Dd])
                # Deselect all networks
                TEMP_SELECTED_NETWORKS=""
                echo -e "${UI_MUTED}All networks deselected${NC}"
                sleep 1
                ;;
                
            [Ss])
                # Save and apply network connections
                apply_network_connections
                return
                ;;
                
            [Qq]|'')
                return
                ;;
                
            *)
                echo -e "${YELLOW}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Apply network connections - actually connect containers to selected networks
apply_network_connections() {
    clear
    echo -e "${CYAN}${BOLD}💾 Applying Network Connections${NC}"
    echo "================================"
    echo
    
    # Get the selected networks from temporary variable (no .env file involved)
    local selected_networks=($TEMP_SELECTED_NETWORKS)
    
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${UI_MUTED}No networks selected - monitoring will be isolated${NC}"
    else
        echo -e "${UI_MUTED}Connecting to networks:${NC}"
        for network in "${selected_networks[@]}"; do
            local node_name="${network%-net}"
            echo -e "  • $node_name"
        done
    fi
    
    echo
    echo -e "${UI_MUTED}Step 1: Rebuilding compose.yml with selected networks...${NC}"
    
    cd "$HOME/monitoring"
    
    # Use the same template system as installation to rebuild compose.yml with proper service network connections
    sudo tee ~/monitoring/compose.yml > /dev/null <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: ${MONITORING_NAME}-prometheus
    restart: unless-stopped
    user: "65534:65534"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
      - '--web.external-url=http://localhost:${PROMETHEUS_PORT}'
    ports:
      - "${BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - monitoring
EOF

    # Add selected networks to prometheus service
    for network in "${selected_networks[@]}"; do
        echo "      - ${network}" | sudo tee -a ~/monitoring/compose.yml > /dev/null
    done

    # Continue with rest of compose.yml
    sudo tee -a ~/monitoring/compose.yml > /dev/null <<'EOF'
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: ${MONITORING_NAME}-grafana
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${BIND_IP}:${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    networks:
      - monitoring
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: ${MONITORING_NAME}-node-exporter
    restart: unless-stopped
    user: "root"
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - "127.0.0.1:${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - monitoring
    cap_drop:
      - ALL
    cap_add:
      - SYS_TIME
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: ${MONITORING_NAME}_prometheus_data
  grafana_data:
    name: ${MONITORING_NAME}_grafana_data

networks:
  monitoring:
    name: monitoring-net
    driver: bridge
EOF
    
    # Add selected external networks to compose.yml
    for network in "${selected_networks[@]}"; do
        sudo tee -a ~/monitoring/compose.yml > /dev/null <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done
    
    echo -e "${UI_MUTED}Step 2: Connecting containers to networks...${NC}"
    
    # Connect running monitoring containers to selected networks
    local containers=("monitoring-prometheus" "monitoring-grafana" "monitoring-node-exporter")
    
    for container in "${containers[@]}"; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            echo -e "${UI_MUTED}  → Connecting $container...${NC}"
            
            # Disconnect from old external networks (keep monitoring network)
            for old_network in $(docker network ls --format "{{.Name}}" | grep "ethnode.*-net"); do
                docker network disconnect "$old_network" "$container" 2>/dev/null || true
            done
            
            # Connect to selected networks
            for network in "${selected_networks[@]}"; do
                if docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
                    docker network connect "$network" "$container" 2>/dev/null || true
                fi
            done
        fi
    done
    
    echo
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Monitoring network is now isolated${NC}"
    else
        local node_names=()
        for network in "${selected_networks[@]}"; do
            node_names+=("${network%-net}")
        done
        echo -e "${GREEN}✅ Monitoring connected to: ${node_names[*]}${NC}"
    fi
    
    echo -e "${UI_MUTED}Changes applied successfully. Network connections are now active.${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Monitoring management menu
manage_monitoring_menu() {
    while true; do
        local menu_options=(
            "Start/stop monitoring"
            "See Grafana login information"
            "View logs"
            "Update monitoring"
            "Remove monitoring"
            "Back to main menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Manage Monitoring" "${menu_options[@]}"); then
            case $selection in
                0) manage_monitoring_state ;;
                1) view_grafana_credentials ;;
                2) view_monitoring_logs ;;
                3) update_monitoring_services ;;
                4) remove_monitoring_stack ;;
                5) return ;;
            esac
        else
            return
        fi
    done
}

# Check monitoring health exactly like ethnodes
check_monitoring_health() {
    local monitoring_dir="$HOME/monitoring"
    
    # Check if containers running
    local containers_running=false
    if cd "$monitoring_dir" 2>/dev/null; then
        local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
        if echo "$running_services" | grep -q "prometheus" && echo "$running_services" | grep -q "grafana"; then
            containers_running=true
        fi
    fi
    
    # Get bind IP and access level indicator
    local bind_ip=$(grep "^BIND_IP=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local display_ip="$bind_ip"
    local access_indicator=""
    case "$bind_ip" in
        "127.0.0.1") 
            access_indicator=" ${GREEN}[M]${NC}" 
            display_ip="localhost"
            ;;
        "0.0.0.0") 
            access_indicator=" ${RED}[A]${NC}"
            # Get actual machine IP for display
            display_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || ip route get 1 2>/dev/null | awk '/src/ {print $7}' || echo "localhost")
            ;;
        *) 
            access_indicator=" ${YELLOW}[L]${NC}" 
            display_ip="$bind_ip"
            ;;
    esac
    
    # Get versions from .env
    local grafana_version=$(grep "^GRAFANA_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local prometheus_version=$(grep "^PROMETHEUS_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local node_exporter_version=$(grep "^NODE_EXPORTER_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Get ports
    local grafana_port=$(grep "^GRAFANA_PORT=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Check for updates (add update indicators like ethnodes)
    local grafana_update_indicator=""
    local prometheus_update_indicator=""  
    local node_exporter_update_indicator=""
    
    # Only check for updates if monitoring is running (to avoid slowdown)
    if [[ "$containers_running" == true ]]; then
        # Check updates using unified function
        grafana_update_indicator=$(check_service_update "grafana" "$grafana_version")
        prometheus_update_indicator=$(check_service_update "prometheus" "$prometheus_version")
        node_exporter_update_indicator=$(check_service_update "node-exporter" "$node_exporter_version")
    fi
    
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} monitoring${access_indicator}"
        
        # Check individual service status
        local grafana_status="${GREEN}✓${NC}"
        local prometheus_status="${GREEN}✓${NC}"
        local node_exporter_status="${GREEN}✓${NC}"
        
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "grafana"; then
            grafana_status="${RED}✗${NC}"
        fi
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "prometheus"; then
            prometheus_status="${RED}✗${NC}"
        fi
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "node-exporter"; then
            node_exporter_status="${RED}✗${NC}"
        fi
        
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" "$grafana_status" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %b %-20s (%s)%b\n" "$prometheus_status" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator"
        printf "     %b %-20s (%s)%b\n" "$node_exporter_status" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    else
        echo -e "  ${RED}●${NC} monitoring - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\t     http://%s:%s\n" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %-20s (%s)%b\n" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator"
        printf "     %-20s (%s)%b\n" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    fi
    echo
    echo
}

# Helper function to find available port
find_available_port() {
    local start_port=$1
    local increment=${2:-1}
    local used_ports="${3:-}"
    
    [[ -z "$used_ports" ]] && used_ports=$(get_all_used_ports)
    
    local port=$start_port
    while echo " $used_ports " | grep -q " $port "; do
        port=$((port + increment))
    done
    
    echo $port
}


# Plugin installation menu
manage_plugins_menu() {
    while true; do
        clear
        print_header
        
        
        # Check if monitoring stack is installed
        local monitoring_installed=false
        if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" ]]; then
            monitoring_installed=true
        fi
        
        local menu_options=()
        if [[ "$monitoring_installed" == true ]]; then
            menu_options+=("Uninstall monitoring plugin")
        else
            menu_options+=("Install monitoring plugin (with DICKS)")
        fi
        
        menu_options+=("Back to main menu")
        
        local selection
        if selection=$(fancy_select_menu "Available Plugins" "${menu_options[@]}"); then
            if [[ "$monitoring_installed" == true ]]; then
                case $selection in
                    0) remove_monitoring_stack ;;
                    1) return ;;
                esac
            else
                case $selection in
                    0) install_monitoring_plugin_with_dicks ;;
                    1) return ;;
                esac
            fi
        else
            return
        fi
    done
}
# Install monitoring plugin with automatic DICKS network setup
install_monitoring_plugin_with_dicks() {
    clear
    print_header
    
    # Show dashboard if available
    if declare -f print_dashboard >/dev/null; then
        print_dashboard
        echo
    fi
    
    echo -e "${CYAN}${BOLD}🔌 Installing Monitoring Plugin with DICKS${NC}"
    echo -e "${CYAN}${BOLD}===========================================${NC}"
    echo
    echo -e "${UI_MUTED}This will install the monitoring stack (Prometheus + Grafana) and"
    echo -e "automatically connect it to all available ethnode networks.${NC}"
    echo
    
    # Get list of available ethnode networks for preview
    # Use proper discovery that checks for actual ethnodes, not just Docker networks
    local available_networks=($(discover_nodeboi_networks | cut -d':' -f1))
    if [[ ${#available_networks[@]} -gt 0 ]]; then
        echo -e "${BOLD}Networks that will be connected:${NC}"
        for network in "${available_networks[@]}"; do
            local node_name="${network%-net}"
            echo -e "  • $node_name"
        done
        echo
    else
        echo -e "${YELLOW}⚠️  No active ethnodes found. Monitoring will be installed in isolated mode.${NC}"
        echo
    fi
    
    echo -e "${UI_MUTED}Starting automatic installation...${NC}"
    echo
    
    # Install monitoring stack with all networks pre-selected
    if install_monitoring_stack "${available_networks[@]}"; then
        echo -e "${GREEN}✅ Monitoring plugin installed successfully!${NC}"
        
        # Ensure dashboard cache is refreshed to show new monitoring
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache
        
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    else
        echo -e "${RED}❌ Failed to install monitoring plugin${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    fi
}

# Update monitoring services - similar to ethnode update
update_monitoring_services() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring stack not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    # Go directly to dashboard and show update options
    clear
    print_header
    echo
    
    # Show monitoring status without full dashboard to avoid hanging
    local prometheus_version="unknown"
    local grafana_version="unknown"
    local node_exporter_version="unknown"
    
    if cd "$HOME/monitoring" 2>/dev/null; then
        if [[ -f .env ]]; then
            prometheus_version=$(grep "^PROMETHEUS_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
            grafana_version=$(grep "^GRAFANA_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
            node_exporter_version=$(grep "^NODE_EXPORTER_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
        fi
    fi
    
    echo -e "${CYAN}${BOLD}Current Monitoring Stack${NC}"
    echo "========================"
    echo
    echo -e "  • Prometheus: ${YELLOW}${prometheus_version}${NC}"
    echo -e "  • Grafana:    ${YELLOW}${grafana_version}${NC}"
    echo -e "  • Node Exporter: ${YELLOW}${node_exporter_version}${NC}"
    echo
    
    # Update options similar to ethnode update
    local update_options=(
        "Update all to latest versions"
        "Update services to specific versions" 
        "Back to monitoring menu"
    )
    
    local selection
    if selection=$(fancy_select_menu "Update Options" "${update_options[@]}"); then
        case $selection in
            0) update_all_monitoring_services ;;
            1) update_monitoring_to_specific_versions ;;
            2) return ;;
        esac
    fi
}

# Update all monitoring services to latest versions
update_all_monitoring_services() {
    # Source clients library for version fetching
    [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Updating All Monitoring Services${NC}"
    echo "================================="
    echo
    echo -e "${UI_MUTED}This will update to the latest stable versions:${NC}"
    
    # Fetch latest versions dynamically
    echo -e "${UI_MUTED}Checking for latest versions...${NC}"
    local latest_prometheus=$(get_latest_version "prometheus" 2>/dev/null || echo "v3.5.0")
    local latest_grafana=$(get_latest_version "grafana" 2>/dev/null || echo "12.1.0") 
    local latest_node_exporter=$(get_latest_version "node-exporter" 2>/dev/null || echo "v1.9.1")
    
    # Normalize versions for Docker image compatibility
    latest_prometheus=$(normalize_version "prometheus" "$latest_prometheus")
    latest_grafana=$(normalize_version "grafana" "$latest_grafana")
    latest_node_exporter=$(normalize_version "node-exporter" "$latest_node_exporter")
    
    echo -e "  • Prometheus: ${GREEN}${latest_prometheus}${NC}"
    echo -e "  • Grafana: ${GREEN}${latest_grafana}${NC}"
    echo -e "  • Node Exporter: ${GREEN}${latest_node_exporter}${NC}"
    echo
    echo -e "${YELLOW}⚠️  Services will be restarted${NC}"
    echo
    
    echo -e "${UI_MUTED}Press Enter to continue or Ctrl+C to cancel...${NC}"
    read -r
    
    cd "$HOME/monitoring"
    
    echo -e "${UI_MUTED}Updating .env file with latest versions...${NC}"
    sudo sed -i "s/^PROMETHEUS_VERSION=.*/PROMETHEUS_VERSION=${latest_prometheus}/" .env
    sudo sed -i "s/^GRAFANA_VERSION=.*/GRAFANA_VERSION=${latest_grafana}/" .env
    sudo sed -i "s/^NODE_EXPORTER_VERSION=.*/NODE_EXPORTER_VERSION=${latest_node_exporter}/" .env
    
    echo -e "${UI_MUTED}Stopping services...${NC}"
    docker compose down
    
    echo -e "${UI_MUTED}Pulling latest images...${NC}"
    docker compose pull
    
    echo -e "${UI_MUTED}Starting updated services...${NC}"
    docker compose up -d
    
    echo -e "${GREEN}✅ All monitoring services updated successfully${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Update monitoring services to specific versions
update_monitoring_to_specific_versions() {
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Update Services to Specific Versions${NC}"
    echo "===================================="
    echo
    
    cd "$HOME/monitoring"
    source .env
    
    echo -e "${UI_MUTED}Current versions:${NC}"
    echo -e "  • Prometheus: ${YELLOW}${PROMETHEUS_VERSION}${NC}"
    echo -e "  • Grafana:    ${YELLOW}${GRAFANA_VERSION}${NC}" 
    echo -e "  • Node Exporter: ${YELLOW}${NODE_EXPORTER_VERSION}${NC}"
    echo
    
    echo -e "${UI_MUTED}Enter new versions (press Enter to keep current):${NC}"
    echo
    
    # Get new versions from user
    echo -n "Prometheus version (current: ${PROMETHEUS_VERSION}): "
    read new_prometheus_version
    [[ -z "$new_prometheus_version" ]] && new_prometheus_version="$PROMETHEUS_VERSION"
    
    echo -n "Grafana version (current: ${GRAFANA_VERSION}): "
    read new_grafana_version
    [[ -z "$new_grafana_version" ]] && new_grafana_version="$GRAFANA_VERSION"
    
    echo -n "Node Exporter version (current: ${NODE_EXPORTER_VERSION}): "
    read new_node_exporter_version
    [[ -z "$new_node_exporter_version" ]] && new_node_exporter_version="$NODE_EXPORTER_VERSION"
    
    echo
    echo -e "${UI_MUTED}Will update to:${NC}"
    echo -e "  • Prometheus: ${GREEN}${new_prometheus_version}${NC}"
    echo -e "  • Grafana: ${GREEN}${new_grafana_version}${NC}"
    echo -e "  • Node Exporter: ${GREEN}${new_node_exporter_version}${NC}"
    echo
    
    echo -e "${UI_MUTED}Press Enter to continue or Ctrl+C to cancel...${NC}"
    read -r
    
    # Update .env file with new versions
    sed -i "s/PROMETHEUS_VERSION=.*/PROMETHEUS_VERSION=${new_prometheus_version}/" .env
    sed -i "s/GRAFANA_VERSION=.*/GRAFANA_VERSION=${new_grafana_version}/" .env
    sed -i "s/NODE_EXPORTER_VERSION=.*/NODE_EXPORTER_VERSION=${new_node_exporter_version}/" .env
    
    echo -e "${UI_MUTED}Stopping services...${NC}"
    docker compose down
    
    echo -e "${UI_MUTED}Pulling specified versions...${NC}"
    docker compose pull
    
    echo -e "${UI_MUTED}Starting updated services...${NC}"
    docker compose up -d
    
    echo -e "${GREEN}✅ All services updated to specified versions${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}


# Start/stop monitoring services
manage_monitoring_state() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring stack not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    cd "$HOME/monitoring"
    local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Monitoring Services Status${NC}"
    echo "=========================="
    echo
    
    # Check service status
    local all_running=true
    for service in prometheus grafana node-exporter; do
        if echo "$running_services" | grep -q "$service"; then
            echo -e "  ✓ $service: ${GREEN}Running${NC}"
        else
            echo -e "  ✗ $service: ${RED}Stopped${NC}"
            all_running=false
        fi
    done
    
    echo
    
    local action_options=()
    if [[ "$all_running" == true ]]; then
        action_options+=("Stop all services")
        action_options+=("Restart all services")
    else
        action_options+=("Start all services")
        if [[ -n "$running_services" ]]; then
            action_options+=("Stop all services")
            action_options+=("Restart all services")
        fi
    fi
    action_options+=("Back to monitoring menu")
    
    local selection
    if selection=$(fancy_select_menu "Service Management" "${action_options[@]}"); then
        case "${action_options[$selection]}" in
            "Start all services")
                echo -e "${UI_MUTED}Starting monitoring services...${NC}"
                docker compose up -d
                echo -e "${GREEN}✅ Services started${NC}"
                ;;
            "Stop all services")
                echo -e "${UI_MUTED}Stopping monitoring services...${NC}"
                docker compose down
                echo -e "${YELLOW}⏹️  Services stopped${NC}"
                ;;
            "Restart all services")
                echo -e "${UI_MUTED}Restarting monitoring services...${NC}"
                docker compose restart
                echo -e "${GREEN}🔄 Services restarted${NC}"
                ;;
            "Back to monitoring menu")
                return
                ;;
        esac
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    fi
}

# View monitoring service logs
view_monitoring_logs() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring stack not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    cd "$HOME/monitoring"
    local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
    
    if [[ -z "$running_services" ]]; then
        clear
        print_header
        print_box "No monitoring services are currently running" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}View Monitoring Logs${NC}"
    echo "===================="
    echo
    
    # Build log options for running services
    local log_options=()
    for service in prometheus grafana node-exporter; do
        if echo "$running_services" | grep -q "$service"; then
            log_options+=("View $service logs")
        fi
    done
    log_options+=("View all logs (split screen)")
    log_options+=("Back to monitoring menu")
    
    local selection
    if selection=$(fancy_select_menu "Log Viewer" "${log_options[@]}"); then
        if [[ $selection -lt 3 ]]; then
            # Individual service logs
            local service_name=""
            local service_index=0
            for service in prometheus grafana node-exporter; do
                if echo "$running_services" | grep -q "$service"; then
                    if [[ $service_index -eq $selection ]]; then
                        service_name="$service"
                        break
                    fi
                    ((service_index++))
                fi
            done
            
            if [[ -n "$service_name" ]]; then
                clear
                echo -e "${CYAN}${BOLD}$service_name Logs${NC} (Press Ctrl+C to exit)"
                echo "===================="
                echo
                docker compose logs -f "$service_name"
            fi
        elif [[ "${log_options[$selection]}" == "View all logs (split screen)" ]]; then
            # Split screen logs
            clear
            echo -e "${CYAN}${BOLD}All Monitoring Logs${NC} (Press Ctrl+C to exit)"
            echo "========================"
            echo
            docker compose logs -f
        fi
    fi
}
