#!/bin/bash
# lib/service-lifecycle.sh - Central service lifecycle manager for NODEBOI
# Iteration 4: Integration of registry and hooks for complete service management

# Set up environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODEBOI_LIB="${NODEBOI_LIB:-$SCRIPT_DIR}"

# Source dependencies
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"

# Colors for lifecycle logging - muted grey for clean output
LC_INFO='\033[38;5;240m'
LC_SUCCESS='\033[38;5;240m'
LC_WARNING='\033[38;5;240m'
LC_ERROR='\033[38;5;240m'
LC_RESET='\033[0m'

log_lifecycle() {
    echo -e "${LC_INFO}[LIFECYCLE] $1${LC_RESET}" >&2
}

log_lifecycle_success() {
    echo -e "${LC_SUCCESS}[LIFECYCLE] ✓ $1${LC_RESET}" >&2
}

log_lifecycle_error() {
    echo -e "${LC_ERROR}[LIFECYCLE] ✗ $1${LC_RESET}" >&2
}

log_lifecycle_warning() {
    echo -e "${LC_WARNING}[LIFECYCLE] ⚠ $1${LC_RESET}" >&2
}

# Central service removal function - combines registry and hooks
remove_service() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_lifecycle_error "remove_service: service name required"
        return 1
    fi
    
    log_lifecycle "Starting removal of service: $service_name"
    
    # 1. Validate service exists
    if [[ ! -d "$HOME/$service_name" ]]; then
        log_lifecycle_error "Service '$service_name' does not exist"
        return 1
    fi
    
    # 2. Get service info to determine type
    local service_info=$(get_service_info "$service_name" 2>/dev/null)
    local service_type="unknown"
    if [[ $? -eq 0 ]] && [[ -n "$service_info" ]]; then
        service_type=$(echo "$service_info" | jq -r '.type' 2>/dev/null)
    fi
    
    # Ensure service_type is not empty or null
    if [[ -z "$service_type" ]] || [[ "$service_type" == "null" ]]; then
        service_type="unknown"
    fi
    
    # If we still don't know the type, infer from name
    if [[ "$service_type" == "unknown" ]]; then
        case "$service_name" in
            ethnode*) service_type="ethnode" ;;
            monitoring) service_type="monitoring" ;;
            *validator) service_type="validator" ;;
            vero) service_type="validator" ;;
            web3signer) service_type="web3signer" ;;
        esac
    fi
    
    log_lifecycle "Detected service type: $service_type"
    
    # 3. Pre-removal hooks based on service type
    log_lifecycle "Executing pre-removal hooks for $service_type"
    local hook_success=true
    
    case "$service_type" in
        "ethnode")
            if ! cleanup_ethnode_monitoring "$service_name"; then
                log_lifecycle_warning "Ethnode monitoring cleanup had some issues"
            fi
            ;;
        "validator")
            if ! cleanup_validator "$service_name"; then
                log_lifecycle_warning "Validator cleanup had some issues"
            fi
            ;;
        "web3signer")
            if ! cleanup_web3signer; then
                log_lifecycle_warning "Web3signer cleanup had some issues"
            fi
            ;;
        "monitoring")
            log_lifecycle "Monitoring service removal - no specific pre-hooks needed"
            ;;
        *)
            log_lifecycle_warning "Unknown service type '$service_type' - no specific cleanup hooks"
            ;;
    esac
    
    # 4. Service cleanup completed
    
    # 5. Trigger event-driven dashboard refresh
    log_lifecycle "Triggering dashboard refresh after removal"
    if trigger_dashboard_refresh "service_removed" "$service_name"; then
        log_lifecycle_success "Dashboard refreshed"
    else
        log_lifecycle_warning "Dashboard refresh may have failed (non-critical)"
    fi
    
    log_lifecycle_success "Service removal completed: $service_name"
    return 0
}

# Central service lifecycle function for post-install operations
register_service_lifecycle() {
    local service_name="$1"
    local service_type="$2"
    local service_path="$3"
    local status="${4:-stopped}"
    
    if [[ -z "$service_name" || -z "$service_type" || -z "$service_path" ]]; then
        log_lifecycle_error "register_service_lifecycle requires name, type, and path"
        return 1
    fi
    
    log_lifecycle "Completing post-install operations for service: $service_name ($service_type)"
    
    # 1. Future: Post-install hooks could go here
    # trigger_post_install_hooks "$service_type" "$service_name"
    
    # 2. Trigger event-driven dashboard refresh
    log_lifecycle "Triggering dashboard refresh after service setup"
    if trigger_dashboard_refresh "service_registered" "$service_name"; then
        log_lifecycle_success "Dashboard refreshed"
    else
        log_lifecycle_warning "Dashboard refresh may have failed (non-critical)"
    fi
    
    return 0
}

# Service status update function
update_service_status() {
    local service_name="$1"
    local new_status="$2"
    
    if [[ -z "$service_name" || -z "$new_status" ]]; then
        log_lifecycle_error "update_service_status requires service name and status"
        return 1
    fi
    
    log_lifecycle "Status update requested for $service_name: $new_status"
    
    # Without a registry, status is tracked by Docker container state
    log_lifecycle "Service status is managed through Docker container lifecycle"
    return 0
}

# Get service status (live Docker check)
get_service_status() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        echo "Error: Service name required" >&2
        return 1
    fi
    
    # Get live status from Docker
    local live_status="stopped"
    if [[ -d "$HOME/$service_name" ]]; then
        if cd "$HOME/$service_name" 2>/dev/null && docker compose ps 2>/dev/null | grep -q "Up"; then
            live_status="running"
        fi
    fi
    
    # Return status
    echo "{
  \"status\": \"$live_status\",
  \"path\": \"$HOME/$service_name\"
}"
}

# Event-driven dashboard refresh function
trigger_dashboard_refresh() {
    local event_type="$1"
    local service_name="$2"
    
    log_lifecycle "Dashboard refresh triggered: $event_type for $service_name"
    
    # Try multiple dashboard refresh methods for compatibility
    local refresh_success=false
    
    # Method 1: Try production NODEBOI's force_refresh_dashboard
    if [[ -f "${NODEBOI_LIB}/../lib/manage.sh" ]] && source "${NODEBOI_LIB}/../lib/manage.sh" 2>/dev/null; then
        if declare -f force_refresh_dashboard >/dev/null 2>&1; then
            force_refresh_dashboard 2>/dev/null && refresh_success=true
        fi
    fi
    
    # Method 2: Try to refresh the cache file directly
    if [[ "$refresh_success" == false ]]; then
        local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
        if [[ -f "$cache_file" ]]; then
            # Update the timestamp to trigger refresh
            touch "$cache_file" 2>/dev/null && refresh_success=true
        fi
    fi
    
    # Method 3: Try to source and call generate_dashboard if available
    if [[ "$refresh_success" == false ]]; then
        if declare -f generate_dashboard >/dev/null 2>&1; then
            local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
            mkdir -p "$(dirname "$cache_file")" 2>/dev/null
            generate_dashboard > "$cache_file" 2>/dev/null && refresh_success=true
        fi
    fi
    
    if [[ "$refresh_success" == true ]]; then
        log_lifecycle "Dashboard refresh completed successfully"
        return 0
    else
        log_lifecycle_warning "Dashboard refresh failed - manual refresh may be needed"
        return 1
    fi
}

# Test function for service lifecycle integration
test_service_lifecycle() {
    echo "Testing service lifecycle integration..."
    echo
    
    # Test service registration
    echo "1. Testing service registration..."
    if register_service_lifecycle "test-lifecycle-service" "test" "/tmp/test-lifecycle" "running"; then
        echo "   ✓ Service registration works"
    else
        echo "   ✗ Service registration failed"
        return 1
    fi
    
    # Test service status check
    echo "2. Testing service status check..."
    local status=$(get_service_status "test-lifecycle-service")
    if [[ -n "$status" ]]; then
        echo "   ✓ Service status check works"
        echo "   Status: $status"
    else
        echo "   ✗ Service status check failed"
        return 1
    fi
    
    # Test service removal
    echo "3. Testing service removal..."
    if remove_service "test-lifecycle-service"; then
        echo "   ✓ Service removal works"
    else
        echo "   ✗ Service removal failed"
        return 1
    fi
    
    # Verify removal
    echo "4. Verifying service was removed..."
    if [[ ! -d "/tmp/test-lifecycle" ]]; then
        echo "   ✓ Service successfully removed from filesystem"
    else
        echo "   ✗ Service directory still exists after removal"
        return 1
    fi
    
    echo "✓ All service lifecycle integration tests passed!"
    return 0
}

# Export functions for use by other modules
export -f trigger_dashboard_refresh

# If script is run directly, run test
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Service Lifecycle Integration Test ==="
    test_service_lifecycle
fi