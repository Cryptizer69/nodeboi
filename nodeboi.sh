#!/bin/bash

set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

SCRIPT_VERSION="0.0.19"
NODEBOI_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODEBOI_LIB="${NODEBOI_HOME}/lib"

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
    echo -e "                           ${YELLOW}v2.0.10${NC}"
    echo
}

press_enter() {
    echo
    read -p "Press Enter to continue..."
}

# Load all library files
for lib in "${NODEBOI_LIB}"/*.sh; do
    source "$lib"
done

# Main menu
main_menu() {
    while true; do
        clear
        print_header
        print_dashboard

        echo -e "${BOLD}Main Menu${NC}\n=========="
        echo "  1) Install new node"
        echo "  2) Remove node"
        echo "  3) View node details"
        echo "  4) Start/stop nodes"
        echo "  5) Update nodes"
        echo "  6) Update NODEBOI"
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
        echo -n "  Normalize version v2.0.10 for teku: "
        normalize_version "teku" "v2.0.10"
        echo ""
        echo "All systems operational!"
        ;;
    *)
        check_prerequisites
        main_menu
        ;;
esac
