#!/bin/bash
# lib/monitoring-lifecycle.sh - Monitoring stack lifecycle management for NODEBOI
# Handles installation, updates, and removal of monitoring services

# Import required modules
[[ -f "${NODEBOI_LIB}/common.sh" ]] && source "${NODEBOI_LIB}/common.sh"
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"
[[ -f "${NODEBOI_LIB}/templates.sh" ]] && source "${NODEBOI_LIB}/templates.sh"

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
    # Creating staging environment...
    mkdir -p "$staging_dir/grafana/provisioning/datasources"
    
    # Setup user info
    # Setting up user configuration...
    
    # Use current user (eth-docker pattern - no system user needed)
    local NODE_UID=$(id -u)
    local NODE_GID=$(id -g)
    # Using current user: UID=${NODE_UID}, GID=${NODE_GID}
    
    # Step 2: Get Grafana password
    clear
    print_header
    
    # Show dashboard if available
    if declare -f print_dashboard >/dev/null; then
        print_dashboard
        echo
    fi
    
    echo -e "${CYAN}Grafana Setup${NC}"
    echo "============="
    echo
    local grafana_password
    echo -ne "${UI_MUTED}Set Grafana admin password (or press Enter for random): ${NC}"
    read -r grafana_password
    
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
        # Setting network access to all networks (0.0.0.0)...
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
                    echo -e "${RED}⚠ WARNING: Grafana accessible from ALL networks${NC}"
                    echo
                    echo -e "${UI_MUTED}Security note:${NC}"
                    echo -e "${UI_MUTED}• Grafana will be accessible from your local network (safe for most home setups)${NC}"
                    echo -e "${UI_MUTED}• Only unsafe if router ports are forwarded to the internet${NC}"
                    echo -e "${UI_MUTED}• Ensure your network is trusted and firewall is configured${NC}"
                    ;;
            esac
        fi
    fi
    
    # Step 4: Auto-discover and connect to all ethnode networks
    echo
    local selected_networks=()
    
    if [[ ${#preselected_networks[@]} -gt 0 ]]; then
        # Use pre-selected networks (from services installation)
        # Pre-selected networks: ${preselected_networks[*]}
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
    # Allocating ports...
    init_port_management >/dev/null 2>&1
    
    local used_ports=$(get_all_used_ports)
    local prometheus_port=$(find_available_port 9090 1 "$used_ports")
    local grafana_port=$(find_available_port 3000 1 "$used_ports") 
    local node_exporter_port=$(find_available_port 9100 1 "$used_ports")
    
    # Step 6-9: Generate complete monitoring stack using centralized templates
    echo -e "${UI_MUTED}Generating monitoring configuration files...${NC}"
    generate_complete_monitoring_stack "$staging_dir" "$NODE_UID" "$NODE_GID" "$prometheus_port" "$grafana_port" "$node_exporter_port" "$grafana_password" "$bind_ip" "${selected_networks[@]}"
    
    # Add basic prometheus targets
    local prometheus_targets=$(generate_prometheus_targets_basic)
    echo "$prometheus_targets" >> "$staging_dir/prometheus.yml"
    
    # Note: Dashboard import will be done after Grafana starts via API
    # Dashboard import will be done automatically after startup...
    
    # Step 10: Set permissions
    # Setting permissions...
    # Ensure proper permissions on directories (already owned by current user)
    chmod 755 "$staging_dir/"
    chmod 755 "$staging_dir/grafana/provisioning/"
    chmod 755 "$staging_dir/grafana/provisioning/datasources/"
    
    # Step 11: Launch monitoring
    echo -e "${UI_MUTED}Starting monitoring services...${NC}"
    # ATOMIC OPERATION: Move from staging to final location
    # Finalizing monitoring installation...
    # Moving from staging to final location...
    
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
            echo -e "${CYAN}Grafana Setup${NC}"
            echo "============="
            
            if [[ "$bind_ip" == "127.0.0.1" ]]; then
                echo -e "${UI_MUTED}Access: ${NC}${GREEN}http://localhost:${grafana_port}/dashboards${NC}"
            elif [[ "$bind_ip" == "0.0.0.0" ]]; then
                # Get actual machine IP when binding to all interfaces
                local machine_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}' || echo "localhost")
                echo -e "${UI_MUTED}Access: ${NC}${GREEN}http://${machine_ip}:${grafana_port}/dashboards${NC}"
            else
                echo -e "${UI_MUTED}Access: ${NC}${GREEN}http://${bind_ip}:${grafana_port}/dashboards${NC}"
            fi
            echo -e "${UI_MUTED}Username: ${NC}${GREEN}admin${NC}"
            echo -e "${UI_MUTED}Password: ${NC}${GREEN}${grafana_password}${NC}"
            echo
            echo -e "${CYAN}Dashboard Setup${NC}"
            echo "==============="
            echo -e "${UI_MUTED}Run: nodeboi → Manage monitoring → Grafana Dashboards${NC}"
            echo
            echo -e "${UI_MUTED}Press Enter to return to main menu...${NC}"
            read -r
            
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
    
    echo -e "\n${UI_MUTED}Remove Monitoring${NC}"
    echo -e "${UI_MUTED}=================${NC}"
    
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

install_monitoring_services_with_networks() {
    # Prevent recursive calls
    if [[ "${INSTALLING_MONITORING}" == "true" ]]; then
        echo "Installation already in progress, skipping..."
        return
    fi
    export INSTALLING_MONITORING=true
    
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
        unset INSTALLING_MONITORING
        return
    fi

    echo
    echo -e "${CYAN}Installing Monitoring Services${NC}"
    echo "==============================="
    echo
    echo -e "${UI_MUTED}This will install:${NC}"
    echo
    echo -e "${UI_MUTED}  • Prometheus${NC}"
    echo -e "${UI_MUTED}  • Grafana${NC}"
    echo -e "${UI_MUTED}  • Node Exporter${NC}"
    echo
    echo -e "${UI_MUTED}Prometheus will be added to these networks to scrape metrics:${NC}"
    echo
    
    # Get list of available ethnode networks for preview
    # Use proper discovery that checks for actual ethnodes, not just Docker networks
    local discovered_networks=($(discover_nodeboi_networks | cut -d':' -f1))
    
    # Filter networks that will actually be connected (exclude web3signer for security)
    local available_networks=()
    for network in "${discovered_networks[@]}"; do
        if [[ "$network" =~ ^ethnode.*-net$ ]] || [[ "$network" == "monitoring-net" ]] || [[ "$network" == "validator-net" ]]; then
            available_networks+=("$network")
        fi
    done
    
    if [[ ${#available_networks[@]} -gt 0 ]]; then
        for network in "${available_networks[@]}"; do
            local node_name="${network%-net}"
            echo -e "${UI_MUTED}  • $node_name${NC}"
        done
        echo
    else
        echo -e "${YELLOW}⚠️  No active ethnodes found. Monitoring will be installed in isolated mode.${NC}"
        echo
    fi
    
    echo -e "${UI_MUTED}Press Enter to start installation...${NC}"
    read -r
    echo
    
    # Install monitoring with all networks pre-selected
    if install_monitoring_stack "${available_networks[@]}"; then
        # Ensure dashboard cache is refreshed to show new monitoring
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        
        # Set flag to return to main menu after ULCS operation
        RETURN_TO_MAIN_MENU=true
        unset INSTALLING_MONITORING
        return 0
    else
        echo -e "${RED}❌ Failed to install monitoring services${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        unset INSTALLING_MONITORING
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

#============================================================================
# DASHBOARD IMPORT FUNCTIONS
#============================================================================

# Import relevant dashboards via Grafana API during monitoring installation
import_monitoring_dashboards_api() {
    local bind_ip="$1"
    local grafana_port="$2"
    local grafana_password="$3"
    shift 3
    local selected_networks=("$@")
    
    local grafana_url="http://${bind_ip}:${grafana_port}"
    local auth="admin:${grafana_password}"
    
    # Wait for Grafana to be ready
    local max_attempts=10
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s -u "$auth" "$grafana_url/api/health" >/dev/null 2>&1; then
            break
        fi
        echo -e "${UI_MUTED}  Waiting for Grafana to be ready... (attempt $attempt/$max_attempts)${NC}"
        sleep 2
        ((attempt++))
    done
    
    if [[ $attempt -gt $max_attempts ]]; then
        echo -e "${YELLOW}⚠️  Grafana not ready, skipping dashboard import${NC}"
        return 1
    fi
    
    # Always import Node Exporter dashboard
    echo -e "${UI_MUTED}  • Importing Node Exporter dashboard...${NC}"
    import_dashboard_from_grafana_com "$grafana_url" "$auth" "1860"
    
    # Import client-specific dashboards based on detected services
    local imported_clients=()
    for network in "${selected_networks[@]}"; do
        local node_name="${network%-net}"
        local node_dir="$HOME/$node_name"
        
        if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
            local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            # Import execution client dashboards
            if [[ "$compose_file" == *"reth"* ]] && [[ ! " ${imported_clients[*]} " =~ " reth " ]]; then
                echo -e "${UI_MUTED}  • Importing Reth dashboard...${NC}"
                import_dashboard_from_grafana_com "$grafana_url" "$auth" "22941"
                imported_clients+=("reth")
            elif [[ "$compose_file" == *"besu"* ]] && [[ ! " ${imported_clients[*]} " =~ " besu " ]]; then
                echo -e "${UI_MUTED}  • Importing Besu dashboard...${NC}"
                import_dashboard_from_grafana_com "$grafana_url" "$auth" "10273"
                imported_clients+=("besu")
            elif [[ "$compose_file" == *"nethermind"* ]] && [[ ! " ${imported_clients[*]} " =~ " nethermind " ]]; then
                echo -e "${UI_MUTED}  • Importing Nethermind dashboard...${NC}"
                import_dashboard_from_grafana_com "$grafana_url" "$auth" "13100"
                imported_clients+=("nethermind")
            fi
        fi
    done
    
    if [[ ${#imported_clients[@]} -gt 0 ]]; then
        echo -e "${GREEN}✓ Dashboards imported: Node Exporter, ${imported_clients[*]}${NC}"
    else
        echo -e "${GREEN}✓ Node Exporter dashboard imported${NC}"
    fi
}

# Import a dashboard from grafana.com by ID
import_dashboard_from_grafana_com() {
    local grafana_url="$1"
    local auth="$2"
    local dashboard_id="$3"
    
    # Create import payload
    local import_payload=$(cat <<EOF
{
    "dashboard": {
        "id": null
    },
    "inputs": [
        {
            "name": "DS_PROMETHEUS",
            "type": "datasource",
            "pluginId": "prometheus",
            "value": "prometheus"
        }
    ],
    "overwrite": true,
    "pluginId": "${dashboard_id}"
}
EOF
)
    
    # Import dashboard
    if curl -s -u "$auth" \
        -H "Content-Type: application/json" \
        -d "$import_payload" \
        "$grafana_url/api/dashboards/import" >/dev/null 2>&1; then
        return 0
    else
        echo -e "${YELLOW}⚠️  Failed to import dashboard ${dashboard_id}${NC}"
        return 1
    fi
}