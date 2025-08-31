#!/bin/bash
# NODEBOI UI Functions

# TUI detection
detect_tui_tool() {
    if command -v dialog &> /dev/null; then
        echo "dialog"
    elif command -v whiptail &> /dev/null; then
        echo "whiptail"
    else
        echo "basic"
    fi
}

TUI_TOOL=$(detect_tui_tool)

# Interactive prompts
prompt_node_name() {
    local default_name="ethnode$(get_next_instance_number)"
    
    echo
    echo -e "${BOLD}Node Configuration${NC}"
    echo "=================="
    
    while true; do
        read -p "Enter node name (default: $default_name): " node_name
        node_name=${node_name:-$default_name}
        
        # Validate name
        if [[ "$node_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            if [[ ! -d "$HOME/$node_name" ]]; then
                break
            else
                log_error "Directory $HOME/$node_name already exists"
            fi
        else
            log_error "Invalid name. Use only letters, numbers, hyphens, and underscores"
        fi
    done
    
    echo "$node_name"
}

prompt_network() {
    echo
    echo "Available Networks:"
    echo "1) hoodi    - Hoodi testnet (recommended for testing)"
    echo "2) mainnet  - Ethereum mainnet (real ETH, higher requirements)"
    
    while true; do
        read -p "Select network (1-2, default: 1): " network_choice
        network_choice=${network_choice:-1}
        
        case $network_choice in
            1) echo "hoodi"; break ;;
            2) echo "mainnet"; break ;;
            *) log_error "Invalid choice. Please enter 1 or 2" ;;
        esac
    done
}

prompt_execution_client_with_version() {
    echo
    echo -e "${BOLD}Execution Client Selection${NC}"
    echo "=========================="
    echo "1) reth        - Fast, Rust-based (recommended)"
    echo "2) besu        - Java-based, enterprise features"
    echo "3) nethermind  - C#-based, Windows friendly"
    echo
    
    while true; do
        read -p "Select execution client (1-3, default: 1): " exec_choice
        exec_choice=${exec_choice:-1}
        
        local client=""
        case $exec_choice in
            1) client="reth"; break ;;
            2) client="besu"; break ;;
            3) client="nethermind"; break ;;
            *) echo -e "${RED}Invalid choice. Please enter 1-3${NC}" ;;
        esac
    done
    
    # Version confirmation
    local latest_version=$(get_latest_version "$client")
    echo
    echo -e "${YELLOW}Version Information:${NC}"
    echo "Latest $client version: $latest_version"
    echo
    echo -e "${YELLOW}⚠ Important:${NC} Always check the official $client GitHub for the latest releases:"
    case "$client" in
        "reth") echo "   https://github.com/paradigmxyz/reth/releases" ;;
        "besu") echo "   https://github.com/hyperledger/besu/releases" ;;
        "nethermind") echo "   https://github.com/NethermindEth/nethermind/releases" ;;
    esac
    echo "   You can adjust the version in the .env file after installation."
    echo
    
    read -p "Use latest version ($latest_version)? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        read -p "Enter custom version: " custom_version
        echo "$client:$custom_version"
    else
        echo "$client:$latest_version"
    fi
}

prompt_consensus_client_with_version() {
    echo
    echo -e "${BOLD}Consensus Client Selection${NC}"
    echo "=========================="
    echo "1) lodestar  - TypeScript-based, feature-rich (recommended)"
    echo "2) teku      - Java-based, enterprise features"
    echo "3) grandine  - Rust-based, high performance"
    echo
    
    while true; do
        read -p "Select consensus client (1-3, default: 1): " cons_choice
        cons_choice=${cons_choice:-1}
        
        local client=""
        case $cons_choice in
            1) client="lodestar"; break ;;
            2) client="teku"; break ;;
            3) client="grandine"; break ;;
            *) echo -e "${RED}Invalid choice. Please enter 1-3${NC}" ;;
        esac
    done
    
    # Version confirmation
    local latest_version=$(get_latest_version "$client")
    echo
    echo -e "${YELLOW}Version Information:${NC}"
    echo "Latest $client version: $latest_version"
    echo
    echo -e "${YELLOW}⚠ Important:${NC} Always check the official $client GitHub for the latest releases:"
    case "$client" in
        "lodestar") echo "   https://github.com/ChainSafe/lodestar/releases" ;;
        "teku") echo "   https://github.com/Consensys/teku/releases" ;;
        "grandine") echo "   https://github.com/grandinetech/grandine/releases" ;;
    esac
    echo "   You can adjust the version in the .env file after installation."
    echo
    
    read -p "Use latest version ($latest_version)? (Y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        read -p "Enter custom version: " custom_version
        echo "$client:$custom_version"
    else
        echo "$client:$latest_version"
    fi
}

prompt_ports() {
    local node_name="$1"
    
    echo
    echo -e "${BOLD}Port Configuration${NC}"
    echo "=================="
    echo "These ports need to be forwarded in your router for optimal P2P connectivity:"
    echo
    
    # Calculate suggested defaults
    local instance_num=$(echo "$node_name" | sed 's/[^0-9]//g')
    instance_num=${instance_num:-1}
    
    local suggested_el_p2p=$(find_next_available_port $((30303 + instance_num - 1)))
    local suggested_cl_p2p=$(find_next_available_port $((9000 + (instance_num - 1) * 3)))
    local suggested_ws_port=$(find_next_available_port $((8546 + instance_num - 1)))
    
    echo "Suggested ports (automatically checked for conflicts):"
    echo "  EL P2P: $suggested_el_p2p"
    echo "  CL P2P: $suggested_cl_p2p"
    echo "  WebSocket: $suggested_ws_port"
    echo
    
    # Get EL P2P port
    while true; do
        read -p "Execution Layer P2P port (default: $suggested_el_p2p): " el_p2p_port
        el_p2p_port=${el_p2p_port:-$suggested_el_p2p}
        
        if [[ "$el_p2p_port" =~ ^[0-9]+$ ]] && (( el_p2p_port >= 1024 && el_p2p_port <= 65535 )); then
            if ! is_port_available "$el_p2p_port"; then
                log_warn "Port $el_p2p_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                [[ $REPLY =~ ^[Yy]$ ]] && break
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    # Get CL P2P port
    while true; do
        read -p "Consensus Layer P2P port (default: $suggested_cl_p2p): " cl_p2p_port
        cl_p2p_port=${cl_p2p_port:-$suggested_cl_p2p}
        
        if [[ "$cl_p2p_port" =~ ^[0-9]+$ ]] && (( cl_p2p_port >= 1024 && cl_p2p_port <= 65535 )); then
            if ! is_port_available "$cl_p2p_port"; then
                log_warn "Port $cl_p2p_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                [[ $REPLY =~ ^[Yy]$ ]] && break
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    # Get WebSocket port
    while true; do
        read -p "WebSocket port (default: $suggested_ws_port): " ws_port
        ws_port=${ws_port:-$suggested_ws_port}
        
        if [[ "$ws_port" =~ ^[0-9]+$ ]] && (( ws_port >= 1024 && ws_port <= 65535 )); then
            if ! is_port_available "$ws_port"; then
                log_warn "Port $ws_port is already in use"
                read -p "Use it anyway? (y/N): " -n 1 -r
                echo
                [[ $REPLY =~ ^[Yy]$ ]] && break
            else
                break
            fi
        else
            log_error "Invalid port. Must be between 1024-65535"
        fi
    done
    
    echo "$el_p2p_port:$cl_p2p_port:$ws_port"
}
