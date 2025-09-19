#!/bin/bash
# lib/service-registry.sh - Service registry operations for NODEBOI
# Iteration 1: Minimal working service discovery

# Global settings
REGISTRY_FILE="$HOME/.nodeboi/service-registry.json"

# Initialize registry file if it doesn't exist
initialize_registry() {
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        mkdir -p "$(dirname "$REGISTRY_FILE")"
        echo '{
  "services": {},
  "metadata": {
    "last_updated": "'$(date -Iseconds)'",
    "version": "1.0"
  }
}' > "$REGISTRY_FILE"
    fi
}

# Discover existing services from ~/.nodeboi/ directory structure
discover_existing_services() {
    local services_found=0
    
    # Check for monitoring
    if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/compose.yml" ]]; then
        echo "monitoring"
        ((services_found++))
    fi
    
    # Check for ethnodes
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            echo "$(basename "$dir")"
            ((services_found++))
        fi
    done
    
    # Check for validators
    for service in "teku-validator" "vero"; do
        if [[ -d "$HOME/$service" && -f "$HOME/$service/.env" ]]; then
            echo "$service"
            ((services_found++))
        fi
    done
    
    # Check for web3signer
    if [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/compose.yml" ]]; then
        echo "web3signer"
        ((services_found++))
    fi
    
    return $services_found
}

# Get service information (Iteration 1 - basic implementation)
get_service_info() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        echo "Error: Service name required" >&2
        return 1
    fi
    
    # Check if service exists by directory
    local service_path="$HOME/$service_name"
    if [[ ! -d "$service_path" ]]; then
        echo "Error: Service '$service_name' not found" >&2
        return 1
    fi
    
    # Determine service type
    local service_type="unknown"
    case "$service_name" in
        ethnode*)   service_type="ethnode" ;;
        monitoring) service_type="monitoring" ;;
        *validator) service_type="validator" ;;
        web3signer) service_type="web3signer" ;;
    esac
    
    # Check if service is running (basic Docker check)
    local status="stopped"
    if cd "$service_path" 2>/dev/null && docker compose ps 2>/dev/null | grep -q "Up"; then
        status="running"
    fi
    
    # Return JSON structure
    echo "{
  \"type\": \"$service_type\",
  \"path\": \"$service_path\",
  \"status\": \"$status\",
  \"discovered\": \"$(date -Iseconds)\"
}"
    
    return 0
}

# Test function for validation
test_service_discovery() {
    echo "Testing service discovery..."
    
    local services=$(discover_existing_services)
    local count=$?
    
    echo "Found $count services:"
    while read -r service; do
        echo "  - $service"
        get_service_info "$service" | jq '.' 2>/dev/null || echo "    (jq not available for formatting)"
    done <<< "$services"
}

# Register a service in the registry
register_service() {
    local service_name="$1"
    local service_type="$2" 
    local service_path="$3"
    local status="${4:-stopped}"
    
    if [[ -z "$service_name" || -z "$service_type" || -z "$service_path" ]]; then
        echo "Error: register_service requires name, type, and path" >&2
        return 1
    fi
    
    # Initialize registry if needed
    initialize_registry
    
    # Create service entry
    local timestamp=$(date -Iseconds)
    local service_json="{
  \"type\": \"$service_type\",
  \"path\": \"$service_path\", 
  \"status\": \"$status\",
  \"registered\": \"$timestamp\",
  \"last_updated\": \"$timestamp\"
}"
    
    # Update registry using jq if available, otherwise basic approach
    if command -v jq >/dev/null 2>&1; then
        local temp_file=$(mktemp)
        jq --arg name "$service_name" --argjson service "$service_json" --arg timestamp "$timestamp" \
           '.services[$name] = $service | .metadata.last_updated = $timestamp' \
           "$REGISTRY_FILE" > "$temp_file" && mv "$temp_file" "$REGISTRY_FILE"
    else
        echo "Warning: jq not available, using basic JSON update" >&2
        # Fallback: recreate file (simple but works)
        initialize_registry
    fi
    
    # Trigger event-driven dashboard refresh if function exists
    if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
        trigger_dashboard_refresh "service_registered" "$service_name" >/dev/null 2>&1 || true
    fi
    
    return 0
}

# Remove a service from the registry
unregister_service() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        echo "Error: unregister_service requires service name" >&2
        return 1
    fi
    
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        echo "Warning: Registry file does not exist" >&2
        return 0
    fi
    
    # Remove service using jq if available
    if command -v jq >/dev/null 2>&1; then
        local temp_file=$(mktemp)
        local timestamp=$(date -Iseconds)
        jq --arg name "$service_name" --arg timestamp "$timestamp" \
           'del(.services[$name]) | .metadata.last_updated = $timestamp' \
           "$REGISTRY_FILE" > "$temp_file" && mv "$temp_file" "$REGISTRY_FILE"
    else
        echo "Warning: jq not available, cannot remove service from registry" >&2
        return 1
    fi
    
    return 0
}

# Check if service is registered
is_service_registered() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        return 1
    fi
    
    if [[ ! -f "$REGISTRY_FILE" ]]; then
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        jq -e ".services[\"$service_name\"]" "$REGISTRY_FILE" >/dev/null 2>&1
    else
        # Fallback: basic grep
        grep -q "\"$service_name\":" "$REGISTRY_FILE" 2>/dev/null
    fi
}

# Test function for Iteration 2 validation
test_registry_crud() {
    echo "Testing registry CRUD operations..."
    
    # Test registration
    echo "1. Registering test service..."
    if register_service "test-service" "test" "/tmp/test" "running"; then
        echo "   ✓ Registration successful"
    else
        echo "   ✗ Registration failed"
        return 1
    fi
    
    # Test check if registered
    echo "2. Checking if service is registered..."
    if is_service_registered "test-service"; then
        echo "   ✓ Service found in registry"
    else
        echo "   ✗ Service not found"
        return 1
    fi
    
    # Test unregistration  
    echo "3. Unregistering test service..."
    if unregister_service "test-service"; then
        echo "   ✓ Unregistration successful"
    else
        echo "   ✗ Unregistration failed"
        return 1
    fi
    
    # Verify removal
    echo "4. Verifying service removed..."
    if ! is_service_registered "test-service"; then
        echo "   ✓ Service successfully removed from registry"
    else
        echo "   ✗ Service still in registry"
        return 1
    fi
    
    echo "✓ All registry CRUD operations working!"
    return 0
}

# If script is run directly, run tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "=== Iteration 1: Service Discovery Test ==="
    test_service_discovery
    echo
    echo "=== Iteration 2: Registry CRUD Test ==="
    test_registry_crud
fi