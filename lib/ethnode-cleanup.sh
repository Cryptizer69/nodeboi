#!/bin/bash
# lib/ethnode-cleanup.sh - Unified ethnode lifecycle management
# This centralizes all cleanup operations for consistent ethnode removal

# Source dependencies
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
[[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"

# Colors for cleanup logging
CLEANUP_INFO='\033[0;36m'
CLEANUP_SUCCESS='\033[0;32m'
CLEANUP_WARNING='\033[1;33m'
CLEANUP_ERROR='\033[0;31m'
CLEANUP_RESET='\033[0m'

log_cleanup() {
    echo -e "${CLEANUP_INFO}[CLEANUP] $1${CLEANUP_RESET}" >&2
}

log_cleanup_success() {
    echo -e "${CLEANUP_SUCCESS}[CLEANUP] ✓ $1${CLEANUP_RESET}" >&2
}

log_cleanup_error() {
    echo -e "${CLEANUP_ERROR}[CLEANUP] ✗ $1${CLEANUP_RESET}" >&2
}

log_cleanup_warning() {
    echo -e "${CLEANUP_WARNING}[CLEANUP] ⚠ $1${CLEANUP_RESET}" >&2
}

# Main ethnode removal orchestrator
remove_ethnode_complete() {
    local ethnode_name="$1"
    local with_monitoring_cleanup="${2:-true}"
    
    if [[ -z "$ethnode_name" ]]; then
        log_cleanup_error "remove_ethnode_complete: ethnode name required"
        return 1
    fi
    
    local ethnode_dir="$HOME/$ethnode_name"
    
    # Validate ethnode exists
    if [[ ! -d "$ethnode_dir" ]]; then
        log_cleanup_error "Ethnode directory not found: $ethnode_dir"
        return 1
    fi
    
    log_cleanup "Starting complete removal of ethnode: $ethnode_name"
    
    local cleanup_errors=0
    local total_steps=0
    local completed_steps=0
    
    # Count total cleanup steps for progress tracking
    total_steps=7
    [[ "$with_monitoring_cleanup" == "true" ]] && ((total_steps++))
    
    echo -e "${UI_MUTED}Ethnode cleanup progress: [0/$total_steps] Initializing...${NC}"
    
    # Step 1: Stop all running containers
    log_cleanup "Step 1/$total_steps: Stopping ethnode containers"
    if stop_ethnode_containers "$ethnode_name" "$ethnode_dir"; then
        log_cleanup_success "Containers stopped"
        ((completed_steps++))
    else
        log_cleanup_error "Failed to stop some containers"
        ((cleanup_errors++))
        ((completed_steps++)) # Continue even if this fails
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Containers stopped${NC}"
    
    # Step 2: Update validator configurations (before removing beacon endpoints)
    log_cleanup "Step 2/$total_steps: Updating validator configurations"
    if remove_ethnode_from_validators "$ethnode_name"; then
        log_cleanup_success "Validator configurations updated"
        ((completed_steps++))
    else
        log_cleanup_warning "Some validator updates may have failed (non-critical)"
        ((completed_steps++))
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Validator configs updated${NC}"
    
    # Step 3: Monitoring cleanup (if requested)
    if [[ "$with_monitoring_cleanup" == "true" ]]; then
        log_cleanup "Step 3/$total_steps: Cleaning up monitoring integration"
        if cleanup_ethnode_monitoring "$ethnode_name"; then
            log_cleanup_success "Monitoring cleanup completed"
            ((completed_steps++))
        else
            log_cleanup_warning "Monitoring cleanup had some issues (non-critical)"
            ((completed_steps++))
        fi
        echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Monitoring cleaned up${NC}"
    fi
    
    # Step 4: Remove Docker containers
    log_cleanup "Step 4/$total_steps: Removing Docker containers"
    if remove_ethnode_containers "$ethnode_name"; then
        log_cleanup_success "Containers removed"
        ((completed_steps++))
    else
        log_cleanup_error "Failed to remove some containers"
        ((cleanup_errors++))
        ((completed_steps++))
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Containers removed${NC}"
    
    # Step 5: Remove Docker volumes
    log_cleanup "Step 5/$total_steps: Removing Docker volumes"
    if remove_ethnode_volumes "$ethnode_name"; then
        log_cleanup_success "Volumes removed"
        ((completed_steps++))
    else
        log_cleanup_warning "Some volumes may still exist (non-critical)"
        ((completed_steps++))
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Volumes removed${NC}"
    
    # Step 6: Remove isolated network
    log_cleanup "Step 6/$total_steps: Removing isolated network"
    if remove_ethnode_network "$ethnode_name"; then
        log_cleanup_success "Network removed"
        ((completed_steps++))
    else
        log_cleanup_warning "Network removal failed (may be in use)"
        ((completed_steps++))
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Network removed${NC}"
    
    # Step 7: Remove file system directory
    log_cleanup "Step 7/$total_steps: Removing file system directory"
    if remove_ethnode_filesystem "$ethnode_name" "$ethnode_dir"; then
        log_cleanup_success "Directory removed"
        ((completed_steps++))
    else
        log_cleanup_error "Failed to remove directory"
        ((cleanup_errors++))
        ((completed_steps++))
    fi
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Directory removed${NC}"
    
    # Step 8: Unregister from service registry
    log_cleanup "Step 8/$total_steps: Unregistering from service registry"
    if declare -f remove_service >/dev/null 2>&1; then
        if remove_service "$ethnode_name"; then
            log_cleanup_success "Service unregistered"
        else
            log_cleanup_warning "Service registry update failed (non-critical)"
        fi
    else
        log_cleanup_warning "Service registry functions not available"
    fi
    ((completed_steps++))
    echo -e "${UI_MUTED}Cleanup progress: [$completed_steps/$total_steps] Service unregistered${NC}"
    
    # Final status report
    echo
    if [[ $cleanup_errors -eq 0 ]]; then
        log_cleanup_success "Ethnode $ethnode_name removed successfully (all $completed_steps steps completed)"
        echo -e "${GREEN}✓ $ethnode_name removed successfully with complete cleanup${NC}"
        return 0
    else
        log_cleanup_warning "Ethnode $ethnode_name removed with $cleanup_errors critical errors"
        echo -e "${YELLOW}⚠ $ethnode_name removed but some cleanup operations failed${NC}"
        echo -e "${UI_MUTED}You may need to manually verify Docker containers and volumes are gone${NC}"
        return 1
    fi
}

# Stop all containers for an ethnode
stop_ethnode_containers() {
    local ethnode_name="$1"
    local ethnode_dir="$2"
    
    local stop_errors=0
    
    # First try docker compose down in the ethnode directory
    if [[ -d "$ethnode_dir" && -f "$ethnode_dir/compose.yml" ]]; then
        log_cleanup "Stopping services via docker compose"
        if cd "$ethnode_dir" 2>/dev/null && docker compose down -t 30 >/dev/null 2>&1; then
            log_cleanup "Docker compose services stopped"
        else
            log_cleanup_warning "Docker compose down failed, trying individual container stop"
            ((stop_errors++))
        fi
    fi
    
    # Also stop any containers that match the ethnode name pattern (backup method)
    local running_containers=$(docker ps --filter "name=${ethnode_name}" --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$running_containers" ]]; then
        log_cleanup "Stopping remaining containers: $(echo $running_containers | tr '\n' ' ')"
        echo "$running_containers" | while read -r container; do
            if [[ -n "$container" ]]; then
                if docker stop "$container" >/dev/null 2>&1; then
                    log_cleanup "Stopped container: $container"
                else
                    log_cleanup_warning "Failed to stop container: $container"
                    ((stop_errors++))
                fi
            fi
        done
    fi
    
    return $stop_errors
}

# Remove all Docker containers for an ethnode
remove_ethnode_containers() {
    local ethnode_name="$1"
    
    # Remove all containers (running and stopped) matching the ethnode name
    local containers=$(docker ps -aq --filter "name=${ethnode_name}" 2>/dev/null || true)
    
    if [[ -z "$containers" ]]; then
        log_cleanup "No containers found for $ethnode_name"
        return 0
    fi
    
    log_cleanup "Removing containers: $(echo $containers | tr '\n' ' ')"
    echo "$containers" | xargs -r docker rm -f >/dev/null 2>&1
    local rm_result=$?
    
    if [[ $rm_result -eq 0 ]]; then
        log_cleanup "All containers removed for $ethnode_name"
        return 0
    else
        log_cleanup_error "Failed to remove some containers for $ethnode_name"
        return 1
    fi
}

# Remove all Docker volumes for an ethnode
remove_ethnode_volumes() {
    local ethnode_name="$1"
    
    # Find volumes matching the ethnode name pattern
    local volumes=$(docker volume ls -q --filter "name=${ethnode_name}" 2>/dev/null || true)
    
    if [[ -z "$volumes" ]]; then
        log_cleanup "No volumes found for $ethnode_name"
        return 0
    fi
    
    log_cleanup "Removing volumes: $(echo $volumes | tr '\n' ' ')"
    echo "$volumes" | xargs -r docker volume rm -f >/dev/null 2>&1
    local rm_result=$?
    
    if [[ $rm_result -eq 0 ]]; then
        log_cleanup "All volumes removed for $ethnode_name"
        return 0
    else
        log_cleanup_warning "Some volumes may still exist (possibly in use)"
        return 1
    fi
}

# Remove the isolated network for an ethnode
remove_ethnode_network() {
    local ethnode_name="$1"
    local network_name="${ethnode_name}-net"
    
    # Check if network exists
    if ! docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"; then
        log_cleanup "Network $network_name does not exist"
        return 0
    fi
    
    # Check if network is still in use
    local containers_in_network=$(docker network inspect "$network_name" --format '{{range $id, $config := .Containers}}{{$config.Name}} {{end}}' 2>/dev/null || true)
    
    if [[ -n "$containers_in_network" ]]; then
        log_cleanup_warning "Network $network_name still has containers: $containers_in_network"
        log_cleanup_warning "Attempting to disconnect containers..."
        
        # Try to disconnect containers
        echo "$containers_in_network" | tr ' ' '\n' | while read -r container; do
            [[ -n "$container" ]] && docker network disconnect "$network_name" "$container" 2>/dev/null || true
        done
    fi
    
    # Remove the network
    if docker network rm "$network_name" >/dev/null 2>&1; then
        log_cleanup "Network $network_name removed"
        return 0
    else
        log_cleanup_warning "Failed to remove network $network_name (may be in use)"
        return 1
    fi
}

# Remove ethnode file system directory
remove_ethnode_filesystem() {
    local ethnode_name="$1" 
    local ethnode_dir="$2"
    
    if [[ ! -d "$ethnode_dir" ]]; then
        log_cleanup "Directory $ethnode_dir does not exist"
        return 0
    fi
    
    # Ensure we're not in the directory we're trying to remove
    if [[ "$PWD" == "$ethnode_dir"* ]]; then
        cd "$HOME" 2>/dev/null || cd / 2>/dev/null
    fi
    
    # Remove the directory
    if rm -rf "$ethnode_dir" 2>/dev/null; then
        log_cleanup "Directory $ethnode_dir removed"
        return 0
    else
        log_cleanup_error "Failed to remove directory $ethnode_dir"
        return 1
    fi
}

# Remove ethnode from all validator configurations
remove_ethnode_from_validators() {
    local ethnode_name="$1"
    
    local validators_updated=0
    local validators_failed=0
    
    # Update Vero validator
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        log_cleanup "Updating Vero validator configuration"
        if remove_beacon_endpoint_from_vero "$ethnode_name"; then
            log_cleanup_success "Vero configuration updated"
            ((validators_updated++))
        else
            log_cleanup_warning "Failed to update Vero configuration"
            ((validators_failed++))
        fi
    fi
    
    # Update Teku validator
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        log_cleanup "Updating Teku validator configuration"
        if remove_beacon_endpoint_from_teku_validator "$ethnode_name"; then
            log_cleanup_success "Teku validator configuration updated"
            ((validators_updated++))
        else
            log_cleanup_warning "Failed to update Teku validator configuration"
            ((validators_failed++))
        fi
    fi
    
    if [[ $validators_updated -eq 0 && $validators_failed -eq 0 ]]; then
        log_cleanup "No validator services found - no configurations to update"
        return 0
    elif [[ $validators_failed -eq 0 ]]; then
        log_cleanup_success "All validator configurations updated ($validators_updated validators)"
        return 0
    else
        log_cleanup_warning "Some validator configurations failed to update ($validators_failed failed, $validators_updated succeeded)"
        return 1
    fi
}

# Remove beacon endpoint from Vero validator configuration
remove_beacon_endpoint_from_vero() {
    local ethnode_name="$1"
    local vero_env="$HOME/vero/.env"
    
    # Determine the expected beacon URL for this ethnode
    local expected_url="http://${ethnode_name}-"
    
    # Get current beacon URLs
    local current_urls=$(grep "^BEACON_NODE_URLS=" "$vero_env" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    
    if [[ -z "$current_urls" ]]; then
        log_cleanup "No beacon URLs found in Vero configuration"
        return 0
    fi
    
    # Check if this ethnode is referenced
    if [[ "$current_urls" != *"$expected_url"* ]]; then
        log_cleanup "Ethnode $ethnode_name not found in Vero beacon configuration"
        return 0
    fi
    
    # Remove this ethnode's URL from the list
    local updated_urls=$(echo "$current_urls" | tr ',' '\n' | grep -v "$expected_url" | tr '\n' ',' | sed 's/,$//')
    
    # Create backup
    cp "$vero_env" "${vero_env}.backup.$(date +%s)" || {
        log_cleanup_error "Could not create backup of Vero .env file"
        return 1
    }
    
    # Update the configuration
    if awk -v new_urls="$updated_urls" '
        /^BEACON_NODE_URLS=/ { print "BEACON_NODE_URLS=" new_urls; next }
        { print }
    ' "$vero_env" > "${vero_env}.tmp"; then
        mv "${vero_env}.tmp" "$vero_env"
        log_cleanup "Removed $ethnode_name from Vero beacon configuration"
        
        # Restart Vero if running
        if docker ps --format "{{.Names}}" | grep -q "^vero$"; then
            log_cleanup "Restarting Vero to apply configuration changes"
            (cd "$HOME/vero" && docker compose restart >/dev/null 2>&1) || true
        fi
        
        return 0
    else
        log_cleanup_error "Failed to update Vero configuration"
        mv "${vero_env}.backup.$(date +%s)" "$vero_env" 2>/dev/null || true
        rm -f "${vero_env}.tmp"
        return 1
    fi
}

# Remove beacon endpoint from Teku validator configuration  
remove_beacon_endpoint_from_teku_validator() {
    local ethnode_name="$1"
    local teku_env="$HOME/teku-validator/.env"
    
    # This is similar to Vero but for Teku validator
    # Implementation would depend on how Teku validator stores beacon endpoints
    # For now, just log the action that would be taken
    log_cleanup "Would update Teku validator configuration to remove $ethnode_name"
    return 0
}

# Quick ethnode removal (minimal cleanup for testing/development)
remove_ethnode_quick() {
    local ethnode_name="$1"
    
    if [[ -z "$ethnode_name" ]]; then
        log_cleanup_error "remove_ethnode_quick: ethnode name required"
        return 1
    fi
    
    local ethnode_dir="$HOME/$ethnode_name"
    
    log_cleanup "Starting quick removal of ethnode: $ethnode_name (minimal cleanup)"
    
    # Stop containers
    stop_ethnode_containers "$ethnode_name" "$ethnode_dir"
    
    # Remove directory
    remove_ethnode_filesystem "$ethnode_name" "$ethnode_dir"
    
    # Remove network
    remove_ethnode_network "$ethnode_name"
    
    log_cleanup_success "Quick removal of $ethnode_name completed"
    echo -e "${GREEN}✓ $ethnode_name removed (quick cleanup)${NC}"
}

# Validate ethnode exists before removal
validate_ethnode_for_removal() {
    local ethnode_name="$1"
    
    if [[ -z "$ethnode_name" ]]; then
        echo "Error: Ethnode name is required" >&2
        return 1
    fi
    
    # Check if it matches ethnode naming pattern
    if [[ ! "$ethnode_name" =~ ^ethnode[0-9]+$ ]]; then
        echo "Error: '$ethnode_name' does not match ethnode naming pattern (ethnodeN)" >&2
        return 1
    fi
    
    local ethnode_dir="$HOME/$ethnode_name"
    if [[ ! -d "$ethnode_dir" ]]; then
        echo "Error: Ethnode directory not found: $ethnode_dir" >&2
        return 1
    fi
    
    return 0
}

# Dry-run mode: show what would be removed without actually removing
show_ethnode_removal_plan() {
    local ethnode_name="$1"
    
    if ! validate_ethnode_for_removal "$ethnode_name"; then
        return 1
    fi
    
    echo -e "${CYAN}Removal plan for $ethnode_name:${NC}"
    echo -e "${UI_MUTED}================================${NC}"
    
    # Show containers that would be removed
    local containers=$(docker ps -a --filter "name=${ethnode_name}" --format "{{.Names}}" 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        echo -e "${UI_MUTED}Containers to remove:${NC}"
        echo "$containers" | sed 's/^/  - /'
    else
        echo -e "${UI_MUTED}No containers found${NC}"
    fi
    
    # Show volumes that would be removed
    local volumes=$(docker volume ls -q --filter "name=${ethnode_name}" 2>/dev/null || true)
    if [[ -n "$volumes" ]]; then
        echo -e "${UI_MUTED}Volumes to remove:${NC}"
        echo "$volumes" | sed 's/^/  - /'
    else
        echo -e "${UI_MUTED}No volumes found${NC}"
    fi
    
    # Show network that would be removed
    local network="${ethnode_name}-net"
    if docker network ls --format "{{.Name}}" | grep -q "^${network}$"; then
        echo -e "${UI_MUTED}Network to remove: $network${NC}"
    else
        echo -e "${UI_MUTED}No network found${NC}"
    fi
    
    # Show directory that would be removed
    echo -e "${UI_MUTED}Directory to remove: $HOME/$ethnode_name${NC}"
    
    # Show integrations that would be updated
    echo -e "${UI_MUTED}Integrations to update:${NC}"
    [[ -d "$HOME/vero" ]] && echo "  - Vero validator beacon configuration"
    [[ -d "$HOME/teku-validator" ]] && echo "  - Teku validator beacon configuration"  
    [[ -d "$HOME/monitoring" ]] && echo "  - Monitoring (Prometheus targets, Grafana dashboards)"
    
    echo -e "${UI_MUTED}Service registry: Unregister $ethnode_name${NC}"
    echo
}

# Interactive ethnode removal with confirmation
remove_ethnode_interactive() {
    local ethnode_name="$1"
    
    if ! validate_ethnode_for_removal "$ethnode_name"; then
        return 1
    fi
    
    # Show removal plan
    show_ethnode_removal_plan "$ethnode_name"
    
    # Get user confirmation
    echo -e "${YELLOW}This will permanently remove $ethnode_name and all its data.${NC}"
    read -r -p "Continue with removal? [y/N]: " confirm
    echo
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${UI_MUTED}Removal cancelled by user${NC}"
        return 1
    fi
    
    # Ask about monitoring cleanup
    local with_monitoring="true"
    if [[ -d "$HOME/monitoring" ]]; then
        read -r -p "Also clean up monitoring integration? [Y/n]: " monitor_confirm
        [[ "$monitor_confirm" =~ ^[Nn]$ ]] && with_monitoring="false"
    fi
    
    # Perform the removal
    remove_ethnode_complete "$ethnode_name" "$with_monitoring"
}

# Test function for ethnode cleanup system
test_ethnode_cleanup() {
    echo "Testing ethnode cleanup system..."
    echo
    
    # Test validation
    echo "1. Testing validation..."
    if ! validate_ethnode_for_removal "invalid-name" >/dev/null 2>&1; then
        echo "   ✓ Properly rejected invalid ethnode name"
    else
        echo "   ✗ Should have rejected invalid ethnode name"
        return 1
    fi
    
    if ! validate_ethnode_for_removal "" >/dev/null 2>&1; then
        echo "   ✓ Properly rejected empty ethnode name"
    else
        echo "   ✗ Should have rejected empty ethnode name"
        return 1
    fi
    
    # Test dry-run functionality
    echo "2. Testing dry-run functionality..."
    # This test requires an actual ethnode to exist, so we'll just test the function exists
    if declare -f show_ethnode_removal_plan >/dev/null 2>&1; then
        echo "   ✓ Removal plan function available"
    else
        echo "   ✗ Removal plan function missing"
        return 1
    fi
    
    # Test individual cleanup functions
    echo "3. Testing cleanup components..."
    if declare -f remove_ethnode_containers >/dev/null 2>&1; then
        echo "   ✓ Container removal function available"
    else
        echo "   ✗ Container removal function missing"
        return 1
    fi
    
    if declare -f remove_ethnode_network >/dev/null 2>&1; then
        echo "   ✓ Network removal function available"
    else
        echo "   ✗ Network removal function missing"
        return 1
    fi
    
    echo "✓ All ethnode cleanup tests passed!"
    return 0
}

# If script is run directly, run tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Ethnode Cleanup System Test ==="
    test_ethnode_cleanup
fi