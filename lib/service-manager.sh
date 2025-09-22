#!/bin/bash
# lib/service-manager.sh - Main entry point for universal service management
# This is the primary interface that orchestrates all service operations

# Set up environment
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NODEBOI_LIB="${NODEBOI_LIB:-$SCRIPT_DIR}"

# Source all required components
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"
[[ -f "${NODEBOI_LIB}/ulcs.sh" ]] && source "${NODEBOI_LIB}/ulcs.sh"
[[ -f "${NODEBOI_LIB}/lifecycle-hooks.sh" ]] && source "${NODEBOI_LIB}/lifecycle-hooks.sh"
[[ -f "${NODEBOI_LIB}/service-lifecycle.sh" ]] && source "${NODEBOI_LIB}/service-lifecycle.sh"

# Service Manager logging
SM_INFO='\033[0;35m'
SM_SUCCESS='\033[0;32m'
SM_WARNING='\033[1;33m'
SM_ERROR='\033[0;31m'
SM_RESET='\033[0m'

log_sm() {
    echo -e "${SM_INFO}[SERVICE-MGR] $1${SM_RESET}" >&2
}

log_sm_success() {
    echo -e "${SM_SUCCESS}[SERVICE-MGR] ✓ $1${SM_RESET}" >&2
}

log_sm_error() {
    echo -e "${SM_ERROR}[SERVICE-MGR] ✗ $1${SM_RESET}" >&2
}

log_sm_warning() {
    echo -e "${SM_WARNING}[SERVICE-MGR] ⚠ $1${SM_RESET}" >&2
}

# Show completion message and wait for user input
show_completion_message() {
    local operation="$1"
    local service_name="$2" 
    local result="$3"
    
    echo
    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}[✓] ${operation^} complete.${NC}"
        echo
        echo -e "${UI_MUTED}Updating monitoring integration...${NC}"
        echo -e "${GREEN}✓ $service_name ${operation} completed successfully${NC}"
    else
        echo -e "${RED}[✗] ${operation^} failed.${NC}"
        echo -e "${RED}✗ $service_name ${operation} encountered errors - check logs for details${NC}"
    fi
    
    echo
    echo -e "${UI_MUTED}Press Enter to return to NODEBOI main menu...${NC}"
    read -r
    
    # Trigger dashboard refresh when user presses Enter (not automatically)
    if [[ $result -eq 0 ]]; then
        echo -e "${UI_MUTED}Refreshing dashboard...${NC}"
        if declare -f trigger_dashboard_refresh >/dev/null 2>&1; then
            trigger_dashboard_refresh "${operation}_completed" "$service_name" >/dev/null 2>&1 || true
        fi
    fi
}

# Initialize service manager
init_service_manager() {
    log_sm "Initializing universal service manager"
    
    # Initialize service registry
    if declare -f initialize_registry >/dev/null 2>&1; then
        initialize_registry
        log_sm "Service registry initialized"
    else
        log_sm_warning "Service registry not available"
    fi
    
    # Initialize service flows
    if declare -f init_service_flows >/dev/null 2>&1; then
        init_service_flows
        log_sm "Service flows initialized"
    else
        log_sm_warning "Service flows not available"
    fi
    
    log_sm_success "Service manager ready"
    return 0
}

# Main service management interface
manage_service_operation() {
    local operation="$1"
    local service_name="$2"
    shift 2
    local params="$*"
    
    case "$operation" in
        "remove"|"delete"|"uninstall")
            remove_service_operation "$service_name" "$params"
            ;;
        "install"|"create"|"add")
            install_service_operation "$service_name" "$params"
            ;;
        "start")
            start_service_operation "$service_name"
            ;;
        "stop")
            stop_service_operation "$service_name"
            ;;
        "restart")
            restart_service_operation "$service_name"
            ;;
        "update"|"upgrade")
            update_service_operation "$service_name" "$params"
            ;;
        "status"|"info")
            status_service_operation "$service_name"
            ;;
        "list")
            list_services_operation
            ;;
        "plan"|"dry-run")
            plan_service_operation "$service_name" "remove"
            ;;
        *)
            log_sm_error "Unknown operation: $operation"
            show_service_manager_help
            return 1
            ;;
    esac
}

# Service removal operation
remove_service_operation() {
    local service_name="$1"
    local params="$2"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for removal"
        return 1
    fi
    
    # Initialize if not already done
    init_service_manager >/dev/null 2>&1
    
    log_sm "Initiating removal of service: $service_name"
    
    # Determine if this should be interactive based on params
    local interactive="true"
    local with_integrations="true"
    
    # Parse parameters
    for param in $params; do
        case "$param" in
            "--non-interactive"|"-n"|"--yes"|"-y")
                interactive="false"
                ;;
            "--no-integrations"|"--skip-integrations")
                with_integrations="false"
                ;;
            "--quick"|"--fast")
                # Use quick removal (less thorough cleanup)
                if declare -f remove_ethnode_quick >/dev/null 2>&1; then
                    log_sm "Using quick removal mode"
                    remove_ethnode_quick "$service_name"
                    show_completion_message "removal" "$service_name" $?
                    return $?
                fi
                ;;
        esac
    done
    
    # Use universal service removal
    if declare -f remove_service_universal >/dev/null 2>&1; then
        local result
        remove_service_universal "$service_name" "$with_integrations" "$interactive"
        result=$?
        
        # Show completion message and wait for user input
        show_completion_message "removal" "$service_name" $result
        return $result
    else
        log_sm_error "Universal service removal not available"
        return 1
    fi
}

# Service installation operation
install_service_operation() {
    local service_name="$1"
    local params="$2"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for installation"
        return 1
    fi
    
    # Detect service type from name
    local service_type=$(detect_service_type "$service_name")
    if [[ "$service_type" == "unknown" ]]; then
        log_sm_error "Cannot determine service type for: $service_name"
        return 1
    fi
    
    init_service_manager >/dev/null 2>&1
    
    log_sm "Initiating installation of $service_type service: $service_name"
    
    if declare -f install_service_universal >/dev/null 2>&1; then
        install_service_universal "$service_name" "$service_type" "$params"
        return $?
    else
        log_sm_error "Universal service installation not available"
        return 1
    fi
}

# Service start operation
start_service_operation() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for start operation"
        return 1
    fi
    
    init_service_manager >/dev/null 2>&1
    
    if declare -f start_service_universal >/dev/null 2>&1; then
        local result
        start_service_universal "$service_name"
        result=$?
        
        # Show completion message and wait for user input
        show_completion_message "start" "$service_name" $result
        return $result
    else
        log_sm_error "Universal service start not available"
        return 1
    fi
}

# Service stop operation
stop_service_operation() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for stop operation"
        return 1
    fi
    
    init_service_manager >/dev/null 2>&1
    
    if declare -f stop_service_universal >/dev/null 2>&1; then
        local result
        stop_service_universal "$service_name"
        result=$?
        
        # Show completion message and wait for user input
        show_completion_message "stop" "$service_name" $result
        return $result
    else
        log_sm_error "Universal service stop not available"
        return 1
    fi
}

# Service restart operation
restart_service_operation() {
    local service_name="$1"
    
    log_sm "Restarting service: $service_name"
    
    if stop_service_operation "$service_name"; then
        sleep 2
        start_service_operation "$service_name"
        return $?
    else
        log_sm_error "Failed to stop service, aborting restart"
        return 1
    fi
}

# Service update operation
update_service_operation() {
    local service_name="$1"
    local params="$2"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for update operation"
        return 1
    fi
    
    init_service_manager >/dev/null 2>&1
    
    if declare -f update_service_universal >/dev/null 2>&1; then
        update_service_universal "$service_name" "$params"
        return $?
    else
        log_sm_error "Universal service update not available"
        return 1
    fi
}

# Service status operation
status_service_operation() {
    local service_name="$1"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for status operation"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    
    echo -e "${CYAN}Service Status Report${NC}"
    echo -e "${UI_MUTED}===================${NC}"
    echo -e "${UI_MUTED}Service: $service_name${NC}"
    echo -e "${UI_MUTED}Type: $service_type${NC}"
    echo
    
    # Check if service exists
    if [[ -d "$HOME/$service_name" ]]; then
        echo -e "${UI_MUTED}Directory: $HOME/$service_name${NC}"
        
        # Check container status
        local containers=$(docker ps -a --filter "name=${service_name}" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null)
        if [[ -n "$containers" ]]; then
            echo -e "${UI_MUTED}Containers:${NC}"
            echo "$containers" | tail -n +2 | sed 's/^/  /'
        else
            echo -e "${UI_MUTED}No containers found${NC}"
        fi
        
        # Check networks
        local networks=$(docker network ls --filter "name=${service_name}" --format "{{.Name}}" 2>/dev/null)
        if [[ -n "$networks" ]]; then
            echo -e "${UI_MUTED}Networks: $networks${NC}"
        fi
        
        # Check volumes
        local volumes=$(docker volume ls --filter "name=${service_name}" --format "{{.Name}}" 2>/dev/null)
        if [[ -n "$volumes" ]]; then
            echo -e "${UI_MUTED}Volumes: $(echo $volumes | wc -w) volume(s)${NC}"
        fi
        
    else
        echo -e "${YELLOW}Service directory does not exist${NC}"
        return 1
    fi
    
    return 0
}

# List all services operation
list_services_operation() {
    echo -e "${CYAN}NODEBOI Services${NC}"
    echo -e "${UI_MUTED}================${NC}"
    
    local found_services=false
    
    # List ethnodes
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local service_name=$(basename "$dir")
            local status="stopped"
            if cd "$dir" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
                status="running"
            fi
            echo -e "${UI_MUTED}  $service_name (ethnode) - $status${NC}"
            found_services=true
        fi
    done
    
    # List other services
    for service in "monitoring" "vero" "teku-validator" "web3signer"; do
        if [[ -d "$HOME/$service" ]]; then
            local service_type=$(detect_service_type "$service")
            local status="stopped"
            if cd "$HOME/$service" 2>/dev/null && docker compose ps --format "table {{.Service}}\t{{.Status}}" | grep -q "Up"; then
                status="running"
            fi
            echo -e "${UI_MUTED}  $service ($service_type) - $status${NC}"
            found_services=true
        fi
    done
    
    if [[ "$found_services" == false ]]; then
        echo -e "${UI_MUTED}No services found${NC}"
    fi
    
    return 0
}

# Show removal plan operation
plan_service_operation() {
    local service_name="$1"
    local operation="$2"
    
    if [[ -z "$service_name" ]]; then
        log_sm_error "Service name required for plan operation"
        return 1
    fi
    
    if [[ "$operation" != "remove" ]]; then
        log_sm_error "Only removal plans are currently supported"
        return 1
    fi
    
    local service_type=$(detect_service_type "$service_name")
    init_service_manager >/dev/null 2>&1
    
    if declare -f show_service_removal_plan >/dev/null 2>&1; then
        local flow_def=$(get_service_flow "$service_type")
        show_service_removal_plan "$service_name" "$service_type" "$flow_def"
        return $?
    else
        log_sm_error "Service plan functionality not available"
        return 1
    fi
}

# Show help for service manager
show_service_manager_help() {
    echo -e "${CYAN}Universal Service Manager${NC}"
    echo -e "${UI_MUTED}=========================${NC}"
    echo
    echo "Usage: manage_service_operation <operation> <service_name> [options]"
    echo
    echo "Operations:"
    echo "  remove, delete, uninstall  Remove a service completely"
    echo "  install, create, add       Install a new service"
    echo "  start                      Start a service"
    echo "  stop                       Stop a service"
    echo "  restart                    Restart a service"
    echo "  update, upgrade            Update a service"
    echo "  status, info               Show service status"
    echo "  list                       List all services"
    echo "  plan, dry-run             Show what would be removed"
    echo
    echo "Options:"
    echo "  --non-interactive, -n, -y  Skip confirmation prompts"
    echo "  --no-integrations          Skip integration cleanup"
    echo "  --quick, --fast            Use quick removal (less thorough)"
    echo
    echo "Examples:"
    echo "  manage_service_operation remove ethnode1"
    echo "  manage_service_operation remove ethnode2 --non-interactive"
    echo "  manage_service_operation list"
    echo "  manage_service_operation plan ethnode1"
    echo "  manage_service_operation status monitoring"
}

# Command line interface for direct usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        show_service_manager_help
        exit 1
    fi
    
    manage_service_operation "$@"
fi

# Export main function for use by other scripts
export -f manage_service_operation
export -f init_service_manager