#!/bin/bash
# lib/lifecycle-integration.sh - Integration layer between legacy and lifecycle systems
# This ensures legacy code properly uses the lifecycle system

# Load lifecycle system
[[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"

#============================================================================
# Legacy to Lifecycle Router Functions
#============================================================================

# Universal dashboard refresh that routes to appropriate system
universal_dashboard_refresh() {
    local event_type="${1:-manual_refresh}"
    local service_name="${2:-dashboard}"
    
    # Try lifecycle system first (preferred)
    if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
        trigger_dashboard_refresh "$event_type" "$service_name" 2>/dev/null && return 0
    fi
    
    # Fallback to legacy refresh methods
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" 2>/dev/null
        if declare -f force_refresh_dashboard >/dev/null 2>&1; then
            force_refresh_dashboard >/dev/null 2>&1 && return 0
        fi
    fi
    
    # Last resort: direct cache touch
    local cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    if [[ -f "$cache_file" ]]; then
        touch "$cache_file" 2>/dev/null && return 0
    fi
    
    return 1
}

# Route service removals through lifecycle system
universal_service_removal() {
    local service_name="$1"
    local service_type="${2:-auto}"
    
    if [[ -z "$service_name" ]]; then
        echo "Error: Service name required for removal" >&2
        return 1
    fi
    
    # Auto-detect service type if not provided
    if [[ "$service_type" == "auto" ]]; then
        case "$service_name" in
            ethnode*) service_type="ethnode" ;;
            monitoring) service_type="monitoring" ;;
            *validator|vero) service_type="validator" ;;
            web3signer) service_type="web3signer" ;;
            *) service_type="unknown" ;;
        esac
    fi
    
    echo "Removing $service_name (type: $service_type) via lifecycle system..."
    
    # Use lifecycle system if available
    if declare -f remove_service >/dev/null 2>&1; then
        remove_service "$service_name"
    else
        echo "Warning: Lifecycle system not available, falling back to legacy removal" >&2
        return 1
    fi
}

# Standardize monitoring integration calls
universal_monitoring_integration() {
    local action="$1"  # add, remove, sync
    local service_name="$2"
    local service_type="${3:-auto}"
    
    case "$action" in
        "add")
            if declare -f add_grafana_dashboards_for_service >/dev/null 2>&1; then
                add_grafana_dashboards_for_service "$service_name" "$service_type"
            fi
            ;;
        "remove")
            if declare -f cleanup_monitoring_integration >/dev/null 2>&1; then
                cleanup_monitoring_integration "$service_name" "$service_type"
            elif declare -f cleanup_ethnode_monitoring >/dev/null 2>&1; then
                cleanup_ethnode_monitoring "$service_name"
            fi
            ;;
        "sync")
            if declare -f sync_grafana_dashboards >/dev/null 2>&1; then
                sync_grafana_dashboards
            elif declare -f sync_dashboards_with_services >/dev/null 2>&1; then
                sync_dashboards_with_services
            fi
            ;;
    esac
}

#============================================================================
# Legacy Function Compatibility - Replace scattered calls
#============================================================================

# Replace all scattered force_refresh_dashboard calls
force_refresh_dashboard() {
    universal_dashboard_refresh "force_refresh" "legacy_call"
}

# Replace generate_dashboard_background calls
generate_dashboard_background() {
    universal_dashboard_refresh "background_refresh" "legacy_background"
}

# Replace refresh_dashboard_cache calls
refresh_dashboard_cache() {
    universal_dashboard_refresh "cache_refresh" "legacy_cache"
}

#============================================================================
# Export Functions for Global Use
#============================================================================

export -f universal_dashboard_refresh
export -f universal_service_removal
export -f universal_monitoring_integration
export -f force_refresh_dashboard
export -f generate_dashboard_background
export -f refresh_dashboard_cache