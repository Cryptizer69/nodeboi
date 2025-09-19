#!/bin/bash
# lib/monitoring.sh - Monitoring management for NODEBOI

# Load dependencies
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"

# Load monitoring modules
[[ -f "${NODEBOI_LIB}/monitoring-lifecycle.sh" ]] && source "${NODEBOI_LIB}/monitoring-lifecycle.sh"
[[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]] && source "${NODEBOI_LIB}/grafana-dashboard-management.sh"

# Load Universal Lifecycle System
[[ -f "${NODEBOI_LIB}/universal-service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/universal-service-lifecycle.sh"

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

# Missing function that legacy code calls - route to dashboard management
sync_grafana_dashboards() {
    # COMPATIBILITY LAYER: Redirect legacy calls to ULCS native monitoring
    echo "[LEGACY-COMPAT] Redirecting sync_grafana_dashboards to ULCS native system" >&2
    
    # Source ULCS monitoring if available
    if [[ -f "${NODEBOI_LIB}/ulcs-monitoring.sh" ]]; then
        source "${NODEBOI_LIB}/ulcs-monitoring.sh"
        
        # Use ULCS native functions
        if declare -f ulcs_generate_prometheus_config >/dev/null 2>&1; then
            ulcs_generate_prometheus_config && ulcs_sync_dashboards
            return $?
        fi
    fi
    
    # Fallback to legacy system if ULCS not available
    echo "[LEGACY-COMPAT] ULCS not available, falling back to legacy system" >&2
    if declare -f sync_dashboards_with_services >/dev/null 2>&1; then
        sync_dashboards_with_services
    else
        [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]] && source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
        if declare -f sync_dashboards_with_services >/dev/null 2>&1; then
            sync_dashboards_with_services
        else
            echo "[LEGACY-COMPAT] No dashboard sync system available" >&2
            return 1
        fi
    fi
}



# Generate Prometheus scrape configs for discovered services

generate_prometheus_targets_authoritative() {
    local selected_networks=("$@")
    local prometheus_configs=""
    local processed_nodes=()  # Track processed nodes to avoid duplicates
    
    # Get the monitoring name from .env
    local monitoring_name="${MONITORING_NAME:-monitoring}"
    prometheus_configs+="  - job_name: 'node-exporter'
    static_configs:
      - targets: ['${monitoring_name}-node-exporter:9100']

"
    
    # Process each selected network
    for network in "${selected_networks[@]}"; do
        if [[ "$network" == "validator-net" || "$network" == "monitoring-net" ]]; then
            # For validator-net/monitoring-net, discover all ethnode services
            for dir in "$HOME"/ethnode*; do
                if [[ -d "$dir" && -f "$dir/.env" ]]; then
                    local node_name=$(basename "$dir")
                    local node_dir="$dir"
                    
                    # Skip if already processed
                    if [[ ! " ${processed_nodes[*]} " =~ " ${node_name} " ]]; then
                        generate_targets_for_node "$node_name" "$node_dir" prometheus_configs
                        processed_nodes+=("$node_name")
                    fi
                fi
            done
        else
            # Individual network support (e.g., ethnode1-net, ethnode2-net)
            local node_name="${network%-net}"
            local node_dir="$HOME/$node_name"
            
            # Skip if already processed
            if [[ ! " ${processed_nodes[*]} " =~ " ${node_name} " ]] && [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
                generate_targets_for_node "$node_name" "$node_dir" prometheus_configs
                processed_nodes+=("$node_name")
            fi
        fi
    done
    
    # Add validator services (only once, regardless of networks)
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        prometheus_configs+="  - job_name: 'vero'
    static_configs:
      - targets: ['vero:9010']

"
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        prometheus_configs+="  - job_name: 'teku-validator'
    static_configs:
      - targets: ['teku-validator:8008']

"
    fi
    
    echo "$prometheus_configs"
}

# Helper function to generate targets for a specific node
generate_targets_for_node() {
    local node_name="$1"
    local node_dir="$2"
    local -n configs_ref="$3"
    
    if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
        # Parse client types from compose file directly
        local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
        
        # Detect execution client
        local exec_client=""
        if [[ "$compose_file" == *"reth"* ]]; then
            exec_client="reth"
        elif [[ "$compose_file" == *"besu"* ]]; then
            exec_client="besu"
        elif [[ "$compose_file" == *"nethermind"* ]]; then
            exec_client="nethermind"
        fi
        
        # Detect consensus client
        local cons_client=""
        if [[ "$compose_file" == *"teku"* ]]; then
            cons_client="teku"
        elif [[ "$compose_file" == *"grandine"* ]]; then
            cons_client="grandine"
        elif [[ "$compose_file" == *"lodestar"* ]]; then
            cons_client="lodestar"
        elif [[ "$compose_file" == *"lighthouse"* ]]; then
            cons_client="lighthouse"
        fi
        
        # Get metrics ports from .env
        if [[ "$exec_client" == "reth" ]]; then
            configs_ref+="  - job_name: '${node_name}-reth'
    static_configs:
      - targets: ['${node_name}-reth:9001']
        labels:
          node: '${node_name}'
          client: 'reth'
          instance: '${node_name}-reth:9001'

"
        elif [[ "$exec_client" == "besu" ]]; then
            # Add proper labels for Besu dashboard compatibility
            configs_ref+="  - job_name: '${node_name}-besu'
    static_configs:
      - targets: ['${node_name}-besu:6060']
        labels:
          node: '${node_name}'
          client: 'besu'
          instance: '${node_name}-besu:6060'
          system: '${node_name}-besu:6060'  # For dashboard compatibility

"
        elif [[ "$exec_client" == "nethermind" ]]; then
            configs_ref+="  - job_name: '${node_name}-nethermind'
    static_configs:
      - targets: ['${node_name}-nethermind:6060']
        labels:
          node: '${node_name}'
          client: 'nethermind'
          instance: '${node_name}-nethermind:6060'

"
        fi
        
        # Consensus clients all use port 8008
        if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
            configs_ref+="  - job_name: '${node_name}-${cons_client}'
    static_configs:
      - targets: ['${node_name}-${cons_client}:8008']
        labels:
          node: '${node_name}'
          client: '${cons_client}'
          instance: '${node_name}-${cons_client}:8008'

"
        fi
    fi
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
            "See Grafana login information"
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
                    press_enter
                    ;;
                "Stop monitoring")
                    echo -e "${UI_MUTED}Stopping monitoring services...${NC}"
                    # Use Universal Lifecycle System
                    if declare -f stop_service_universal >/dev/null 2>&1; then
                        stop_service_universal "monitoring"
                    else
                        echo -e "${RED}✗ Universal Lifecycle System not available${NC}"
                    fi
                    press_enter
                    ;;
                "Start/stop monitoring")
                    manage_monitoring_state
                    ;;
                "See Grafana login information")
                    view_grafana_credentials
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
        
        printf "     %b %-20s (%s)%b\t     http://%s:%s/dashboards\n" "$grafana_status" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" "$prometheus_status" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator" "$display_ip" "$prometheus_port"
        printf "     %b %-20s (%s)%b\n" "$node_exporter_status" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    else
        echo -e "  ${RED}●${NC} monitoring - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\t     http://%s:%s/dashboards\n" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %-20s (%s)%b\t     http://%s:%s\n" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator" "$display_ip" "$prometheus_port"
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
                    0) install_monitoring_services_with_dicks ;;
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