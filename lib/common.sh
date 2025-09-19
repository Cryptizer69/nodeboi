#!/bin/bash
# lib/common.sh - Common utilities and shared functions for NODEBOI

# Load dashboard management system (with circular dependency protection)
if [[ -z "$_COMMON_SH_LOADED" ]]; then
    export _COMMON_SH_LOADED=1
    [[ -f "${NODEBOI_LIB}/grafana-dashboard-management.sh" ]] && source "${NODEBOI_LIB}/grafana-dashboard-management.sh"
    # Load lifecycle integration layer to bridge legacy and new systems
    [[ -f "${NODEBOI_LIB}/lifecycle-integration.sh" ]] && source "${NODEBOI_LIB}/lifecycle-integration.sh"
    # Load lifecycle hooks for service management
    [[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"
fi

# Global settings
export DASHBOARD_CACHE_LOCK="$HOME/.nodeboi/cache/dashboard.lock"

# Standardized logging functions
log_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

log_error() {
    echo -e "${RED}✗ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
}

log_info() {
    echo -e "${UI_MUTED}$1${NC}"
}

# Universal Dashboard Refresh - Routes to lifecycle system first, fallback to legacy
refresh_dashboard() {
    # Lifecycle system first (preferred)
    if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
        trigger_dashboard_refresh "manual_refresh" "dashboard_refresh" 2>/dev/null || true
    # Legacy fallback
    elif [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
    fi
}

# Background dashboard refresh (non-blocking) - lifecycle aware
refresh_dashboard_background() {
    # Lifecycle system first (preferred)
    if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
        trigger_dashboard_refresh "background_refresh" "dashboard_background" 2>/dev/null || true
    # Legacy fallback
    elif [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" && generate_dashboard_background
    fi
}

# Monitoring dashboard refresh utility - function is imported from grafana-dashboard-management.sh

# Service Management - Universal entry point for ALL service operations
# Now integrated with lifecycle system for proper state management
manage_service() {
    local action="$1"
    local service="$2"
    local service_name="${3:-}"
    
    # Auto-detect service directory if not provided
    local service_dir
    if [[ -d "$service" ]]; then
        service_dir="$service"
        service_name="${service_name:-$(basename "$service")}"
    elif [[ -d "$HOME/$service" ]]; then
        service_dir="$HOME/$service" 
        service_name="${service_name:-$service}"
    else
        log_error "Service not found: $service"
        return 1
    fi
    
    # Use the existing safe_docker_compose with event hooks
    safe_docker_compose "$action" "$service_dir" "$service_name"
    local compose_result=$?
    
    # Lifecycle integration: Update service registry status
    if [[ $compose_result -eq 0 ]]; then
        case "$action" in
            "up"|"start")
                if declare -f update_service_status >/dev/null 2>&1; then
                    update_service_status "$service_name" "running" 2>/dev/null || true
                fi
                ;;
            "down"|"stop")
                if declare -f update_service_status >/dev/null 2>&1; then
                    update_service_status "$service_name" "stopped" 2>/dev/null || true
                fi
                ;;
            "restart")
                if declare -f update_service_status >/dev/null 2>&1; then
                    update_service_status "$service_name" "running" 2>/dev/null || true
                fi
                ;;
        esac
    fi
    
    # Lifecycle integration: Trigger dashboard refresh
    case "$action" in
        "up"|"start"|"down"|"stop"|"restart")
            if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
                trigger_dashboard_refresh "service_${action}" "$service_name" 2>/dev/null || true
            elif declare -f refresh_monitoring_dashboards >/dev/null 2>&1; then
                refresh_monitoring_dashboards >/dev/null 2>&1 || true
            fi
            ;;
    esac
    
    return $compose_result
}

# Safe Docker Compose operations with error handling
safe_docker_compose() {
    local action="$1"
    local service_dir="$2"
    local service_name="${3:-}"
    
    if [[ ! -d "$service_dir" ]]; then
        log_error "Directory not found: $service_dir"
        return 1
    fi
    
    cd "$service_dir" || return 1
    
    case "$action" in
        "up")
            # Safety warning for validator services
            if [[ "$service_name" =~ ^(vero|teku-validator)$ ]] || [[ "$service_dir" =~ (vero|teku-validator)$ ]]; then
                if ! validator_safety_warning "$service_name validator"; then
                    log_error "Validator startup cancelled by user"
                    return 1
                fi
            fi
            
            # For ethnode services, start all containers (don't pass service_name as it's not a compose service)
            if [[ "$service_name" =~ ^ethnode[0-9]*$ ]] || [[ "$service_dir" =~ ethnode[0-9]*$ ]]; then
                docker compose up -d
            else
                docker compose up -d $service_name
            fi
            # Monitoring lifecycle hooks
            if [[ "$service_name" == "monitoring" ]] || [[ "$service_dir" =~ monitoring$ ]]; then
                # Pre-start configuration fix
                if declare -f setup_monitoring_on_start >/dev/null; then
                    setup_monitoring_on_start "$service_dir"
                fi
                # Post-start network connections (run in background)
                if declare -f connect_monitoring_networks >/dev/null; then
                    (sleep 5 && connect_monitoring_networks) &
                fi
            fi
            # GDS: Add dashboard immediately when service starts
            if [[ -n "$service_name" ]] && declare -f gds_on_service_start >/dev/null; then
                gds_on_service_start "$service_name" "$service_dir"
            fi
            ;;
        "down")
            # GDS: Remove dashboard immediately when service stops
            if [[ -n "$service_name" ]] && declare -f gds_on_service_stop >/dev/null; then
                gds_on_service_stop "$service_name" "$service_dir"
            fi
            # For ethnode services, stop all containers
            if [[ "$service_name" =~ ^ethnode[0-9]*$ ]] || [[ "$service_dir" =~ ethnode[0-9]*$ ]]; then
                docker compose down
            else
                docker compose down $service_name
            fi
            ;;
        "restart")
            # Safety warning for validator services
            if [[ "$service_name" =~ ^(vero|teku-validator)$ ]] || [[ "$service_dir" =~ (vero|teku-validator)$ ]]; then
                if ! validator_safety_warning "$service_name validator"; then
                    log_error "Validator restart cancelled by user"
                    return 1
                fi
            fi
            
            # GDS: Handle restart as stop then start
            if [[ -n "$service_name" ]] && declare -f gds_on_service_stop >/dev/null; then
                gds_on_service_stop "$service_name" "$service_dir"
            fi
            # For ethnode services, restart all containers
            if [[ "$service_name" =~ ^ethnode[0-9]*$ ]] || [[ "$service_dir" =~ ethnode[0-9]*$ ]]; then
                docker compose down && docker compose up -d
            else
                docker compose down $service_name && docker compose up -d $service_name
            fi
            if [[ -n "$service_name" ]] && declare -f gds_on_service_start >/dev/null; then
                gds_on_service_start "$service_name" "$service_dir"
            fi
            ;;
        "logs")
            docker compose logs -f --tail=20 $service_name
            ;;
        *)
            docker compose "$action" $service_name
            ;;
    esac
}

# Check if a service is running
is_service_running() {
    local service_dir="$1"
    local service_name="$2"
    
    if [[ ! -d "$service_dir" ]]; then
        return 1
    fi
    
    cd "$service_dir" && docker compose ps "$service_name" 2>/dev/null | grep -q "running"
}

# Common pause function
pause_for_user() {
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Standardized error handling
handle_error() {
    local exit_code=$?
    local error_msg="$1"
    local cleanup_func="${2:-}"
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "$error_msg"
        
        # Run cleanup function if provided
        if [[ -n "$cleanup_func" ]] && declare -f "$cleanup_func" > /dev/null; then
            "$cleanup_func"
        fi
        
        return $exit_code
    fi
    
    return 0
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate Docker is running
validate_docker() {
    if ! command_exists docker; then
        log_error "Docker is not installed or not in PATH"
        return 1
    fi
    
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running"
        return 1
    fi
    
    if ! docker compose version >/dev/null 2>&1; then
        log_error "Docker Compose v2 is not available"
        return 1
    fi
    
    return 0
}

# Validator startup safety warning
validator_safety_warning() {
    local operation="$1"
    
    echo
    echo "Validator Startup Warning"
    echo
    echo "Slashing Risk: Starting a validator with keys that are active elsewhere will"
    echo "result in slashing penalties and loss of staked ETH."
    echo
    echo "Doppelganger Protection: Starting a validator immediately after stopping it"
    echo "can trigger doppelganger detection, causing the validator client to quit."
    echo "There's no harm in this but it's an annoyance because you have to restart"
    echo "the client. To avoid this, wait more than 15 minutes."
    echo
    echo "Verification: Check beaconcha.in to confirm your keys have been offline"
    echo "for at least 2 epochs before proceeding."
    echo
    echo "Type PROCEED to confirm you have waited and verified offline status:"
    read -r response
    
    if [[ "${response^^}" == "PROCEED" ]]; then
        echo "Starting $operation..."
        return 0
    else
        echo "Startup cancelled."
        return 1
    fi
}

# Generic confirmation function
confirm_action() {
    local message="$1"
    local default="${2:-n}"
    local response
    
    if [[ "$default" == "y" ]]; then
        read -p "$message [Y/n]: " response
        response=${response:-y}
    else
        read -p "$message [y/N]: " response
        response=${response:-n}
    fi
    
    [[ "$response" =~ ^[Yy]$ ]]
}