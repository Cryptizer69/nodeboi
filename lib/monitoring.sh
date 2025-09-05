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
        echo -e "${YELLOW}Monitoring stack already installed${NC}"
        
        if fancy_confirm "Remove existing installation?" "n"; then
            cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
            sudo rm -rf "$HOME/monitoring"
            echo -e "${UI_MUTED}Existing monitoring removed${NC}"
        else
            press_enter
            return
        fi
    fi
    
    # Step 1: Setup directories and user
    echo -e "${UI_MUTED}Setting up directories and user...${NC}"
    mkdir -p ~/monitoring/grafana/provisioning/datasources
    
    # Create monitoring user
    if ! id "monitoring" &>/dev/null; then
        sudo useradd -r -s /bin/false monitoring
    fi
    local NODE_UID=$(id -u monitoring)
    local NODE_GID=$(id -g monitoring)
    echo -e "${UI_MUTED}  Monitoring user: monitoring (${NODE_UID}:${NODE_GID})${NC}"
    
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
    echo
    local access_options=(
        "My machine only (127.0.0.1) - Most secure"
        "Local network access (auto-detect IP)"
        "All networks (0.0.0.0) - Use with caution"
    )
    
    local bind_ip="127.0.0.1"
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
    
    # Step 4: Auto-discover and connect to all ethnode networks
    echo
    echo -e "${UI_MUTED}Auto-discovering ethnode networks...${NC}"
    local available_networks=($(discover_nodeboi_networks))
    
    # Auto-select all ethnode networks
    local selected_networks=()
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
PROMETHEUS_VERSION=v3.0.0
GRAFANA_VERSION=11.2.0
NODE_EXPORTER_VERSION=v1.8.2

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
        echo "      - ${network}" >> ~/monitoring/compose.yml
    done

    # Continue with rest of compose.yml
    cat >> ~/monitoring/compose.yml <<'EOF'
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
    name: ${MONITORING_NAME}-net
    driver: bridge
EOF
    
    # Add external networks to compose.yml
    for network in "${selected_networks[@]}"; do
        cat >> ~/monitoring/compose.yml <<EOF
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
    sudo chown -R ${NODE_UID}:${NODE_GID} ~/monitoring/
    
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
                echo -e "Prometheus:  ${GREEN}http://localhost:${prometheus_port}${NC}"
            else
                echo -e "Grafana:     ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
                echo -e "Prometheus:  ${GREEN}http://${bind_ip}:${prometheus_port}${NC}"
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
        echo -e "  Prometheus: ${GREEN}http://localhost:${prometheus_port}${NC}"
    elif [[ "$bind_ip" == "0.0.0.0" ]]; then
        local actual_ip=$(hostname -I | awk '{print $1}')
        echo -e "  Grafana:    ${GREEN}http://${actual_ip}:${grafana_port}${NC}"
        echo -e "  Prometheus: ${GREEN}http://${actual_ip}:${prometheus_port}${NC}"
    else
        echo -e "  Grafana:    ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
        echo -e "  Prometheus: ${GREEN}http://${bind_ip}:${prometheus_port}${NC}"
    fi
    
    echo
    echo -e "${BOLD}Credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}${grafana_password}${NC}"
    
    echo
    press_enter
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
    
    if fancy_confirm "Remove monitoring stack? This will delete all metrics data!" "n"; then
        echo -e "\n${UI_MUTED}Stopping containers...${NC}"
        cd "$HOME/monitoring"
        docker compose down -v
        
        echo -e "${UI_MUTED}Removing directory...${NC}"
        cd "$HOME"
        sudo rm -rf "$HOME/monitoring"
        
        # Remove monitoring user (optional)
        if fancy_confirm "Also remove monitoring system user?" "n"; then
            sudo userdel monitoring 2>/dev/null || true
        fi
        
        echo -e "${GREEN}✓ Monitoring stack removed${NC}"
    else
        echo "Removal cancelled"
    fi
    
    press_enter
}

# Update monitoring stack with version selection
update_monitoring_stack() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    clear
    print_header
    
    echo -e "\n${CYAN}${BOLD}Update Monitoring Stack${NC}"
    echo "======================="
    echo
    
    # Get current versions
    local current_prometheus=$(grep "^PROMETHEUS_VERSION=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local current_grafana=$(grep "^GRAFANA_VERSION=" "$HOME/monitoring/.env" | cut -d'=' -f2)  
    local current_node_exporter=$(grep "^NODE_EXPORTER_VERSION=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    
    echo -e "${UI_MUTED}Current versions:${NC}"
    echo -e "${UI_MUTED}  Prometheus: $current_prometheus${NC}"
    echo -e "${UI_MUTED}  Grafana: $current_grafana${NC}"
    echo -e "${UI_MUTED}  Node Exporter: $current_node_exporter${NC}"
    echo
    
    # Service selection menu
    local update_options=(
        "Update all services (recommended)"
        "Update Prometheus only"
        "Update Grafana only" 
        "Update Node Exporter only"
        "Cancel"
    )
    
    local selection
    if ! selection=$(fancy_select_menu "Select Update Scope" "${update_options[@]}"); then
        return
    fi
    
    local services_to_update=()
    case $selection in
        0) services_to_update=("prometheus" "grafana" "node-exporter") ;;
        1) services_to_update=("prometheus") ;;
        2) services_to_update=("grafana") ;;
        3) services_to_update=("node-exporter") ;;
        4) return ;;
    esac
    
    echo
    echo -e "${UI_MUTED}Updating services: ${services_to_update[*]}${NC}"
    
    # Version selection for each service
    local new_prometheus_version="$current_prometheus"
    local new_grafana_version="$current_grafana"
    local new_node_exporter_version="$current_node_exporter"
    
    for service in "${services_to_update[@]}"; do
        case $service in
            "prometheus")
                echo
                new_prometheus_version=$(prompt_monitoring_version "Prometheus" "$current_prometheus")
                [[ -z "$new_prometheus_version" ]] && new_prometheus_version="$current_prometheus"
                ;;
            "grafana")
                echo
                new_grafana_version=$(prompt_monitoring_version "Grafana" "$current_grafana")
                [[ -z "$new_grafana_version" ]] && new_grafana_version="$current_grafana"
                ;;
            "node-exporter")
                echo
                new_node_exporter_version=$(prompt_monitoring_version "Node Exporter" "$current_node_exporter")
                [[ -z "$new_node_exporter_version" ]] && new_node_exporter_version="$current_node_exporter"
                ;;
        esac
    done
    
    # Show update summary
    echo
    echo -e "${BOLD}Update Summary:${NC}"
    echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━${NC}"
    
    if [[ "$new_prometheus_version" != "$current_prometheus" ]]; then
        echo -e "Prometheus: $current_prometheus → ${GREEN}$new_prometheus_version${NC}"
    fi
    if [[ "$new_grafana_version" != "$current_grafana" ]]; then
        echo -e "Grafana: $current_grafana → ${GREEN}$new_grafana_version${NC}"
    fi
    if [[ "$new_node_exporter_version" != "$current_node_exporter" ]]; then
        echo -e "Node Exporter: $current_node_exporter → ${GREEN}$new_node_exporter_version${NC}"
    fi
    
    # Check if any versions changed
    if [[ "$new_prometheus_version" == "$current_prometheus" && \
          "$new_grafana_version" == "$current_grafana" && \
          "$new_node_exporter_version" == "$current_node_exporter" ]]; then
        echo -e "${UI_MUTED}No version changes - will restart services with current versions${NC}"
    fi
    
    echo
    if ! fancy_confirm "Proceed with update?" "y"; then
        echo -e "${UI_MUTED}Update cancelled${NC}"
        press_enter
        return
    fi
    
    # Update .env file with new versions
    cd "$HOME/monitoring"
    sudo sed -i "s/^PROMETHEUS_VERSION=.*/PROMETHEUS_VERSION=${new_prometheus_version}/" .env
    sudo sed -i "s/^GRAFANA_VERSION=.*/GRAFANA_VERSION=${new_grafana_version}/" .env
    sudo sed -i "s/^NODE_EXPORTER_VERSION=.*/NODE_EXPORTER_VERSION=${new_node_exporter_version}/" .env
    
    # Perform the update
    echo -e "\n${UI_MUTED}Updating monitoring stack...${NC}"
    echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Pull new images
    echo -e "${UI_MUTED}Pulling Docker images...${NC}"
    if docker compose pull; then
        echo -e "${GREEN}✓ Images pulled successfully${NC}"
    else
        echo -e "${RED}✗ Failed to pull images${NC}"
        press_enter
        return
    fi
    
    # Restart services
    echo -e "${UI_MUTED}Restarting services...${NC}"
    if docker compose down && docker compose up -d --force-recreate; then
        echo -e "${GREEN}✓ Services restarted successfully${NC}"
        
        # Show final status
        echo
        sleep 2
        local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
        
        if echo "$running_services" | grep -q "prometheus" && \
           echo "$running_services" | grep -q "grafana" && \
           echo "$running_services" | grep -q "node-exporter"; then
            echo -e "${GREEN}✓ All monitoring services are running${NC}"
            
            local bind_ip=$(grep "^BIND_IP=" .env | cut -d'=' -f2)
            local grafana_port=$(grep "^GRAFANA_PORT=" .env | cut -d'=' -f2)
            
            echo
            echo -e "${BOLD}Access Information:${NC}"
            if [[ "$bind_ip" == "127.0.0.1" ]]; then
                echo -e "Grafana: ${GREEN}http://localhost:${grafana_port}${NC}"
            elif [[ "$bind_ip" == "0.0.0.0" ]]; then
                local actual_ip=$(hostname -I | awk '{print $1}')
                echo -e "Grafana: ${GREEN}http://${actual_ip}:${grafana_port}${NC}"
            else
                echo -e "Grafana: ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
            fi
        else
            echo -e "${YELLOW}⚠ Some services may not be running properly${NC}"
            echo -e "${UI_MUTED}Check logs with: docker compose logs${NC}"
        fi
    else
        echo -e "${RED}✗ Failed to restart services${NC}"
    fi
    
    echo
    press_enter
}

# Prompt for monitoring service version selection
prompt_monitoring_version() {
    local service_name=$1
    local current_version=$2
    
    local version_options=(
        "Keep current version ($current_version)"
        "Enter version number"
        "Use latest version"
    )
    
    local version_choice
    if ! version_choice=$(fancy_select_menu "$service_name Version" "${version_options[@]}"); then
        echo "$current_version"
        return
    fi
    
    case $version_choice in
        0)
            # Keep current
            echo "$current_version"
            ;;
        1)
            # Manual entry
            local manual_version
            manual_version=$(fancy_text_input "$service_name Version" \
                "Enter version (e.g., v3.5.0, 11.2.0):" \
                "" \
                "")
            
            if [[ -z "$manual_version" ]]; then
                echo -e "${UI_MUTED}Using current version: $current_version${NC}" >&2
                echo "$current_version"
            else
                echo -e "${UI_MUTED}Using manual version: $manual_version${NC}" >&2
                echo "$manual_version"
            fi
            ;;
        2)
            # Latest version - fetch from GitHub API using unified function
            echo -e "${UI_MUTED}Fetching latest version...${NC}" >&2
            local service_key
            case "$service_name" in
                "Prometheus") service_key="prometheus" ;;
                "Grafana") service_key="grafana" ;;
                "Node Exporter") service_key="node-exporter" ;;
                *) service_key="" ;;
            esac
            
            if [[ -n "$service_key" ]]; then
                local latest_version=$(get_latest_version "$service_key" 2>/dev/null)
                if [[ -n "$latest_version" ]]; then
                    echo -e "${UI_MUTED}Using latest version: $latest_version${NC}" >&2
                    echo "$latest_version"
                else
                    echo -e "${UI_MUTED}Could not fetch latest version, using current: $current_version${NC}" >&2
                    echo "$current_version"
                fi
            else
                echo "$current_version"
            fi
            ;;
    esac
}

# Monitoring management menu
manage_monitoring_menu() {
    while true; do
        # Check if monitoring is installed
        if [[ -d "$HOME/monitoring" ]]; then
            
            local menu_options=(
                "Start/stop monitoring"
                "Update monitoring"
                "Remove monitoring stack"
                "View logs"
                "See Grafana credentials"
                "Back to main menu"
            )
        else
            local menu_options=(
                "Install monitoring stack"
                "Back to main menu"
            )
        fi
        
        local selection
        if selection=$(fancy_select_menu "Monitoring Options" "${menu_options[@]}"); then
            if [[ -d "$HOME/monitoring" ]]; then
                case $selection in
                    0) 
                        # Start/stop monitoring - check current status and toggle
                        cd "$HOME/monitoring"
                        if docker compose ps --services --filter status=running 2>/dev/null | grep -q prometheus; then
                            echo -e "${UI_MUTED}Stopping monitoring stack...${NC}"
                            docker compose down
                            echo -e "${GREEN}✓ Monitoring stopped${NC}"
                        else
                            echo -e "${UI_MUTED}Starting monitoring stack...${NC}"
                            docker compose up -d
                            echo -e "${GREEN}✓ Monitoring started${NC}"
                        fi
                        press_enter
                        ;;
                    1) update_monitoring_stack ;;
                    2) remove_monitoring_stack ;;
                    3)
                        cd "$HOME/monitoring"
                        docker compose logs --tail=50 -f
                        ;;
                    4) view_grafana_credentials ;;
                    5) return ;;
                esac
            else
                case $selection in
                    0) install_monitoring_stack ;;
                    1) return ;;
                esac
            fi
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
        
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" "$grafana_status" "Grafana" "$grafana_version" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %b %-20s (%s)%b\n" "$prometheus_status" "Prometheus" "$prometheus_version" "$prometheus_update_indicator"
        printf "     %b %-20s (%s)%b\n" "$node_exporter_status" "Node Exporter" "$node_exporter_version" "$node_exporter_update_indicator"
    else
        echo -e "  ${RED}●${NC} monitoring - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\t     http://%s:%s\n" "Grafana" "$grafana_version" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %-20s (%s)%b\n" "Prometheus" "$prometheus_version" "$prometheus_update_indicator"
        printf "     %-20s (%s)%b\n" "Node Exporter" "$node_exporter_version" "$node_exporter_update_indicator"
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
        
        echo -e "${BOLD}Plugin Services${NC}"
        echo "==============="
        echo
        echo -e "${UI_MUTED}Install additional services to extend NODEBOI functionality${NC}"
        echo
        
        local menu_options=(
            "Install monitoring stack (Prometheus + Grafana)"
            "Install SSV Operator (coming soon)"
            "Install Vero Monitor (coming soon)"  
            "Install Web3Signer (coming soon)"
            "Back to main menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Available Plugins" "${menu_options[@]}"); then
            case $selection in
                0) install_monitoring_stack ;;
                1) 
                    echo -e "${YELLOW}SSV Operator plugin coming soon${NC}"
                    press_enter
                    ;;
                2)
                    echo -e "${YELLOW}Vero Monitor plugin coming soon${NC}"
                    press_enter
                    ;;
                3)
                    echo -e "${YELLOW}Web3Signer plugin coming soon${NC}"
                    press_enter
                    ;;
                4) return ;;
            esac
        else
            return
        fi
    done
}