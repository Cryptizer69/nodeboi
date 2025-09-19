#!/bin/bash
# lib/universal-service-lifecycle.sh - Universal service lifecycle management for ALL NODEBOI services
# This provides unified install, remove, start, stop, and update flows for every service type

# Source dependencies
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
[[ -f "${NODEBOI_LIB}/service-registry.sh" ]] && source "${NODEBOI_LIB}/service-registry.sh"
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"
[[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
[[ -f "${NODEBOI_LIB}/ulcs-monitoring.sh" ]] && source "${NODEBOI_LIB}/ulcs-monitoring.sh"

# Universal lifecycle logging
USL_INFO='\033[0;36m'
USL_SUCCESS='\033[0;32m'
USL_WARNING='\033[1;33m'
USL_ERROR='\033[0;31m'
USL_RESET='\033[0m'

log_usl() {
    echo -e "${USL_INFO}[USL] $1${USL_RESET}" >&2
}

log_usl_success() {
    echo -e "${USL_SUCCESS}[USL] ✓ $1${USL_RESET}" >&2
}

log_usl_error() {
    echo -e "${USL_ERROR}[USL] ✗ $1${USL_RESET}" >&2
}

log_usl_warning() {
    echo -e "${USL_WARNING}[USL] ⚠ $1${USL_RESET}" >&2
}

# Service flow definitions - defines what resources each service type manages
declare -A SERVICE_FLOWS

# Initialize service flow definitions
init_service_flows() {
    # Ethnode services (ethnode1, ethnode2, etc.)
    # Networks: ethnode-net (execution, consensus, mevboost, validator, prometheus)
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
        "remove": ["stop_services", "update_dependents", "cleanup_integrations", "remove_containers", "remove_volumes", "remove_networks", "remove_directories", "unregister"],
        "start": ["ensure_networks", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "recreate_services", "health_check"]
    },
    "integration_hooks": {
        "monitoring": "ulcs_integrate_monitoring",
        "validators": "update_beacon_endpoints"
    }
}
EOF
)

    # Validator services (vero, teku-validator)
    # Networks: validator-net (validator, prometheus), web3signer-net (validator, web3signer), ethnode-nets (validator connects to all ethnodes)
    SERVICE_FLOWS["validator"]=$(cat <<'EOF'
{
    "type": "validator",
    "resources": {
        "containers": ["${service_name}*"],
        "volumes": ["${service_name}_*", "${service_name}-*"],
        "networks": ["validator-net", "web3signer-net", "${ethnode_networks}"],
        "directories": ["$HOME/${service_name}"],
        "files": [],
        "integrations": ["monitoring", "ethnodes", "web3signer"]
    },
    "dependencies": ["ethnodes"],
    "dependents": [],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "connect_to_ethnodes", "start_services", "integrate"],
        "remove": ["stop_services", "cleanup_integrations", "remove_containers", "remove_volumes", "cleanup_shared_networks", "remove_directories", "unregister"],
        "start": ["ensure_networks", "connect_to_ethnodes", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "recreate_services", "health_check"]
    },
    "integration_hooks": {
        "monitoring": "ulcs_integrate_monitoring",
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
        "integrations": ["validators"]
    },
    "dependencies": [],
    "dependents": ["validators"],
    "lifecycle": {
        "install": ["create_directories", "copy_configs", "setup_networking", "setup_database", "start_services"],
        "remove": ["stop_services", "update_dependents", "cleanup_integrations", "remove_containers", "remove_volumes", "remove_networks", "remove_directories", "unregister"],
        "start": ["ensure_networks", "ensure_database", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "migrate_database", "recreate_services", "health_check"]
    },
    "integration_hooks": {
        "validators": "update_signing_config"
    }
}
EOF
)

    # Monitoring service
    # Networks: monitoring-net (node-exporter, prometheus, grafana), validator-net (prometheus), ethnode-nets (prometheus connects to all)
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
        "install": ["create_directories", "copy_configs", "setup_networking", "setup_grafana_dashboards", "start_services"],
        "remove": ["stop_services", "remove_containers", "remove_volumes", "remove_networks", "remove_directories", "unregister"],
        "start": ["ensure_networks", "start_services", "health_check"],
        "stop": ["stop_services"],
        "update": ["pull_images", "update_dashboards", "recreate_services", "health_check"]
    },
    "integration_hooks": {}
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
        log_usl_error "Unknown service type: $service_type"
        return 1
    fi
}

# Universal service removal orchestrator
remove_service_universal() {
    local service_name="$1"
    local with_integrations="${2:-true}"
    local interactive="${3:-true}"
    
    if [[ -z "$service_name" ]]; then
        log_usl_error "remove_service_universal: service name required"
        return 1
    fi
    
    # Validate service exists
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_usl_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    # Detect service type
    local service_type=$(detect_service_type "$service_name")
    if [[ "$service_type" == "unknown" ]]; then
        log_usl_error "Cannot determine service type for: $service_name"
        return 1
    fi
    
    log_usl "Starting universal removal of $service_type service: $service_name"
    
    # Get service flow definition
    local flow_def=$(get_service_flow "$service_type")
    if [[ $? -ne 0 ]]; then
        log_usl_error "Cannot get service flow for type: $service_type"
        return 1
    fi
    
    # Interactive confirmation if requested - single confirmation with service-specific warnings
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
        
        # Always do full cleanup when user confirms - no second question
        with_integrations="true"
        echo -e "${UI_MUTED}Proceeding with complete removal including all integrations...${NC}"
    fi
    
    # Execute removal lifecycle
    execute_service_lifecycle "$service_name" "$service_type" "remove" "$flow_def" "$with_integrations"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_usl_success "Service $service_name removed successfully"
        echo -e "${GREEN}✓ $service_name ($service_type) removed successfully with complete cleanup${NC}"
    else
        log_usl_error "Service $service_name removal failed"
        echo -e "${RED}✗ $service_name removal failed - check logs for details${NC}"
    fi
    
    return $result
}

# Universal service installation orchestrator  
install_service_universal() {
    local service_name="$1"
    local service_type="$2"
    local config_params="$3"
    
    if [[ -z "$service_name" || -z "$service_type" ]]; then
        log_usl_error "install_service_universal: service name and type required"
        return 1
    fi
    
    # Check if service already exists
    if [[ -d "$HOME/$service_name" ]]; then
        log_usl_error "Service already exists: $service_name"
        return 1
    fi
    
    log_usl "Starting universal installation of $service_type service: $service_name"
    
    # Get service flow definition
    local flow_def=$(get_service_flow "$service_type")
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    
    # Execute installation lifecycle
    execute_service_lifecycle "$service_name" "$service_type" "install" "$flow_def" "true" "$config_params"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_usl_success "Service $service_name installed successfully"
        echo -e "${GREEN}✓ $service_name ($service_type) installed successfully${NC}"
    else
        log_usl_error "Service $service_name installation failed"
        echo -e "${RED}✗ $service_name installation failed - check logs for details${NC}"
    fi
    
    return $result
}

# Universal service start orchestrator
start_service_universal() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_usl_error "start_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_usl_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_usl "Starting $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "start" "$flow_def"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_usl_success "Service $service_name started successfully"
        echo -e "${GREEN}✓ $service_name started successfully${NC}"
    else
        log_usl_error "Service $service_name start failed"
        echo -e "${RED}✗ $service_name start failed${NC}"
    fi
    
    return $result
}

# Universal service stop orchestrator
stop_service_universal() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_usl_error "stop_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_usl_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_usl "Stopping $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "stop" "$flow_def"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_usl_success "Service $service_name stopped successfully"
        echo -e "${GREEN}✓ $service_name stopped successfully${NC}"
    else
        log_usl_error "Service $service_name stop failed"
        echo -e "${RED}✗ $service_name stop failed${NC}"
    fi
    
    return $result
}

# Universal service update orchestrator
update_service_universal() {
    local service_name="$1"
    local update_params="$2"
    
    if [[ -z "$service_name" ]]; then
        log_usl_error "update_service_universal: service name required"
        return 1
    fi
    
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_usl_error "Service directory not found: $HOME/$service_name"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    log_usl "Updating $service_type service: $service_name"
    
    local flow_def=$(get_service_flow "$service_type")
    execute_service_lifecycle "$service_name" "$service_type" "update" "$flow_def" "true" "$update_params"
    local result=$?
    
    if [[ $result -eq 0 ]]; then
        log_usl_success "Service $service_name updated successfully"
        echo -e "${GREEN}✓ $service_name updated successfully${NC}"
    else
        log_usl_error "Service $service_name update failed"
        echo -e "${RED}✗ $service_name update failed${NC}"
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
        log_usl_error "No lifecycle steps defined for $service_type.$action"
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
        
        log_usl "Step $step_count/$total_steps: $step"
        echo -e "${UI_MUTED}Progress: [$step_count/$total_steps] $step${NC}"
        
        if execute_lifecycle_step "$service_name" "$service_type" "$step" "$flow_def" "$with_integrations" "$params"; then
            log_usl_success "Step completed: $step"
        else
            log_usl_error "Step failed: $step"
            ((errors++))
            
            # Some steps are allowed to fail
            case "$step" in
                "cleanup_integrations"|"update_dependents"|"cleanup_shared_networks"|"unregister")
                    log_usl_warning "Non-critical step failed, continuing..."
                    ;;
                *)
                    # Critical failure
                    log_usl_error "Critical step failed, aborting lifecycle"
                    return 1
                    ;;
            esac
        fi
    done <<< "$steps"
    
    if [[ $errors -eq 0 ]]; then
        log_usl_success "Lifecycle $action completed successfully for $service_name"
        return 0
    else
        log_usl_warning "Lifecycle $action completed with $errors non-critical errors for $service_name"
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
        "unregister")
            unregister_service_from_registry "$service_name"
            ;;
        "ensure_networks")
            ensure_service_networks "$service_name" "$flow_def"
            ;;
        
        # Integration steps
        "cleanup_integrations")
            [[ "$with_integrations" == "true" ]] && ulcs_cleanup_service_integrations "$service_name" "$service_type" "$flow_def"
            ;;
        "integrate")
            [[ "$with_integrations" == "true" ]] && ulcs_integrate_service "$service_name" "$service_type" "$flow_def"
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
        
        # Monitoring-specific steps
        "setup_grafana_dashboards")
            setup_grafana_dashboards "$service_name"
            ;;
        "update_dashboards")
            update_service_dashboards "$service_name"
            ;;
        
        *)
            log_usl_warning "Unknown lifecycle step: $step"
            return 1
            ;;
    esac
}

# Show service-specific warning messages (preserving legacy warnings)
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
                echo -e "${YELLOW}⚠️  WARNING: This will completely remove Vero and all its data${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            elif [[ "$service_name" == "teku-validator" ]]; then
                echo -e "${YELLOW}⚠️  WARNING: This will completely remove Teku validator and all its data${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            else
                echo -e "${YELLOW}⚠️  WARNING: This will completely remove the validator service${NC}"
                echo -e "${UI_MUTED}• All validator configuration will be lost${NC}"
                echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            fi
            echo -e "${UI_MUTED}• Beacon node connections will be removed${NC}"
            echo -e "${UI_MUTED}• Web3signer remote signing configuration will be lost${NC}"
            echo -e "${UI_MUTED}• Attestation and validation history will be lost${NC}"
            echo -e "${YELLOW}• Keys remain in web3signer - validator will stop but keys are safe${NC}"
            ;;
        "web3signer")
            echo -e "${YELLOW}⚠️  WARNING: This will completely remove Web3signer and all its data${NC}"
            echo -e "${UI_MUTED}• All keystore configurations will be lost${NC}"
            echo -e "${UI_MUTED}• PostgreSQL database will be deleted${NC}"
            echo -e "${UI_MUTED}• All validator keys and signing data will be removed${NC}"
            echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            echo -e "${UI_MUTED}• This action cannot be undone${NC}"
            echo -e "${RED}• WARNING: Removed keys cannot be used for validation${NC}"
            echo -e "${RED}• Validators using this signer will stop working${NC}"
            ;;
        "monitoring")
            echo -e "${YELLOW}⚠️  WARNING: This will completely remove the monitoring stack${NC}"
            echo -e "${UI_MUTED}• All Grafana dashboards will be lost${NC}"
            echo -e "${UI_MUTED}• All Prometheus metrics history will be deleted${NC}"
            echo -e "${UI_MUTED}• All monitoring data and configurations will be removed${NC}"
            echo -e "${UI_MUTED}• Container and volumes will be deleted${NC}"
            echo -e "${UI_MUTED}• This action cannot be undone${NC}"
            echo -e "${YELLOW}• All services will lose monitoring and observability${NC}"
            ;;
        *)
            # Generic warning for unknown service types
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
    
    # Extract and show resources that will be removed (with manual variable substitution)
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

# Initialize service flows when this script is sourced
init_service_flows

# Export key functions for use by other scripts
export -f remove_service_universal
export -f install_service_universal
export -f start_service_universal
export -f stop_service_universal
export -f update_service_universal
export -f show_service_removal_plan
export -f detect_service_type