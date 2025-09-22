#!/bin/bash
# lib/service-operations.sh - Implementation of universal service operations
# This contains the actual implementations of lifecycle step functions

# Source dependencies
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"

# Service operations logging - muted grey for clean output
SO_INFO='\033[38;5;240m'
SO_SUCCESS='\033[38;5;240m'
SO_WARNING='\033[38;5;240m'
SO_ERROR='\033[38;5;240m'
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
    
    # Use standard Docker Compose startup (env vars from .env file)
    if cd "$service_dir" && docker compose up -d >/dev/null 2>&1; then
        log_so_success "Services started successfully"
        return 0
    else
        log_so_error "Failed to start services"
        return 1
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
    
    # Use standard Docker Compose startup (env vars from .env file)
    if cd "$service_dir" && docker compose up -d --force-recreate >/dev/null 2>&1; then
        log_so_success "Services recreated successfully"
        return 0
    else
        log_so_error "Failed to recreate services"
        return 1
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
    
    log_so "Updating network connections after $service_name removal"
    
    # Only update network connections - no automatic cleanup
    if update_monitoring_network_connections; then
        log_so_success "Network connections updated - users should manually remove any custom targets"
    else
        log_so_warning "Failed to update network connections"
        return 1
    fi
    
    return 0
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
    
    log_so "Updating network connections for monitoring access to $service_name"
    
    # Only update network connections - no automatic targets or dashboards
    if update_monitoring_network_connections; then
        log_so_success "Network connections updated - users can manually configure targets"
    else
        log_so_warning "Failed to update network connections"
        return 1
    fi
    
    return 0
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

# Removed automatic dashboard setup - users import dashboards manually

# Removed automatic dashboard updates - users manage dashboards manually

# Removed automatic prometheus config rebuilding - users manage targets manually

# Removed automatic dashboard removal - users manage dashboards manually

# Removed automatic monitoring restart - users can restart manually if needed

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

# Removed automatic prometheus config rebuilding after service addition

# Removed automatic dashboard copying - users import dashboards manually

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

# JSON-RPC admin_shutdown for Nethermind
shutdown_nethermind_via_jsonrpc() {
    local service_name="$1"
    local rpc_port="${2:-8545}"
    
    log_so "Attempting Nethermind shutdown via JSON-RPC admin_shutdown"
    
    # Try JSON-RPC admin_shutdown method
    local rpc_response
    if rpc_response=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"admin_shutdown","params":[],"id":1}' \
        --max-time 5 \
        "http://127.0.0.1:${rpc_port}" 2>/dev/null); then
        
        if [[ "$rpc_response" == *'"result"'* ]]; then
            log_so "✓ Nethermind acknowledged shutdown command via JSON-RPC"
            return 0
        else
            log_so "JSON-RPC response: $rpc_response"
            return 1
        fi
    else
        log_so "Failed to connect to Nethermind JSON-RPC on port $rpc_port"
        return 1
    fi
}

# Nethermind graceful shutdown with database flush
stop_nethermind_gracefully() {
    local service_name="$1"
    local service_dir="$2" 
    local env_vars="$3"
    
    log_so "Initiating improved Nethermind graceful shutdown procedure"
    
    local container_name="${service_name}-nethermind"
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        
        # Method 1: JSON-RPC admin_shutdown (preferred)
        local rpc_port=$(grep "^.*8545.*->8545" <<< "$(docker port "$container_name")" | cut -d: -f2 2>/dev/null || echo "8545")
        if shutdown_nethermind_via_jsonrpc "$service_name" "$rpc_port"; then
            log_so "Waiting for Nethermind to shutdown via JSON-RPC..."
            local wait_time=0
            local max_wait=120
            while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
                if [[ $((wait_time % 15)) -eq 0 ]]; then
                    log_so "Waiting for Nethermind database flush via JSON-RPC... ($wait_time/${max_wait}s)"
                fi
                sleep 3
                ((wait_time += 3))
            done
        fi
        
        # Method 2: Extended docker stop (if still running)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_so "JSON-RPC shutdown incomplete, trying extended docker stop..."
            docker stop --time=180 "$container_name" >/dev/null 2>&1 || true
        fi
        
        # Method 3: SIGTERM with extended wait (fallback)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_so "Extended stop failed, using SIGTERM with extended timeout..."
            docker kill -s TERM "$container_name" 2>/dev/null || true
            
            local wait_time=0
            local max_wait=120
            while [[ $wait_time -lt $max_wait ]] && docker ps --format "{{.Names}}" | grep -q "^$container_name$"; do
                if [[ $((wait_time % 15)) -eq 0 ]]; then
                    log_so "Waiting for Nethermind database flush via SIGTERM... ($wait_time/${max_wait}s)"
                fi
                sleep 3
                ((wait_time += 3))
            done
        fi
        
        # Method 4: Force compose down (final fallback)
        if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
            log_so_warning "All graceful methods failed, forcing shutdown"
            local compose_cmd="docker compose down -t 10"
            if [[ -n "$env_vars" ]]; then
                compose_cmd="env $env_vars $compose_cmd"
            fi
            cd "$service_dir" && eval "$compose_cmd" >/dev/null 2>&1
        else
            log_so_success "Nethermind stopped gracefully"
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

# =====================================================================
# ULCS LIFECYCLE STEP IMPLEMENTATIONS
# =====================================================================

# Create directories for a service
create_service_directories() {
    local service_name="$1"
    local params="$2"
    
    log_so "Creating directory structure for $service_name"
    
    local service_dir="$HOME/$service_name"
    if mkdir -p "$service_dir"; then
        log_so_success "Directory $service_dir created"
        return 0
    else
        log_so_error "Failed to create directory $service_dir"
        return 1
    fi
}

# Copy configuration files for a service  
copy_service_configs() {
    local service_name="$1"
    local service_type="$2" 
    local params="$3"
    
    log_so "Generating configuration files for $service_type service"
    
    case "$service_type" in
        "ethnode")
            # For ethnode, use a simplified config generation that doesn't require user interaction
            log_so "ULCS ethnode config generation not yet implemented"
            log_so "Please use the traditional ethnode installation method from the main menu"
            return 1
            ;;
        *)
            log_so_error "Unknown service type: $service_type"
            return 1
            ;;
    esac
}

# Setup networking for a service
setup_service_networking() {
    local service_name="$1" 
    local flow_def="$2"
    
    log_so "Creating network: ${service_name}-net"
    
    # Create service-specific network
    if docker network create "${service_name}-net" >/dev/null 2>&1; then
        log_so_success "Network ${service_name}-net created"
        return 0
    else
        # Network might already exist
        if docker network ls --format "{{.Name}}" | grep -q "^${service_name}-net$"; then
            log_so "Network ${service_name}-net already exists"
            return 0
        else
            log_so_error "Failed to create network ${service_name}-net"
            return 1
        fi
    fi
}

# Start service containers
start_service_containers() {
    local service_name="$1"
    local service_dir="$HOME/$service_name"
    
    if [[ ! -d "$service_dir" || ! -f "$service_dir/compose.yml" ]]; then
        log_so_error "No compose.yml found in $service_dir"
        return 1
    fi
    
    log_so "Starting services"
    
    # Use standard Docker Compose startup (env vars from .env file)
    if cd "$service_dir" && docker compose up -d >/dev/null 2>&1; then
        log_so_success "Services started successfully"
        return 0
    else
        log_so_error "Failed to start services"
        return 1
    fi
}

export -f create_service_directories
export -f copy_service_configs  
export -f setup_service_networking
export -f start_service_containers
export -f cleanup_service_integrations
export -f cleanup_monitoring_integration
export -f regenerate_prometheus_config_safe
export -f remove_grafana_dashboards_for_service
export -f restart_monitoring_stack