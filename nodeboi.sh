#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="v0.4.1"
NODEBOI_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODEBOI_LIB="${NODEBOI_HOME}/lib"

# Load all library files (except plugins)
for lib in "${NODEBOI_LIB}"/*.sh; do
    [[ -f "$lib" && "$(basename "$lib")" != "plugins.sh" ]] && source "$lib"
done  

# Check if Web3signer is properly installed (not just partial/aborted installation)
is_web3signer_properly_installed() {
    local web3signer_dir="$HOME/web3signer"
    
    # Check if directory exists
    [[ ! -d "$web3signer_dir" ]] && return 1
    
    # Check for essential files that indicate complete installation
    [[ ! -f "$web3signer_dir/compose.yml" ]] && return 1
    [[ ! -f "$web3signer_dir/.env" ]] && return 1
    [[ ! -f "$web3signer_dir/import-keys.sh" ]] && return 1
    [[ ! -d "$web3signer_dir/web3signer_config" ]] && return 1
    
    return 0
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
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
        local install_options=("Install new ethnode")
        
        # Add Web3signer option if not installed
        if ! is_web3signer_properly_installed; then
            install_options+=("Install Web3signer")
        fi
        
        # Always show validator option (after Web3signer option)
        install_options+=("Install validator")
        
        # Add monitoring option if not installed
        if [[ ! -d "$HOME/monitoring" || ! -f "$HOME/monitoring/docker-compose.yml" ]]; then
            install_options+=("Install monitoring")
        fi
        
        install_options+=("Back to main menu")
        
        local selection
        if selection=$(fancy_select_menu "Install New Service" "${install_options[@]}"); then
            local selected_option="${install_options[$selection]}"
            
            case "$selected_option" in
                "Install new ethnode")
                    install_node
                    ;;
                "Install Web3signer")
                    [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
                    install_web3signer
                    ;;
                "Install validator")
                    if is_web3signer_properly_installed; then
                        install_validator_submenu
                    else
                        echo -e "${RED}✗ Install Web3signer first before launching a validator client${NC}"
                        pause_for_user
                    fi
                    ;;
                "Install monitoring")
                    [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh"
                    install_monitoring_services_with_dicks
                    ;;
                "Back to main menu")
                    return
                    ;;
            esac
        else
            return
        fi
    done
}

# Install validator submenu
install_validator_submenu() {
    while true; do
        local validator_options=()
        
        # Add Vero if not already installed
        if [[ ! -d "$HOME/vero" ]]; then
            validator_options+=("Install Vero")
        fi
        
        # Add Teku (placeholder for future implementation)
        validator_options+=("Install Teku (coming soon)")
        validator_options+=("Back to install menu")
        
        local selection
        if selection=$(fancy_select_menu "Install Validator Client" "${validator_options[@]}"); then
            local selected_option="${validator_options[$selection]}"
            
            case "$selected_option" in
                "Install Vero")
                    [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
                    install_vero
                    ;;
                "Install Teku (coming soon)")
                    echo -e "${YELLOW}Teku validator client support is coming soon!${NC}"
                    press_enter
                    ;;
                "Back to install menu")
                    return
                    ;;
            esac
        else
            return
        fi
    done
}

# Manage Web3signer submenu
manage_web3signer_menu() {
    while true; do
        # Check if Web3signer is running to show appropriate start/stop option
        local is_running=false
        if cd ~/web3signer 2>/dev/null && docker compose ps web3signer 2>/dev/null | grep -q "Up"; then
            is_running=true
        fi
        
        local start_stop_option
        if [[ "$is_running" == "true" ]]; then
            start_stop_option="Stop Web3signer"
        else
            start_stop_option="Start Web3signer"
        fi
        
        local web3signer_options=(
            "$start_stop_option"
            "View logs"
            "Add keys"
            "Remove keys"
            "Update Web3signer"
            "Remove Web3signer"
            "Back to manage menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Manage Web3signer" "${web3signer_options[@]}"); then
            local selected_option="${web3signer_options[$selection]}"
            
            case "$selected_option" in
                "Start Web3signer")
                    echo -e "${UI_MUTED}Starting Web3signer...${NC}"
                    cd ~/web3signer && docker compose up -d
                    echo -e "${GREEN}✓ Web3signer started${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
                    [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
                    press_enter
                    ;;
                "Stop Web3signer")
                    echo -e "${UI_MUTED}Stopping Web3signer...${NC}"
                    cd ~/web3signer && docker compose down
                    echo -e "${GREEN}✓ Web3signer stopped${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
                    press_enter
                    ;;
                "View logs")
                    echo -e "${UI_MUTED}Showing Web3signer logs (Ctrl+C to exit)...${NC}"
                    cd ~/web3signer && docker compose logs -f web3signer
                    ;;
                "Add keys")
                    echo -e "${CYAN}Add Validator Keys${NC}"
                    echo "=================="
                    echo
                    [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
                    interactive_key_import
                    ;;
                "Remove keys")
                    echo -e "${CYAN}Remove Validator Keys${NC}"
                    echo "====================="
                    echo
                    echo "This will list and allow you to remove validator keys from Web3signer."
                    echo -e "${YELLOW}⚠️  WARNING: Removed keys cannot be used for validation${NC}"
                    echo
                    if fancy_confirm "Continue with key removal?" "n"; then
                        # Call the remove keys script
                        if [[ -f ~/web3signer/remove-keys.sh ]]; then
                            cd ~/web3signer && ./remove-keys.sh
                        else
                            echo -e "${RED}Remove keys script not found${NC}"
                            echo "This feature may not be fully implemented yet."
                        fi
                    fi
                    press_enter
                    ;;
                "Update Web3signer")
                    [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
                    update_web3signer
                    ;;
                "Remove Web3signer")
                    [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
                    remove_web3signer
                    # Return to main menu after removal since Web3signer management no longer makes sense
                    return
                    ;;
                "Back to manage menu")
                    return
                    ;;
            esac
        else
            return
        fi
    done
}

# Manage Vero submenu
manage_vero_menu() {
    while true; do
        # Check Vero status dynamically
        local vero_status=""
        if cd ~/vero 2>/dev/null && docker compose ps | grep -q "vero.*running"; then
            vero_status="Stop Vero"
        else
            vero_status="Start Vero"
        fi
        
        local vero_options=(
            "$vero_status"
            "View logs"
            "Manage beacon endpoints"
            "Update fee recipient"
            "Remove Vero"
            "Back to manage menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Manage Vero" "${vero_options[@]}"); then
            local selected_option="${vero_options[$selection]}"
            
            case "$selected_option" in
                "Start Vero")
                    echo -e "${UI_MUTED}Starting Vero...${NC}"
                    cd ~/vero && docker compose up -d
                    echo -e "${GREEN}✓ Vero started${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
                    [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
                    press_enter
                    ;;
                "Stop Vero")
                    echo -e "${UI_MUTED}Stopping Vero...${NC}"
                    cd ~/vero && docker compose down
                    echo -e "${GREEN}✓ Vero stopped${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
                    press_enter
                    ;;
                "Start/Stop Vero")
                    # Legacy fallback - check status and toggle
                    if cd ~/vero && docker compose ps | grep -q "vero.*running"; then
                        echo -e "${UI_MUTED}Stopping Vero...${NC}"
                        docker compose down
                        echo -e "${GREEN}✓ Vero stopped${NC}"
                    else
                        echo -e "${UI_MUTED}Starting Vero...${NC}"
                        docker compose up -d
                        echo -e "${GREEN}✓ Vero started${NC}"
                        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
                        [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
                    fi
                    press_enter
                    ;;
                "View logs")
                    echo -e "${UI_MUTED}Showing Vero logs (Ctrl+C to exit)...${NC}"
                    cd ~/vero && docker compose logs -f vero
                    ;;
                "Manage beacon endpoints")
                    echo -e "${YELLOW}Beacon endpoint management coming soon!${NC}"
                    echo -e "${UI_MUTED}For now, edit ~/vero/.env manually and restart Vero${NC}"
                    press_enter
                    ;;
                "Update fee recipient")
                    update_vero_fee_recipient
                    ;;
                "Remove Vero")
                    remove_vero
                    # Return to main menu after removal since Vero management no longer makes sense
                    return
                    ;;
                "Back to manage menu")
                    return
                    ;;
            esac
        else
            return
        fi
    done
}

# Update Vero fee recipient
update_vero_fee_recipient() {
    echo -e "${CYAN}Update Fee Recipient${NC}"
    echo "===================="
    echo
    
    # Get current fee recipient
    local current_recipient=$(grep "FEE_RECIPIENT=" ~/vero/.env | cut -d'=' -f2)
    echo -e "${UI_MUTED}Current fee recipient: ${current_recipient}${NC}"
    echo
    
    # Get new fee recipient
    local new_recipient
    new_recipient=$(fancy_text_input "Update Fee Recipient" \
        "Enter new fee recipient address:" \
        "$current_recipient" \
        "")
    
    # Validate format
    if [[ ! "$new_recipient" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo -e "${RED}Invalid fee recipient address format${NC}"
        press_enter
        return 1
    fi
    
    # Update .env file
    sed -i "s/FEE_RECIPIENT=.*/FEE_RECIPIENT=${new_recipient}/" ~/vero/.env
    
    echo -e "${GREEN}✓ Fee recipient updated${NC}"
    echo -e "${YELLOW}⚠️  Restart Vero to apply changes${NC}"
    echo
    
    if fancy_confirm "Restart Vero now?" "y"; then
        cd ~/vero && docker compose down vero && docker compose up -d vero
        echo -e "${GREEN}✓ Vero restarted with new fee recipient${NC}"
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard > /dev/null 2>&1
        [[ -f "${NODEBOI_LIB}/monitoring.sh" ]] && source "${NODEBOI_LIB}/monitoring.sh" && refresh_monitoring_dashboards > /dev/null 2>&1
        
        # Refresh dashboard cache to show updated status  
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    fi
    
    press_enter
}

# Manage service submenu
manage_service_menu() {
    while true; do
        local manage_options=()
        
        # Check what services are installed and add appropriate options
        local has_ethnodes=false
        local has_monitoring=false
        local has_web3signer=false
        local has_vero=false
        
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
        
        # Check for validator services
        if [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/.env" ]]; then
            has_web3signer=true
        fi
        
        if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
            has_vero=true
        fi
        
        # Build menu based on what's installed
        if [[ "$has_ethnodes" == true ]]; then
            manage_options+=("Manage ethnodes")
        fi
        
        if [[ "$has_web3signer" == true ]]; then
            manage_options+=("Manage Web3signer")
        fi
        
        if [[ "$has_vero" == true ]]; then
            manage_options+=("Manage Vero")
        fi
        
        if [[ "$has_monitoring" == true ]]; then
            manage_options+=("Manage monitoring")
        fi
        
        manage_options+=("Back to main menu")
        
        # If nothing is installed, show helpful message
        if [[ "$has_ethnodes" == false && "$has_monitoring" == false && "$has_web3signer" == false && "$has_vero" == false ]]; then
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
                "Manage Web3signer") manage_web3signer_menu ;;
                "Manage Vero") manage_vero_menu ;;
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
    
    echo -e "\n${YELLOW}${BOLD}⚠️  WARNING: Uninstalling Nodeboi${NC}"
    echo "=================================="
    echo
    echo -e "${GREEN}${BOLD}IMPORTANT:${NC} Nodeboi is just a management wrapper."
    echo -e "Your running services will ${GREEN}${BOLD}continue running normally${NC}."
    echo -e "This only removes the ~/.nodeboi/ directory and management tools."
    echo
    echo -e "After uninstall, manage services directly with Docker Compose:"
    echo -e "${UI_MUTED}  • docker compose -f ~/ethnode1/compose.yml up/down${NC}"
    echo -e "${UI_MUTED}  • docker compose -f ~/monitoring/compose.yml up/down${NC}"
    echo
    
    # First require password confirmation
    echo -e "${YELLOW}For security, please enter your user password:${NC}"
    if ! sudo -v 2>/dev/null; then
        echo -e "${RED}Password verification failed. Removal cancelled.${NC}"
        press_enter
        return
    fi
    
    echo
    read -p "Are you absolutely sure you want to remove nodeboi? Type 'REMOVE' to confirm: " -r
    echo
    
    if [[ $REPLY != "REMOVE" ]]; then
        echo -e "${UI_MUTED}Removal cancelled.${NC}"
        press_enter
        return
    fi
    
    echo -e "${UI_MUTED}Uninstalling nodeboi management tools...${NC}"
    
    # Remove nodeboi directory
    echo -e "${UI_MUTED}Removing nodeboi installation...${NC}"
    cd "$HOME"
    rm -rf "$HOME/.nodeboi"
    
    # Remove systemd service if it exists
    if [[ -f "/etc/systemd/system/nodeboi.service" ]]; then
        echo -e "${UI_MUTED}Removing system service (requires admin permissions)...${NC}"
        sudo systemctl disable --now nodeboi 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/nodeboi.service"
        sudo systemctl daemon-reload
    fi
    
    echo
    echo -e "${GREEN}✅ Nodeboi management tools have been uninstalled.${NC}"
    echo -e "${UI_MUTED}Your services continue running normally.${NC}"
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