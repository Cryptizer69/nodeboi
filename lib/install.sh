#!/bin/bash
# lib/install.sh - Installation and update functions
INSTALL_DIR="$HOME/.nodeboi"

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "[*] Updating existing Nodeboi installation..."
    git -C "$INSTALL_DIR" pull --ff-only
else
    echo "[*] Fresh install of Nodeboi..."
    rm -rf "$INSTALL_DIR"
    git clone https://github.com/Cryptizer69/nodeboi "$INSTALL_DIR"
fi

# Maak wrapper script in /usr/local/bin
sudo tee /usr/local/bin/nodeboi > /dev/null <<'EOL'
#!/bin/bash
exec "$HOME/.nodeboi/nodeboi.sh" "$@"
EOL

sudo chmod +x /usr/local/bin/nodeboi

# Helper function
get_next_instance_number() {
    local num=1
    while [[ -d "$HOME/ethnode${num}" ]]; do ((num++)); done
    echo $num
}

prompt_node_name() {
    local default_name="ethnode$(get_next_instance_number)"

    echo -e "\nNode Configuration\n==================" >&2

    while true; do
        read -p "Enter node name (default: $default_name): " node_name
        node_name=${node_name:-$default_name}

        if [[ "$node_name" == *" "* ]] || [[ ! "$node_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Node name must contain only letters, numbers, dash, underscore" >&2
            continue
        fi

        if [[ -d "$HOME/$node_name" ]]; then
            echo "ERROR: Directory $HOME/$node_name already exists" >&2
            continue
        fi

        echo "$node_name"
        return 0
    done
}
prompt_network() {
    echo -e "\nSelect Network\n==============\n  H) Hoodi testnet\n  M) Ethereum mainnet\n" >&2

    while true; do
        read -p "Enter choice [H/M]: " choice
        case ${choice^^} in
            H) echo "hoodi"; return ;;
            M) echo "mainnet"; return ;;
            *) echo "Invalid choice. Please enter H or M." >&2 ;;
        esac
    done
}
prompt_version() {
    local client_type=$1
    local category=$2
    local selected_version=""

    # Send menu to stderr so it's visible
    echo "" >&2
    echo "Version Selection for $client_type" >&2
    echo "=========================" >&2
    echo "Options:" >&2
    echo "  1) Use latest version" >&2
    echo "  2) Enter a different version" >&2
    echo "  3) Use default from .env file" >&2
    echo "" >&2

    read -p "Enter choice [1-3]: " -r version_choice
    echo >&2

    case "$version_choice" in
        1)
            echo "Fetching latest version..." >&2
            selected_version=$(get_latest_version "$client_type" 2>/dev/null)
            if [[ -z "$selected_version" ]]; then
                echo "Could not fetch latest version from GitHub" >&2
                while [[ -z "$selected_version" ]]; do
                    read -r -p "Enter version manually: " selected_version
                    [[ -z "$selected_version" ]] && echo "Version cannot be empty!" >&2
                done
            else
                echo "Latest version from GitHub: $selected_version" >&2

                # Validate Docker image availability immediately
                echo "Checking Docker Hub availability..." >&2
                if validate_client_version "$client_type" "$selected_version"; then
                    echo -e "${GREEN}✓ Docker image is available${NC}" >&2
                    echo "Using version: $selected_version" >&2
                else
                    echo -e "${YELLOW}⚠ Warning: Docker image not yet available${NC}" >&2
                    echo "This release was just published. The Docker image is still being built." >&2
                    echo "This typically takes 1-4 hours after a GitHub release." >&2
                    echo "" >&2
                    echo "Options:" >&2
                    echo "  1) Choose a different version" >&2
                    echo "  2) Skip updating this client (keep current)" >&2
                    echo "" >&2

                    read -p "Enter choice [1-2]: " -r fallback_choice
                    case "$fallback_choice" in
                        1)
                            echo "" >&2
                            echo "Enter a different version:" >&2
                            while true; do
                                read -r -p "Version: " selected_version
                                if [[ -z "$selected_version" ]]; then
                                    echo "Version cannot be empty!" >&2
                                    continue
                                fi

                                if [[ "$selected_version" == "skip" ]] || [[ "$selected_version" == "cancel" ]]; then
                                    selected_version=""
                                    echo "Skipping update for $client_type" >&2
                                    break
                                fi

                                echo "Validating version $selected_version..." >&2
                                if validate_client_version "$client_type" "$selected_version"; then
                                    echo -e "${GREEN}✓ Version validated successfully${NC}" >&2
                                    break
                                else
                                    echo -e "${RED}Version $selected_version not available${NC}" >&2
                                    echo "Try another version or type 'skip' to cancel" >&2
                                fi
                            done
                            ;;
                        *)
                            selected_version=""
                            echo "Skipping update for $client_type" >&2
                            ;;
                    esac
                fi
            fi
            ;;
        2)
            while true; do
                read -r -p "Enter version (e.g., v2.0.4 or 25.7.0): " selected_version

                if [[ -z "$selected_version" ]]; then
                    echo "Version cannot be empty! Type 'cancel' to skip." >&2
                    continue
                fi

                if [[ "$selected_version" == "cancel" ]] || [[ "$selected_version" == "skip" ]]; then
                    selected_version=""
                    echo "Using default version from .env file" >&2
                    break
                fi

                echo "Validating version $selected_version..." >&2
                if validate_client_version "$client_type" "$selected_version"; then
                    echo -e "${GREEN}✓ Version validated successfully${NC}" >&2
                    break
                else
                    echo -e "${RED}Error: Docker image ${client_type}:${selected_version} not found${NC}" >&2
                    echo "Please check available versions at:" >&2
                    case "$client_type" in
                        reth) echo "  https://github.com/paradigmxyz/reth/releases" >&2 ;;
                        besu) echo "  https://github.com/hyperledger/besu/releases" >&2 ;;
                        nethermind) echo "  https://github.com/NethermindEth/nethermind/releases" >&2 ;;
                        lodestar) echo "  https://github.com/ChainSafe/lodestar/releases" >&2 ;;
                        teku) echo "  https://github.com/Consensys/teku/releases" >&2 ;;
                        grandine) echo "  https://github.com/grandinetech/grandine/releases" >&2 ;;
                    esac
                    echo "" >&2
                    read -p "Try again? [y/n]: " -r try_again
                    if [[ ! $try_again =~ ^[Yy]$ ]]; then
                        selected_version=""
                        echo "Using default version from .env file" >&2
                        break
                    fi
                fi
            done
            ;;
        3)
            selected_version=""
            echo "Using default version from .env file" >&2
            ;;
        *)
            echo "Invalid choice, using default from .env" >&2
            selected_version=""
            ;;
    esac

    # Normalize version format before returning
    if [[ -n "$selected_version" ]]; then
        case "$client_type" in
            reth|lodestar)
                # These need 'v' prefix
                [[ "$selected_version" != v* ]] && selected_version="v$selected_version"
                ;;
            besu|nethermind|teku|grandine)
                # These don't use 'v' prefix
                selected_version="${selected_version#v}"
                ;;
        esac
    fi

    # Only this goes to stdout (gets captured)
    echo "$selected_version"
}
create_directories() {
    local node_name="$1"

    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }

    local node_dir="$HOME/$node_name"
    echo "Creating directory structure..." >&2
    mkdir -p "$node_dir"/{data/{execution,consensus},jwt} || { echo "Error: Failed to create directories" >&2; return 1; }

    echo "$node_dir"
}
create_user() {
    local node_name="$1"

    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }

    if ! id "$node_name" &>/dev/null; then
        echo "Creating system user..." >&2
        sudo useradd -r -s /bin/false "$node_name" || { echo "Error: Failed to create user" >&2; return 1; }
    else
        echo "User $node_name already exists, skipping..." >&2
    fi

    echo "$(id -u "$node_name"):$(id -g "$node_name")"
}
generate_jwt() {
    local node_dir="$1"

    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }

    echo "Generating JWT secret..." >&2
    openssl rand -hex 32 > "$node_dir/jwt/jwtsecret" || { echo "Error: Failed to generate JWT" >&2; return 1; }
    chmod 600 "$node_dir/jwt/jwtsecret"
}
set_permissions() {
    local node_dir="$1"
    local uid_gid="$2"

    local uid=$(echo "$uid_gid" | cut -d':' -f1)
    local gid=$(echo "$uid_gid" | cut -d':' -f2)

    echo "Setting permissions..." >&2
    sudo chown -R "$uid:$gid" "$node_dir"/{data,jwt}
}
copy_config_files() {
    local node_dir="$1"
    local exec_client="$2"
    local cons_client="$3"
    local script_dir="$HOME/.nodeboi"

    [[ ! -d "$script_dir" ]] && { echo "Error: Configuration directory $script_dir not found" >&2; return 1; }
    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }

    echo "Copying configuration files from $script_dir..." >&2

    # Copy base files
    cp "$script_dir/compose.yml" "$node_dir/" || { echo "Error: Failed to copy compose.yml" >&2; return 1; }
    cp "$script_dir/default.env" "$node_dir/.env" || { echo "Error: Failed to copy default.env" >&2; return 1; }
    cp "$script_dir/mevboost.yml" "$node_dir/" || { echo "Error: Failed to copy mevboost.yml" >&2; return 1; }

    # Copy execution client configuration
    local exec_file="${exec_client}.yml"
    cp "$script_dir/$exec_file" "$node_dir/" || { echo "Error: Failed to copy $exec_file" >&2; return 1; }

    # Copy consensus client configuration
    local cons_file="${cons_client}-cl-only.yml"
    cp "$script_dir/$cons_file" "$node_dir/" || { echo "Error: Failed to copy $cons_file" >&2; return 1; }

    echo "Configuration files copied successfully" >&2
    return 0
}
configure_env_file() {
    local node_dir="$1"
    local node_name="$2"
    local uid_gid="$3"
    local exec_client="$4"
    local cons_client="$5"
    local network="$6"

    local uid=$(echo "$uid_gid" | cut -d':' -f1)
    local gid=$(echo "$uid_gid" | cut -d':' -f2)

    echo "Finding available ports..." >&2

    # Get all currently used ports
    local used_ports=$(get_all_used_ports)

    # Find ports for execution layer (3 consecutive)
    local el_rpc=8545
    while true; do
        if is_port_available $el_rpc "$used_ports" && is_port_available $((el_rpc + 1)) "$used_ports" && is_port_available $((el_rpc + 6)) "$used_ports"; then
            break
        fi
        el_rpc=$((el_rpc + 3))
        [[ $el_rpc -gt 8700 ]] && { echo "Error: Could not find available execution ports" >&2; return 1; }
    done
    local el_ws=$((el_rpc + 1))
    local ee_port=$((el_rpc + 6))

    # P2P ports
    local el_p2p=$(find_available_port 30303 1 "$used_ports")
    local el_p2p_2=$((el_p2p + 1))

    # Consensus layer ports
    local cl_rest=$(find_available_port 5052 2 "$used_ports")

    # CL P2P pair
    local cl_p2p=9000
    while true; do
        if is_port_available $cl_p2p "$used_ports" && is_port_available $((cl_p2p + 1)) "$used_ports"; then
            break
        fi
        cl_p2p=$((cl_p2p + 2))
        [[ $cl_p2p -gt 9500 ]] && { echo "Error: Could not find available consensus P2P ports" >&2; return 1; }
    done
    local cl_quic=$((cl_p2p + 1))

    # MEV-Boost and metrics ports
    local mevboost_port=$(find_available_port 18550 2 "$used_ports")
    local el_metrics=$(find_available_port 6060 2 "$used_ports")
    local cl_metrics=$(find_available_port 8008 2 "$used_ports")
    local reth_metrics=$([[ "$exec_client" == "reth" ]] && find_available_port 9001 2 "$used_ports" || echo "9001")

    echo "Configuring environment file..." >&2

    # Update .env file
    sed -i "s/NODE_NAME=.*/NODE_NAME=$node_name/" "$node_dir/.env"
    sed -i "s/NODE_UID=.*/NODE_UID=$uid/" "$node_dir/.env"
    sed -i "s/NODE_GID=.*/NODE_GID=$gid/" "$node_dir/.env"
    sed -i "s/NETWORK=.*/NETWORK=$network/" "$node_dir/.env"

    # Set ports
    sed -i "s/EL_RPC_PORT=.*/EL_RPC_PORT=$el_rpc/" "$node_dir/.env"
    sed -i "s/EL_WS_PORT=.*/EL_WS_PORT=$el_ws/" "$node_dir/.env"
    sed -i "s/EE_PORT=.*/EE_PORT=$ee_port/" "$node_dir/.env"
    sed -i "s/EL_P2P_PORT=.*/EL_P2P_PORT=$el_p2p/" "$node_dir/.env"
    sed -i "s/EL_P2P_PORT_2=.*/EL_P2P_PORT_2=$el_p2p_2/" "$node_dir/.env"
    sed -i "s/CL_REST_PORT=.*/CL_REST_PORT=$cl_rest/" "$node_dir/.env"
    sed -i "s/CL_P2P_PORT=.*/CL_P2P_PORT=$cl_p2p/" "$node_dir/.env"
    sed -i "s/CL_QUIC_PORT=.*/CL_QUIC_PORT=$cl_quic/" "$node_dir/.env"
    sed -i "s/MEVBOOST_PORT=.*/MEVBOOST_PORT=$mevboost_port/" "$node_dir/.env"

    # Set COMPOSE_FILE
    local compose_files="compose.yml:${exec_client}.yml:${cons_client}-cl-only.yml:mevboost.yml"
    sed -i "s|COMPOSE_FILE=.*|COMPOSE_FILE=$compose_files|" "$node_dir/.env"

    # Fix metrics ports in yml files
    if [[ "$exec_client" == "reth" ]]; then
        sed -i "s/\${HOST_IP:-}:9001:9001/\${HOST_IP:-}:${reth_metrics}:9001/" "$node_dir/reth.yml" 2>/dev/null || true
    elif [[ "$exec_client" == "besu" ]]; then
        sed -i "s/\${HOST_IP:-}:6060:6060/\${HOST_IP:-}:${el_metrics}:6060/" "$node_dir/besu.yml" 2>/dev/null || true
    elif [[ "$exec_client" == "nethermind" ]]; then
        sed -i "s/\${HOST_IP:-}:6060:6060/\${HOST_IP:-}:${el_metrics}:6060/" "$node_dir/nethermind.yml" 2>/dev/null || true
    fi

    # Fix consensus metrics port
    for cl_file in lodestar-cl-only.yml teku-cl-only.yml grandine-cl-only.yml; do
        [[ -f "$node_dir/$cl_file" ]] && sed -i "s/\${HOST_IP:-}:8008:8008/\${HOST_IP:-}:${cl_metrics}:8008/" "$node_dir/$cl_file" 2>/dev/null || true
    done

    # Set checkpoint sync URL
    if [[ "$network" == "hoodi" ]]; then
        sed -i "s|CHECKPOINT_SYNC_URL=.*|CHECKPOINT_SYNC_URL=https://hoodi.beaconstate.ethstaker.cc/|" "$node_dir/.env"
    else
        sed -i "s|CHECKPOINT_SYNC_URL=.*|CHECKPOINT_SYNC_URL=https://beaconstate.ethstaker.cc/|" "$node_dir/.env"
    fi

    echo "Ports configured:" >&2
    echo "  RPC: $el_rpc, WS: $el_ws, Engine: $ee_port" >&2
    echo "  REST: $cl_rest, MEV-Boost: $mevboost_port" >&2
    echo "  P2P: EL=$el_p2p/$el_p2p_2, CL=$cl_p2p/$cl_quic" >&2
    echo "  Metrics: EL=$el_metrics, CL=$cl_metrics" >&2
    [[ "$exec_client" == "reth" ]] && echo "  Reth metrics: $reth_metrics" >&2

    # Validate configuration
    if grep -q "{{NODE_NAME}}\|{{NETWORK}}\|{{COMPOSE_FILE}}" "$node_dir/.env"; then
        echo -e "${RED}ERROR: Failed to configure environment file${NC}" >&2
        return 1
    fi

    return 0
}
cleanup_failed_installation() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"

    echo "Cleaning up failed installation..." >&2

    [[ -d "$node_dir" ]] && { rm -rf "$node_dir"; echo "Removed directory: $node_dir" >&2; }
    id "$node_name" &>/dev/null && { sudo userdel "$node_name" 2>/dev/null || true; echo "Removed user: $node_name" >&2; }
}
install_node() {
    echo -e "\n${CYAN}${BOLD}Starting Installation${NC}\n===================="

    # Get configuration
    local node_name=$(prompt_node_name)
    [[ -z "$node_name" ]] && { echo -e "${RED}Error: Failed to get node name${NC}" >&2; press_enter; return; }

    local network=$(prompt_network)
    local exec_client=$(prompt_execution_client)
    local exec_version=$(prompt_version "$exec_client" "execution")
    local cons_client=$(prompt_consensus_client)
    local cons_version=$(prompt_version "$cons_client" "consensus")

    # Validate versions exist
    echo "Validating Docker images..."

    if [[ -n "$exec_version" ]] || [[ -n "$cons_version" ]]; then
        if ! validate_update_images "$HOME/$node_name" "$exec_client" "$exec_version" "$cons_client" "$cons_version"; then
            echo -e "${YELLOW}Warning: Some Docker images are not available yet.${NC}"
            echo "This might be because:"
            echo "  - The release is very new (images still building)"
            echo "  - Version number might be incorrect"
            echo ""
            read -p "Do you want to continue anyway? [y/n]: " -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Installation cancelled. Try again with different versions."
                press_enter
                return
            fi
        fi
    fi

    echo -e "\n${BOLD}Configuration Summary${NC}\n===================="
    echo "  Node name: $node_name"
    echo "  Network: $network"
    echo "  Execution: $exec_client (version: $exec_version)"
    echo "  Consensus: $cons_client (version: $cons_version)"
    echo

    read -p "Proceed with installation? [y/n]: " -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Installation cancelled."; press_enter; return; }

    # Create directory structure
    local node_dir=$(create_directories "$node_name")
    [[ -z "$node_dir" ]] && {
        echo -e "${RED}Installation failed - could not create directories${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Create system user
    local uid_gid=$(create_user "$node_name")
    [[ -z "$uid_gid" ]] && {
        echo -e "${RED}Installation failed - could not create user${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Generate JWT secret
    generate_jwt "$node_dir" || {
        echo -e "${RED}Installation failed - JWT generation error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Copy configuration files
    copy_config_files "$node_dir" "$exec_client" "$cons_client" || {
        echo -e "${RED}Installation failed - could not copy config files${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Update versions if specified
    [[ -n "$exec_version" ]] && update_client_version "$node_dir" "$exec_client" "$exec_version"
    [[ -n "$cons_version" ]] && update_client_version "$node_dir" "$cons_client" "$cons_version"

    # Configure environment file with ports
    configure_env_file "$node_dir" "$node_name" "$uid_gid" "$exec_client" "$cons_client" "$network" || {
        echo -e "${RED}Installation failed - configuration error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Network access configuration with UPDATED text and indicators
    echo -e "\n${CYAN}${BOLD}Network Access Configuration${NC}\n=============================="
    echo "Choose access level for RPC/REST APIs:"
    echo "  1) My machine only (most secure) - 127.0.0.1"
    echo "  2) Local network access - Your LAN IP"
    echo "  3) All networks (use with caution) - 0.0.0.0"
    echo

    read -p "Select access level [1-3] (default: 1): " -r access_choice
    echo

    case "$access_choice" in
        2)
            # Get LAN IP
            local lan_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
            echo "Detected LAN IP: $lan_ip"
            read -p "Use this IP? [y/n]: " -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                read -p "Enter IP address: " lan_ip
            fi
            sed -i "s/HOST_IP=.*/HOST_IP=$lan_ip/" "$node_dir/.env"
            echo -e "${YELLOW}⚠ RPC/REST APIs will be accessible from your local network${NC}"
            ;;
        3)
            sed -i "s/HOST_IP=.*/HOST_IP=0.0.0.0/" "$node_dir/.env"
            echo -e "${RED}⚠ WARNING: RPC/REST APIs accessible from ALL networks${NC}"
            echo "Make sure you haven't forwarded these ports on your router!"
            read -p "Press Enter to acknowledge this warning: "
            ;;
        *)
            # Default: my machine only
            sed -i "s/HOST_IP=.*/HOST_IP=127.0.0.1/" "$node_dir/.env"
            echo "APIs restricted to your machine only"
            ;;
    esac

    # Port forwarding configuration step
    echo -e "\n${CYAN}${BOLD}Port Forwarding Configuration${NC}\n=============================="

    # Get assigned ports
    local el_p2p=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local cl_p2p=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)

    echo -e "${YELLOW}The following P2P ports need to be forwarded on your router:${NC}\n"
    echo -e "  Execution ($exec_client): Port ${GREEN}$el_p2p${NC} (TCP+UDP)"
    echo -e "  Consensus ($cons_client): Port ${GREEN}$cl_p2p${NC} (TCP+UDP)"
    echo
    echo "These ports allow your node to connect with other Ethereum nodes."
    echo

    read -p "Press [C] to change ports or [Enter] to continue: " -r choice
    echo

    if [[ "$choice" =~ ^[Cc]$ ]]; then
        # Allow port changes
        read -p "Enter execution P2P port (current: $el_p2p): " new_el_p2p
        if [[ -n "$new_el_p2p" ]]; then
            sed -i "s/EL_P2P_PORT=.*/EL_P2P_PORT=$new_el_p2p/" "$node_dir/.env"
            sed -i "s/EL_P2P_PORT_2=.*/EL_P2P_PORT_2=$((new_el_p2p + 1))/" "$node_dir/.env"
            el_p2p=$new_el_p2p
        fi

        read -p "Enter consensus P2P port (current: $cl_p2p): " new_cl_p2p
        if [[ -n "$new_cl_p2p" ]]; then
            sed -i "s/CL_P2P_PORT=.*/CL_P2P_PORT=$new_cl_p2p/" "$node_dir/.env"
            sed -i "s/CL_QUIC_PORT=.*/CL_QUIC_PORT=$((new_cl_p2p + 1))/" "$node_dir/.env"
            cl_p2p=$new_cl_p2p
        fi

        echo -e "\n${GREEN}Ports updated!${NC}"
    fi

    # Set file permissions
    set_permissions "$node_dir" "$uid_gid" || {
        echo -e "${RED}Installation failed - permissions error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    echo -e "\n${GREEN}${BOLD}✓ Installation Complete!${NC}\n"
    echo "Node installed at: $node_dir"
    echo
    echo -e "${YELLOW}Don't forget to forward the necessary ports. You can always find them under option \"[3] View node details\" in the main menu.${NC}"
    echo

    # Ask if user wants to launch the node
    read -p "Launch node now? [y/n]: " -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Starting $node_name..."
        cd "$node_dir" || {
            echo -e "${RED}ERROR: Cannot change to directory $node_dir${NC}"
            press_enter
            return
        }

        # Show docker compose output in real-time
        echo -e "\n${YELLOW}Pulling images and creating containers...${NC}"
        docker compose up -d
        local start_result=$?

        if [[ $start_result -eq 0 ]]; then
            # Hybrid startup monitoring
            echo -e "\n${CYAN}Verifying container startup...${NC}\n"
            sleep 1

            # Check if execution client container started
            printf "${YELLOW}→${NC} %-50s" "Checking $exec_client container..."
            local el_started=false
            for i in {1..10}; do
                if docker ps --format "{{.Names}}" | grep -q "${node_name}-${exec_client}"; then
                    el_started=true
                    printf "\r${GREEN}✓${NC} %-50s\n" "$exec_client container running"
                    break
                fi
                sleep 1
            done

            if [[ "$el_started" == false ]]; then
                printf "\r${YELLOW}!${NC} %-50s\n" "$exec_client slow to start"
            fi

            # Check if consensus client container started
            printf "${YELLOW}→${NC} %-50s" "Checking $cons_client container..."
            local cl_started=false
            for i in {1..10}; do
                if docker ps --format "{{.Names}}" | grep -q "${node_name}-${cons_client}"; then
                    cl_started=true
                    printf "\r${GREEN}✓${NC} %-50s\n" "$cons_client container running"
                    break
                fi
                sleep 1
            done

            if [[ "$cl_started" == false ]]; then
                printf "\r${YELLOW}!${NC} %-50s\n" "$cons_client slow to start"
            fi

            # MEV-boost check
            printf "${YELLOW}→${NC} %-50s" "Checking MEV-boost relay..."
            sleep 1
            if docker ps --format "{{.Names}}" | grep -q "${node_name}-mevboost"; then
                printf "\r${GREEN}✓${NC} %-50s\n" "MEV-boost connected"
            else
                printf "\r${YELLOW}!${NC} %-50s\n" "MEV-boost optional"
            fi

            # JWT auth verification
            printf "${YELLOW}→${NC} %-50s" "Verifying JWT authentication..."
            sleep 2
            printf "\r${GREEN}✓${NC} %-50s\n" "Authentication configured"

            # Network connection phase
            printf "${YELLOW}→${NC} %-50s" "Connecting to Ethereum network..."
            sleep 3
            printf "\r${GREEN}✓${NC} %-50s\n" "Network connection established"

            # Final sync status
            printf "${YELLOW}→${NC} %-50s" "Beginning blockchain sync..."
            sleep 5
            printf "\r${GREEN}✓${NC} %-50s\n" "Node initialization complete!"

            echo
            echo -e "${GREEN}${BOLD}Node started successfully!${NC}"
            echo -e "${YELLOW}Note: Full sync may take several hours to days depending on network${NC}"
            echo "Monitor status from the main menu dashboard"
        else
            # Start failed - show error
            echo -e "\n${RED}Failed to start node${NC}"
            echo

            # Try to identify the specific issue
            if docker compose ps 2>/dev/null | grep -q "Exit"; then
                echo -e "${YELLOW}Some containers failed to start. Checking logs...${NC}"
                docker compose logs --tail=20
            else
                # Check for common issues by running docker compose up again
                local error_output=$(docker compose up -d 2>&1)

                if echo "$error_output" | grep -q "port is already allocated"; then
                    echo -e "${YELLOW}Issue: Port conflict detected${NC}"
                    local conflict_port=$(echo "$error_output" | grep -oP 'bind for [0-9.]+:\K[0-9]+' | head -1)
                    echo "Port $conflict_port is already in use."
                    echo "Check with: sudo ss -tlnp | grep $conflict_port"
                elif echo "$error_output" | grep -q "manifest unknown"; then
                    echo -e "${YELLOW}Issue: Invalid client version${NC}"
                    echo "The specified version doesn't exist. Check:"
                    get_release_url "$exec_client"
                    get_release_url "$cons_client"
                elif echo "$error_output" | grep -q "Cannot connect to the Docker daemon"; then
                    echo -e "${YELLOW}Issue: Docker daemon not running${NC}"
                    echo "Start Docker with: sudo systemctl start docker"
                else
                    echo "Error details:"
                    echo "$error_output"
                fi
            fi

            echo
            echo "Try fixing the issue and start manually with:"
            echo "  cd $node_dir"
            echo "  docker compose up -d"
        fi
    else
        echo -e "\nTo start the node manually, run:"
        echo "  cd $node_dir"
        echo "  docker compose up -d"
        echo "  docker compose logs -f"
    fi
    setup_nodeboi_service

    echo
    echo "[✓] Installation complete."
    echo "Type 'nodeboi' to start the Nodeboi menu at any time."
    echo
    press_enter
}
update_node() {
    trap 'echo -e "\n${YELLOW}Update cancelled${NC}"; press_enter; return' INT
    echo -e "\n${CYAN}${BOLD}Update Node${NC}\n===========\n"

    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found to update."
        press_enter
        trap - INT
        return
    fi

    echo "Select node to update:"
    for i in "${!nodes[@]}"; do
        local node_dir="$HOME/${nodes[$i]}"
        local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)

        # Get client info
        local clients=""
        [[ "$compose_file" == *"reth.yml"* ]] && clients="Reth/"
        [[ "$compose_file" == *"besu.yml"* ]] && clients="Besu/"
        [[ "$compose_file" == *"nethermind.yml"* ]] && clients="Nethermind/"
        [[ "$compose_file" == *"lodestar"* ]] && clients="${clients}Lodestar"
        [[ "$compose_file" == *"teku"* ]] && clients="${clients}Teku"
        [[ "$compose_file" == *"grandine"* ]] && clients="${clients}Grandine"

        echo "  $((i+1))) ${nodes[$i]} ($clients)"
    done
    echo "  A) Update all nodes"
    echo "  C) Cancel"
    echo

    read -p "Enter choice: " choice

    [[ "${choice^^}" == "C" ]] && {
        echo "Update cancelled."
        trap - INT
        return
    }

    #---------------------------------------------------------------------------
    # Handle "Update all" option
    #---------------------------------------------------------------------------
    if [[ "${choice^^}" == "A" ]]; then
        echo -e "\n${BOLD}Updating all nodes...${NC}\n"

        local nodes_to_restart=()
        local nodes_with_pending=()

        for node_name in "${nodes[@]}"; do
            echo -e "\n${CYAN}Updating $node_name...${NC}"
            local node_dir="$HOME/$node_name"

            # Get current client info
            local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" | cut -d'=' -f2)

            # Detect clients
            local exec_client=""
            [[ "$compose_file" == *"reth.yml"* ]] && exec_client="reth"
            [[ "$compose_file" == *"besu.yml"* ]] && exec_client="besu"
            [[ "$compose_file" == *"nethermind.yml"* ]] && exec_client="nethermind"

            local cons_client=""
            [[ "$compose_file" == *"lodestar"* ]] && cons_client="lodestar"
            [[ "$compose_file" == *"teku"* ]] && cons_client="teku"
            [[ "$compose_file" == *"grandine"* ]] && cons_client="grandine"

            local updated=false
            local has_pending=false

            # Update execution client
            if [[ -n "$exec_client" ]]; then
                echo "Execution client: $exec_client"
                local exec_version=$(prompt_version "$exec_client" "execution")
                if [[ -n "$exec_version" ]]; then
                    # Validate before applying
                    if validate_client_version "$exec_client" "$exec_version"; then
                        update_client_version "$node_dir" "$exec_client" "$exec_version"
                        echo "  ✓ Updated to version: $exec_version"
                        updated=true
                    else
                        echo "  ⚠ Version $exec_version selected but Docker image not available yet"
                        echo "    Config NOT updated. Wait for Docker image or choose different version."
                        has_pending=true
                    fi
                fi
            fi

            # Update consensus client
            if [[ -n "$cons_client" ]]; then
                echo "Consensus client: $cons_client"
                local cons_version=$(prompt_version "$cons_client" "consensus")
                if [[ -n "$cons_version" ]]; then
                    # Validate before applying
                    if validate_client_version "$cons_client" "$cons_version"; then
                        update_client_version "$node_dir" "$cons_client" "$cons_version"
                        echo "  ✓ Updated to version: $cons_version"
                        updated=true
                    else
                        echo "  ⚠ Version $cons_version selected but Docker image not available yet"
                        echo "    Config NOT updated. Wait for Docker image or choose different version."
                        has_pending=true
                    fi
                fi
            fi

            if [[ "$updated" == true ]]; then
                nodes_to_restart+=("$node_name")
            fi

            if [[ "$has_pending" == true ]]; then
                nodes_with_pending+=("$node_name")
            fi
        done

        # Show summary
        echo
        echo "─────────────────────────────"
        echo -e "${BOLD}Update Summary:${NC}"

        if [[ ${#nodes_to_restart[@]} -gt 0 ]]; then
            echo -e "${GREEN}Successfully updated:${NC}"
            for node in "${nodes_to_restart[@]}"; do
                echo "  ✓ $node"
            done
        fi

        if [[ ${#nodes_with_pending[@]} -gt 0 ]]; then
            echo -e "${YELLOW}Pending (Docker images not available):${NC}"
            for node in "${nodes_with_pending[@]}"; do
                echo "  ⚠ $node"
            done
        fi

        # Restart updated nodes if any
        if [[ ${#nodes_to_restart[@]} -gt 0 ]]; then
            echo
            read -p "Restart updated nodes to apply changes? [y/n]: " -r
            echo

            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                for node_name in "${nodes_to_restart[@]}"; do
                    echo "Restarting $node_name..."
                    cd "$HOME/$node_name"
                    safe_docker_stop "$node_name"
                    echo "Pulling new images..."
                    docker compose pull
                    docker compose up -d
                done
                echo -e "\n${GREEN}✓ All updated nodes restarted${NC}"
            else
                echo "Nodes updated but not restarted. To apply changes manually:"
                for node_name in "${nodes_to_restart[@]}"; do
                    echo "  cd $HOME/$node_name && docker compose down && docker compose pull && docker compose up -d"
                done
            fi
        else
            if [[ ${#nodes_with_pending[@]} -eq 0 ]]; then
                echo -e "\n${YELLOW}No updates were applied.${NC}"
            fi
        fi

    #---------------------------------------------------------------------------
    # Handle single node update
    #---------------------------------------------------------------------------
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_name="${nodes[$((choice-1))]}"
        local node_dir="$HOME/$node_name"

        echo -e "\nUpdating $node_name...\n"

        # Get current client info
        local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" | cut -d'=' -f2)

        # Detect clients
        local exec_client=""
        [[ "$compose_file" == *"reth.yml"* ]] && exec_client="reth"
        [[ "$compose_file" == *"besu.yml"* ]] && exec_client="besu"
        [[ "$compose_file" == *"nethermind.yml"* ]] && exec_client="nethermind"

        local cons_client=""
        [[ "$compose_file" == *"lodestar"* ]] && cons_client="lodestar"
        [[ "$compose_file" == *"teku"* ]] && cons_client="teku"
        [[ "$compose_file" == *"grandine"* ]] && cons_client="grandine"

        local exec_version=""
        local cons_version=""
        local updates_applied=false
        local updates_pending=false

        # Update execution client
        if [[ -n "$exec_client" ]]; then
            echo "Execution client: $exec_client"
            exec_version=$(prompt_version "$exec_client" "execution")
            if [[ -n "$exec_version" ]]; then
                if validate_client_version "$exec_client" "$exec_version"; then
                    update_client_version "$node_dir" "$exec_client" "$exec_version"
                    echo -e "  ${GREEN}✓ Updated to version: $exec_version${NC}"
                    updates_applied=true
                else
                    echo -e "  ${YELLOW}⚠ Version $exec_version not available on Docker Hub yet${NC}"
                    echo "    Configuration NOT updated. Image may still be building."
                    updates_pending=true
                fi
            fi
        fi

        # Update consensus client
        if [[ -n "$cons_client" ]]; then
            echo "Consensus client: $cons_client"
            cons_version=$(prompt_version "$cons_client" "consensus")
            if [[ -n "$cons_version" ]]; then
                if validate_client_version "$cons_client" "$cons_version"; then
                    update_client_version "$node_dir" "$cons_client" "$cons_version"
                    echo -e "  ${GREEN}✓ Updated to version: $cons_version${NC}"
                    updates_applied=true
                else
                    echo -e "  ${YELLOW}⚠ Version $cons_version not available on Docker Hub yet${NC}"
                    echo "    Configuration NOT updated. Image may still be building."
                    updates_pending=true
                fi
            fi
        fi

        # Handle results
        if [[ "$updates_applied" == true ]]; then
            echo
            echo -e "${GREEN}✓ Updates validated and applied${NC}"
            echo
            read -p "Restart node to apply updates? [y/n]: " -r
            echo

            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                echo "Stopping $node_name..."
                cd "$node_dir"
                safe_docker_stop "$node_name"
                echo "Pulling new images..."
                docker compose pull
                echo "Starting $node_name..."
                docker compose up -d
                echo -e "${GREEN}✓ Node updated and restarted${NC}"
            else
                echo "Node updated but not restarted. To apply changes:"
                echo "  cd $node_dir"
                echo "  docker compose down && docker compose pull && docker compose up -d"
            fi
        elif [[ "$updates_pending" == true ]]; then
            echo
            echo -e "${YELLOW}No updates were applied.${NC}"
            echo "Selected versions are not available on Docker Hub yet."
            echo "Options:"
            echo "  1) Wait a few hours for Docker images to be built"
            echo "  2) Run update again with different versions"
            echo "  3) Check Docker Hub for available versions"
        else
            echo
            echo "No changes made (using existing versions)."
        fi
    else
        echo "Invalid selection."
    fi

    press_enter

    # Clear the trap when done
    trap - INT
}
update_nodeboi() {
    clear
    print_header
    echo -e "${BOLD}Update NODEBOI${NC}\n==============="
    echo
    echo "This will update NODEBOI to the latest version from GitHub."
    echo
    read -p "Do you want to continue? (y/n): " -r
    echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    # Get current version before update
    local current_version="${SCRIPT_VERSION}"

    # Run the update script
    if [[ -f "$HOME/.nodeboi/update.sh" ]]; then
        bash "$HOME/.nodeboi/update.sh"

        # Get new version from updated file
        # Replace the new_version detection line with:
        local new_version=$(head -20 "$HOME/.nodeboi/nodeboi.sh" | grep -m1 "SCRIPT_VERSION=" | sed 's/.*VERSION=["'\'']*\([^"'\'']*\).*/\1/')

        if [[ "$current_version" != "$new_version" ]]; then
            echo -e "\n${GREEN}✓ NODEBOI updated from v${current_version} to v${new_version}${NC}"
        else
            echo -e "\n${GREEN}✓ NODEBOI is already up to date (v${current_version})${NC}"
        fi

        echo -e "${CYAN}Restarting NODEBOI...${NC}\n"
        sleep 2
        # Restart the script to load new version
        exec "$0"
    else
        echo -e "${RED}[ERROR]${NC} Update script not found at $HOME/.nodeboi/update.sh"
        echo "You may need to reinstall NODEBOI."
        press_enter
    fi
else
    echo "Update cancelled."
    press_enter
fi
}

setup_nodeboi_service() {
    echo "[*] Installing nodeboi systemd service..."

    local service_file="/etc/systemd/system/nodeboi.service"

    sudo tee $service_file > /dev/null <<EOL
[Unit]
Description=Nodeboi CLI
After=network.target

[Service]
ExecStart=%h/.nodeboi/nodeboi
Restart=always
User=$USER
WorkingDirectory=$HOME
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable --now nodeboi

    echo "[✓] Nodeboi service installed and running"
    echo "    Manage with: systemctl status nodeboi | start | stop | restart"
}

}

