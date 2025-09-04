#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="v0.2.38"
NODEBOI_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODEBOI_LIB="${NODEBOI_HOME}/lib"

# Load all library files
for lib in "${NODEBOI_LIB}"/*.sh; do
    [[ -f "$lib" ]] && source "$lib"
done

# Initialize plugin system
init_plugin_system  

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
    echo -e "                    ${CYAN}ETHEREUM NODE AUTOMATION${NC}"
    echo -e "                           ${YELLOW}${SCRIPT_VERSION}${NC}"

    echo
}

press_enter() {
    echo
    read -p "Press Enter to continue..."
}

# Main menu with fancy UI as default
main_menu() {
    while true; do
        local menu_options=(
            "Install new node"
            "Remove node"  
            "View node details"
            "Start/stop nodes"
            "Updates"
            "Plugin services"
            "Quit"
        )

        local selection
        if selection=$(fancy_select_menu "Main Menu" "${menu_options[@]}"); then
            case $selection in
                0) install_node ;;
                1) remove_nodes_menu ;;
                2) show_node_details ;;
                3) manage_node_state ;;
                4) updates_menu ;;
                5) manage_plugins_menu ;;
                6) echo -e "\n${GREEN}Goodbye!${NC}"; exit 0 ;;
            esac
        else
            # User pressed 'q' or quit
            echo -e "\n${GREEN}Goodbye!${NC}"
            exit 0
        fi
    done
}

# Updates menu
updates_menu() {
    while true; do
        local update_options=(
            "Update system (Linux packages)"
            "Update ethnode"
            "Update nodeboi"
            "Back to main menu"
        )

        local selection
        if selection=$(fancy_select_menu "Updates" "${update_options[@]}"); then
            case $selection in
                0) update_system ;;
                1) update_node ;;
                2) update_nodeboi ;;
                3) return ;;  # Back to main menu
            esac
        else
            return  # User pressed 'q' - back to main menu
        fi
    done
}

# Handle command line arguments
case "$1" in
    check-image)
        shift
        client="${1:-teku}"
        version="${2:-24.10.3}"
        echo "Testing Docker image availability for $client:$version"
        if validate_client_version "$client" "$version"; then
            echo "✓ Image is available!"
            exit 0
        else
            echo "✗ Image not found"
            exit 1
        fi
        ;;
    test)
        echo "NODEBOI Test Mode"
        echo "================="
        echo "Loaded clients:"
        echo "  Execution: ${EXECUTION_CLIENTS[@]}"
        echo "  Consensus: ${CONSENSUS_CLIENTS[@]}"
        echo ""
        echo "Testing functions:"
        echo -n "  Docker image for teku: "
        get_docker_image "teku"
        echo -n "  Normalize version v0.2.38 for teku: "
        normalize_version "teku" "v0.2.38"
        echo ""
        echo "All systems operational!"
        ;;
    *)
        check_prerequisites
        main_menu
        ;;
esac
