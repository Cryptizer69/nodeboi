#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="v0.3.3"
NODEBOI_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODEBOI_LIB="${NODEBOI_HOME}/lib"

# Load all library files (except plugins)
for lib in "${NODEBOI_LIB}"/*.sh; do
    [[ -f "$lib" && "$(basename "$lib")" != "plugins.sh" ]] && source "$lib"
done  

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
PINK='\033[38;5;213m'

# UI Functions
print_header() {
    echo -e "${PINK}${BOLD}"
    cat << "HEADER"
      ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗
      ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║
      ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║
      ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║
      ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║
      ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
HEADER
    echo -e "${NC}"
    echo -e "                      ${CYAN}ETHEREUM NODE AUTOMATION${NC}"
    echo -e "                             ${YELLOW}${SCRIPT_VERSION}${NC}"

    echo
}

press_enter() {
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC} " && read -r
}

# Install service submenu
install_service_menu() {
    while true; do
        local install_options=(
            "Install ethnode"
            "Install monitoring stack" 
            "Back to main menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Install New Service" "${install_options[@]}"); then
            case $selection in
                0) install_node ;;
                1) 
                    # Load monitoring library and install
                    [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh"
                    install_monitoring_plugin_with_dicks
                    ;;
                2) return ;;
            esac
        else
            return
        fi
    done
}

# Manage service submenu
manage_service_menu() {
    while true; do
        local manage_options=()
        
        # Check what services are installed and add appropriate options
        local has_ethnodes=false
        local has_monitoring=false
        
        # Check for ethnodes
        for dir in "$HOME"/ethnode*; do
            if [[ -d "$dir" && -f "$dir/.env" ]]; then
                has_ethnodes=true
                break
            fi
        done
        
        # Check for monitoring
        if [[ -d "$HOME/monitoring" ]]; then
            has_monitoring=true
        fi
        
        # Build menu based on what's installed
        if [[ "$has_ethnodes" == true ]]; then
            manage_options+=("Manage ethnodes")
        fi
        
        if [[ "$has_monitoring" == true ]]; then
            manage_options+=("Manage monitoring")
        fi
        
        manage_options+=("Back to main menu")
        
        # If nothing is installed, show helpful message
        if [[ "$has_ethnodes" == false && "$has_monitoring" == false ]]; then
            clear
            print_header
            echo -e "${YELLOW}No services installed yet${NC}"
            echo 
            echo "Install services first from the main menu"
            press_enter
            return
        fi
        
        local selection
        if selection=$(fancy_select_menu "Manage Services" "${manage_options[@]}"); then
            local option="${manage_options[$selection]}"
            case "$option" in
                "Manage ethnodes") manage_nodes_menu ;;
                "Manage monitoring")
                    [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh"
                    manage_monitoring_menu
                    ;;
                "Back to main menu") return ;;
            esac
        else
            return
        fi
    done
}

# Main menu with service-based structure
main_menu() {
    while true; do
        local menu_options=(
            "Install new service"
            "Manage services"
            "System"
            "Quit"
        )

        local selection
        if selection=$(fancy_select_menu "Main Menu" "${menu_options[@]}"); then
            case $selection in
                0) install_service_menu 
                   # Refresh dashboard after returning from install menu
                   [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache ;;
                1) manage_service_menu 
                   # Refresh dashboard after returning from manage menu  
                   [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache ;;
                2) system_menu ;;
                3) exit 0 ;;
            esac
        else
            # Check return code - 255 is 'q' (quit), 254 is backspace (do nothing)
            local menu_result=$?
            if [[ $menu_result -eq 255 ]]; then
                # User pressed 'q' - exit
                exit 0
            fi
            # For backspace (254) or other codes, just continue the loop
        fi
    done
}

# Manage nodes submenu
manage_nodes_menu() {
    while true; do
        local manage_options=(
            "Start/stop nodes"
            "Update node"
            "Remove node"
            "View logs"
            "View node details"
            "Back to main menu"
        )

        local selection
        if selection=$(fancy_select_menu "Manage Nodes" "${manage_options[@]}"); then
            case $selection in
                0) manage_node_state ;;
                1) update_node ;;
                2) remove_nodes_menu ;;
                3) view_split_screen_logs ;;
                4) show_node_details ;;
                5) return ;;  # Back to main menu
            esac
        else
            return  # User pressed 'q' - back to main menu
        fi
    done
}

# System menu
system_menu() {
    while true; do
        local system_options=(
            "Update system (Linux packages)"
            "Update nodeboi"
            "Clean up orphaned networks"
            "Remove nodeboi"
            "Back to main menu"
        )

        local selection
        if selection=$(fancy_select_menu "System" "${system_options[@]}"); then
            case $selection in
                0) update_system ;;
                1) update_nodeboi ;;
                2) [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && cleanup_orphaned_networks ;;
                3) remove_nodeboi ;;
                4) return ;;  # Back to main menu
            esac
        else
            return  # User pressed 'q' - back to main menu
        fi
    done
}

# Remove nodeboi completely
remove_nodeboi() {
    clear
    print_header
    
    echo -e "\n${RED}${BOLD}⚠️  WARNING: Complete Nodeboi Removal${NC}"
    echo "========================================="
    echo
    
    # Check for running services FIRST
    echo -e "${UI_MUTED}Checking for running services...${NC}"
    local running_services=()
    local has_running=false
    
    # Check for running ethnode containers
    for node_dir in "$HOME"/ethnode*; do
        if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
            local node_name=$(basename "$node_dir")
            if docker ps --filter "name=${node_name}-" --format "{{.Names}}" | grep -q "${node_name}-"; then
                running_services+=("$node_name")
                has_running=true
            fi
        fi
    done
    
    # Check for running monitoring
    if docker ps --filter "name=monitoring-" --format "{{.Names}}" | grep -q "monitoring-"; then
        running_services+=("monitoring")
        has_running=true
    fi
    
    if [[ "$has_running" == true ]]; then
        echo
        echo -e "${RED}${BOLD}ERROR: Cannot remove nodeboi while services are running!${NC}"
        echo "======================================================="
        echo
        echo -e "${YELLOW}The following services are currently running:${NC}"
        for service in "${running_services[@]}"; do
            echo -e "${UI_MUTED}  • $service${NC}"
        done
        echo
        echo -e "${UI_MUTED}Please stop all services first using:${NC}"
        echo -e "${UI_MUTED}  Main Menu → Manage services → Start/stop nodes${NC}"
        echo -e "${UI_MUTED}  Main Menu → Manage services → Manage monitoring → Start/stop monitoring${NC}"
        echo
        press_enter
        return
    fi
    
    echo -e "${GREEN}✓ No running services detected${NC}"
    echo
    echo -e "${YELLOW}This will permanently remove:${NC}"
    echo -e "${UI_MUTED}  • All ethnodes and their data${NC}"
    echo -e "${UI_MUTED}  • Monitoring stack and data${NC}" 
    echo -e "${UI_MUTED}  • All Docker containers and volumes${NC}"
    echo -e "${UI_MUTED}  • All Docker networks created by nodeboi${NC}"
    echo -e "${UI_MUTED}  • The entire nodeboi installation (~/.nodeboi/)${NC}"
    echo -e "${UI_MUTED}  • Any system users created by nodeboi${NC}"
    echo
    echo -e "${RED}${BOLD}THIS CANNOT BE UNDONE!${NC}"
    echo
    
    read -p "Are you absolutely sure you want to remove nodeboi? Type 'REMOVE' to confirm: " -r
    echo
    
    if [[ $REPLY != "REMOVE" ]]; then
        echo -e "${UI_MUTED}Removal cancelled.${NC}"
        press_enter
        return
    fi
    
    echo -e "${UI_MUTED}Removing nodeboi components...${NC}"
    echo
    
    # Remove ethnode directories (services are already stopped)
    echo -e "${UI_MUTED}Cleaning up ethnode directories...${NC}"
    for node_dir in "$HOME"/ethnode*; do
        if [[ -d "$node_dir" ]]; then
            local node_name=$(basename "$node_dir")
            echo -e "${UI_MUTED}  Removing $node_name directory...${NC}"
            rm -rf "$node_dir" 2>/dev/null || sudo rm -rf "$node_dir"
            
            # Remove system user if it exists (legacy cleanup)
            if id "$node_name" &>/dev/null; then
                sudo userdel -r "$node_name" 2>/dev/null || true
            fi
        fi
    done
    
    # Remove monitoring directory (service is already stopped)
    echo -e "${UI_MUTED}Cleaning up monitoring directory...${NC}"
    if [[ -d "$HOME/monitoring" ]]; then
        rm -rf "$HOME/monitoring" 2>/dev/null || sudo rm -rf "$HOME/monitoring"
    fi
    
    # Remove monitoring system user if it exists (legacy cleanup)
    if id "monitoring" &>/dev/null; then
        sudo userdel monitoring 2>/dev/null || true
    fi
    
    # Remove Docker networks created by nodeboi
    echo -e "${UI_MUTED}Removing Docker networks...${NC}"
    docker network ls --format "{{.Name}}" | grep -E "(ethnode|monitoring)" | xargs -r docker network rm 2>/dev/null || true
    
    # Remove nodeboi directory
    echo -e "${UI_MUTED}Removing nodeboi installation...${NC}"
    cd "$HOME"
    rm -rf "$HOME/.nodeboi"
    
    # Remove systemd service if it exists
    if [[ -f "/etc/systemd/system/nodeboi.service" ]]; then
        sudo systemctl disable --now nodeboi 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/nodeboi.service"
        sudo systemctl daemon-reload
    fi
    
    echo
    echo -e "${GREEN}✅ Nodeboi has been completely removed from your system.${NC}"
    echo
    echo -e "${UI_MUTED}Thank you for using nodeboi!${NC}"
    echo
    
    exit 0
}

# Handle command line arguments
case "$1" in
    check-image)
        shift
        client="${1:-teku}"
        version="${2:-24.10.3}"
        echo "Testing Docker image availability for $client:$version"
        if validate_client_version "$client" "$version"; then
            echo -e "${GREEN}✓ Image is available!${NC}"
            exit 0
        else
            echo -e "${RED}✗ Image not found${NC}"
            exit 1
        fi
        ;;
    test)
        echo -e "${UI_MUTED}NODEBOI Test Mode${NC}"
        echo -e "${UI_MUTED}=================${NC}"
        echo -e "${UI_MUTED}Loaded clients:${NC}"
        echo -e "${UI_MUTED}  Execution: ${EXECUTION_CLIENTS[@]}${NC}"
        echo -e "${UI_MUTED}  Consensus: ${CONSENSUS_CLIENTS[@]}${NC}"
        echo
        echo -e "${UI_MUTED}Testing functions:${NC}"
        echo -n -e "${UI_MUTED}  Docker image for teku: ${NC}"
        get_docker_image "teku"
        echo -n -e "${UI_MUTED}  Normalize version v0.2.40 for teku: ${NC}"
        normalize_version "teku" "v0.2.40"
        echo
        echo -e "${GREEN}All systems operational!${NC}"
        ;;
    *)
        check_prerequisites
        
        # Generate dashboard cache SYNCHRONOUSLY at startup to ensure consistency
        echo -e "${UI_MUTED}Initializing dashboard...${NC}"
        if [[ -f "${NODEBOI_LIB}/manage.sh" ]]; then
            source "${NODEBOI_LIB}/manage.sh" && refresh_dashboard_cache
        fi
        
        main_menu
        ;;
esac