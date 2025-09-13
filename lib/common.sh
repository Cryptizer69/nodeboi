#!/bin/bash
# lib/common.sh - Common utilities and shared functions for NODEBOI

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

# Dashboard refresh utility - centralize the repeated pattern
refresh_dashboard() {
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
    fi
}

# Background dashboard refresh (non-blocking)
refresh_dashboard_background() {
    if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
        (source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1) &
    fi
}

# Monitoring dashboard refresh utility
refresh_monitoring_dashboards() {
    if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
    fi
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
            docker compose up -d $service_name
            ;;
        "down")
            docker compose down $service_name
            ;;
        "restart")
            docker compose down $service_name && docker compose up -d $service_name
            ;;
        "logs")
            docker compose logs -f $service_name
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