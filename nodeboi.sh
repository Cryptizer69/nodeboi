#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="v0.3.0"
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

# Main menu with fancy UI as default
main_menu() {
    while true; do
        local menu_options=(
            "Install new node"
            "Manage nodes"
            "System"
            "Plugin services"
            "Quit"
        )

        local selection
        if selection=$(fancy_select_menu "Main Menu" "${menu_options[@]}"); then
            case $selection in
                0) install_node ;;
                1) manage_nodes_menu ;;
                2) system_menu ;;
                3) plugins_under_construction ;;
                4) exit 0 ;;
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
            "Back to main menu"
        )

        local selection
        if selection=$(fancy_select_menu "System" "${system_options[@]}"); then
            case $selection in
                0) update_system ;;
                1) update_nodeboi ;;
                2) return ;;  # Back to main menu
            esac
        else
            return  # User pressed 'q' - back to main menu
        fi
    done
}

# Plugins under construction
plugins_under_construction() {
    clear
    print_header
    echo -e "${BOLD}Plugin Services${NC}\n===============\n"
    echo -e "${YELLOW}🚧 Under Construction 🚧${NC}\n"
    echo -e "${UI_MUTED}The plugin system is being redesigned and will be available in a future version.${NC}\n"
    press_enter
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
        main_menu
        ;;
esac
