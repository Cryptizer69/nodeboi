#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="v0.2.35"
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

# Main menu
main_menu() {
    while true; do
        clear
        print_header
        print_dashboard        # Shows nodes
        print_plugin_dashboard  # NEW: Shows plugins

        echo -e "${BOLD}Main Menu${NC}\n=========="
        echo "  1) Install new node"
        echo "  2) Remove node"
        echo "  3) View node details"
        echo "  4) Start/stop nodes"
        echo "  5) Update nodes"
        echo "  6) Plugin services"    # NEW: Plugin menu
        echo "  7) Update NODEBOI"
        echo "  Q) Quit"
        echo

        read -p "Select option: " -r choice
        echo

        case "$choice" in
            1)
                install_node
                ;;
            2)
                remove_nodes_menu
                ;;
            3)
                show_node_details
                ;;
            4)
                manage_node_state
                ;;
            5)
                update_node
                ;;
            6)
                manage_plugins_menu  # NEW: From plugins.sh
                ;;
            7)
                update_nodeboi
                ;;
            [Qq])
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option"
                press_enter
                ;;
        esac
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
        echo -n "  Normalize version v0.2.35 for teku: "
        normalize_version "teku" "v0.2.35"
        echo ""
        echo "All systems operational!"
        ;;
    *)
        check_prerequisites
        main_menu
        ;;
esac
