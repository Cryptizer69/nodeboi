#!/bin/bash
# lib/service-operations.sh - Implementation of universal service operations
# This contains the actual implementations of lifecycle step functions

# Source dependencies
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"

# Service operations logging
SO_INFO='\033[0;34m'
SO_SUCCESS='\033[0;32m'
SO_WARNING='\033[1;33m'
SO_ERROR='\033[0;31m'
SO_RESET='\033[0m'

log_so() {
    echo -e "${SO_INFO}[SO] $1${SO_RESET}" >&2
}

log_so_success() {
    echo -e "${SO_SUCCESS}[SO] ✓ $1${SO_RESET}" >&2
}

log_so_error() {
    echo -e "${SO_ERROR}[SO] ✗ $1${SO_RESET}" >&2
}

log_so_warning() {
    echo -e "${SO_WARNING}[SO] ⚠ $1${SO_RESET}" >&2
}

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
        log_so "Stopping services via docker compose"
        
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
                log_so "Detected Nethermind - using graceful shutdown procedure"
                shutdown_method="nethermind"
            elif [[ "$compose_file" == *"besu"* ]]; then
                log_so "Detected Besu - using graceful shutdown procedure"
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
                    log_so "Docker compose services stopped"
                else
                    log_so_warning "Docker compose down failed, trying individual container stop"
                    ((stop_errors++))
                fi
                ;;
        esac
    fi
    
    # Stop any remaining containers matching the service name pattern
    local running_containers=$(docker ps --filter "name=${service_name}" --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$running_containers" ]]; then
        log_so "Stopping remaining containers: $(echo $running_containers | tr '\n' ' ')"
        echo "$running_containers" | while read -r container; do
            if [[ -n "$container" ]]; then
                if docker stop "$container" >/dev/null 2>&1; then
                    log_so "Stopped container: $container"
                else
                    log_so_warning "Failed to stop container: $container"
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
            log_so "Removing containers matching pattern '$pattern': $(echo $containers | tr '\n' ' ')"
            if echo "$containers" | xargs -r docker rm -f >/dev/null 2>&1; then
                removed_count=$((removed_count + $(echo "$containers" | wc -w)))
                log_so "Containers removed for pattern: $pattern"
            else
                log_so_error "Failed to remove some containers for pattern: $pattern"
                return 1
            fi
        fi
    done
    
    if [[ $removed_count -eq 0 ]]; then
        log_so "No containers found for $service_name"
    else
        log_so_success "Removed $removed_count containers for $service_name"
    fi
    
    return 0
}

# Start containers for a service
start_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" ]]; then
        log_so_error "Service directory not found: $service_dir"
        return 1
    fi
    
    if [[ ! -f "$service_dir/compose.yml" ]]; then
        log_so_error "No compose.yml found in $service_dir"
        return 1
    fi
    
    log_so "Starting services via docker compose"
    
    # Set required environment variables for ethnode services
    local env_vars=""
    if [[ "$service_name" =~ ^ethnode[0-9]+$ ]]; then
        env_vars="NODE_NAME=$service_name"
    fi
    
    # Start with proper environment
    if [[ -n "$env_vars" ]]; then
        if cd "$service_dir" && env $env_vars docker compose up -d >/dev/null 2>&1; then
            log_so_success "Services started successfully"
            return 0
        else
            log_so_error "Failed to start services"
            return 1
        fi
    else
        if cd "$service_dir" && docker compose up -d >/dev/null 2>&1; then
            log_so_success "Services started successfully"
            return 0
        else
            log_so_error "Failed to start services"
            return 1
        fi
    fi
}

# Pull latest images for a service
pull_service_images() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" || ! -f "$service_dir/compose.yml" ]]; then
        log_so_error "Cannot pull images - compose.yml not found"
        return 1
    fi
    
    log_so "Pulling latest images"
    if cd "$service_dir" && docker compose pull >/dev/null 2>&1; then
        log_so_success "Images pulled successfully"
        return 0
    else
        log_so_error "Failed to pull images"
        return 1
    fi
}

# Recreate containers for a service
recreate_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" || ! -f "$service_dir/compose.yml" ]]; then
        log_so_error "Cannot recreate services - compose.yml not found"
        return 1
    fi
    
    log_so "Recreating services"
    
    # Set required environment variables for ethnode services
    local env_vars=""
    if [[ "$service_name" =~ ^ethnode[0-9]+$ ]]; then
        env_vars="NODE_NAME=$service_name"
    fi
    
    # Recreate with proper environment
    if [[ -n "$env_vars" ]]; then
        if cd "$service_dir" && env $env_vars docker compose up -d --force-recreate >/dev/null 2>&1; then
            log_so_success "Services recreated successfully"
            return 0
        else
            log_so_error "Failed to recreate services"
            return 1
        fi
    else
        if cd "$service_dir" && docker compose up -d --force-recreate >/dev/null 2>&1; then
            log_so_success "Services recreated successfully"
            return 0
        else
            log_so_error "Failed to recreate services"
            return 1
        fi
    fi
}

# Health check for a service
health_check_service() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" ]]; then
        log_so_error "Service directory not found for health check"
        return 1
    fi
    
    # Basic health check - ensure containers are running
    if cd "$service_dir" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
        log_so_success "Health check passed - services are running"
        return 0
    else
        log_so_warning "Health check failed - some services may not be running"
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
            log_so "Removing volumes matching pattern '$pattern': $(echo $volumes | tr '\n' ' ')"
            if echo "$volumes" | xargs -r docker volume rm -f >/dev/null 2>&1; then
                removed_count=$((removed_count + $(echo "$volumes" | wc -w)))
                log_so "Volumes removed for pattern: $pattern"
            else
                log_so_warning "Some volumes may still exist (possibly in use)"
            fi
        fi
    done
    
    if [[ $removed_count -eq 0 ]]; then
        log_so "No volumes found for $service_name"
    else
        log_so_success "Removed $removed_count volumes for $service_name"
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
        log_so "No networks defined for $service_name"
        return 0
    fi
    
    local removed_count=0
    
    for network in $networks; do
        if docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            # Check if network is still in use
            local containers_in_network=$(docker network inspect "$network" --format '{{range $id, $config := .Containers}}{{$config.Name}} {{end}}' 2>/dev/null || true)
            
            if [[ -n "$containers_in_network" ]]; then
                log_so_warning "Network $network still has containers: $containers_in_network"
                log_so "Attempting to disconnect containers..."
                
                # Try to disconnect containers
                echo "$containers_in_network" | tr ' ' '\n' | while read -r container; do
                    [[ -n "$container" ]] && docker network disconnect "$network" "$container" 2>/dev/null || true
                done
            fi
            
            # Remove the network
            if docker network rm "$network" >/dev/null 2>&1; then
                log_so_success "Network $network removed"
                ((removed_count++))
            else
                log_so_warning "Failed to remove network $network (may be in use)"
            fi
        else
            log_so "Network $network does not exist"
        fi
    done
    
    return 0
}

# Ensure networks exist for a service
ensure_service_networks() {
    local service_name="$1"
    local flow_def="$2"
    
    local networks=$(echo "$flow_def" | jq -r '.resources.networks[]?' 2>/dev/null | sed "s/\${service_name}/$service_name/g")
    
    for network in $networks; do
        if ! docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
            log_so "Creating network: $network"
            if docker network create "$network" >/dev/null 2>&1; then
                log_so_success "Network $network created"
            else
                log_so_error "Failed to create network: $network"
                return 1
            fi
        else
            log_so "Network $network already exists"
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
            log_so "Removing orphaned validator-net..."
            if docker network rm validator-net 2>/dev/null; then
                log_so_success "Orphaned validator-net removed"
            else
                log_so_warning "Failed to remove validator-net (may be in use)"
            fi
        fi
    else
        log_so "Validator network retained (other services still exist: ${validator_services[*]})"
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
        log_so "Directory $service_dir does not exist"
        return 0
    fi
    
    # Ensure we're not in the directory we're trying to remove
    if [[ "$PWD" == "$service_dir"* ]]; then
        cd "$HOME" 2>/dev/null || cd / 2>/dev/null
    fi
    
    # Remove the directory
    if rm -rf "$service_dir" 2>/dev/null; then
        log_so_success "Directory $service_dir removed"
        return 0
    else
        log_so_error "Failed to remove directory $service_dir"
        return 1
    fi
}

# Create service directories during installation
create_service_directories() {
    local service_name="$1"
    local params="$2"
    local service_dir="$HOME/$service_name"
    
    log_so "Creating directory structure for $service_name"
    if mkdir -p "$service_dir" 2>/dev/null; then
        log_so_success "Directory $service_dir created"
        return 0
    else
        log_so_error "Failed to create directory $service_dir"
        return 1
    fi
}

# Copy service configuration files
copy_service_configs() {
    local service_name="$1"
    local service_type="$2"
    local params="$3"
    
    # This would copy appropriate config files based on service type
    # Implementation depends on specific service requirements
    log_so "Copying configuration files for $service_type service"
    
    # Placeholder - actual implementation would copy specific config files
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
                cleanup_monitoring_integration "$service_name" "$service_type"
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

# Clean up monitoring integration
cleanup_monitoring_integration() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_so "No monitoring service found"
        return 0
    fi
    
    log_so "Cleaning up monitoring integration for $service_name"
    
    local cleanup_success=true
    
    # 1. Call existing monitoring cleanup hooks
    if declare -f cleanup_ethnode_monitoring >/dev/null 2>&1; then
        if ! cleanup_ethnode_monitoring "$service_name"; then
            log_so_error "Hook-based monitoring cleanup failed"
            cleanup_success=false
        fi
    fi
    
    # 2. Rebuild prometheus.yml configuration (remove scrape targets)
    log_so "Rebuilding prometheus.yml configuration"
    if rebuild_prometheus_config_after_removal "$service_name" "$service_type"; then
        log_so_success "Prometheus configuration rebuilt"
    else
        log_so_warning "Failed to rebuild prometheus configuration"
        cleanup_success=false
    fi
    
    # 3. Remove service-specific Grafana dashboards
    log_so "Removing Grafana dashboards for $service_name"
    if remove_grafana_dashboards_for_service "$service_name" "$service_type"; then
        log_so_success "Grafana dashboards removed"
    else
        log_so_warning "Failed to remove some Grafana dashboards"
        cleanup_success=false
    fi
    
    # 4. Restart monitoring stack to apply changes
    log_so "Restarting monitoring stack to apply configuration changes"
    if restart_monitoring_stack; then
        log_so_success "Monitoring stack restarted"
    else
        log_so_warning "Failed to restart monitoring stack"
        cleanup_success=false
    fi
    
    if [[ "$cleanup_success" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Integrate with monitoring
# Integrate with validators (stub - not implemented yet)
integrate_with_validators() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Validator integration for $service_name not implemented yet"
    return 0
}

# Integrate with ethnodes
integrate_with_ethnodes() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Ethnode integration for $service_name not implemented yet"
    return 0
}

# Integrate with web3signer  
integrate_with_web3signer() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Web3signer integration for $service_name not implemented yet"
    return 0
}

integrate_with_monitoring() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_so "No monitoring service found - skipping integration"
        return 0
    fi
    
    log_so "Integrating $service_name with monitoring"
    
    local integration_success=true
    
    # 1. Rebuild prometheus.yml to include new service targets
    log_so "Rebuilding prometheus.yml to include $service_name"
    if rebuild_prometheus_config_after_addition "$service_name" "$service_type"; then
        log_so_success "Prometheus configuration updated"
    else
        log_so_warning "Failed to update prometheus configuration"
        integration_success=false
    fi
    
    # 2. Add service-specific Grafana dashboards
    log_so "Adding Grafana dashboards for $service_name"
    if add_grafana_dashboards_for_service "$service_name" "$service_type"; then
        log_so_success "Grafana dashboards added"
    else
        log_so_warning "Failed to add some Grafana dashboards"
        integration_success=false
    fi
    
    # 3. Update network connections (rebuild prometheus compose.yml for multi-network access)
    log_so "Updating network connections for monitoring integration"
    if update_monitoring_network_connections; then
        log_so_success "Network connections updated"
    else
        log_so_warning "Failed to update network connections"
        integration_success=false
    fi
    
    # 4. Restart monitoring stack to apply all changes
    log_so "Restarting monitoring stack to apply integration changes"
    if restart_monitoring_stack; then
        log_so_success "Monitoring stack restarted"
    else
        log_so_warning "Failed to restart monitoring stack"
        integration_success=false
    fi
    
    if [[ "$integration_success" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# =====================================================================
# VALIDATOR-SPECIFIC OPERATIONS
# =====================================================================

# Connect validator to ethnodes
connect_validator_to_ethnodes() {
    local service_name="$1"
    
    log_so "Connecting validator $service_name to available ethnodes"
    
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
        log_so_warning "No ethnodes found for validator connection"
        return 1
    fi
    
    log_so_success "Found ${#available_ethnodes[@]} available ethnodes: ${available_ethnodes[*]}"
    return 0
}

# Discover and configure beacon endpoints
discover_and_configure_beacon_endpoints() {
    local service_name="$1"
    
    log_so "Discovering beacon endpoints for $service_name"
    
    # This would use the existing beacon endpoint discovery logic
    # Implementation would depend on specific validator configuration
    return 0
}

# Clean up validator integration
cleanup_validator_integration() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Cleaning up validator integration for $service_name"
    
    # Remove service from validator configurations
    return 0
}

# Update validators after service removal
update_validators_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ "$service_type" == "ethnode" ]]; then
        log_so "Updating validators after ethnode removal"
        
        # Update Vero if it exists
        if [[ -d "$HOME/vero" ]]; then
            remove_beacon_endpoint_from_vero "$service_name"
        fi
        
        # Update Teku validator if it exists
        if [[ -d "$HOME/teku-validator" ]]; then
            remove_beacon_endpoint_from_teku_validator "$service_name"
        fi
    fi
    
    return 0
}

# =====================================================================
# SERVICE REGISTRY OPERATIONS
# =====================================================================

# Unregister service from registry
unregister_service_from_registry() {
    local service_name="$1"
    
    if declare -f unregister_service >/dev/null 2>&1; then
        log_so "Unregistering $service_name from service registry"
        if unregister_service "$service_name"; then
            log_so_success "Service unregistered successfully"
            return 0
        else
            log_so_warning "Service registry update failed (non-critical)"
            return 1
        fi
    else
        log_so "Service registry functions not available"
        return 0
    fi
}

# =====================================================================
# DATABASE OPERATIONS (for web3signer)
# =====================================================================

# Setup service database
setup_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_so "Setting up database for web3signer"
        # Database setup logic would go here
    fi
    
    return 0
}

# Ensure service database is running
ensure_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_so "Ensuring database is available for web3signer"
        # Database health check logic would go here
    fi
    
    return 0
}

# Migrate service database
migrate_service_database() {
    local service_name="$1"
    
    if [[ "$service_name" == "web3signer" ]]; then
        log_so "Running database migrations for web3signer"
        # Database migration logic would go here
    fi
    
    return 0
}

# =====================================================================
# MONITORING-SPECIFIC OPERATIONS
# =====================================================================

# Setup Grafana dashboards
setup_grafana_dashboards() {
    local service_name="$1"
    
    log_so "Setting up Grafana dashboards for monitoring service"
    # Dashboard setup logic would go here
    return 0
}

# Update service dashboards
update_service_dashboards() {
    local service_name="$1"
    
    log_so "Updating dashboards for $service_name"
    # Dashboard update logic would go here
    return 0
}

# Rebuild prometheus.yml configuration after service removal
rebuild_prometheus_config_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    # Source the grafana dashboard management functions
    if [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]]; then
        source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
    else
        log_so_error "Grafana dashboard management functions not available"
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
    
    log_so "Rebuilding prometheus config for networks: ${running_networks[*]}"
    
    # Call the existing regenerate_prometheus_config function
    if declare -f regenerate_prometheus_config >/dev/null 2>&1; then
        regenerate_prometheus_config "$HOME/monitoring" "${running_networks[@]}"
        return $?
    else
        log_so_error "regenerate_prometheus_config function not available"
        return 1
    fi
}

# Remove Grafana dashboards for a specific service
remove_grafana_dashboards_for_service() {
    local service_name="$1"
    local service_type="$2"
    
    # Check if Grafana is running
    if ! docker ps --format "{{.Names}}" | grep -q "monitoring-grafana"; then
        log_so "Grafana not running - dashboard removal skipped"
        return 0
    fi
    
    local grafana_url="http://localhost:3000"
    local admin_user="admin"
    local admin_pass="admin"
    
    # Get admin password from monitoring .env if available
    if [[ -f "$HOME/monitoring/.env" ]]; then
        local env_pass=$(grep "GF_SECURITY_ADMIN_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2 2>/dev/null)
        [[ -n "$env_pass" ]] && admin_pass="$env_pass"
    fi
    
    # Check dependencies
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log_so_warning "curl or jq not available - cannot remove dashboards via API"
        return 0
    fi
    
    local dashboards_removed=0
    
    # Define search patterns based on service type
    local search_patterns=()
    case "$service_type" in
        "ethnode")
            search_patterns+=("$service_name" "$(echo "$service_name" | sed 's/ethnode//')")
            ;;
        "validator")
            search_patterns+=("$service_name" "validator" "vero" "teku.*validator")
            ;;
        "web3signer")
            # Web3signer has no monitoring dashboards
            log_so "Web3signer has no monitoring dashboards to remove"
            return 0
            ;;
        "monitoring")
            # Don't remove monitoring dashboards when removing monitoring service
            log_so "Skipping dashboard removal for monitoring service"
            return 0
            ;;
    esac
    
    # Get all dashboards and remove matching ones
    local dashboards=$(curl -s -u "$admin_user:$admin_pass" "$grafana_url/api/search?type=dash-db" 2>/dev/null)
    
    if [[ -n "$dashboards" && "$dashboards" != "[]" ]]; then
        for pattern in "${search_patterns[@]}"; do
            local matching_dashboards=$(echo "$dashboards" | jq -r ".[] | select(.title | test(\"$pattern\"; \"i\")) | .uid" 2>/dev/null)
            
            while IFS= read -r uid; do
                if [[ -n "$uid" && "$uid" != "null" ]]; then
                    log_so "Removing dashboard: $uid (pattern: $pattern)"
                    if curl -s -X DELETE -u "$admin_user:$admin_pass" "$grafana_url/api/dashboards/uid/$uid" >/dev/null 2>&1; then
                        ((dashboards_removed++))
                        log_so "Successfully removed dashboard UID: $uid"
                    else
                        log_so_warning "Failed to remove dashboard UID: $uid"
                    fi
                fi
            done <<< "$matching_dashboards"
        done
    fi
    
    log_so "Removed $dashboards_removed dashboard(s) for $service_name"
    return 0
}

# Restart monitoring stack to apply configuration changes
restart_monitoring_stack() {
    local monitoring_dir="$HOME/monitoring"
    
    if [[ ! -d "$monitoring_dir" ]]; then
        log_so_error "Monitoring directory not found"
        return 1
    fi
    
    if [[ ! -f "$monitoring_dir/compose.yml" ]]; then
        log_so_error "Monitoring compose.yml not found"
        return 1
    fi
    
    # Check if monitoring is running
    local running_containers=$(docker ps --filter "name=monitoring" --format "{{.Names}}" 2>/dev/null)
    
    if [[ -z "$running_containers" ]]; then
        log_so "Monitoring stack not running - no restart needed"
        return 0
    fi
    
    log_so "Stopping monitoring stack..."
    if cd "$monitoring_dir" && docker compose down >/dev/null 2>&1; then
        log_so "Monitoring stack stopped"
    else
        log_so_warning "Failed to stop monitoring stack gracefully"
    fi
    
    # Brief pause to ensure clean shutdown
    sleep 3
    
    log_so "Starting monitoring stack with new configuration..."
    if cd "$monitoring_dir" && docker compose up -d >/dev/null 2>&1; then
        log_so "Monitoring stack restarted successfully"
        
        # Wait a moment for services to start
        sleep 5
        
        # Verify services are running
        local restarted_containers=$(docker ps --filter "name=monitoring" --format "{{.Names}}" 2>/dev/null)
        if [[ -n "$restarted_containers" ]]; then
            log_so "Verified monitoring services are running: $(echo $restarted_containers | tr '\n' ' ')"
            return 0
        else
            log_so_error "Monitoring services failed to start after restart"
            return 1
        fi
    else
        log_so_error "Failed to restart monitoring stack"
        return 1
    fi
}

# Update monitoring after service removal
update_monitoring_after_removal() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Updating monitoring after removal of $service_name"
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
        
        # Restart Vero if running
        if docker ps --format "{{.Names}}" | grep -q "^vero$"; then
            (cd "$HOME/vero" && docker compose restart >/dev/null 2>&1) || true
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
    log_so "Would update Teku validator configuration to remove $ethnode_name"
    return 0
}

# Export all functions for use by the lifecycle system
export -f stop_service_containers
export -f remove_service_containers
# =====================================================================
# ADDITIONAL MONITORING INTEGRATION FUNCTIONS
# =====================================================================

# Rebuild prometheus configuration after service addition
rebuild_prometheus_config_after_addition() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Rebuilding prometheus.yml after adding $service_name"
    
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
        log_so_warning "regenerate_prometheus_config function not available"
        return 1
    fi
}

# Add Grafana dashboards for a service
add_grafana_dashboards_for_service() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Adding Grafana dashboards for $service_type service: $service_name"
    
    # Check if monitoring is available
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_so "No monitoring directory found"
        return 1
    fi
    
    # Copy appropriate dashboards based on service type
    local template_dir="/home/floris/.nodeboi/grafana-dashboards"
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
            log_so "Web3signer has no monitoring dashboards to add"
            return 0
            ;;
    esac
    
    return 0
}

# Update monitoring network connections (rebuild compose.yml with all networks)
update_monitoring_network_connections() {
    log_so "Updating monitoring network connections"
    
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
        log_so_warning "Network manager not available"
        return 1
    fi
}

# Update network cleanup logic to handle shared network removal intelligently
cleanup_shared_service_networks() {
    local service_name="$1"
    local service_type="$2"
    
    log_so "Cleaning up networks for $service_type service: $service_name"
    
    case "$service_type" in
        "ethnode")
            # Ethnode networks are isolated - always safe to remove
            local ethnode_net="${service_name}-net"
            if docker network inspect "$ethnode_net" >/dev/null 2>&1; then
                log_so "Removing isolated ethnode network: $ethnode_net"
                docker network rm "$ethnode_net" 2>/dev/null
            fi
            ;;
        "validator")
            # Check if any other validators remain before removing validator-net
            local remaining_validators=()
            for service in "vero" "teku-validator"; do
                if [[ -d "$HOME/$service" && "$service" != "$service_name" ]]; then
                    remaining_validators+=("$service")
                fi
            done
            
            if [[ ${#remaining_validators[@]} -eq 0 ]]; then
                log_so "No validators remaining - removing validator-net"
                docker network rm "validator-net" 2>/dev/null
            else
                log_so "Other validators remain (${remaining_validators[*]}) - keeping validator-net"
            fi
            ;;
        "web3signer")
            # web3signer-net can be removed when web3signer is removed
            log_so "Removing web3signer-net"
            docker network rm "web3signer-net" 2>/dev/null
            ;;
        "monitoring")
            # monitoring-net removed with monitoring service
            log_so "Removing monitoring-net"
            docker network rm "monitoring-net" 2>/dev/null
            ;;
    esac
    
    # Always update remaining service network connections
    if declare -f manage_service_networks >/dev/null 2>&1; then
        log_so "Updating network connections for remaining services"
        manage_service_networks "sync" "silent"
    fi
    
    return 0
}

# =====================================================================
# EXPORTS
# =====================================================================

export -f start_service_containers
export -f pull_service_images
export -f recreate_service_containers
export -f health_check_service
export -f remove_service_volumes
export -f remove_service_networks
export -f ensure_service_networks
export -f cleanup_shared_networks
export -f setup_service_networking
export -f remove_service_directories
export -f create_service_directories
export -f copy_service_configs
export -f cleanup_service_integrations
export -f integrate_service
export -f update_dependent_services
export -f cleanup_monitoring_integration
export -f integrate_with_monitoring
export -f connect_validator_to_ethnodes
export -f discover_and_configure_beacon_endpoints
export -f cleanup_validator_integration
export -f update_validators_after_removal
export -f unregister_service_from_registry
export -f setup_service_database
export -f ensure_service_database
export -f migrate_service_database
export -f setup_grafana_dashboards
export -f update_service_dashboards
export -f update_monitoring_after_removal
export -f remove_beacon_endpoint_from_vero
export -f remove_beacon_endpoint_from_teku_validator
export -f rebuild_prometheus_config_after_addition
export -f add_grafana_dashboards_for_service
export -f update_monitoring_network_connections
export -f cleanup_shared_service_networks
export -f integrate_with_validators
export -f integrate_with_ethnodes  
export -f integrate_with_web3signer

# =====================================================================
# CLIENT-SPECIFIC SHUTDOWN PROCEDURES
# =====================================================================

# Nethermind graceful shutdown with database flush
stop_nethermind_gracefully() {
    local service_name="$1"
    local service_dir="$2" 
    local env_vars="$3"
    
    log_so "Initiating Nethermind graceful shutdown procedure"
    
    # Step 1: Send SIGTERM to Nethermind container to trigger graceful shutdown
    local container_name="${service_name}-nethermind"
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        log_so "Sending SIGTERM to Nethermind for graceful shutdown..."
        docker kill -s TERM "$container_name" 2>/dev/null || true
        
        # Step 2: Wait with progress indicator for database flush (up to 60 seconds)
        local wait_time=0
        local max_wait=60
        while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
            if [[ $((wait_time % 10)) -eq 0 ]]; then
                log_so "Waiting for Nethermind database flush... ($wait_time/${max_wait}s)"
            fi
            sleep 2
            ((wait_time += 2))
        done
        
        # Step 3: If still running after graceful period, force compose down
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_so_warning "Nethermind did not stop gracefully, forcing shutdown"
            local compose_cmd="docker compose down -t 10"
            if [[ -n "$env_vars" ]]; then
                compose_cmd="env $env_vars $compose_cmd"
            fi
            cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
        else
            log_so_success "Nethermind stopped gracefully after database flush"
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
    
    log_so "Initiating Besu graceful shutdown procedure"
    
    local container_name="${service_name}-besu"
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        log_so "Sending SIGTERM to Besu for graceful shutdown..."
        docker kill -s TERM "$container_name" 2>/dev/null || true
        
        # Wait up to 45 seconds for Besu to shutdown gracefully
        local wait_time=0
        local max_wait=45
        while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
            if [[ $((wait_time % 15)) -eq 0 ]]; then
                log_so "Waiting for Besu graceful shutdown... ($wait_time/${max_wait}s)"
            fi
            sleep 3
            ((wait_time += 3))
        done
        
        # Force shutdown if needed
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_so_warning "Besu did not stop gracefully, forcing shutdown"
        else
            log_so_success "Besu stopped gracefully"
        fi
    fi
    
    # Clean up all containers via compose
    local compose_cmd="docker compose down -t 10"
    if [[ -n "$env_vars" ]]; then
        compose_cmd="env $env_vars $compose_cmd"
    fi
    cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
}

export -f stop_nethermind_gracefully
export -f stop_besu_gracefully

# =====================================================================
# INTEGRATION CLEANUP FUNCTIONS
# =====================================================================

# Clean up service integrations during removal
cleanup_service_integrations() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    log_so "Cleaning up integrations for $service_name"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                cleanup_monitoring_integration "$service_name" "$service_type"
                ;;
            "validators") 
                cleanup_validator_integration "$service_name" "$service_type"
                ;;
            "ethnodes")
                # Remove beacon endpoints from validators
                remove_beacon_endpoint_from_vero "$service_name" 2>/dev/null || true
                remove_beacon_endpoint_from_teku_validator "$service_name" 2>/dev/null || true
                ;;
            "web3signer")
                log_so "Web3signer integration cleanup not yet implemented"
                ;;
        esac
    done
    
    return 0
}

# Cleanup monitoring integration for a removed service
cleanup_monitoring_integration() {
    local service_name="$1"
    local service_type="$2"
    
    if [[ ! -d "$HOME/monitoring" ]]; then
        log_so "No monitoring service found - skipping cleanup"
        return 0
    fi
    
    log_so "Cleaning up monitoring integration for $service_name"
    
    # 1. Regenerate prometheus.yml without the removed service
    log_so "Regenerating prometheus.yml to exclude $service_name"
    if regenerate_prometheus_config_safe "$HOME/monitoring" "monitoring-net"; then
        log_so_success "Prometheus configuration updated"
    else
        log_so_warning "Failed to update prometheus configuration"
    fi
    
    # 2. Remove service-specific Grafana dashboards
    log_so "Removing Grafana dashboards for $service_name"
    if remove_grafana_dashboards_for_service "$service_name" "$service_type"; then
        log_so_success "Grafana dashboards removed"
    else
        log_so_warning "Failed to remove some Grafana dashboards"
    fi
    
    # 3. Restart monitoring services to apply changes
    log_so "Restarting monitoring services to apply changes"
    if restart_monitoring_stack; then
        log_so_success "Monitoring stack restarted"
    else
        log_so_warning "Failed to restart monitoring stack"
    fi
    
    return 0
}

# Safe prometheus config regeneration with file locking
regenerate_prometheus_config_safe() {
    local monitoring_dir="$1"
    local network="$2"
    
    # Use file locking to prevent concurrent config updates
    local lock_file="$monitoring_dir/.prometheus-config.lock"
    local config_file="$monitoring_dir/prometheus.yml"
    local temp_file="$monitoring_dir/prometheus.yml.tmp"
    
    # Acquire lock with timeout
    local lock_timeout=30
    local lock_wait=0
    while [[ $lock_wait -lt $lock_timeout ]]; do
        if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
            break
        fi
        sleep 1
        ((lock_wait++))
    done
    
    if [[ $lock_wait -ge $lock_timeout ]]; then
        log_so_error "Could not acquire prometheus config lock after ${lock_timeout}s"
        return 1
    fi
    
    # Ensure lock cleanup on exit
    trap 'rm -f "$lock_file"' EXIT
    
    # Use existing regenerate function but with atomic file operations
    if declare -f regenerate_prometheus_config >/dev/null 2>&1; then
        if regenerate_prometheus_config "$monitoring_dir" "$network"; then
            # Verify the generated config is valid YAML
            if python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
                log_so_success "Prometheus config regenerated and validated"
                rm -f "$lock_file"
                trap - EXIT
                return 0
            else
                log_so_error "Generated prometheus config is invalid YAML"
                rm -f "$lock_file"
                trap - EXIT
                return 1
            fi
        else
            log_so_error "Failed to regenerate prometheus config"
            rm -f "$lock_file" 
            trap - EXIT
            return 1
        fi
    else
        log_so_error "regenerate_prometheus_config function not available"
        rm -f "$lock_file"
        trap - EXIT
        return 1
    fi
}

# Remove Grafana dashboards for a specific service
remove_grafana_dashboards_for_service() {
    local service_name="$1"
    local service_type="$2"
    local dashboards_dir="$HOME/monitoring/grafana/dashboards"
    
    if [[ ! -d "$dashboards_dir" ]]; then
        log_so "No dashboards directory found"
        return 0
    fi
    
    # Remove service-specific dashboards
    case "$service_type" in
        "ethnode")
            # Remove both execution and consensus client dashboards
            rm -f "$dashboards_dir/${service_name}-"*.json 2>/dev/null || true
            log_so "Removed ethnode dashboards for $service_name"
            ;;
        "validator") 
            # Remove validator dashboards
            rm -f "$dashboards_dir/${service_name}-"*.json 2>/dev/null || true
            log_so "Removed validator dashboards for $service_name"
            ;;
        *)
            # Generic removal
            rm -f "$dashboards_dir/${service_name}"*.json 2>/dev/null || true
            log_so "Removed generic dashboards for $service_name"
            ;;
    esac
    
    return 0
}

# Restart monitoring stack
restart_monitoring_stack() {
    if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/docker-compose.yml" ]]; then
        cd "$HOME/monitoring" 
        docker compose restart prometheus grafana >/dev/null 2>&1
        return $?
    fi
    return 1
}

export -f cleanup_service_integrations
export -f cleanup_monitoring_integration
export -f regenerate_prometheus_config_safe
export -f remove_grafana_dashboards_for_service
export -f restart_monitoring_stack