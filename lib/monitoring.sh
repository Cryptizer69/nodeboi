#!/bin/bash
# lib/monitoring.sh - Monitoring management for NODEBOI

# Load dependencies
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"

# Load monitoring modules
[[ -f "${NODEBOI_LIB}/monitoring-lifecycle.sh" ]] && source "${NODEBOI_LIB}/monitoring-lifecycle.sh"
[[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]] && source "${NODEBOI_LIB}/grafana-dashboard-management.sh"

# Load Universal Lifecycle System
[[ -f "${NODEBOI_LIB}/ulcs.sh" ]] && source "${NODEBOI_LIB}/ulcs.sh"

#============================================================================
# Legacy Function Compatibility Layer - Route to Lifecycle System
#============================================================================

# Missing function that legacy code calls - route to lifecycle system
remove_ethnode_from_monitoring() {
    local ethnode_name="$1"
    
    if [[ -z "$ethnode_name" ]]; then
        echo "Error: ethnode name required" >&2
        return 1
    fi
    
    # Route to lifecycle system
    if declare -f cleanup_ethnode_monitoring >/dev/null 2>&1; then
        cleanup_ethnode_monitoring "$ethnode_name"
    else
        echo "Warning: cleanup_ethnode_monitoring not available, sourcing lifecycle hooks" >&2
        [[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"
        if declare -f cleanup_ethnode_monitoring >/dev/null 2>&1; then
            cleanup_ethnode_monitoring "$ethnode_name"
        else
            echo "Error: Could not load lifecycle system for monitoring cleanup" >&2
            return 1
        fi
    fi
}

# Removed automatic dashboard syncing - users manage dashboards manually



# Generate basic Prometheus scrape config with only node-exporter
generate_prometheus_targets_basic() {
    # Get the monitoring name from .env
    local monitoring_name="${MONITORING_NAME:-monitoring}"
    echo "  - job_name: 'Node metrics'
    static_configs:
      - targets: ['${monitoring_name}-node-exporter:9100']

"
}

# Monitoring management menu
manage_monitoring_menu() {
    while true; do
        # Check monitoring status dynamically
        local monitoring_status=""
        if cd ~/monitoring 2>/dev/null; then
            local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
            local all_running=true
            for service in prometheus grafana node-exporter; do
                if ! echo "$running_services" | grep -q "$service"; then
                    all_running=false
                    break
                fi
            done
            
            if [[ "$all_running" == true ]]; then
                monitoring_status="Stop monitoring"
            else
                monitoring_status="Start monitoring"
            fi
        else
            monitoring_status="Start monitoring"
        fi
        
        local menu_options=(
            "$monitoring_status"
            "View logs"
            "Grafana Dashboards"
            "Update monitoring"
            "Remove monitoring"
            "Back to main menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Manage Monitoring" "${menu_options[@]}"); then
            case "${menu_options[$selection]}" in
                "Start monitoring")
                    echo -e "${UI_MUTED}Starting monitoring services...${NC}"
                    # Use Universal Lifecycle System
                    if declare -f start_service_universal >/dev/null 2>&1; then
                        start_service_universal "monitoring"
                    else
                        echo -e "${RED}✗ Universal Lifecycle System not available${NC}"
                    fi
                    echo -e "${UI_MUTED}Press Enter to return to menu...${NC}"
                    read -r
                    ;;
                "Stop monitoring")
                    echo -e "${UI_MUTED}Stopping monitoring services...${NC}"
                    # Use Universal Lifecycle System
                    if declare -f stop_service_universal >/dev/null 2>&1; then
                        stop_service_universal "monitoring"
                    else
                        echo -e "${RED}✗ Universal Lifecycle System not available${NC}"
                    fi
                    echo -e "${UI_MUTED}Press Enter to return to menu...${NC}"
                    read -r
                    ;;
                "Start/stop monitoring")
                    manage_monitoring_state
                    ;;
                "Grafana Dashboards")
                    show_grafana_dashboards_menu
                    ;;
                "View logs")
                    view_monitoring_logs
                    ;;
                "Update monitoring")
                    update_monitoring_services
                    ;;
                "Remove monitoring")
                    remove_monitoring_stack
                    # After removing monitoring, exit to main menu since monitoring no longer exists
                    return
                    ;;
                "Back to main menu")
                    return
                    ;;
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
            access_indicator=" ${UI_WARNING}[L]${UI_RESET}" 
            display_ip="$bind_ip"
            ;;
    esac
    
    # Get versions from .env
    local grafana_version=$(grep "^GRAFANA_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local prometheus_version=$(grep "^PROMETHEUS_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local node_exporter_version=$(grep "^NODE_EXPORTER_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Get ports
    local grafana_port=$(grep "^GRAFANA_PORT=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local prometheus_port=$(grep "^PROMETHEUS_PORT=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
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
        
        printf "     %b %-25s (%s)%b\t     http://%s:%s/dashboards\n" \
            "$grafana_status" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %b %-25s (%s)%b\t     http://%s:%s\n" \
            "$prometheus_status" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator" "$display_ip" "$prometheus_port"
        printf "     %b %-25s (%s)%b\n" \
            "$node_exporter_status" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    else
        echo -e "  ${RED}●${NC} monitoring - ${RED}Stopped${NC}"
        printf "     %-25s (%s)%b\t     http://%s:%s/dashboards\n" \
            "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %-25s (%s)%b\t     http://%s:%s\n" \
            "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator" "$display_ip" "$prometheus_port"
        printf "     %-25s (%s)%b\n" \
            "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
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

# Services installation menu
manage_services_menu() {
    while true; do
        clear
        print_header
        
        
        # Check if monitoring is installed
        local monitoring_installed=false
        if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" ]]; then
            monitoring_installed=true
        fi
        
        local menu_options=()
        if [[ "$monitoring_installed" == true ]]; then
            menu_options+=("Uninstall monitoring services")
        else
            menu_options+=("Install monitoring services")
        fi
        
        menu_options+=("Back to main menu")
        
        local selection
        if selection=$(fancy_select_menu "Available Services" "${menu_options[@]}"); then
            if [[ "$monitoring_installed" == true ]]; then
                case $selection in
                    0) remove_monitoring_stack; return ;;  # Exit to main menu after removal
                    1) return ;;
                esac
            else
                case $selection in
                    0) install_monitoring_services_with_networks ;;
                    1) return ;;
                esac
            fi
        else
            return
        fi
    done
}

# View monitoring service logs
view_monitoring_logs() {
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
    log_options+=("View all logs")
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
                docker compose logs -f --tail=20 "$service_name"
            fi
        elif [[ "${log_options[$selection]}" == "View all logs" ]]; then
            # All service logs combined
            clear
            echo -e "${CYAN}${BOLD}All Monitoring Logs${NC} (Press Ctrl+C to exit)"
            echo "========================"
            echo
            docker compose logs -f --tail=20
        fi
    fi
}

# View Grafana credentials
show_grafana_dashboards_menu() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${RED}✗ Monitoring not installed${NC}"
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Grafana Dashboards${NC}"
    echo "=================="
    echo
    
    # Show login information first
    echo -e "${BOLD}Step 1: Access Grafana${NC}"
    
    # Get server IP, port, and password from .env
    local server_ip
    local grafana_port="3000"
    local grafana_password="admin"
    
    if [[ -f "$HOME/monitoring/.env" ]]; then
        local bind_ip=$(grep "GRAFANA_BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null || echo "127.0.0.1")
        grafana_port=$(grep "GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null || echo "3000")
        grafana_password=$(grep "GRAFANA_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null || echo "admin")
        
        # Get actual machine IP instead of localhost
        if [[ "$bind_ip" == "127.0.0.1" || "$bind_ip" == "localhost" ]]; then
            # Get the machine's actual IP address
            server_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}' || echo "localhost")
        else
            server_ip="$bind_ip"
        fi
        
        echo "  Go to: http://${server_ip}:${grafana_port}/"
        echo "  Username: admin"
        echo "  Password: ${grafana_password}"
        echo
    else
        echo -e "${RED}Error: Monitoring not configured${NC}"
        echo -e "${UI_MUTED}Press Enter to return to menu...${NC}"
        read -r
        return
    fi
    
    echo -e "${BOLD}Step 2: Import Dashboards${NC}"
    echo "  • Click 'Dashboards' in the left sidebar"
    echo "  • Click 'New' in the top right corner"
    echo "  • Click 'Import'"
    echo "  • Add Grafana URL/ID or paste JSON"
    echo "  • Click 'Load'"
    echo "  • Click datasource dropdown, select 'Prometheus'"
    echo "  • Click 'Import'"
    echo
    
    echo -e "${BOLD}Step 3: Available Dashboards${NC}"
    echo
    echo -e "${YELLOW}System Dashboards:${NC}"
    echo "  • Node Exporter: Enter dashboard ID - 1860"
    echo
    
    echo -e "${YELLOW}Execution Client Dashboards:${NC}"
    echo "  • Nethermind: Enter dashboard ID - 16277"
    echo "  • Besu: Enter dashboard ID - 10273"
    echo "  • Reth: https://github.com/paradigmxyz/reth/blob/main/etc/grafana/dashboards/overview.json"
    echo
    
    echo -e "${YELLOW}Consensus Client Dashboards:${NC}"
    echo "  • Teku: Enter dashboard ID - 16737"
    echo "  • Lodestar: https://raw.githubusercontent.com/ChainSafe/lodestar/stable/dashboards/lodestar_summary.json"
    echo "  • Grandine: https://github.com/grandinetech/grandine/raw/develop/prometheus_metrics/dashboards/overview.json"
    echo
    
    echo -e "${YELLOW}Validator Dashboards:${NC}"
    echo "  • Teku Validator: Use the same dashboard as consensus client (validator information displayed on top)"
    echo "  • Vero Validator: https://github.com/serenita-org/vero/tree/master/grafana"
    echo
    
    echo -e "${UI_MUTED}Press Enter to return to menu...${NC}"
    read -r
}

# Legacy function kept for compatibility
view_grafana_credentials() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${RED}✗ Monitoring not installed${NC}"
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    # Clear the menu area while keeping the dashboard
    printf '\033[10A\033[J'  # Move up 10 lines and clear from cursor to end of screen
    
    echo -e "${CYAN}${BOLD}Grafana Login Information${NC}"
    echo "========================="
    echo
    
    # Extract info from .env file
    local grafana_port="3000"
    local grafana_password=""
    local bind_ip="127.0.0.1"
    
    if [[ -f "$HOME/monitoring/.env" ]]; then
        grafana_port=$(grep "^GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
        grafana_password=$(grep "^GRAFANA_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2)
        bind_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    fi
    
    echo -e "${BOLD}Access URL:${NC}"
    if [[ "$bind_ip" == "0.0.0.0" ]]; then
        local local_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
        echo "  http://${local_ip}:${grafana_port}"
        echo "  http://localhost:${grafana_port}"
    else
        echo "  http://${bind_ip}:${grafana_port}"
    fi
    
    echo
    echo -e "${BOLD}Login Credentials:${NC}"
    echo "  Username: admin"
    echo "  Password: ${grafana_password}"
    
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Show dashboard import instructions
