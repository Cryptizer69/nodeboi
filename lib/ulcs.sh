#!/bin/bash
# lib/ulcs.sh - Universal Lifecycle & Configuration System
# Complete service lifecycle management for all NODEBOI services
#
# This consolidated file provides comprehensive service management including:
# - Section 1: Core logging & utilities
# - Section 2: Service orchestration (universal lifecycle management)
# - Section 3: Resource operations (containers, volumes, networks, filesystems)
# - Section 4: Monitoring integration (prometheus, grafana, API-based)
#
# Originally consolidated from:
# - universal-service-lifecycle.sh (service orchestration)
# - service-operations.sh (resource operations)  
# - ulcs-monitoring.sh (monitoring integration)
#
# All functions use consistent log_ulcs_* logging for unified output.

# Source dependencies
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
# Service registry system deprecated - using direct service detection"
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"
[[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
# Note: grafana-dashboard-management.sh loaded on-demand to avoid circular deps

# =====================================================================
# SECTION 1: CORE LOGGING & UTILITIES
# =====================================================================

# ULCS logging - Consistent muted grey for clean output
ULCS_INFO='\033[38;5;240m'        # Muted grey for regular messages
ULCS_IMPORTANT='\033[38;5;240m'   # Muted grey for important messages
ULCS_SUCCESS='\033[38;5;240m'     # Muted grey for success
ULCS_WARNING='\033[38;5;240m'     # Muted grey for warnings
ULCS_ERROR='\033[38;5;240m'       # Muted grey for errors

# =====================================================================
# VALIDATOR BYPASS - Call working validator installers directly
# =====================================================================

# Bypass ULCS entirely for validators and call working installer directly
install_validator_direct() {
    local service_name="$1"
    
    log_ulcs "Bypassing ULCS lifecycle for validator: $service_name"
    log_ulcs "Calling working validator installer directly"
    
    # Source the working validator manager
    if [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]]; then
        source "${NODEBOI_LIB}/validator-manager.sh"
        
        case "$service_name" in
            "vero")
                log_ulcs "Calling install_vero() directly"
                install_vero
                local result=$?
                ;;
            "teku-validator")
                log_ulcs "Calling install_teku_validator() directly"
                install_teku_validator
                local result=$?
                ;;
            *)
                log_ulcs_error "Unknown validator type: $service_name"
                return 1
                ;;
        esac
        
        # Handle post-install registry integration if successful
        if [[ $result -eq 0 ]]; then
            log_ulcs_success "Validator installation completed successfully"
            # Register with service registry if function exists
            if declare -f register_service >/dev/null 2>&1; then
                register_service "$service_name" "validator" "$HOME/$service_name" "running"
            fi
        else
            log_ulcs_error "Validator installation failed"
        fi
        
        return $result
    else
        log_ulcs_error "Validator manager not found at ${NODEBOI_LIB}/validator-manager.sh"
        return 1
    fi
}
ULCS_RESET='\033[0m'

# Regular informational messages (grey, no prefix)
log_ulcs() {
    echo -e "${ULCS_INFO}$1${ULCS_RESET}" >&2
}

# Important status messages (blue, no prefix)
log_ulcs_important() {
    echo -e "${ULCS_IMPORTANT}$1${ULCS_RESET}" >&2
}

# Success messages (green with checkmark)
log_ulcs_success() {
    echo -e "${ULCS_SUCCESS}[OK] $1${ULCS_RESET}" >&2
}

# Error messages (red with X)
log_ulcs_error() {
    echo -e "${ULCS_ERROR}[ERROR] $1${ULCS_RESET}" >&2
}

# Warning messages (yellow with warning symbol)
log_ulcs_warning() {
    echo -e "${ULCS_WARNING}[WARNING] $1${ULCS_RESET}" >&2
}

# Service flow definitions - defines what resources each service type manages
declare -A SERVICE_FLOWS

# Initialize service flow definitions
init_service_flows() {
    # Ethnode services (ethnode1, ethnode2, etc.)
    SERVICE_FLOWS["ethnode"]=$(cat <<'EOF'
{
    "type": "ethnode",
    "resources": {
        "containers": ["${service_name}-*"],
        "volumes": ["${service_name}_*", "${service_name}-*"],
        "networks": ["${service_name}-net"],
        "directories": ["$HOME/${service_name}"],
        "files": [],
        "integrations": ["monitoring", "validators"]
    },
    "dependencies": [],
    "dependents": ["validators"],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "start_services", "integrate"],
        "remove": ["stop_services", "update_dependents", "remove_containers", "remove_volumes", "remove_networks", "remove_directories", "cleanup_integrations"],
        "start": ["ensure_networks", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "recreate_services", "health_check", "refresh_dashboard"]
    },
    "integration_hooks": {
        "validators": "update_beacon_endpoints"
    }
}
EOF
)

    # Validator services (vero, teku-validator)
    SERVICE_FLOWS["validator"]=$(cat <<'EOF'
{
    "type": "validator",
    "resources": {
        "containers": ["${service_name}*"],
        "volumes": ["${service_name}_*", "${service_name}-*"],
        "networks": ["validator-net", "web3signer-net", "ethnode1-net", "ethnode2-net"],
        "directories": ["$HOME/${service_name}"],
        "files": [],
        "integrations": ["monitoring", "ethnodes", "web3signer"]
    },
    "dependencies": ["ethnodes"],
    "dependents": [],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "connect_to_ethnodes", "start_services", "integrate"],
        "remove": ["stop_services", "cleanup_integrations", "remove_containers", "remove_volumes", "cleanup_shared_networks", "remove_directories"],
        "start": ["ensure_networks", "connect_to_ethnodes", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "recreate_services", "health_check", "refresh_dashboard"]
    },
    "integration_hooks": {
        "monitoring": "ulcs_restart_monitoring_only",
        "ethnodes": "discover_beacon_endpoints",
        "web3signer": "configure_remote_signing"
    }
}
EOF
)

    # Web3signer service
    SERVICE_FLOWS["web3signer"]=$(cat <<'EOF'
{
    "type": "web3signer",
    "resources": {
        "containers": ["web3signer*"],
        "volumes": ["web3signer_*", "web3signer-*"],
        "networks": ["web3signer-net"],
        "directories": ["$HOME/web3signer"],
        "files": [],
        "integrations": ["monitoring", "validators"]
    },
    "dependencies": [],
    "dependents": ["validators"],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "setup_database", "start_services"],
        "remove": ["stop_services", "update_dependents", "remove_containers", "remove_volumes", "remove_networks", "remove_directories", "cleanup_integrations"],
        "start": ["ensure_networks", "ensure_database", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "migrate_database", "recreate_services", "health_check", "refresh_dashboard"]
    },
    "integration_hooks": {
        "validators": "update_signing_config"
    }
}
EOF
)

    # Monitoring service
    SERVICE_FLOWS["monitoring"]=$(cat <<'EOF'
{
    "type": "monitoring",
    "resources": {
        "containers": ["monitoring-*"],
        "volumes": ["monitoring_*", "monitoring-*"],
        "networks": ["monitoring-net", "validator-net", "${ethnode_networks}"],
        "directories": ["$HOME/monitoring"],
        "files": ["$HOME/monitoring/prometheus.yml", "$HOME/monitoring/grafana/dashboards/*"],
        "integrations": []
    },
    "dependencies": [],
    "dependents": ["ethnodes", "validators", "web3signer"],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "start_services"],
        "remove": ["stop_services", "remove_containers", "remove_volumes", "remove_networks", "remove_directories"],
        "start": ["ensure_networks", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "recreate_services", "health_check", "refresh_dashboard"]
    },
    "integration_hooks": {
        "monitoring": "ulcs_restart_monitoring_only"
    }
}
EOF
)
}

# Get service type from service name
detect_service_type() {
    local service_name="$1"
    
    case "$service_name" in
        ethnode*) echo "ethnode" ;;
        monitoring) echo "monitoring" ;;
        *validator|vero) echo "validator" ;;
        web3signer) echo "web3signer" ;;
        *) echo "unknown" ;;
    esac
}

# Get service flow definition
get_service_flow() {
    local service_type="$1"
    
    if [[ -n "${SERVICE_FLOWS[$service_type]}" ]]; then
        echo "${SERVICE_FLOWS[$service_type]}"
        return 0
    else
        log_ulcs_error "Unknown service type: $service_type"
        return 1
    fi
}

# =====================================================================
# SECTION 2: SERVICE ORCHESTRATION
# =====================================================================

# Universal service removal orchestrator
remove_service_universal() {
    local service_name="$1"
    local with_integrations="${2:-true}"
    local interactive="${3:-true}"
    
    if [[ -z "$service_name" ]]; then
        log_ulcs_error "remove_service_universal: service name required"
        return 1
    fi
    
    # Validate service exists
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_ulcs_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    # Detect service type
    local service_type=$(detect_service_type "$service_name")
    if [[ "$service_type" == "unknown" ]]; then
        log_ulcs_error "Cannot determine service type for: $service_name"
        return 1
    fi
    
    log_ulcs_important "Starting universal removal of $service_type service: $service_name"
    
    # Get service flow definition
    local flow_def=$(get_service_flow "$service_type")
    if [[ $? -ne 0 ]]; then
        log_ulcs_error "Cannot get service flow for type: $service_type"
        return 1
    fi
    
    # Interactive confirmation if requested
    if [[ "$interactive" == "true" ]]; then
        show_service_removal_plan "$service_name" "$service_type" "$flow_def"
        echo
        show_service_specific_warning "$service_name" "$service_type"
        echo
        read -r -p "Continue with complete removal? [y/n]: " confirm
        echo
        
        if [[ ! "$confirm" =~ ^[yY]?$ ]]; then
            echo -e "${UI_MUTED}Removal cancelled by user${NC}"
            return 1
        fi
        
        with_integrations="true"
        echo -e "${UI_MUTED}Proceeding with complete removal including all integrations...${NC}"
    fi
    
    # Execute removal lifecycle
    execute_service_lifecycle "$service_name" "$service_type" "remove" "$flow_def" "$with_integrations"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_ulcs_success "Service $service_name removed successfully"
        echo -e "${GREEN}[OK] $service_name ($service_type) removed successfully with complete cleanup${NC}"
    else
        log_ulcs_error "Service $service_name removal failed"
        echo -e "${RED}[ERROR] $service_name removal failed - check logs for details${NC}"
    fi
    
    return $result
}

# Universal service installation orchestrator  
install_service_universal() {
    local service_name="$1"
    local service_type="$2"
    local config_params="$3"
    
    if [[ -z "$service_name" || -z "$service_type" ]]; then
        log_ulcs_error "install_service_universal: service name and type required"
        return 1
    fi
    
    # Check if service already exists
    if [[ -d "$HOME/$service_name" ]]; then
        log_ulcs_error "Service already exists: $service_name"
        return 1
    fi
    
    log_ulcs "Starting universal installation of $service_type service: $service_name"
    
    # Get service flow definition
    local flow_def=$(get_service_flow "$service_type")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Execute installation lifecycle
    execute_service_lifecycle "$service_name" "$service_type" "install" "$flow_def" "true" "$config_params"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_ulcs_success "Service $service_name installed successfully"
        echo -e "${GREEN}[OK] $service_name ($service_type) installed successfully${NC}"
    else
        log_ulcs_error "Service $service_name installation failed"
        echo -e "${RED}[ERROR] $service_name installation failed - check logs for details${NC}"
    fi
    
    return $result
}

# Universal service start orchestrator
start_service_universal() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_ulcs_error "start_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_ulcs_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_ulcs "Starting $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "start" "$flow_def"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_ulcs_success "Service $service_name started successfully"
        echo -e "${GREEN}[OK] $service_name started successfully${NC}"
    else
        log_ulcs_error "Service $service_name start failed"
        echo -e "${RED}[ERROR] $service_name start failed${NC}"
    fi
    
    return $result
}

# Universal service stop orchestrator
stop_service_universal() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_ulcs_error "stop_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_ulcs_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_ulcs "Stopping $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "stop" "$flow_def"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_ulcs_success "Service $service_name stopped successfully"
        echo -e "${GREEN}[OK] $service_name stopped successfully${NC}"
    else
        log_ulcs_error "Service $service_name stop failed"
        echo -e "${RED}[ERROR] $service_name stop failed${NC}"
    fi
    
    return $result
}

# Universal service update orchestrator
update_service_universal() {
    local service_name="$1"
    local update_params="$2"
    
    if [[ -z "$service_name" ]]; then
        log_ulcs_error "update_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_ulcs_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_ulcs "Updating $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "update" "$flow_def" "true" "$update_params"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_ulcs_success "Service $service_name updated successfully"
        echo -e "${GREEN}[OK] $service_name updated successfully${NC}"
    else
        log_ulcs_error "Service $service_name update failed"
        echo -e "${RED}[ERROR] $service_name update failed${NC}"
    fi
    
    return $result
}

# Execute service lifecycle based on flow definition
execute_service_lifecycle() {
    local service_name="$1"
    local service_type="$2"
    local action="$3"
    local flow_def="$4"
    local with_integrations="${5:-true}"
    local params="${6:-}"
    
    # Extract lifecycle steps for this action
    local steps=$(echo "$flow_def" | jq -r ".lifecycle.$action[]?" 2>/dev/null)
    
    if [[ -z "$steps" ]]; then
        log_ulcs_error "No lifecycle steps defined for $service_type.$action"
        return 1
    fi
    
    local total_steps=$(echo "$steps" | wc -l)
    local step_count=0
    local errors=0
    
    echo -e "${UI_MUTED}Executing $action lifecycle for $service_name ($total_steps steps)${NC}"
    
    # Execute each step in order
    while IFS= read -r step; do
        [[ -z "$step" ]] && continue
        ((step_count++))
        
        log_ulcs "Step $step_count/$total_steps: $step"
        echo -e "${UI_MUTED}Progress: [$step_count/$total_steps] $step${NC}"
        
        if execute_lifecycle_step "$service_name" "$service_type" "$step" "$flow_def" "$with_integrations" "$params"; then
            log_ulcs_success "Step completed: $step"
        else
            log_ulcs_error "Step failed: $step"
            ((errors++))
            
            # Some steps are allowed to fail
            case "$step" in
                "cleanup_integrations"|"update_dependents"|"cleanup_shared_networks")
                    log_ulcs_warning "Non-critical step failed, continuing..."
                    ;;
                *)
                    # Critical failure
                    log_ulcs_error "Critical step failed, aborting lifecycle"
                    return 1
                    ;;
            esac
        fi
    done <<< "$steps"
    
    if [[ $errors -eq 0 ]]; then
        log_ulcs_success "Lifecycle $action completed successfully for $service_name"
        return 0
    else
        log_ulcs_warning "Lifecycle $action completed with $errors non-critical errors for $service_name"
        return 0  # Non-critical errors don't fail the overall operation
    fi
}

# Execute individual lifecycle step
execute_lifecycle_step() {
    local service_name="$1"
    local service_type="$2" 
    local step="$3"
    local flow_def="$4"
    local with_integrations="$5"
    local params="$6"
    
    
    case "$step" in
        # Common steps for all services
        "stop_services")
            stop_service_containers "$service_name"
            ;;
        "remove_containers")
            remove_service_containers "$service_name"
            ;;
        "remove_volumes")
            remove_service_volumes "$service_name"
            ;;
        "remove_networks")
            remove_service_networks "$service_name" "$flow_def"
            ;;
        "remove_directories")
            remove_service_directories "$service_name"
            ;;
        "start_services")
            start_service_containers "$service_name"
            ;;
        "pull_images")
            pull_service_images "$service_name"
            ;;
        "recreate_services")
            recreate_service_containers "$service_name"
            ;;
        "health_check")
            health_check_service "$service_name"
            ;;
        "refresh_dashboard")
            update_service_dashboards "$service_name"
            ;;
        "ensure_networks")
            ensure_service_networks "$service_name" "$flow_def"
            ;;
        
        # Integration steps
        "cleanup_integrations")
            [[ "$with_integrations" == "true" ]] && ulcs_cleanup_service_integrations "$service_name" "$service_type" "$flow_def"
            ;;
        "integrate")
            if [[ "$with_integrations" == "true" ]]; then
                ulcs_integrate_service "$service_name" "$service_type" "$flow_def"
            fi
            ;;
        "update_dependents")
            update_dependent_services "$service_name" "$service_type" "$flow_def"
            ;;
        
        # Service-specific steps
        "cleanup_shared_networks")
            cleanup_shared_networks "$service_name" "$service_type"
            ;;
        "connect_to_ethnodes")
            connect_validator_to_ethnodes "$service_name"
            ;;
        "discover_beacon_endpoints")
            discover_and_configure_beacon_endpoints "$service_name"
            ;;
        
        # Installation steps
        "create_directories")
            create_service_directories "$service_name" "$params"
            ;;
        "copy_configs")
            copy_service_configs "$service_name" "$service_type" "$params"
            ;;
        "setup_networking")
            setup_service_networking "$service_name" "$flow_def"
            ;;
        
        # Database steps (for web3signer)
        "setup_database")
            setup_service_database "$service_name"
            ;;
        "ensure_database")
            ensure_service_database "$service_name"
            ;;
        "migrate_database")
            migrate_service_database "$service_name"
            ;;
        
        # Monitoring-specific steps removed - users manage manually
        
        *)
            log_ulcs_warning "Unknown lifecycle step: $step"
            return 1
            ;;
    esac
}

# Show service-specific warning messages
show_service_specific_warning() {
    local service_name="$1"
    local service_type="$2"
    
    case "$service_type" in
        "ethnode")
            echo -e "${RED}${BOLD}WARNING: This will permanently remove $service_name${NC}"
            echo -e "${UI_MUTED}• All blockchain data will be lost${NC}"
            echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            echo -e "${UI_MUTED}• Network isolation will be removed${NC}"
            echo -e "${UI_MUTED}• Monitoring integration will be cleaned up${NC}"
            echo -e "${UI_MUTED}• Validator beacon endpoints will be updated${NC}"
            ;;
        "validator")
            if [[ "$service_name" == "vero" ]]; then
                echo -e "${YELLOW}[WARNING] This will completely remove Vero and all its data${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            elif [[ "$service_name" == "teku-validator" ]]; then
                echo -e "${YELLOW}[WARNING] This will completely remove Teku validator and all its data${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            else
                echo -e "${YELLOW}[WARNING] This will completely remove the validator service${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            fi
            echo -e "${UI_MUTED}• Beacon node connections will be removed${NC}"
            echo -e "${UI_MUTED}• Web3signer remote signing configuration will be lost${NC}"
            echo -e "${UI_MUTED}• Attestation and validation history will be lost${NC}"
            echo -e "${YELLOW}• Keys remain in web3signer - validator will stop but keys are safe${NC}"
            ;;
        "web3signer")
            echo -e "${YELLOW}[WARNING] This will completely remove Web3signer and all its data${NC}"
            echo -e "${UI_MUTED}• All keystore configurations will be lost${NC}"
            echo -e "${UI_MUTED}• PostgreSQL database will be deleted${NC}"
            echo -e "${UI_MUTED}• All validator keys and signing data will be removed${NC}"
            echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            echo -e "${UI_MUTED}• This action cannot be undone${NC}"
            echo -e "${RED}• WARNING: Removed keys cannot be used for validation${NC}"
            echo -e "${RED}• Validators using this signer will stop working${NC}"
            ;;
        "monitoring")
            echo -e "${YELLOW}[WARNING] This will completely remove the monitoring stack${NC}"
            echo -e "${UI_MUTED}• All Grafana dashboards will be lost${NC}"
            echo -e "${UI_MUTED}• All Prometheus metrics history will be deleted${NC}"
            echo -e "${UI_MUTED}• All monitoring data and configurations will be removed${NC}"
            echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            echo -e "${UI_MUTED}• This action cannot be undone${NC}"
            echo -e "${YELLOW}• All services will lose monitoring and observability${NC}"
            ;;
        *)
            echo -e "${RED}${BOLD}This will permanently remove $service_name and all its data.${NC}"
            echo -e "${YELLOW}This includes containers, volumes, networks, directories, and service integrations.${NC}"
            ;;
    esac
}

# Show service removal plan
show_service_removal_plan() {
    local service_name="$1"
    local service_type="$2" 
    local flow_def="$3"
    
    echo -e "${CYAN}Removal plan for $service_name ($service_type):${NC}"
    echo -e "${UI_MUTED}================================${NC}"
    
    # Extract and show resources that will be removed
    local containers=$(echo "$flow_def" | jq -r '.resources.containers[]?' | sed "s/\${service_name}/$service_name/g")
    local volumes=$(echo "$flow_def" | jq -r '.resources.volumes[]?' | sed "s/\${service_name}/$service_name/g")  
    local networks=$(echo "$flow_def" | jq -r '.resources.networks[]?' | sed "s/\${service_name}/$service_name/g")
    local directories=$(echo "$flow_def" | jq -r '.resources.directories[]?' | sed "s/\${service_name}/$service_name/g" | sed "s|\$HOME|$HOME|g")
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    # Show actual containers found
    echo -e "${UI_MUTED}Containers to remove:${NC}"
    for pattern in $containers; do
        local found=$(docker ps -a --filter "name=${pattern}" --format "{{.Names}}" 2>/dev/null | head -5)
        [[ -n "$found" ]] && echo "$found" | sed 's/^/  - /' || echo "  - No containers matching $pattern"
    done
    
    # Show actual volumes found
    echo -e "${UI_MUTED}Volumes to remove:${NC}"
    for pattern in $volumes; do
        local found=$(docker volume ls -q --filter "name=${pattern}" 2>/dev/null | head -5)
        [[ -n "$found" ]] && echo "$found" | sed 's/^/  - /' || echo "  - No volumes matching $pattern"
    done
    
    # Show networks
    echo -e "${UI_MUTED}Networks to remove:${NC}"
    for network in $networks; do
        if docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            echo "  - $network"
        else
            echo "  - $network (not found)"
        fi
    done
    
    # Show directories
    echo -e "${UI_MUTED}Directories to remove:${NC}"
    for dir in $directories; do
        echo "  - $dir"
    done
    
    # Show integrations that will be updated
    if [[ -n "$integrations" ]]; then
        echo -e "${UI_MUTED}Integrations to update:${NC}"
        for integration in $integrations; do
            case "$integration" in
                "monitoring") [[ -d "$HOME/monitoring" ]] && echo "  - Monitoring (Prometheus targets, Grafana dashboards)" ;;
                "validators") echo "  - Validator beacon configurations" ;;
                "ethnodes") echo "  - Ethnode beacon endpoints" ;;
                "web3signer") [[ -d "$HOME/web3signer" ]] && echo "  - Web3signer configuration" ;;
            esac
        done
    fi
}

# =====================================================================
# SECTION 3: RESOURCE OPERATIONS
# =====================================================================

# =====================================================================
# CONTAINER OPERATIONS
# =====================================================================

# Stop all containers for a service
stop_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    local stop_errors=0
    
    # Try docker compose down first (if service has compose file)
    if [[ -d "$service_dir" && -f "$service_dir/compose.yml" ]]; then
        log_ulcs "Stopping services via docker compose"
        
        # Set required environment variables for ethnode services
        local env_vars=""
        if [[ "$service_name" =~ ^ethnode[0-9]+$ ]]; then
            env_vars="NODE_NAME=$service_name"
        fi
        
        # Client-specific shutdown logic
        local timeout=30
        local shutdown_method="standard"
        
        # Detect client types and apply specific shutdown procedures
        if [[ -f "$service_dir/.env" ]]; then
            local compose_file=$(grep "COMPOSE_FILE=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            if [[ "$compose_file" == *"nethermind"* ]]; then
                log_ulcs_important "Detected Nethermind - using graceful shutdown procedure (can take several minutes)"
                shutdown_method="nethermind"
            elif [[ "$compose_file" == *"besu"* ]]; then
                log_ulcs_important "Detected Besu - using graceful shutdown procedure (can take 1-2 minutes)"
                shutdown_method="besu"
            fi
        fi
        
        # Apply client-specific shutdown
        case "$shutdown_method" in
            "nethermind")
                stop_nethermind_gracefully "$service_name" "$service_dir" "$env_vars"
                ;;
            "besu") 
                stop_besu_gracefully "$service_name" "$service_dir" "$env_vars"
                ;;
            *)
                # Standard shutdown for other clients
                local compose_cmd="docker compose down -t $timeout"
                if [[ -n "$env_vars" ]]; then
                    compose_cmd="env $env_vars $compose_cmd"
                fi
                
                if cd "$service_dir" 2>/dev/null && eval "$compose_cmd" >/dev/null 2>&1; then
                    log_ulcs "Docker compose services stopped"
                else
                    log_ulcs_warning "Docker compose down failed, trying individual container stop"
                    ((stop_errors++))
                fi
                ;;
        esac
    fi
    
    # Stop any remaining containers matching the service name pattern
    local running_containers=$(docker ps --filter "name=${service_name}" --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$running_containers" ]]; then
        log_ulcs "Stopping remaining containers: $(echo $running_containers | tr '\n' ' ')"
        echo "$running_containers" | while read -r container; do
            if [[ -n "$container" ]]; then
                if docker stop "$container" >/dev/null 2>&1; then
                    log_ulcs "Stopped container: $container"
                else
                    log_ulcs_warning "Failed to stop container: $container"
                    ((stop_errors++))
                fi
            fi
        done
    fi
    
    return $stop_errors
}

# Remove all containers for a service
remove_service_containers() {
    local service_name="$1"
    
    # Remove all containers (running and stopped) matching patterns
    # Use exact matching to prevent cross-contamination between similar service names
    local container_patterns=("${service_name}" "${service_name}-*")
    local removed_count=0
    
    for pattern in "${container_patterns[@]}"; do
        local containers=$(docker ps -aq --filter "name=${pattern}" 2>/dev/null || true)
        
        if [[ -n "$containers" ]]; then
            log_ulcs "Removing containers matching pattern '$pattern': $(echo $containers | tr '\n' ' ')"
            if echo "$containers" | xargs -r docker rm -f >/dev/null 2>&1; then
                removed_count=$((removed_count + $(echo "$containers" | wc -w)))
                log_ulcs "Containers removed for pattern: $pattern"
            else
                log_ulcs_error "Failed to remove some containers for pattern: $pattern"
                return 1
            fi
        fi
    done
    
    if [[ $removed_count -eq 0 ]]; then
        log_ulcs "No containers found for $service_name"
    else
        log_ulcs_success "Removed $removed_count containers for $service_name"
    fi
    
    return 0
}

# Start containers for a service
start_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" ]]; then
        log_ulcs_error "Service directory not found: $service_dir"
        return 1
    fi
    
    if [[ ! -f "$service_dir/compose.yml" ]]; then
        log_ulcs_error "No compose.yml found in $service_dir"
        return 1
    fi
    
    log_ulcs "Starting services via docker compose"
    
    # Use standard Docker Compose startup (env vars from .env file)
    if cd "$service_dir" && docker compose up -d >/dev/null 2>&1; then
        log_ulcs_success "Services started successfully"
        return 0
    else
        log_ulcs_error "Failed to start services"
        return 1
    fi
}

# Pull latest images for a service
pull_service_images() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" || ! -f "$service_dir/compose.yml" ]]; then
        log_ulcs_error "Cannot pull images - compose.yml not found"
        return 1
    fi
    
    log_ulcs "Pulling latest images"
    if cd "$service_dir" && docker compose pull >/dev/null 2>&1; then
        log_ulcs_success "Images pulled successfully"
        return 0
    else
        log_ulcs_error "Failed to pull images"
        return 1
    fi
}

# Recreate containers for a service
recreate_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" || ! -f "$service_dir/compose.yml" ]]; then
        log_ulcs_error "Cannot recreate services - compose.yml not found"
        return 1
    fi
    
    log_ulcs "Recreating services"
    
    # Use standard Docker Compose startup (env vars from .env file)
    if cd "$service_dir" && docker compose up -d --force-recreate >/dev/null 2>&1; then
        log_ulcs_success "Services recreated successfully"
        return 0
    else
        log_ulcs_error "Failed to recreate services"
        return 1
    fi
}

# Health check for a service
health_check_service() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" ]]; then
        log_ulcs_error "Service directory not found for health check"
        return 1
    fi
    
    # Basic health check - ensure containers are running
    if cd "$service_dir" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
        log_ulcs_success "Health check passed - services are running"
        return 0
    else
        log_ulcs_warning "Health check failed - some services may not be running"
        return 1
    fi
}

# =====================================================================
# VOLUME OPERATIONS
# =====================================================================

# Remove all volumes for a service
remove_service_volumes() {
    local service_name="$1"
    
    # Define volume patterns based on service naming conventions
    local volume_patterns=("${service_name}_*" "${service_name}-*" "${service_name}*")
    local removed_count=0
    
    for pattern in "${volume_patterns[@]}"; do
        local volumes=$(docker volume ls -q --filter "name=${pattern}" 2>/dev/null || true)
        
        if [[ -n "$volumes" ]]; then
            log_ulcs "Removing volumes matching pattern '$pattern': $(echo $volumes | tr '\n' ' ')"
            if echo "$volumes" | xargs -r docker volume rm -f >/dev/null 2>&1; then
                removed_count=$((removed_count + $(echo "$volumes" | wc -w)))
                log_ulcs "Volumes removed for pattern: $pattern"
            else
                log_ulcs_warning "Some volumes may still exist (possibly in use)"
            fi
        fi
    done
    
    if [[ $removed_count -eq 0 ]]; then
        log_ulcs "No volumes found for $service_name"
    else
        log_ulcs_success "Removed $removed_count volumes for $service_name"
    fi
    
    return 0
}

# =====================================================================
# NETWORK OPERATIONS
# =====================================================================

# Remove networks for a service based on flow definition
remove_service_networks() {
    local service_name="$1"
    local flow_def="$2"
    
    # Extract network names from flow definition and substitute variables
    local networks=$(echo "$flow_def" | jq -r '.resources.networks[]?' 2>/dev/null | sed "s/\${service_name}/$service_name/g")
    
    if [[ -z "$networks" ]]; then
        log_ulcs "No networks defined for $service_name"
        return 0
    fi
    
    local removed_count=0
    
    for network in $networks; do
        if docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            # Check if network is still in use
            local containers_in_network=$(docker network inspect "$network" --format '{{range $id, $config := .Containers}}{{$config.Name}} {{end}}' 2>/dev/null || true)
            
            if [[ -n "$containers_in_network" ]]; then
                log_ulcs_warning "Network $network still has containers: $containers_in_network"
                log_ulcs "Attempting to disconnect containers..."
                
                # Try to disconnect containers
                echo "$containers_in_network" | tr ' ' '\n' | while read -r container; do
                    [[ -n "$container" ]] && docker network disconnect "$network" "$container" 2>/dev/null || true
                done
            fi
            
            # Remove the network
            if docker network rm "$network" >/dev/null 2>&1; then
                log_ulcs_success "Network $network removed"
                ((removed_count++))
            else
                log_ulcs_warning "Failed to remove network $network (may be in use)"
            fi
        else
            log_ulcs "Network $network does not exist"
        fi
    done
    
    return 0
}

# Ensure networks exist for a service
ensure_service_networks() {
    local service_name="$1"
    local flow_def="$2"
    
    # For monitoring service, use comprehensive network management
    if [[ "$service_name" == "monitoring" ]]; then
        if declare -f manage_service_networks >/dev/null 2>&1; then
            log_ulcs "Ensuring monitoring networks with comprehensive management"
            manage_service_networks "sync" "silent"
            return $?
        fi
    fi
    
    local networks=$(echo "$flow_def" | jq -r '.resources.networks[]?' 2>/dev/null | sed "s/\${service_name}/$service_name/g")
    
    for network in $networks; do
        # Skip placeholder variables that couldn't be expanded
        [[ "$network" == *'${ethnode_networks}'* ]] && continue
        
        if ! docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            log_ulcs "Creating network: $network"
            if docker network create "$network" >/dev/null 2>&1; then
                log_ulcs_success "Network $network created"
            else
                log_ulcs_error "Failed to create network: $network"
                return 1
            fi
        else
            log_ulcs "Network $network already exists"
        fi
    done
    
    return 0
}

# Cleanup shared networks (for validators)
cleanup_shared_networks() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ "$service_type" != "validator" ]]; then
        return 0  # Only applies to validators
    fi
    
    # Check if this was the last validator service
    local validator_services=()
    for service in "teku-validator" "vero"; do
        if [[ -d "$HOME/$service" && "$service" != "$service_name" ]]; then
            validator_services+=("$service")
        fi
    done
    
    # Check for running validator containers
    local running_validators=$(docker ps --format "{{.Names}}" | grep -E "^(vero|teku-validator|web3signer)" | grep -v "^${service_name}$" || true)
    
    # If no other validator services exist and no validator containers running, remove validator-net
    if [[ ${#validator_services[@]} -eq 0 && -z "$running_validators" ]]; then
        if docker network ls --format "{{.Name}}" | grep -q "^validator-net$"; then
            log_ulcs "Removing orphaned validator-net..."
            if docker network rm validator-net 2>/dev/null; then
                log_ulcs_success "Orphaned validator-net removed"
            else
                log_ulcs_warning "Failed to remove validator-net (may be in use)"
            fi
        fi
    else
        log_ulcs "Validator network retained (other services still exist: ${validator_services[*]})"
    fi
    
    return 0
}

# Setup networking for a service during installation
setup_service_networking() {
    local service_name="$1" 
    local flow_def="$2"
    
    # Ensure required networks exist
    ensure_service_networks "$service_name" "$flow_def"
}

# =====================================================================
# FILESYSTEM OPERATIONS
# =====================================================================

# Remove service directories
remove_service_directories() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" ]]; then
        log_ulcs "Directory $service_dir does not exist"
        return 0
    fi
    
    # Ensure we're not in the directory we're trying to remove
    if [[ "$PWD" == "$service_dir"* ]]; then
        cd "$HOME" 2>/dev/null || cd / 2>/dev/null
    fi
    
    # Remove the directory
    if rm -rf "$service_dir" 2>/dev/null; then
        log_ulcs_success "Directory $service_dir removed"
        return 0
    else
        log_ulcs_error "Failed to remove directory $service_dir"
        return 1
    fi
}

# Create service directories during installation
create_service_directories() {
    local service_name="$1"
    local params="$2"
    local service_dir="$HOME/$service_name"
    
    log_ulcs "Creating directory structure for $service_name"
    if mkdir -p "$service_dir" 2>/dev/null; then
        log_ulcs_success "Directory $service_dir created"
        return 0
    else
        log_ulcs_error "Failed to create directory $service_dir"
        return 1
    fi
}

# Copy service configuration files
copy_service_configs() {
    local service_name="$1"
    local service_type="$2"
    local params="$3"
    
    log_ulcs "Copying configuration files for $service_type service: $service_name"
    
    local service_dir="$HOME/$service_name"
    
    case "$service_type" in
        "validator")
            # Call the working validator installation functions
            log_ulcs "Installing validator configuration: $service_name"
            
            # Source validator manager functions
            if [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]]; then
                source "${NODEBOI_LIB}/validator-manager.sh"
            else
                log_ulcs_error "validator-manager.sh not found"
                return 1
            fi
            
            # Call appropriate installation function based on service name
            case "$service_name" in
                "vero")
                    log_ulcs "Calling install_vero_core for ULCS integration"
                    # We'll create this core function that does the config work without UI
                    install_vero_core "$service_dir" "$params"
                    ;;
                "teku-validator")
                    log_ulcs "Calling install_teku_validator_core for ULCS integration"
                    # We'll create this core function that does the config work without UI
                    install_teku_validator_core "$service_dir" "$params"
                    ;;
                *)
                    log_ulcs_error "Unknown validator type: $service_name"
                    return 1
                    ;;
            esac
            ;;
        "ethnode"|"monitoring"|"web3signer")
            # These services have their own config management
            log_ulcs "Config copying handled by service-specific installer for $service_type"
            return 0
            ;;
        *)
            log_ulcs_warning "No config copying implemented for service type: $service_type"
            return 0
            ;;
    esac
}

# Connect validator to ethnodes (stub - validators handle this themselves)
connect_validator_to_ethnodes() {
    local service_name="$1"
    log_ulcs "Validator connection to ethnodes handled by service installer"
    return 0
}

# =====================================================================
# INTEGRATION OPERATIONS
# =====================================================================

# Clean up service integrations
cleanup_service_integrations() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                # Monitoring integration removed - no automatic cleanup needed
                ;;
            "validators")
                cleanup_validator_integration "$service_name" "$service_type"
                ;;
            "ethnodes")
                cleanup_ethnode_integration "$service_name" "$service_type"
                ;;
            "web3signer")
                cleanup_web3signer_integration "$service_name" "$service_type"
                ;;
        esac
    done
    
    return 0
}

# Integrate a service with other services
integrate_service() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                integrate_with_monitoring "$service_name" "$service_type"
                ;;
            "validators")
                integrate_with_validators "$service_name" "$service_type"
                ;;
            "ethnodes")
                integrate_with_ethnodes "$service_name" "$service_type"
                ;;
            "web3signer")
                integrate_with_web3signer "$service_name" "$service_type"
                ;;
        esac
    done
    
    return 0
}

# Update dependent services when a service is removed
update_dependent_services() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    # Extract dependents from flow definition
    local dependents=$(echo "$flow_def" | jq -r '.dependents[]?' 2>/dev/null)
    
    for dependent in $dependents; do
        case "$dependent" in
            "validators")
                update_validators_after_removal "$service_name" "$service_type"
                ;;
            "ethnodes")
                update_ethnodes_after_removal "$service_name" "$service_type"
                ;;
            "monitoring")
                update_monitoring_after_removal "$service_name" "$service_type"
                ;;
        esac
    done
    
    return 0
}

# =====================================================================
# MONITORING INTEGRATION
# =====================================================================

# Removed automatic monitoring integration cleanup

# Integrate with monitoring
integrate_with_monitoring() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_ulcs "No monitoring service found - skipping integration"
        return 0
    fi
    
    log_ulcs "Updating network connections for monitoring access to $service_name"
    
    # Only update network connections - no automatic targets or dashboards
    if update_monitoring_network_connections; then
        log_ulcs_success "Network connections updated - users can manually configure targets"
    else
        log_ulcs_warning "Failed to update network connections"
        return 1
    fi
    
    return 0
}

# Integrate with validators (stub - not implemented yet)
integrate_with_validators() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Validator integration for $service_name not implemented yet"
    return 0
}

# Integrate with ethnodes
integrate_with_ethnodes() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Ethnode integration for $service_name not implemented yet"
    return 0
}

# Integrate with web3signer  
integrate_with_web3signer() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Web3signer integration for $service_name not implemented yet"
    return 0
}

# =====================================================================
# VALIDATOR-SPECIFIC OPERATIONS
# =====================================================================

# Connect validator to ethnodes
connect_validator_to_ethnodes() {
    local service_name="$1"
    
    log_ulcs "Connecting validator $service_name to available ethnodes"
    
    # Find available ethnodes
    local available_ethnodes=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local ethnode_name=$(basename "$dir")
            local ethnode_net="${ethnode_name}-net"
            if docker network ls --format "{{.Name}}" | grep -q "^${ethnode_net}$"; then
                available_ethnodes+=("$ethnode_name")
            fi
        fi
    done
    
    if [[ ${#available_ethnodes[@]} -eq 0 ]]; then
        log_ulcs_warning "No ethnodes found for validator connection"
        return 1
    fi
    
    log_ulcs_success "Found ${#available_ethnodes[@]} available ethnodes: ${available_ethnodes[*]}"
    return 0
}

# Discover and configure beacon endpoints
discover_and_configure_beacon_endpoints() {
    local service_name="$1"
    
    log_ulcs "Discovering and configuring beacon endpoints for $service_name"
    
    # Only handle validators
    if [[ "$service_name" != "vero" && "$service_name" != "teku-validator" ]]; then
        log_ulcs "Skipping beacon endpoint configuration for non-validator service: $service_name"
        return 0
    fi
    
    local service_dir="$HOME/$service_name"
    if [[ ! -d "$service_dir" ]]; then
        log_ulcs_warning "Service directory not found: $service_dir"
        return 1
    fi
    
    # Get current beacon node URLs from .env
    local current_urls=""
    if [[ -f "$service_dir/.env" ]]; then
        current_urls=$(grep "^BEACON_NODE_URLS=" "$service_dir/.env" 2>/dev/null | cut -d'=' -f2)
    fi
    
    log_ulcs "Current beacon URLs: $current_urls"
    
    # Find all available ethnodes and their networks
    local available_ethnodes=()
    local beacon_urls=()
    local required_networks=("validator-net" "web3signer-net")
    
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local ethnode_name=$(basename "$dir")
            local ethnode_net="${ethnode_name}-net"
            
            # Check if network exists
            if docker network ls --format "{{.Name}}" | grep -q "^${ethnode_net}$"; then
                available_ethnodes+=("$ethnode_name")
                required_networks+=("$ethnode_net")
                
                # Extract consensus client from COMPOSE_FILE
                local compose_file_line=$(grep "^COMPOSE_FILE=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)
                local consensus_client=""
                
                if [[ "$compose_file_line" =~ teku ]]; then
                    consensus_client="teku"
                elif [[ "$compose_file_line" =~ grandine ]]; then
                    consensus_client="grandine"
                elif [[ "$compose_file_line" =~ lighthouse ]]; then
                    consensus_client="lighthouse"
                elif [[ "$compose_file_line" =~ prysm ]]; then
                    consensus_client="prysm"
                fi
                
                if [[ -n "$consensus_client" ]]; then
                    beacon_urls+=("http://${ethnode_name}-${consensus_client}:5052")
                fi
            fi
        fi
    done
    
    if [[ ${#available_ethnodes[@]} -eq 0 ]]; then
        log_ulcs_warning "No ethnodes found for beacon endpoint configuration"
        return 1
    fi
    
    log_ulcs "Found ${#available_ethnodes[@]} ethnodes: ${available_ethnodes[*]}"
    
    # Update validator configuration if URLs or networks changed
    local new_beacon_urls=$(IFS=','; echo "${beacon_urls[*]}")
    
    if [[ "$current_urls" != "$new_beacon_urls" ]] || validator_networks_need_update "$service_name" "${required_networks[@]}"; then
        log_ulcs "Updating $service_name configuration for network changes"
        
        # Update beacon URLs in .env
        if [[ -f "$service_dir/.env" && -n "$new_beacon_urls" ]]; then
            log_ulcs "Updating beacon URLs: $new_beacon_urls"
            sed -i "s|^BEACON_NODE_URLS=.*|BEACON_NODE_URLS=$new_beacon_urls|" "$service_dir/.env"
            
            # Also update VERO_COMMAND if it exists (for new format)
            if grep -q "^VERO_COMMAND=" "$service_dir/.env" 2>/dev/null; then
                local updated_command=$(grep "^VERO_COMMAND=" "$service_dir/.env" | sed "s|--beacon-node-urls=[^[:space:]]*|--beacon-node-urls=$new_beacon_urls|")
                sed -i "s|^VERO_COMMAND=.*|$updated_command|" "$service_dir/.env"
            fi
        fi
        
        # Update compose.yml networks
        update_validator_networks "$service_name" "${required_networks[@]}"
        
        # Restart validator to apply changes
        if docker ps --format "{{.Names}}" | grep -q "^$service_name$"; then
            log_ulcs "Restarting $service_name with updated configuration"
            cd "$service_dir" && docker compose restart >/dev/null 2>&1
        fi
        
        log_ulcs_success "Updated $service_name beacon endpoints and networks"
    else
        log_ulcs "$service_name configuration is already up to date"
    fi
    
    return 0
}

# Check if validator networks need updating
validator_networks_need_update() {
    local service_name="$1"
    shift
    local required_networks=("$@")
    
    local service_dir="$HOME/$service_name"
    local compose_file="$service_dir/compose.yml"
    
    if [[ ! -f "$compose_file" ]]; then
        return 0  # Needs update if no compose file
    fi
    
    # Check if all required networks are in compose file
    for network in "${required_networks[@]}"; do
        if ! grep -q "- $network" "$compose_file" 2>/dev/null; then
            return 0  # Needs update
        fi
    done
    
    # Check if there are extra ethnode networks that shouldn't be there
    local current_ethnode_nets=$(grep -E "^\s*-\s+ethnode[0-9]+-net" "$compose_file" 2>/dev/null | sed 's/.*- //' || true)
    local required_ethnode_nets=$(printf '%s\n' "${required_networks[@]}" | grep "ethnode.*-net" || true)
    
    if [[ "$current_ethnode_nets" != "$required_ethnode_nets" ]]; then
        return 0  # Needs update
    fi
    
    return 1  # No update needed
}

# Update validator compose.yml networks
update_validator_networks() {
    local service_name="$1"
    shift
    local required_networks=("$@")
    
    local service_dir="$HOME/$service_name"
    local compose_file="$service_dir/compose.yml"
    
    if [[ ! -f "$compose_file" ]]; then
        log_ulcs_warning "Compose file not found: $compose_file"
        return 1
    fi
    
    log_ulcs "Updating $service_name networks: ${required_networks[*]}"
    
    # Create a temporary file for the updated compose
    local temp_file=$(mktemp)
    
    # Copy everything before the networks section
    awk '/^networks:/ {exit} {print}' "$compose_file" > "$temp_file"
    
    # Add the updated service networks
    echo "    networks:" >> "$temp_file"
    for network in "${required_networks[@]}"; do
        echo "      - $network" >> "$temp_file"
    done
    
    # Copy the rest of the service definition until the networks section
    awk '/^networks:/ {found=1; next} found && /^[a-zA-Z]/ && !/^  / {found=0} !found {print}' "$compose_file" >> "$temp_file"
    
    # Add the network definitions section
    echo "" >> "$temp_file"
    echo "networks:" >> "$temp_file"
    for network in "${required_networks[@]}"; do
        echo "  $network:" >> "$temp_file"
        echo "    external: true" >> "$temp_file"
        echo "    name: $network" >> "$temp_file"
    done
    
    # Replace the original file
    mv "$temp_file" "$compose_file"
    
    log_ulcs_success "Updated $service_name compose.yml networks"
    return 0
}

# Update beacon endpoints for validators when ethnodes change
update_beacon_endpoints() {
    local ethnode_name="$1"
    
    log_ulcs "Updating validator beacon endpoints after $ethnode_name changes"
    
    # Find all validators and update their beacon endpoints
    for validator_dir in "$HOME"/vero "$HOME"/teku-validator; do
        if [[ -d "$validator_dir" ]]; then
            local validator_name=$(basename "$validator_dir")
            log_ulcs "Updating beacon endpoints for $validator_name"
            discover_and_configure_beacon_endpoints "$validator_name"
        fi
    done
    
    return 0
}

# Clean up validator integration
cleanup_validator_integration() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Cleaning up validator integration for $service_name"
    
    # Remove service from validator configurations
    return 0
}

# Update validators after service removal
update_validators_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ "$service_type" == "ethnode" ]]; then
        log_ulcs "Updating validators after ethnode removal"
        
        # Update Vero if it exists
        if [[ -d "$HOME/vero" ]]; then
            remove_beacon_endpoint_from_vero "$service_name"
        fi
        
        # Update Teku validator if it exists
        if [[ -d "$HOME/teku-validator" ]]; then
            remove_beacon_endpoint_from_teku_validator "$service_name"
        fi
        
        # Clean up ethnode network references from monitoring stack
        if [[ -d "$HOME/monitoring" ]]; then
            cleanup_ethnode_network_references "$service_name"
        fi
    fi
    
    return 0
}

# Clean up ethnode network references from compose files
cleanup_ethnode_network_references() {
    local ethnode_name="$1"
    local network_name="${ethnode_name}-net"
    
    log_ulcs "Cleaning up $network_name references from dependent services"
    
    # List of services that might reference ethnode networks
    local dependent_services=("monitoring" "vero" "teku-validator" "web3signer")
    
    for service in "${dependent_services[@]}"; do
        local compose_file="$HOME/$service/compose.yml"
        if [[ -f "$compose_file" ]]; then
            # Remove network from networks list
            sed -i "/- ${network_name}/d" "$compose_file"
            # Remove network definition block
            sed -i "/${network_name}:/,+2d" "$compose_file"
            log_ulcs "Cleaned $network_name references from $service/compose.yml"
        fi
    done
}


# =====================================================================
# DATABASE OPERATIONS (for web3signer)
# =====================================================================

# Setup service database
setup_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_ulcs "Setting up database for web3signer"
        # Database setup logic would go here
    fi
    
    return 0
}

# Ensure service database is running
ensure_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_ulcs "Ensuring database is available for web3signer"
        # Database health check logic would go here
    fi
    
    return 0
}

# Migrate service database
migrate_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_ulcs "Running database migrations for web3signer"
        # Database migration logic would go here
    fi
    
    return 0
}

# =====================================================================
# MONITORING-SPECIFIC OPERATIONS
# =====================================================================

# Removed automatic dashboard setup - users import dashboards manually
setup_grafana_dashboards() {
    local service_name="$1"
    log_ulcs "Dashboard setup skipped - users manage dashboards manually"
    return 0
}

# Update service dashboards using lifecycle system
update_service_dashboards() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_ulcs_error "update_service_dashboards: service name required"
        return 1
    fi
    
    log_ulcs "Triggering dashboard refresh for service: $service_name"
    
    # Method 1: Try to source and use lifecycle system
    if [[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]]; then
        source "${NODEBOI_LIB}/service-lifecycle.sh" 2>/dev/null
        if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
            if trigger_dashboard_refresh "service_updated" "$service_name" 2>/dev/null; then
                log_ulcs_success "Dashboard refresh triggered via lifecycle system"
                return 0
            fi
        fi
    fi
    
    # Method 2: Direct force refresh from manage.sh
    local manage_script="${NODEBOI_LIB}/manage.sh"
    if [[ -f "$manage_script" ]]; then
        (
            export NODEBOI_LIB="${NODEBOI_LIB}"
            source "$manage_script" 2>/dev/null
            if declare -f force_refresh_dashboard >/dev/null 2>&1; then
                force_refresh_dashboard >/dev/null 2>&1
            fi
        ) && {
            log_ulcs_success "Dashboard refreshed via direct method"
            return 0
        }
    fi
    
    # Method 3: Background refresh via common.sh
    if [[ -f "${NODEBOI_LIB}/common.sh" ]]; then
        source "${NODEBOI_LIB}/common.sh" 2>/dev/null
        if declare -f refresh_dashboard >/dev/null 2>&1; then
            if refresh_dashboard >/dev/null 2>&1; then
                log_ulcs_success "Dashboard refreshed via common method"
                return 0
            fi
        fi
    fi
    
    log_ulcs_warning "Could not refresh dashboard - no refresh mechanism available"
    return 1
}

# DEPRECATED: Replaced by ulcs_full_monitoring_rebuild() - kept for compatibility
# Rebuild prometheus.yml configuration after service removal
rebuild_prometheus_config_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    # Source the grafana dashboard management functions
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
    else
        log_ulcs_error "Grafana dashboard management functions not available"
        return 1
    fi
    
    # Discover current running networks (excluding the removed service)
    local running_networks=()
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && "$(basename "$dir")" != "$service_name" ]]; then
            local ethnode_name=$(basename "$dir")
            local network_name="${ethnode_name}-net"
            
            # Check if the ethnode containers are actually running
            if cd "$dir" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
                running_networks+=("$network_name")
            fi
        fi
    done
    
    # Add other service networks (only if services are actually running)
    # Check monitoring
    if [[ "$service_name" != "monitoring" ]] && [[ -d "$HOME/monitoring" ]]; then
        if cd "$HOME/monitoring" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
            running_networks+=("monitoring-net")
        fi
    fi
    
    # Check validators
    if [[ "$service_name" != "vero" ]] && [[ -d "$HOME/vero" ]]; then
        if cd "$HOME/vero" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
            running_networks+=("validator-net")
        fi
    fi
    if [[ "$service_name" != "teku-validator" ]] && [[ -d "$HOME/teku-validator" ]]; then
        if cd "$HOME/teku-validator" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
            running_networks+=("validator-net")
        fi
    fi
    
    # Check web3signer
    if [[ "$service_name" != "web3signer" ]] && [[ -d "$HOME/web3signer" ]]; then
        if cd "$HOME/web3signer" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
            running_networks+=("web3signer-net")
        fi
    fi
    
    # Removed automatic prometheus config rebuilding - users manage targets manually
    return 0
}

# DEPRECATED: Replaced by ulcs_nuke_grafana_dashboards() - kept for compatibility 
# Remove Grafana dashboards for a specific service
remove_grafana_dashboards_for_service() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Removing Grafana dashboards for $service_name"
    
    # Source the new API functions
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
    else
        log_ulcs_warning "Grafana API functions not available"
        return 1
    fi
    
    # Use the new API-based removal
    if grafana_remove_service_dashboards "$service_name"; then
        log_ulcs "Successfully removed dashboards for $service_name"
        return 0
    else
        log_ulcs_warning "Failed to remove dashboards for $service_name"
        return 1
    fi
}

# Restart monitoring stack to apply configuration changes
restart_monitoring_stack() {
    local monitoring_dir="$HOME/monitoring"
    
    if [[ ! -d "$monitoring_dir" ]]; then
        log_ulcs_error "Monitoring directory not found"
        return 1
    fi
    
    if [[ ! -f "$monitoring_dir/compose.yml" ]]; then
        log_ulcs_error "Monitoring compose.yml not found"
        return 1
    fi
    
    # Check if monitoring is running
    local running_containers=$(docker ps --filter "name=monitoring" --format "{{.Names}}" 2>/dev/null)
    
    if [[ -z "$running_containers" ]]; then
        log_ulcs "Monitoring stack not running - no restart needed"
        return 0
    fi
    
    log_ulcs "Stopping monitoring stack..."
    if cd "$monitoring_dir" && docker compose down >/dev/null 2>&1; then
        log_ulcs "Monitoring stack stopped"
    else
        log_ulcs_warning "Failed to stop monitoring stack gracefully"
    fi
    
    # Brief pause to ensure clean shutdown
    sleep 3
    
    log_ulcs "Starting monitoring stack with new configuration..."
    if cd "$monitoring_dir" && docker compose up -d >/dev/null 2>&1; then
        log_ulcs "Monitoring stack restarted successfully"
        
        # Wait a moment for services to start
        sleep 5
        
        # Verify services are running
        local restarted_containers=$(docker ps --filter "name=monitoring" --format "{{.Names}}" 2>/dev/null)
        
        # Verify critical mounts are working
        if docker ps --format "{{.Names}}" | grep -q "monitoring-grafana"; then
            # Check if dashboard directory is properly mounted
            if ! docker exec monitoring-grafana ls /etc/grafana/dashboards/ >/dev/null 2>&1; then
                log_ulcs_warning "Grafana dashboard mount failed, attempting restart"
                docker compose restart grafana >/dev/null 2>&1
                sleep 3
            fi
        fi
        
        if docker ps --format "{{.Names}}" | grep -q "monitoring-prometheus"; then
            # Check if prometheus config is accessible
            if ! docker exec monitoring-prometheus ls /etc/prometheus/prometheus.yml >/dev/null 2>&1; then
                log_ulcs_warning "Prometheus config mount failed, attempting restart"
                docker compose restart prometheus >/dev/null 2>&1
                sleep 3
            fi
        fi
        if [[ -n "$restarted_containers" ]]; then
            log_ulcs "Verified monitoring services are running: $(echo $restarted_containers | tr '\n' ' ')"
            return 0
        else
            log_ulcs_error "Monitoring services failed to start after restart"
            return 1
        fi
    else
        log_ulcs_error "Failed to restart monitoring stack"
        return 1
    fi
}

# Update monitoring after service removal
update_monitoring_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Updating monitoring after removal of $service_name"
    # This is now handled by cleanup_monitoring_integration
    return 0
}

# =====================================================================
# HELPER FUNCTIONS FROM EXISTING CODE
# =====================================================================

# Remove beacon endpoint from Vero (from ethnode-cleanup.sh)
remove_beacon_endpoint_from_vero() {
    local ethnode_name="$1"
    local vero_env="$HOME/vero/.env"
    
    if [[ ! -f "$vero_env" ]]; then
        return 0
    fi
    
    local expected_url="http://${ethnode_name}-"
    local current_urls=$(grep "^BEACON_NODE_URLS=" "$vero_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    
    if [[ -z "$current_urls" || "$current_urls" != *"$expected_url"* ]]; then
        return 0
    fi
    
    local updated_urls=$(echo "$current_urls" | tr ',' '\n' | grep -v "$expected_url" | tr '\n' ',' | sed 's/,$//')
    
    # Create backup and update
    cp "$vero_env" "${vero_env}.backup.$(date +%s)" || return 1
    
    if awk -v new_urls="$updated_urls" '
        /^BEACON_NODE_URLS=/ { print "BEACON_NODE_URLS=" new_urls; next }
        { print }
    ' "$vero_env" > "${vero_env}.tmp"; then
        mv "${vero_env}.tmp" "$vero_env"
        
        # Clean up network references in compose.yml
        local vero_compose="$HOME/vero/compose.yml"
        if [[ -f "$vero_compose" ]]; then
            # Remove ethnode network references
            sed -i "/- ${ethnode_name}-net/d" "$vero_compose"
            sed -i "/${ethnode_name}-net:/,+2d" "$vero_compose"
        fi
        
        # Recreate Vero container to pick up new environment (not just restart)
        if docker ps --format "{{.Names}}" | grep -q "^vero$"; then
            (cd "$HOME/vero" && docker compose down >/dev/null 2>&1 && docker compose up -d >/dev/null 2>&1) || true
        fi
        
        return 0
    else
        mv "${vero_env}.backup.$(date +%s)" "$vero_env" 2>/dev/null || true
        rm -f "${vero_env}.tmp"
        return 1
    fi
}

# Remove beacon endpoint from Teku validator
remove_beacon_endpoint_from_teku_validator() {
    local ethnode_name="$1"
    
    # Implementation would be similar to Vero but for Teku validator
    log_ulcs "Would update Teku validator configuration to remove $ethnode_name"
    return 0
}

# DEPRECATED: Replaced by ulcs_full_monitoring_rebuild() - kept for compatibility
# Rebuild prometheus configuration after service addition
rebuild_prometheus_config_after_addition() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Rebuilding prometheus.yml after adding $service_name"
    
    # Use existing prometheus rebuild logic
    if declare -f regenerate_prometheus_config >/dev/null 2>&1; then
        regenerate_prometheus_config
        return $?
    else
        # Try to source the grafana dashboard management module
        if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
            source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
            if declare -f regenerate_prometheus_config >/dev/null 2>&1; then
                regenerate_prometheus_config
                return $?
            fi
        fi
        log_ulcs_warning "regenerate_prometheus_config function not available"
        return 1
    fi
}

# DEPRECATED: Replaced by ulcs_rebuild_all_grafana_dashboards() - kept for compatibility
# Add Grafana dashboards for a service
add_grafana_dashboards_for_service() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Adding Grafana dashboards for $service_type service: $service_name"
    
    # Check if monitoring is available
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_ulcs "No monitoring directory found"
        return 1
    fi
    
    # Copy appropriate dashboards based on service type
    local template_dir="$HOME/.nodeboi/grafana-dashboards"
    local target_dir="$HOME/monitoring/grafana/dashboards"
    
    case "$service_type" in
        "ethnode")
            # Determine which execution/consensus clients are used
            if [[ -f "$HOME/$service_name/.env" ]]; then
                local compose_file=$(grep "COMPOSE_FILE=" "$HOME/$service_name/.env" | cut -d'=' -f2)
                
                # Add execution client dashboards
                if echo "$compose_file" | grep -q "reth"; then
                    cp "$template_dir/execution/reth-overview.json" "$target_dir/" 2>/dev/null
                fi
                if echo "$compose_file" | grep -q "besu"; then
                    cp "$template_dir/execution/besu-overview.json" "$target_dir/" 2>/dev/null
                fi
                
                # Add consensus client dashboards  
                if echo "$compose_file" | grep -q "teku"; then
                    cp "$template_dir/consensus/teku-overview.json" "$target_dir/" 2>/dev/null
                fi
                if echo "$compose_file" | grep -q "grandine"; then
                    cp "$template_dir/consensus/grandine-overview.json" "$target_dir/" 2>/dev/null
                fi
            fi
            ;;
        "validator")
            # Add validator dashboards
            cp "$template_dir/validators/vero-detailed.json" "$target_dir/" 2>/dev/null
            ;;
        "web3signer")
            # Web3signer has no monitoring dashboards
            log_ulcs "Web3signer has no monitoring dashboards to add"
            return 0
            ;;
    esac
    
    return 0
}

# Update monitoring network connections (rebuild compose.yml with all networks)
update_monitoring_network_connections() {
    log_ulcs "Updating monitoring network connections"
    
    # Use network manager to rebuild monitoring compose.yml
    if declare -f manage_service_networks >/dev/null 2>&1; then
        manage_service_networks "sync" "silent"
        return $?
    else
        # Try to source the network manager module
        if [[ -f "${NODEBOI_LIB}/network-manager.sh" ]]; then
            source "${NODEBOI_LIB}/network-manager.sh"
            if declare -f manage_service_networks >/dev/null 2>&1; then
                manage_service_networks "sync" "silent"
                return $?
            fi
        fi
        log_ulcs_warning "Network manager not available"
        return 1
    fi
}

# =====================================================================
# CLIENT-SPECIFIC SHUTDOWN PROCEDURES
# =====================================================================

# JSON-RPC admin_shutdown for Nethermind
shutdown_nethermind_via_jsonrpc() {
    local service_name="$1"
    local rpc_port="${2:-8545}"
    
    log_ulcs "Attempting Nethermind shutdown via JSON-RPC admin_shutdown"
    
    # Try JSON-RPC admin_shutdown method
    local rpc_response
    if rpc_response=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"admin_shutdown","params":[],"id":1}' \
        --max-time 5 \
        "http://127.0.0.1:${rpc_port}" 2>/dev/null); then
        
        if [[ "$rpc_response" == *'"result"'* ]]; then
            log_ulcs "Nethermind acknowledged shutdown command via JSON-RPC"
            return 0
        else
            log_ulcs "JSON-RPC response: $rpc_response"
            return 1
        fi
    else
        log_ulcs "Failed to connect to Nethermind JSON-RPC on port $rpc_port"
        return 1
    fi
}

# Nethermind graceful shutdown with database flush
stop_nethermind_gracefully() {
    local service_name="$1"
    local service_dir="$2" 
    local env_vars="$3"
    
    log_ulcs_important "Initiating improved Nethermind graceful shutdown procedure (can take up to 3 minutes for database flush)"
    
    local container_name="${service_name}-nethermind"
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        
        # Method 1: JSON-RPC admin_shutdown (preferred)
        local rpc_port=$(grep "^.*8545.*->8545" <<< "$(docker port "$container_name")" | cut -d: -f2 2>/dev/null || echo "8545")
        if shutdown_nethermind_via_jsonrpc "$service_name" "$rpc_port"; then
            log_ulcs "Waiting for Nethermind to shutdown via JSON-RPC..."
            local wait_time=0
            local max_wait=120
            while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
                if [[ $((wait_time % 15)) -eq 0 ]]; then
                    log_ulcs "Waiting for Nethermind database flush via JSON-RPC... ($wait_time/${max_wait}s)"
                fi
                sleep 3
                ((wait_time += 3))
            done
        fi
        
        # Method 2: Extended docker stop (if still running)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_ulcs_important "JSON-RPC shutdown incomplete, trying extended docker stop (please wait, database flushing)..."
            docker stop --time=180 "$container_name" >/dev/null 2>&1 || true
        fi
        
        # Method 3: SIGTERM with extended wait (fallback)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_ulcs "Extended stop failed, using SIGTERM with extended timeout..."
            docker kill -s TERM "$container_name" 2>/dev/null || true
            
            local wait_time=0
            local max_wait=120
            while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
                if [[ $((wait_time % 15)) -eq 0 ]]; then
                    log_ulcs "Waiting for Nethermind database flush via SIGTERM... ($wait_time/${max_wait}s)"
                fi
                sleep 3
                ((wait_time += 3))
            done
        fi
        
        # Method 4: Force compose down (final fallback)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_ulcs_warning "All graceful methods failed, forcing shutdown"
            local compose_cmd="docker compose down -t 10"
            if [[ -n "$env_vars" ]]; then
                compose_cmd="env $env_vars $compose_cmd"
            fi
            cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
        else
            log_ulcs_success "Nethermind stopped gracefully"
            # Clean up remaining containers via compose
            local compose_cmd="docker compose down -t 5"
            if [[ -n "$env_vars" ]]; then
                compose_cmd="env $env_vars $compose_cmd"
            fi
            cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
        fi
    else
        # No Nethermind container running, use standard compose down
        local compose_cmd="docker compose down -t 30"
        if [[ -n "$env_vars" ]]; then
            compose_cmd="env $env_vars $compose_cmd"
        fi
        cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
    fi
}

# Besu graceful shutdown (also benefits from graceful database handling)
stop_besu_gracefully() {
    local service_name="$1"
    local service_dir="$2"
    local env_vars="$3"
    
    log_ulcs_important "Initiating Besu graceful shutdown procedure (please wait for clean database shutdown)"
    
    local container_name="${service_name}-besu"
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        log_ulcs "Sending SIGTERM to Besu for graceful shutdown..."
        docker kill -s TERM "$container_name" 2>/dev/null || true
        
        # Wait up to 45 seconds for Besu to shutdown gracefully
        local wait_time=0
        local max_wait=45
        while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
            if [[ $((wait_time % 15)) -eq 0 ]]; then
                log_ulcs "Waiting for Besu graceful shutdown... ($wait_time/${max_wait}s)"
            fi
            sleep 3
            ((wait_time += 3))
        done
        
        # Force shutdown if needed
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_ulcs_warning "Besu did not stop gracefully, forcing shutdown"
        else
            log_ulcs_success "Besu stopped gracefully"
        fi
    fi
    
    # Clean up all containers via compose
    local compose_cmd="docker compose down -t 10"
    if [[ -n "$env_vars" ]]; then
        compose_cmd="env $env_vars $compose_cmd"
    fi
    cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
}

# =====================================================================
# SECTION 4: MONITORING INTEGRATION
# =====================================================================

# =====================================================================
# ULCS NATIVE PROMETHEUS MANAGEMENT
# =====================================================================

# ULCS Native Prometheus Configuration Generator
# This is the ONLY function that should generate prometheus.yml
ulcs_generate_prometheus_config() {
    local monitoring_dir="${1:-/home/$(whoami)/monitoring}"
    local config_file="$monitoring_dir/prometheus.yml"
    local temp_file="$config_file.tmp"
    
    log_ulcs "Generating prometheus configuration (ULCS native)"
    
    # Create base prometheus configuration
    cat > "$temp_file" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['monitoring-node-exporter:9100']

EOF

    # Discover and add all running services
    local services_added=0
    
    # Add ethnode services
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            if ulcs_add_ethnode_targets "$temp_file" "$node_name" "$ethnode_dir"; then
                ((services_added++))
            fi
        fi
    done
    
    # Add validator services
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if ulcs_add_validator_targets "$temp_file" "vero"; then
            ((services_added++))
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if ulcs_add_validator_targets "$temp_file" "teku-validator"; then
            ((services_added++))
        fi
    fi
    
    # Validate generated configuration
    if ! ulcs_validate_prometheus_config "$temp_file"; then
        log_ulcs_error "Generated prometheus config is invalid"
        rm -f "$temp_file"
        return 1
    fi
    
    # Atomically replace the configuration
    if mv "$temp_file" "$config_file"; then
        log_ulcs_success "Prometheus config updated ($services_added services)"
        return 0
    else
        log_ulcs_error "Failed to update prometheus config"
        rm -f "$temp_file"
        return 1
    fi
}

# Add ethnode targets to prometheus config
ulcs_add_ethnode_targets() {
    local config_file="$1"
    local node_name="$2"
    local node_dir="$3"
    
    # Parse compose file to detect clients
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Detect execution client and add targets
    if [[ "$compose_file" == *"nethermind"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-nethermind'
    static_configs:
      - targets: ['${node_name}-nethermind:6060']
        labels:
          node: '${node_name}'
          client: 'nethermind'
          type: 'execution'

EOF
        log_ulcs "Added ${node_name}-nethermind:6060"
    elif [[ "$compose_file" == *"besu"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-besu'
    static_configs:
      - targets: ['${node_name}-besu:6060']
        labels:
          node: '${node_name}'
          client: 'besu'
          type: 'execution'

EOF
        log_ulcs "Added ${node_name}-besu:6060"
    elif [[ "$compose_file" == *"reth"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-reth'
    static_configs:
      - targets: ['${node_name}-reth:9001']
        labels:
          node: '${node_name}'
          client: 'reth'
          type: 'execution'

EOF
        log_ulcs "Added ${node_name}-reth:9001"
    fi
    
    # Detect consensus client and add targets
    if [[ "$compose_file" == *"lodestar"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-lodestar'
    static_configs:
      - targets: ['${node_name}-lodestar:8008']
        labels:
          node: '${node_name}'
          client: 'lodestar'
          type: 'consensus'

EOF
        log_ulcs "Added ${node_name}-lodestar:8008"
    elif [[ "$compose_file" == *"teku"* ]] && [[ "$compose_file" == *"cl-only"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-teku'
    static_configs:
      - targets: ['${node_name}-teku:8008']
        labels:
          node: '${node_name}'
          client: 'teku'
          type: 'consensus'

EOF
        log_ulcs "Added ${node_name}-teku:8008"
    elif [[ "$compose_file" == *"grandine"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-grandine'
    static_configs:
      - targets: ['${node_name}-grandine:8008']
        labels:
          node: '${node_name}'
          client: 'grandine'
          type: 'consensus'

EOF
        log_ulcs "Added ${node_name}-grandine:8008"
    fi
    
    return 0
}

# Add validator targets to prometheus config
ulcs_add_validator_targets() {
    local config_file="$1"
    local validator_name="$2"
    
    case "$validator_name" in
        "vero")
            cat >> "$config_file" <<EOF
  - job_name: 'vero'
    static_configs:
      - targets: ['vero:9010']
        labels:
          service: 'vero'
          type: 'validator'

EOF
            log_ulcs "Added vero:9010"
            ;;
        "teku-validator")
            cat >> "$config_file" <<EOF
  - job_name: 'teku-validator'
    static_configs:
      - targets: ['teku-validator:8008']
        labels:
          service: 'teku-validator'
          type: 'validator'

EOF
            log_ulcs "Added teku-validator:8008"
            ;;
    esac
    
    return 0
}

# Validate prometheus configuration
ulcs_validate_prometheus_config() {
    local config_file="$1"
    
    # Check if file exists and is not empty
    if [[ ! -f "$config_file" || ! -s "$config_file" ]]; then
        log_ulcs_error "Config file missing or empty"
        return 1
    fi
    
    # Check for basic required sections
    if ! grep -q "global:" "$config_file" || ! grep -q "scrape_configs:" "$config_file"; then
        log_ulcs_error "Config missing required sections"
        return 1
    fi
    
    # Validate YAML syntax if python3 is available
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
            log_ulcs_error "Config has invalid YAML syntax"
            return 1
        fi
    fi
    
    log_ulcs "Config validation passed"
    return 0
}

# =====================================================================
# ULCS NATIVE GRAFANA DASHBOARD MANAGEMENT  
# =====================================================================

# ULCS Native Dashboard Sync
# API-based dashboard sync (NEW)
ulcs_sync_dashboards_api() {
    log_ulcs "Syncing dashboards via API (ULCS native)"
    
    # Source the new API functions
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
    else
        log_ulcs "ERROR: Grafana API functions not available"
        return 1
    fi
    
    # Check Grafana connectivity
    if ! grafana_check_connection; then
        log_ulcs "WARNING: Grafana not accessible, falling back to file-based sync"
        return 1
    fi
    
    local success_count=0
    
    # Sync dashboards for each running ethnode
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            local clients=$(ulcs_detect_ethnode_clients "$ethnode_dir")
            
            if [[ -n "$clients" ]]; then
                if grafana_import_service_dashboards "$node_name" "ethnode" "$clients"; then
                    ((success_count++))
                    log_ulcs "API synced dashboards for $node_name"
                fi
            fi
        fi
    done
    
    # Sync validator dashboards
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if grafana_import_service_dashboards "vero" "validator" "vero"; then
            ((success_count++))
            log_ulcs "API synced dashboards for vero"
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if grafana_import_service_dashboards "teku-validator" "validator" "teku"; then
            ((success_count++))
            log_ulcs "API synced dashboards for teku-validator"
        fi
    fi
    
    # Always ensure node-exporter dashboard exists
    if grafana_import_service_dashboards "node-exporter" "node" "metrics"; then
        ((success_count++))
        log_ulcs "API synced node-exporter dashboard"
    fi
    
    log_ulcs "API synced $success_count services"
    return 0
}

# Helper function to detect ethnode clients
ulcs_detect_ethnode_clients() {
    local ethnode_dir="$1"
    local clients=""
    
    if [[ -f "$ethnode_dir/.env" ]]; then
        local compose_file=$(grep "COMPOSE_FILE=" "$ethnode_dir/.env" 2>/dev/null | cut -d'=' -f2)
        
        # Detect execution client
        if [[ "$compose_file" == *"reth"* ]]; then
            clients="reth"
        elif [[ "$compose_file" == *"besu"* ]]; then
            clients="besu"
        elif [[ "$compose_file" == *"nethermind"* ]]; then
            clients="nethermind"
        elif [[ "$compose_file" == *"geth"* ]]; then
            clients="geth"
        fi
        
        # Detect consensus client
        if [[ "$compose_file" == *"teku"* ]]; then
            clients="${clients:+$clients,}teku"
        elif [[ "$compose_file" == *"lodestar"* ]]; then
            clients="${clients:+$clients,}lodestar"
        elif [[ "$compose_file" == *"lighthouse"* ]]; then
            clients="${clients:+$clients,}lighthouse"
        elif [[ "$compose_file" == *"grandine"* ]]; then
            clients="${clients:+$clients,}grandine"
        fi
    fi
    
    echo "$clients"
}

# File-based dashboard sync (LEGACY)
ulcs_sync_dashboards() {
    local dashboards_dir="${1:-/home/$(whoami)/monitoring/grafana/dashboards}"
    
    # Try API-based sync first
    if ulcs_sync_dashboards_api; then
        return 0
    fi
    
    log_ulcs "Syncing Grafana dashboards (ULCS native) - fallback to file mode"
    
    if [[ ! -d "$dashboards_dir" ]]; then
        log_ulcs_error "Dashboard directory does not exist: $dashboards_dir"
        return 1
    fi
    
    # Remove all existing dashboards to start fresh
    rm -f "$dashboards_dir"/*.json 2>/dev/null
    
    local dashboards_added=0
    
    # Add dashboards for each running ethnode
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            if ulcs_copy_ethnode_dashboards "$dashboards_dir" "$node_name" "$ethnode_dir"; then
                ((dashboards_added++))
            fi
        fi
    done
    
    # Add validator dashboards
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if ulcs_copy_validator_dashboard "$dashboards_dir" "vero"; then
            ((dashboards_added++))
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if ulcs_copy_validator_dashboard "$dashboards_dir" "teku-validator"; then
            ((dashboards_added++))
        fi
    fi
    
    # Always add node-exporter dashboard
    if ulcs_copy_system_dashboards "$dashboards_dir"; then
        ((dashboards_added++))
    fi
    
    log_ulcs_success "Dashboards synced ($dashboards_added total)"
    return 0
}

# Copy dashboards for an ethnode based on its client configuration
ulcs_copy_ethnode_dashboards() {
    local dashboards_dir="$1"
    local node_name="$2"
    local node_dir="$3"
    
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local template_dir="$HOME/.nodeboi/grafana-dashboards"
    
    # Copy execution client dashboard with customized title
    if [[ "$compose_file" == *"nethermind"* ]]; then
        if [[ -f "$template_dir/execution/nethermind-overview.json" ]]; then
            ulcs_copy_dashboard_with_title "$template_dir/execution/nethermind-overview.json" \
                "$dashboards_dir/${node_name}-nethermind-overview.json" \
                "${node_name} - Nethermind"
            log_ulcs "Added ${node_name}-nethermind dashboard"
        fi
    elif [[ "$compose_file" == *"besu"* ]]; then
        if [[ -f "$template_dir/execution/besu-overview.json" ]]; then
            ulcs_copy_dashboard_with_title "$template_dir/execution/besu-overview.json" \
                "$dashboards_dir/${node_name}-besu-overview.json" \
                "${node_name} - Besu"
            log_ulcs "Added ${node_name}-besu dashboard"
        fi
    elif [[ "$compose_file" == *"reth"* ]]; then
        if [[ -f "$template_dir/execution/reth-overview.json" ]]; then
            ulcs_copy_dashboard_with_title "$template_dir/execution/reth-overview.json" \
                "$dashboards_dir/${node_name}-reth-overview.json" \
                "${node_name} - Reth"
            log_ulcs "Added ${node_name}-reth dashboard"
        fi
    fi
    
    # Copy consensus client dashboard
    if [[ "$compose_file" == *"lodestar"* ]]; then
        if [[ -f "$template_dir/consensus/lodestar-summary.json" ]]; then
            cp "$template_dir/consensus/lodestar-summary.json" "$dashboards_dir/${node_name}-lodestar-summary.json"
            log_ulcs "Added ${node_name}-lodestar dashboard"
        fi
    elif [[ "$compose_file" == *"teku"* ]] && [[ "$compose_file" == *"cl-only"* ]]; then
        if [[ -f "$template_dir/consensus/teku-overview.json" ]]; then
            cp "$template_dir/consensus/teku-overview.json" "$dashboards_dir/${node_name}-teku-overview.json"
            log_ulcs "Added ${node_name}-teku dashboard"
        fi
    elif [[ "$compose_file" == *"grandine"* ]]; then
        if [[ -f "$template_dir/consensus/grandine-overview.json" ]]; then
            cp "$template_dir/consensus/grandine-overview.json" "$dashboards_dir/${node_name}-grandine-overview.json"
            log_ulcs "Added ${node_name}-grandine dashboard"
        fi
    fi
    
    return 0
}

# Copy validator dashboards
ulcs_copy_validator_dashboard() {
    local dashboards_dir="$1"
    local validator_name="$2"
    local template_dir="$HOME/.nodeboi/grafana-dashboards"
    
    case "$validator_name" in
        "vero")
            if [[ -f "$template_dir/validators/vero-detailed.json" ]]; then
                cp "$template_dir/validators/vero-detailed.json" "$dashboards_dir/vero-detailed.json"
                log_ulcs "Added vero dashboard"
            fi
            ;;
        "teku-validator")
            if [[ -f "$template_dir/validators/teku-validator-overview.json" ]]; then
                cp "$template_dir/validators/teku-validator-overview.json" "$dashboards_dir/teku-validator-overview.json"
                log_ulcs "Added teku-validator dashboard"
            fi
            ;;
    esac
    
    return 0
}

# Copy system dashboards (node-exporter, etc.)
ulcs_copy_system_dashboards() {
    local dashboards_dir="$1"
    local template_dir="$HOME/.nodeboi/grafana-dashboards"
    
    if [[ -f "$template_dir/system/node-exporter-full.json" ]]; then
        cp "$template_dir/system/node-exporter-full.json" "$dashboards_dir/node-exporter-full.json"
        log_ulcs "Added node-exporter dashboard"
        return 0
    fi
    
    return 1
}

# Copy dashboard with title customization
ulcs_copy_dashboard_with_title() {
    local source_file="$1"
    local target_file="$2"
    local new_title="$3"
    
    if [[ -f "$source_file" ]]; then
        # Use jq to update the title if available, otherwise just copy
        if command -v jq >/dev/null 2>&1; then
            jq --arg title "$new_title" '.title = $title' "$source_file" > "$target_file"
        else
            cp "$source_file" "$target_file"
        fi
        return 0
    fi
    return 1
}

# =====================================================================
# ULCS NATIVE INTEGRATION HOOKS
# =====================================================================

# DEPRECATED: Network management now handled by network-manager.sh
# This function is kept for compatibility but does nothing
ulcs_update_monitoring_networks() {
    log_ulcs "Network management delegated to network-manager.sh"
    return 0
}

# ULCS Native Monitoring Integration (called by ULCS integrate step)
ulcs_integrate_monitoring() {
    local service_name="$1"
    local service_type="$2"
    local config_params="$3"
    
    log_ulcs "Integrating $service_name ($service_type) into monitoring system"
    
    # Removed automatic monitoring rebuild - only network connections updated
    
    # Trigger immediate dashboard refresh in UI
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh"
        if declare -f force_refresh_dashboard >/dev/null 2>&1; then
            force_refresh_dashboard >/dev/null 2>&1 || true
            log_ulcs "UI dashboard refreshed"
        fi
    fi
    
    log_ulcs_success "Monitoring integration complete for $service_name"
    return 0
}

# ULCS Native Monitoring Cleanup (called by ULCS cleanup_integrations step)
ulcs_cleanup_monitoring() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Cleaning up monitoring for $service_name ($service_type)"
    
    # Check if monitoring service exists
    if [[ ! -d "/home/$(whoami)/monitoring" ]]; then
        log_ulcs "No monitoring service found - skipping cleanup"
        return 0
    fi
    
    # Removed automatic monitoring rebuild
    
    log_ulcs_success "$service_name monitoring cleanup complete"
    return 0
}

# Restart prometheus service
ulcs_restart_prometheus() {
    local monitoring_dir="/home/$(whoami)/monitoring"
    
    if [[ ! -d "$monitoring_dir" ]]; then
        log_ulcs_warning "Monitoring directory not found: $monitoring_dir"
        return 1
    fi
    
    # First try reload (faster)
    log_ulcs "Attempting Prometheus configuration reload"
    if curl -s -X POST http://localhost:9090/-/reload >/dev/null 2>&1; then
        # Wait and verify reload worked by checking if config timestamp changed
        sleep 3
        local config_check=$(curl -s http://localhost:9090/api/v1/status/config 2>/dev/null | jq -r '.status' 2>/dev/null)
        if [[ "$config_check" == "success" ]]; then
            log_ulcs "Configuration reload successful"
            return 0
        fi
    fi
    
    # Reload failed, fall back to container restart
    log_ulcs_warning "Reload failed, restarting prometheus container"
    if cd "$monitoring_dir" && docker compose restart prometheus >/dev/null 2>&1; then
        # Wait for container to be ready
        local max_wait=30
        local wait_count=0
        while [[ $wait_count -lt $max_wait ]]; do
            if curl -s http://localhost:9090/-/ready >/dev/null 2>&1; then
                log_ulcs "Prometheus restart successful"
                return 0
            fi
            sleep 1
            ((wait_count++))
        done
        log_ulcs_warning "Prometheus restart completed but service not ready"
        return 1
    fi
    
    log_ulcs_warning "Failed to restart prometheus"
    return 1
}

# ULCS Native Service Integration (replaces integrate_service)
ulcs_integrate_service() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    log_ulcs "Integrating $service_name ($service_type) with all services"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                ulcs_integrate_monitoring "$service_name" "$service_type"
                ;;
            "validators")
                # Call existing validator integration functions (not monitoring-related)
                if declare -f integrate_with_validators >/dev/null 2>&1; then
                    integrate_with_validators "$service_name" "$service_type"
                fi
                ;;
            "ethnodes")
                # Call existing ethnode integration functions (not monitoring-related)  
                if declare -f integrate_with_ethnodes >/dev/null 2>&1; then
                    integrate_with_ethnodes "$service_name" "$service_type"
                fi
                ;;
            "web3signer")
                # Call existing web3signer integration functions (not monitoring-related)
                if declare -f integrate_with_web3signer >/dev/null 2>&1; then
                    integrate_with_web3signer "$service_name" "$service_type"
                fi
                ;;
        esac
    done
    
    log_ulcs_success "$service_name integration complete"
    return 0
}

# ULCS Native Service Integration Cleanup (replaces cleanup_service_integrations)
ulcs_cleanup_service_integrations() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    log_ulcs "Cleaning up integrations for $service_name ($service_type)"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                ulcs_cleanup_monitoring "$service_name" "$service_type"
                ;;
            "validators")
                # Call existing validator cleanup functions (not monitoring-related)
                if declare -f cleanup_validator_integration >/dev/null 2>&1; then
                    cleanup_validator_integration "$service_name" "$service_type"
                fi
                ;;
            "ethnodes")
                # Call existing ethnode cleanup functions (not monitoring-related)
                if declare -f cleanup_ethnode_integration >/dev/null 2>&1; then
                    cleanup_ethnode_integration "$service_name" "$service_type"
                fi
                ;;
            "web3signer")
                # Call existing web3signer cleanup functions (not monitoring-related)
                if declare -f cleanup_web3signer_integration >/dev/null 2>&1; then
                    cleanup_web3signer_integration "$service_name" "$service_type"
                fi
                ;;
        esac
    done
    
    log_ulcs_success "$service_name integration cleanup complete"
    return 0
}

# =====================================================================
# MONITORING VALIDATION AND DEBUGGING
# =====================================================================

# Validate that monitoring integration is working
ulcs_validate_monitoring_integration() {
    local service_name="$1"
    
    log_ulcs "Validating monitoring integration for $service_name"
    
    local monitoring_dir="/home/$(whoami)/monitoring"
    local config_file="$monitoring_dir/prometheus.yml"
    
    # Check prometheus config exists and contains service
    if [[ ! -f "$config_file" ]]; then
        log_ulcs_error "Prometheus config file missing"
        return 1
    fi
    
    if ! grep -q "$service_name" "$config_file"; then
        log_ulcs_error "$service_name not found in prometheus config"
        return 1
    fi
    
    # Check dashboards exist
    local dashboards_dir="$monitoring_dir/grafana/dashboards"
    local dashboard_count=$(find "$dashboards_dir" -name "${service_name}*.json" 2>/dev/null | wc -l)
    
    if [[ $dashboard_count -eq 0 ]]; then
        log_ulcs_error "No dashboards found for $service_name"
        return 1
    fi
    
    log_ulcs_success "Monitoring integration validated for $service_name"
    return 0
}

# Debug monitoring state
ulcs_debug_monitoring() {
    
    local monitoring_dir="/home/$(whoami)/monitoring"
    local config_file="$monitoring_dir/prometheus.yml"
    
    echo "Prometheus config:" >&2
    if [[ -f "$config_file" ]]; then
        echo "  File exists: $config_file" >&2
        echo "  Job count: $(grep -c 'job_name:' "$config_file" 2>/dev/null || echo 0)" >&2
        echo "  Jobs: $(grep 'job_name:' "$config_file" 2>/dev/null | sed "s/.*job_name: '\([^']*\)'.*/\1/" | tr '\n' ' ')" >&2
    else
        echo "  File missing: $config_file" >&2
    fi
    
    echo "Dashboards:" >&2
    local dashboards_dir="$monitoring_dir/grafana/dashboards"
    if [[ -d "$dashboards_dir" ]]; then
        echo "  Directory exists: $dashboards_dir" >&2
        echo "  Dashboard count: $(find "$dashboards_dir" -name "*.json" 2>/dev/null | wc -l)" >&2
        echo "  Dashboards: $(find "$dashboards_dir" -name "*.json" -exec basename {} \; 2>/dev/null | tr '\n' ' ')" >&2
    else
        echo "  Directory missing: $dashboards_dir" >&2
    fi
    
}

# Initialize service flows when this file is sourced
init_service_flows

# =====================================================================
# FUNCTION EXPORTS
# =====================================================================

# Core ULCS functions
export -f log_ulcs
export -f log_ulcs_success
export -f log_ulcs_error
export -f log_ulcs_warning
export -f init_service_flows
export -f detect_service_type
export -f get_service_flow

# Service orchestration functions
export -f remove_service_universal
export -f install_service_universal
export -f start_service_universal
export -f stop_service_universal
export -f update_service_universal
export -f execute_service_lifecycle
export -f execute_lifecycle_step
export -f show_service_specific_warning
export -f show_service_removal_plan

# Container operations
export -f stop_service_containers
export -f remove_service_containers
export -f start_service_containers
export -f pull_service_images
export -f recreate_service_containers
export -f health_check_service

# Volume operations
export -f remove_service_volumes

# Network operations
export -f remove_service_networks
export -f ensure_service_networks
export -f cleanup_shared_networks
export -f setup_service_networking

# Filesystem operations
export -f remove_service_directories
export -f create_service_directories
export -f copy_service_configs

# Integration operations
export -f cleanup_service_integrations
export -f integrate_service
export -f update_dependent_services

# Monitoring integration
# Removed cleanup_monitoring_integration function
export -f integrate_with_monitoring
export -f integrate_with_validators
export -f integrate_with_ethnodes
export -f integrate_with_web3signer

# Validator-specific operations
export -f connect_validator_to_ethnodes
export -f discover_and_configure_beacon_endpoints
export -f validator_networks_need_update
export -f update_validator_networks
export -f update_beacon_endpoints
export -f cleanup_validator_integration
export -f update_validators_after_removal

# Service registry operations

# Database operations (for web3signer)
export -f setup_service_database
export -f ensure_service_database
export -f migrate_service_database

# Monitoring-specific operations
export -f setup_grafana_dashboards
export -f update_service_dashboards
export -f rebuild_prometheus_config_after_removal
export -f remove_grafana_dashboards_for_service
export -f restart_monitoring_stack
export -f update_monitoring_after_removal

# Helper functions
export -f remove_beacon_endpoint_from_vero
export -f remove_beacon_endpoint_from_teku_validator
export -f cleanup_ethnode_network_references
export -f rebuild_prometheus_config_after_addition
export -f add_grafana_dashboards_for_service
export -f update_monitoring_network_connections

# Client-specific shutdown procedures
export -f shutdown_nethermind_via_jsonrpc
export -f stop_nethermind_gracefully
export -f stop_besu_gracefully

# ULCS Native monitoring functions
export -f ulcs_generate_prometheus_config
export -f ulcs_add_ethnode_targets
export -f ulcs_add_validator_targets
export -f ulcs_validate_prometheus_config
export -f ulcs_sync_dashboards_api
export -f ulcs_detect_ethnode_clients
export -f ulcs_sync_dashboards
export -f ulcs_copy_ethnode_dashboards
export -f ulcs_copy_validator_dashboard
export -f ulcs_copy_system_dashboards
export -f ulcs_copy_dashboard_with_title
export -f ulcs_update_monitoring_networks
export -f ulcs_integrate_monitoring
export -f ulcs_cleanup_monitoring
export -f ulcs_restart_prometheus
export -f ulcs_integrate_service
export -f ulcs_cleanup_service_integrations
export -f ulcs_validate_monitoring_integration
export -f ulcs_debug_monitoring
export -f log_ulcs_important

# =====================================================================
# SECTION 5: COMPLETE MONITORING REBUILD (ROBUST APPROACH)
# =====================================================================

# Completely nuke all Grafana dashboards via API
ulcs_nuke_grafana_dashboards() {
    log_ulcs "Nuking all Grafana dashboards via API"
    
    # Load grafana management functions if not already loaded
    if ! declare -f grafana_check_connection >/dev/null 2>&1; then
        if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
            source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
        else
            log_ulcs_error "Grafana dashboard management not available"
            return 1
        fi
    fi
    
    # Check if Grafana is running
    if ! grafana_check_connection >/dev/null 2>&1; then
        log_ulcs_warning "Grafana not accessible, skipping dashboard cleanup"
        return 0
    fi
    
    # Get all dashboard UIDs and delete them
    local dashboard_uids
    if dashboard_uids=$(grafana_cleanup_all_dashboards 2>/dev/null); then
        log_ulcs_success "All Grafana dashboards nuked via API"
        return 0
    else
        log_ulcs_warning "API cleanup failed, trying filesystem cleanup"
        
        # Fallback: Clean filesystem dashboards
        local dashboards_dir="$HOME/monitoring/grafana/dashboards"
        if [[ -d "$dashboards_dir" ]]; then
            rm -f "$dashboards_dir"/*.json 2>/dev/null || true
            log_ulcs_success "Grafana dashboards nuked via filesystem"
        fi
        return 0
    fi
}

# Rebuild all Grafana dashboards from current services
ulcs_rebuild_all_grafana_dashboards() {
    log_ulcs "Rebuilding all Grafana dashboards from current services"
    
    # Load grafana management functions if not already loaded
    if ! declare -f grafana_check_connection >/dev/null 2>&1; then
        if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
            source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
        else
            log_ulcs_error "Grafana dashboard management not available"
            return 1
        fi
    fi
    
    # Check if Grafana is running
    if ! grafana_check_connection >/dev/null 2>&1; then
        log_ulcs_warning "Grafana not accessible, skipping dashboard rebuild"
        return 0
    fi
    
    local dashboards_added=0
    
    # Scan for all running services and add their dashboards
    # 1. Add ethnode dashboards
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            
            # Detect clients from docker containers
            local clients=""
            if docker ps --format "{{.Names}}" | grep -q "${node_name}-.*-execution"; then
                local exec_client=$(docker ps --format "{{.Names}}" | grep "${node_name}-.*-execution" | head -1 | sed "s/${node_name}-\(.*\)-execution/\1/")
                clients="$exec_client"
            fi
            if docker ps --format "{{.Names}}" | grep -q "${node_name}-.*-consensus"; then
                local cons_client=$(docker ps --format "{{.Names}}" | grep "${node_name}-.*-consensus" | head -1 | sed "s/${node_name}-\(.*\)-consensus/\1/")
                clients="${clients:+$clients,}$cons_client"
            fi
            
            if [[ -n "$clients" ]]; then
                if grafana_import_service_dashboards "$node_name" "ethnode" "$clients" >/dev/null 2>&1; then
                    log_ulcs "  ✓ Added dashboards for $node_name ($clients)"
                    ((dashboards_added++))
                else
                    log_ulcs_warning "  ✗ Failed to add dashboards for $node_name"
                fi
            fi
        fi
    done
    
    # 2. Add validator dashboards
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if grafana_import_service_dashboards "vero" "validator" "vero" >/dev/null 2>&1; then
            log_ulcs "  ✓ Added Vero validator dashboard"
            ((dashboards_added++))
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if grafana_import_service_dashboards "teku-validator" "validator" "teku" >/dev/null 2>&1; then
            log_ulcs "  ✓ Added Teku validator dashboard"
            ((dashboards_added++))
        fi
    fi
    
    # 3. Add node-exporter dashboard
    if docker ps --format "{{.Names}}" | grep -q "monitoring-node-exporter"; then
        if grafana_import_service_dashboards "node-exporter" "node" "metrics" >/dev/null 2>&1; then
            log_ulcs "  ✓ Added node-exporter dashboard"
            ((dashboards_added++))
        fi
    fi
    
    log_ulcs_success "Rebuilt $dashboards_added Grafana dashboards"
    return 0
}

# Restart the entire monitoring stack
ulcs_restart_monitoring_stack() {
    log_ulcs "Restarting monitoring stack"
    
    local monitoring_dir="$HOME/monitoring"
    if [[ ! -d "$monitoring_dir" ]]; then
        log_ulcs_warning "Monitoring directory not found, skipping restart"
        return 0
    fi
    
    # Restart all monitoring services
    if cd "$monitoring_dir" && docker compose restart >/dev/null 2>&1; then
        log_ulcs_success "Monitoring stack restarted"
        
        # Wait a moment for services to be ready
        sleep 3
        
        # Verify services are running
        local services_ok=true
        if ! docker ps --format "{{.Names}}" | grep -q "monitoring-prometheus"; then
            log_ulcs_warning "Prometheus not running after restart"
            services_ok=false
        fi
        if ! docker ps --format "{{.Names}}" | grep -q "monitoring-grafana"; then
            log_ulcs_warning "Grafana not running after restart"
            services_ok=false
        fi
        
        if $services_ok; then
            log_ulcs_success "All monitoring services are running"
        else
            log_ulcs_warning "Some monitoring services may not be running properly"
        fi
        
        return 0
    else
        log_ulcs_error "Failed to restart monitoring stack"
        return 1
    fi
}

# Removed automatic monitoring rebuild function

# Simple monitoring restart - no config manipulation
ulcs_restart_monitoring_only() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs "Reinstalling monitoring stack after $service_name ($service_type) changes"
    
    # Check if monitoring exists
    if [[ ! -d "/home/$(whoami)/monitoring" ]]; then
        log_ulcs "No monitoring service found - skipping reinstall"
        return 0
    fi
    
    # Store Grafana password for reinstallation
    local monitoring_dir="/home/$(whoami)/monitoring"
    local grafana_password=""
    if [[ -f "$monitoring_dir/.env" ]]; then
        grafana_password=$(grep "GRAFANA_PASSWORD=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    fi
    
    # Remove existing monitoring
    log_ulcs "Removing existing monitoring installation..."
    cd "$monitoring_dir" 2>/dev/null && docker compose down -v 2>/dev/null || true
    rm -rf "$monitoring_dir" 2>/dev/null || sudo rm -rf "$monitoring_dir"
    
    # Reinstall monitoring with current networks
    log_ulcs "Reinstalling monitoring with current service configuration..."
    local available_networks=($(discover_nodeboi_networks | cut -d':' -f1))
    
    # Source monitoring lifecycle functions
    [[ -f "${NODEBOI_LIB}/monitoring-lifecycle.sh" ]] && source "${NODEBOI_LIB}/monitoring-lifecycle.sh"
    
    # Reinstall monitoring with auto-detected networks
    if install_monitoring_stack "${available_networks[@]}"; then
        log_ulcs_success "Monitoring stack reinstalled successfully"
    else
        log_ulcs_warning "Failed to restart monitoring stack"
        return 1
    fi
    
    return 0
}

# Cleanup function for monitoring integration
ulcs_cleanup_monitoring() {
    ulcs_restart_monitoring_only "$@"
}

# Export the new functions
export -f ulcs_restart_monitoring_only
export -f ulcs_cleanup_monitoring
export -f ulcs_nuke_grafana_dashboards
export -f ulcs_rebuild_all_grafana_dashboards
export -f ulcs_restart_monitoring_stack
# Removed ulcs_full_monitoring_rebuild function

# =====================================================================
# INITIALIZATION
# =====================================================================

# Ensure that service flows are initialized when the module is loaded
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    # Being sourced - initialize flows
    init_service_flows >/dev/null 2>&1
fi