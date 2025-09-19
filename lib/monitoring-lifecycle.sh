#!/bin/bash
# lib/monitoring-lifecycle.sh - Monitoring stack lifecycle management for NODEBOI
# Handles installation, updates, and removal of monitoring services

# Import required modules
[[ -f "${NODEBOI_LIB}/common.sh" ]] && source "${NODEBOI_LIB}/common.sh"
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"

#============================================================================
# MONITORING INSTALLATION
#============================================================================

install_monitoring_stack() {
    # Enable strict error handling for atomic installation
    set -eE
    set -o pipefail
    
    local preselected_networks=("$@")  # Accept networks as parameters
    local final_dir="$HOME/monitoring"  # Final installation location
    local staging_dir="$HOME/.monitoring-install-$$"  # Temporary staging area
    local installation_success=false
    
    # Comprehensive cleanup for atomic installation
    atomic_monitoring_cleanup() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "\n${RED}✗${NC} Monitoring installation failed"
        echo -e "${UI_MUTED}Performing complete cleanup...${NC}"
        
        # Clean up service registration - remove monitoring directory to prevent phantom service
        if [[ -d "$final_dir" ]]; then
            echo -e "${UI_MUTED}Removing service registration...${NC}"
            rm -rf "$final_dir"
        fi
        
        # Stop and remove any Docker resources
        if [[ -d "$staging_dir" && -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>/dev/null || true
        fi
        
        # Remove containers by name pattern
        docker ps -aq --filter "name=monitoring" | xargs -r docker rm -f 2>/dev/null || true
        
        # Remove volumes and networks
        docker volume ls -q --filter "name=monitoring" | xargs -r docker volume rm -f 2>/dev/null || true
        
        # Remove staging directory
        [[ -n "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
        
        echo -e "${GREEN}✓ Cleanup completed${NC}"
        echo -e "${UI_MUTED}Installation aborted - no partial installation left behind${NC}"
        
        press_enter
        return $exit_code
    }
    
    # Set error trap
    trap atomic_monitoring_cleanup ERR INT TERM
    
    echo -e "\n${CYAN}${BOLD}Install Monitoring${NC}"
    echo "========================="
    echo
    echo -e "${UI_MUTED}This will install:${NC}"
    echo -e "${UI_MUTED}  • Prometheus - Metrics collection and storage${NC}"
    echo -e "${UI_MUTED}  • Grafana - Visual dashboards and analytics${NC}"
    echo -e "${UI_MUTED}  • Node Exporter - System metrics (CPU/Memory/Disk)${NC}"
    echo
    
    # Check if already installed
    if [[ -d "$final_dir" ]]; then
        if [[ ${#preselected_networks[@]} -gt 0 ]]; then
            # Services installation - remove existing installation
            echo -e "${UI_MUTED}Removing existing installation...${NC}"
            cd "$final_dir" 2>/dev/null && docker compose down -v 2>/dev/null || true
            if ! rm -rf "$final_dir" 2>/dev/null; then
                echo -e "${YELLOW}Some files require admin permissions to remove${NC}"
                echo -e "${UI_MUTED}You may be prompted for your password...${NC}"
                sudo rm -rf "$final_dir"
            fi
        else
            # Manual installation - show message and return
            echo -e "${YELLOW}The monitoring stack is already installed${NC}"
            echo -e "${UI_MUTED}Press Enter to continue...${NC}"
            read -r
            trap - ERR INT TERM
            return
        fi
    fi
    
    # Create staging environment
    echo -e "${UI_MUTED}Creating staging environment...${NC}"
    mkdir -p "$staging_dir/grafana/provisioning/datasources"
    
    # Setup user info
    echo -e "${UI_MUTED}Setting up user configuration...${NC}"
    
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
        # Services installation - use 0.0.0.0 automatically
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
        # Use pre-selected networks (from services installation)
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
        
        # Only include ethnode networks, not other service networks
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
    cat > "$staging_dir/.env" <<EOF
#============================================================================
# MONITORING CONFIGURATION
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

    # Step 7: Create compose.yml with dynamic network configuration
    cat > "$staging_dir/compose.yml" <<'EOF'
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
EOF

    # Simple approach: connect to monitoring-net + ethnode networks + validator-net
    # NEVER connect to web3signer-net for security isolation
    local monitoring_networks=("monitoring-net" "validator-net")
    for network in "${selected_networks[@]}"; do
        if [[ "$network" =~ ^ethnode.*-net$ ]]; then
            monitoring_networks+=("$network")
        fi
    done
    
    # Remove duplicates and output
    local unique_networks=($(printf '%s\n' "${monitoring_networks[@]}" | sort -u))
    for network in "${unique_networks[@]}"; do
        echo "      - $network" >> "$staging_dir/compose.yml"
    done

    cat >> "$staging_dir/compose.yml" <<'EOF'
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
EOF

    # Add same networks for grafana
    for network in "${unique_networks[@]}"; do
        echo "      - $network" >> "$staging_dir/compose.yml"
    done

    cat >> "$staging_dir/compose.yml" <<'EOF'
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
EOF

    # Add same networks for node-exporter
    for network in "${unique_networks[@]}"; do
        echo "      - $network" >> "$staging_dir/compose.yml"
    done

    cat >> "$staging_dir/compose.yml" <<'EOF'
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: ${MONITORING_NAME}_prometheus_data
  grafana_data:
    name: ${MONITORING_NAME}_grafana_data

networks:
EOF

    # Add network definitions (only for networks we actually use)
    for network in "${unique_networks[@]}"; do
        cat >> "$staging_dir/compose.yml" <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done

    # Step 8: Create Prometheus configuration
    echo -e "${UI_MUTED}Generating Prometheus configuration...${NC}"
    
    cat > "$staging_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
    
    # Add discovered targets
    local prometheus_targets=$(generate_prometheus_targets_authoritative "${selected_networks[@]}")
    echo "$prometheus_targets" >> "$staging_dir/prometheus.yml"
    
    # Step 9: Create Grafana provisioning configuration
    # Create datasource configuration
    cat > "$staging_dir/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1

datasources:
  - name: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
    
    # Create dashboard provisioning directories
    mkdir -p "$staging_dir/grafana/provisioning/dashboards"
    mkdir -p "$staging_dir/grafana/dashboards"
    
    # Create dashboard provisioning configuration
    cat > "$staging_dir/grafana/provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
EOF
    
    # Copy relevant dashboard templates based on active services
    echo -e "${UI_MUTED}Copying dashboard templates for active services...${NC}"
    copy_relevant_dashboards "$staging_dir/grafana/dashboards" "${selected_networks[@]}"
    
    # Step 10: Set permissions
    echo -e "${UI_MUTED}Setting permissions...${NC}"
    # Ensure proper permissions on directories (already owned by current user)
    chmod 755 "$staging_dir/"
    chmod 755 "$staging_dir/grafana/provisioning/"
    chmod 755 "$staging_dir/grafana/provisioning/datasources/"
    
    # Step 11: Launch monitoring
    echo -e "${UI_MUTED}Starting monitoring...${NC}"
    # ATOMIC OPERATION: Move from staging to final location
    echo -e "${UI_MUTED}Finalizing monitoring installation...${NC}"
    echo -e "${UI_MUTED}Moving from staging to final location...${NC}"
    
    # This is the atomic operation - either it all succeeds or fails
    mv "$staging_dir" "$final_dir"
    
    # Mark installation as successful to prevent cleanup
    installation_success=true
    
    # Remove error trap now that installation is complete
    trap - ERR INT TERM
    
    cd "$final_dir"
    
    # Pre-validate networks before starting containers
    echo -e "${UI_MUTED}Validating external network dependencies...${NC}"
    local network_validation_failed=false
    for network in "${selected_networks[@]}"; do
        if ! docker network inspect "$network" >/dev/null 2>&1; then
            echo -e "${RED}✗ Network '$network' does not exist${NC}"
            network_validation_failed=true
        else
            echo -e "${UI_MUTED}✓ $network already exists${NC}"
        fi
    done
    
    if [[ "$network_validation_failed" == "true" ]]; then
        echo -e "${RED}Network validation failed - aborting installation${NC}"
        press_enter
        return 1
    fi
    
    if docker compose up -d; then
        echo
        sleep 2
        
        # Verify containers are running
        if docker compose ps --services --filter status=running | grep -q prometheus; then
            echo -e "${GREEN}✓ Monitoring installed successfully!${NC}"
            echo
            echo -e "${BOLD}Access Information:${NC}"
            echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            
            if [[ "$bind_ip" == "127.0.0.1" ]]; then
                echo -e "Grafana:     ${GREEN}http://localhost:${grafana_port}/dashboards${NC}"
            else
                echo -e "Grafana:     ${GREEN}http://${bind_ip}:${grafana_port}/dashboards${NC}"
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
            
            return 0
        else
            echo -e "${RED}Failed to start monitoring containers${NC}"
            docker compose logs --tail=20
            press_enter
            return 1
        fi
    else
        echo -e "${RED}Failed to launch monitoring${NC}"
        press_enter
        return 1
    fi
}

#============================================================================
# MONITORING REMOVAL
#============================================================================

remove_monitoring_stack() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Remove Monitoring${NC}"
    echo "======================="
    
    echo -e "${UI_MUTED}Stopping monitoring containers...${NC}"
    cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
    
    echo -e "${UI_MUTED}Removing monitoring files...${NC}"
    # Use sudo for files that might be owned by the old monitoring user
    if ! rm -rf "$HOME/monitoring" 2>/dev/null; then
        echo -e "${YELLOW}Some files require admin permissions to remove${NC}"
        echo -e "${UI_MUTED}You may be prompted for your password...${NC}"
        sudo rm -rf "$HOME/monitoring"
    fi
    
    # No system user cleanup needed - using current user
    
    echo -e "${GREEN}✅ Monitoring removed successfully${NC}"
    
    # Refresh dashboard cache to remove monitoring from display
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}

#============================================================================
# MONITORING UPDATES
#============================================================================

update_monitoring_services() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
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
    
    echo -e "${CYAN}${BOLD}Current Monitoring${NC}"
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

#============================================================================
# SERVICE MANAGEMENT
#============================================================================

# Start/stop monitoring services
manage_monitoring_state() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
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
                docker compose down && docker compose up -d
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

#============================================================================
# AUTOMATED INSTALLATION
#============================================================================

install_monitoring_services_with_dicks() {
    clear
    print_header
    
    # Show dashboard if available
    if declare -f print_dashboard >/dev/null; then
        print_dashboard
        echo
    fi
    
    # Check if monitoring is already installed
    if [[ -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}The monitoring stack is already installed${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi

    echo -e "${CYAN}${BOLD}🔌 Installing Monitoring Services${NC}"
    echo -e "${CYAN}${BOLD}===========================================${NC}"
    echo
    echo -e "${UI_MUTED}This will install monitoring (Prometheus + Grafana) and"
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
    
    # Install monitoring with all networks pre-selected
    if install_monitoring_stack "${available_networks[@]}"; then
        echo -e "${GREEN}✅ Monitoring services installed successfully!${NC}"
        
        # Ensure dashboard cache is refreshed to show new monitoring
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        
        echo
        echo -e "${UI_MUTED}Returning to main menu...${NC}"
        sleep 1
        return 0
    else
        echo -e "${RED}❌ Failed to install monitoring services${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    fi
}

#============================================================================
# UTILITY FUNCTIONS
#============================================================================

get_installed_services() {
    local services=()
    
    # Always include node-exporter if monitoring is installed
    if [[ -d "$HOME/monitoring" ]]; then
        services+=("node-exporter")
    fi
    
    # Scan ethnode directories
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local compose_files=$(grep "COMPOSE_FILE=" "$ethnode_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            # Parse compose files to determine clients
            if [[ -n "$compose_files" ]]; then
                # Check for execution clients
                if echo "$compose_files" | grep -q "besu.yml"; then
                    services+=("besu")
                elif echo "$compose_files" | grep -q "reth.yml"; then
                    services+=("reth")
                elif echo "$compose_files" | grep -q "nethermind.yml"; then
                    services+=("nethermind")
                fi
                
                # Check for consensus clients
                if echo "$compose_files" | grep -q "grandine"; then
                    services+=("grandine")
                elif echo "$compose_files" | grep -q "lodestar"; then
                    services+=("lodestar")
                elif echo "$compose_files" | grep -q "teku"; then
                    services+=("teku")
                elif echo "$compose_files" | grep -q "lighthouse"; then
                    services+=("lighthouse")
                fi
            fi
        fi
    done
    
    # Check validator services
    [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]] && services+=("vero")
    [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]] && services+=("teku-validator")
    [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/.env" ]] && services+=("web3signer")
    
    printf "%s\n" "${services[@]}" | sort -u
}