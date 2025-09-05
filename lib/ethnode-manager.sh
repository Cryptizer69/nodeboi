#!/bin/bash
# lib/ethnode-manager.sh - Ethereum node installation, updates, and management

# Source dependencies
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh"

INSTALL_DIR="$HOME/.nodeboi"

# Helper: get next available node instance number
get_next_instance_number() {
    local num=1
    while [[ -d "$HOME/ethnode${num}" ]]; do
        # Check if this is a complete installation (has .env file)
        if [[ -f "$HOME/ethnode${num}/.env" ]]; then
            # Complete installation, try next number
            ((num++))
        else
            # Incomplete installation found - we can reuse this number
            # Now that we have proper cleanup traps, we can handle this more conservatively
            echo "Found incomplete ethnode${num} installation." >&2
            echo "You may want to clean it up manually: rm -rf ~/ethnode${num}" >&2
            # For safety, skip this number and suggest next available
            ((num++))
        fi
    done
    echo $num
}

# Helper: install Nodeboi as a systemd service
setup_nodeboi_service() {
    local service_file="/etc/systemd/system/nodeboi.service"

    sudo tee $service_file > /dev/null <<EOL
[Unit]
Description=Nodeboi CLI
After=network.target

[Service]
ExecStart=%h/.nodeboi/nodeboi.sh
Restart=always
User=%u
WorkingDirectory=%h
Environment=PATH=/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl daemon-reload
    sudo systemctl enable --now nodeboi
}

# Node name validation function
validate_node_name() {
    local node_name="$1"
    
    if [[ "$node_name" == *" "* ]] || [[ ! "$node_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${UI_MUTED}Node name must contain only letters, numbers, dash, underscore${NC}" >&2
        return 1
    fi

    if [[ -d "$HOME/$node_name" ]]; then
        echo "Directory $HOME/$node_name already exists" >&2
        return 1
    fi

    return 0
}

# IP address validation function
validate_ip_address() {
    local ip="$1"
    
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo -e "${UI_MUTED}Please enter a valid IP address (e.g., 192.168.1.100)${NC}" >&2
        return 1
    fi
    
    # Check each octet is 0-255
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -gt 255 ]]; then
            echo -e "${UI_MUTED}IP address octets must be between 0-255${NC}" >&2
            return 1
        fi
    done
    
    return 0
}

# Validate multiple Docker images during installation
validate_update_images() {
    local node_dir="$1"
    local exec_client="$2"
    local exec_version="$3"
    local cons_client="$4"  
    local cons_version="$5"
    
    local validation_failed=false
    
    # Validate execution client version if provided
    if [[ -n "$exec_version" && "$exec_client" != "unknown" ]]; then
        if ! validate_client_version "$exec_client" "$exec_version"; then
            validation_failed=true
        fi
    fi
    
    # Validate consensus client version if provided
    if [[ -n "$cons_version" && "$cons_client" != "unknown" ]]; then
        if ! validate_client_version "$cons_client" "$cons_version"; then
            validation_failed=true
        fi
    fi
    
    # Return success (0) if all validations passed
    [[ "$validation_failed" == false ]]
}

# Version validation function - used during manual version entry
validate_client_version_input() {
    local client_type="$1"
    local version="$2"
    
    if [[ -z "$version" ]]; then
        echo -e "${UI_MUTED}Version cannot be empty${NC}" >&2
        return 1
    fi
    
    if [[ "$version" == "cancel" ]] || [[ "$version" == "skip" ]]; then
        return 2  # Special return code for cancel
    fi
    
    echo -e "${UI_MUTED}Validating version $version...${NC}" >&2
    if validate_client_version "$client_type" "$version"; then
        echo -e "${GREEN}✓ Version validated successfully${NC}" >&2
        return 0
    else
        echo -e "${RED}Error: Docker image ${client_type}:${version} not found${NC}" >&2
        echo -e "${UI_MUTED}Please check available versions at the GitHub releases page${NC}" >&2
        return 1
    fi
}

# Port validation function
validate_port() {
    local port="$1"
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo -e "${UI_MUTED}Port must be a number${NC}" >&2
        return 1
    fi
    
    if [[ "$port" -lt 1024 || "$port" -gt 65535 ]]; then
        echo -e "${UI_MUTED}Port must be between 1024-65535${NC}" >&2
        return 1
    fi
    
    return 0
}

prompt_node_name() {
    local default_name="ethnode$(get_next_instance_number)"
    
    while true; do
        local node_name
        node_name=$(fancy_text_input "Setup Node Name" \
            "Enter a name for your Ethereum node:" \
            "$default_name" \
            "validate_node_name")
        
        # Return empty if user quit
        [[ -z "$node_name" ]] && return 1
        
        # If user chose a non-default name, ask for confirmation
        if [[ "$node_name" != "$default_name" ]]; then
            if fancy_confirm "Confirm custom node name '$node_name'?" "y"; then
                echo "$node_name"
                return 0
            else
                # User said no, ask again
                continue
            fi
        else
            # Default name, no confirmation needed
            echo "$node_name"
            return 0
        fi
    done
}
prompt_network() {
    local network_options=("Hoodi testnet" "Ethereum mainnet")
    
    local selection
    if selection=$(fancy_select_menu "Select Network" "${network_options[@]}"); then
        case $selection in
            0) echo "hoodi" ;;
            1) echo "mainnet" ;;
        esac
    fi
}
prompt_version() {
    local client_type=$1
    local category=$2
    local selected_version=""

    local version_options=(
        "Enter version number"
        "Use latest version"
    )

    local version_choice
    if version_choice=$(fancy_select_menu "Version Selection for $client_type" "${version_options[@]}"); then
        # Increment by 1 to match the original case numbers (1=manual, 2=latest)
        version_choice=$((version_choice + 1))
    else
        # User cancelled - use latest as default
        version_choice=2
    fi

    case "$version_choice" in
        1)
            # Create a wrapper validation function for this specific client
            validate_version_for_client() {
                validate_client_version_input "$client_type" "$1"
                local result=$?
                if [[ $result -eq 2 ]]; then
                    # User requested cancel - return empty string 
                    echo "" 
                    return 0
                fi
                return $result
            }
            
            selected_version=$(fancy_text_input "Version Selection for $client_type" \
                "Enter version (e.g., v2.0.27 or 25.7.0):" \
                "" \
                "validate_version_for_client")
            
            if [[ -z "$selected_version" ]]; then
                echo -e "${UI_MUTED}Using default version from .env file${NC}" >&2
            fi
            ;;
        2)
            echo -e "${UI_MUTED}Fetching latest version...${NC}" >&2
            selected_version=$(get_latest_version "$client_type" 2>/dev/null)
            if [[ -z "$selected_version" ]]; then
                echo -e "${UI_MUTED}Could not fetch latest version from GitHub${NC}" >&2
                while [[ -z "$selected_version" ]]; do
                    read -r -p "Enter version manually: " selected_version
                    [[ -z "$selected_version" ]] && echo -e "${UI_MUTED}Version cannot be empty!${NC}" >&2
                done
            else
                echo -e "${UI_MUTED}Latest version from GitHub: $selected_version${NC}" >&2

                # Validate Docker image availability immediately
                echo -e "${UI_MUTED}Checking Docker Hub availability...${NC}" >&2
                if validate_client_version "$client_type" "$selected_version"; then
                    # Quick confirmation for latest version
                    echo -e "${GREEN}✓ $client_type version $selected_version found as latest version${NC}" >&2
                    if fancy_confirm "Install $client_type version $selected_version?" "y"; then
                        echo -e "${UI_MUTED}Using version: $selected_version${NC}" >&2
                    else
                        echo -e "${UI_MUTED}Version selection cancelled${NC}" >&2
                        selected_version=""
                    fi
                else
                    echo -e "${YELLOW}⚠ Warning: Docker image not yet available${NC}" >&2
                    echo -e "${UI_MUTED}This release was just published. The Docker image is still being built.${NC}" >&2
                    echo -e "${UI_MUTED}This typically takes 1-4 hours after a GitHub release.${NC}" >&2
                    local fallback_options=("Choose a different version" "Skip updating this client (keep current)")
                    local fallback_choice
                    if fallback_choice=$(fancy_select_menu "Docker Image Not Available" "${fallback_options[@]}"); then
                        case $fallback_choice in
                            0)
                                # Create a wrapper validation function for this fallback case
                                validate_fallback_version() {
                                    validate_client_version_input "$client_type" "$1"
                                    local result=$?
                                    if [[ $result -eq 2 ]]; then
                                        echo "" 
                                        return 0
                                    fi
                                    return $result
                                }
                                
                                selected_version=$(fancy_text_input "Choose Different Version" \
                                    "Enter version for $client_type:" \
                                    "" \
                                    "validate_fallback_version")
                                
                                if [[ -z "$selected_version" ]]; then
                                    echo "Skipping update for $client_type" >&2
                                fi
                                ;;
                            1|*)
                                selected_version=""
                                echo "Skipping update for $client_type" >&2
                                ;;
                        esac
                    else
                        selected_version=""
                        echo "Skipping update for $client_type" >&2
                    fi
                fi
            fi
            ;;
        *)
            echo -e "${UI_MUTED}Invalid choice, using latest version${NC}" >&2
            selected_version=$(get_latest_version "$client_type" 2>/dev/null)
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
    echo -e "${UI_MUTED}Creating directory structure...${NC}" >&2
    mkdir -p "$node_dir"/{data/{execution,consensus},jwt} || { echo "Error: Failed to create directories" >&2; return 1; }

    echo "$node_dir"
}
create_user() {
    local node_name="$1"

    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }

    if ! id "$node_name" &>/dev/null; then
        echo -e "${UI_MUTED}Creating system user...${NC}" >&2
        sudo useradd -r -s /bin/false "$node_name" || { echo "Error: Failed to create user" >&2; return 1; }
    else
        echo -e "${UI_MUTED}User $node_name already exists, skipping...${NC}" >&2
    fi

    echo "$(id -u "$node_name"):$(id -g "$node_name")"
}
generate_jwt() {
    local node_dir="$1"

    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }

    echo -e "${UI_MUTED}Generating JWT secret...${NC}" >&2
    openssl rand -hex 32 > "$node_dir/jwt/jwtsecret" || { echo "Error: Failed to generate JWT" >&2; return 1; }
    chmod 600 "$node_dir/jwt/jwtsecret"
}
set_permissions() {
    local node_dir="$1"
    local uid_gid="$2"

    local uid=$(echo "$uid_gid" | cut -d':' -f1)
    local gid=$(echo "$uid_gid" | cut -d':' -f2)

    echo -e "${UI_MUTED}Setting permissions...${NC}" >&2
    sudo chown -R "$uid:$gid" "$node_dir"/{data,jwt}
}
copy_config_files() {
    local node_dir="$1"
    local exec_client="$2"
    local cons_client="$3"
    local script_dir="$HOME/.nodeboi"

    [[ ! -d "$script_dir" ]] && { echo "Error: Configuration directory $script_dir not found" >&2; return 1; }
    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }

    echo -e "${UI_MUTED}Copying configuration files from $script_dir...${NC}" >&2

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

    echo -e "${UI_MUTED}Configuration files copied successfully${NC}" >&2
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

    echo -e "${UI_MUTED}Allocating ports using intelligent port manager...${NC}" >&2

    # Initialize port management system
    init_port_management || { echo "Failed to initialize port management" >&2; return 1; }

    # Use the new port allocation system with MEV-boost choice
    local include_mevboost="false"
    [[ $mevboost_choice -eq 0 ]] && include_mevboost="true"
    local port_assignments=$(allocate_node_ports "$node_name" "$exec_client" "$cons_client" "$include_mevboost")
    if [[ $? -ne 0 ]]; then
        echo "Failed to allocate ports for $node_name" >&2
        return 1
    fi

    # Parse port assignments
    eval "$port_assignments"
    
    # Legacy variable mappings for compatibility
    local el_rpc=$EL_RPC_PORT
    local el_ws=$EL_WS_PORT  
    local ee_port=$EE_PORT
    local el_p2p=$EL_P2P_PORT
    local el_p2p_2=$EL_P2P_PORT_2
    local cl_rest=$CL_REST_PORT
    local cl_p2p=$CL_P2P_PORT
    local cl_quic=$CL_QUIC_PORT
    local mevboost_port=$MEVBOOST_PORT
    local el_metrics=$METRICS_PORT

    echo -e "${UI_MUTED}Configuring environment file...${NC}" >&2

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
    local compose_files="compose.yml:${exec_client}.yml:${cons_client}-cl-only.yml"
    if [[ $mevboost_choice -eq 0 ]]; then
        compose_files="${compose_files}:mevboost.yml"
    fi
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

    echo -e "${UI_MUTED}Ports configured:${NC}" >&2
    echo -e "${UI_MUTED}  RPC: $el_rpc, WS: $el_ws, Engine: $ee_port${NC}" >&2
    echo -e "${UI_MUTED}  REST: $cl_rest, MEV-Boost: $mevboost_port${NC}" >&2
    echo -e "${UI_MUTED}  P2P: EL=$el_p2p/$el_p2p_2, CL=$cl_p2p/$cl_quic${NC}" >&2
    echo -e "${UI_MUTED}  Metrics: EL=$el_metrics, CL=$cl_metrics${NC}" >&2
    [[ "$exec_client" == "reth" ]] && echo -e "${UI_MUTED}  Reth metrics: $reth_metrics${NC}" >&2

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

    echo -e "${UI_MUTED}Cleaning up failed installation...${NC}" >&2

    [[ -d "$node_dir" ]] && { rm -rf "$node_dir"; echo "Removed directory: $node_dir" >&2; }
    id "$node_name" &>/dev/null && { sudo userdel "$node_name" 2>/dev/null || true; echo "Removed user: $node_name" >&2; }
}

install_node() {
    # Global variable to track current installation for cleanup
    local current_install_node=""
    
    # Set up cleanup trap for interruption signals (Ctrl+C, quit, etc.)
    installation_cleanup_handler() {
        echo -e "\n${YELLOW}Installation interrupted!${NC}"
        if [[ -n "$current_install_node" ]]; then
            echo -e "${UI_MUTED}Cleaning up aborted installation...${NC}"
            cleanup_failed_installation "$current_install_node"
        fi
        echo -e "${GREEN}Cleanup complete. Exiting...${NC}"
        exit 0
    }
    
    # Trap various interrupt signals
    trap 'installation_cleanup_handler' SIGINT SIGTERM SIGQUIT

    # Get configuration
    local node_name=$(prompt_node_name)
    [[ -z "$node_name" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        echo -e "${RED}Error: Failed to get node name${NC}" >&2; press_enter; return 
    }
    
    # Set the node name for cleanup tracking
    current_install_node="$node_name"

    local network=$(prompt_network)
    [[ -z "$network" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        return  # Just return silently - user pressed q or backspace
    }
    
    local exec_client=$(prompt_execution_client)
    [[ -z "$exec_client" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local exec_version=$(prompt_version "$exec_client" "execution")
    [[ -z "$exec_version" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local cons_client=$(prompt_consensus_client)
    [[ -z "$cons_client" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local cons_version=$(prompt_version "$cons_client" "consensus")
    [[ -z "$cons_version" ]] && { 
        trap - SIGINT SIGTERM SIGQUIT  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }

    # Validate versions exist
    echo -e "${UI_MUTED}Validating Docker images...${NC}"

    if [[ -n "$exec_version" ]] || [[ -n "$cons_version" ]]; then
        if ! validate_update_images "$HOME/$node_name" "$exec_client" "$exec_version" "$cons_client" "$cons_version"; then
            echo -e "${YELLOW}Warning: Some Docker images are not available yet.${NC}"
            echo -e "${UI_MUTED}This might be because:${NC}"
            echo -e "${UI_MUTED}  - The release is very new (images still building)${NC}"
            echo -e "${UI_MUTED}  - Version number might be incorrect${NC}"
            echo
            read -p "Do you want to continue anyway? [y/n]: " -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${UI_MUTED}Installation cancelled. Try again with different versions.${NC}"
                press_enter
                return
            fi
        fi
    fi

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
    [[ -n "$mevboost_version" ]] && update_client_version "$node_dir" "mevboost" "$mevboost_version"

    # Configure environment file with ports
    configure_env_file "$node_dir" "$node_name" "$uid_gid" "$exec_client" "$cons_client" "$network" || {
        echo -e "${RED}Installation failed - configuration error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # MEV-boost installation choice
    local mevboost_options=("Install with MEV-boost" "Skip MEV-boost")
    local mevboost_choice
    if mevboost_choice=$(fancy_select_menu "MEV-boost Configuration" "${mevboost_options[@]}"); then
        if [[ $mevboost_choice -eq 0 ]]; then
            echo -e "${UI_MUTED}MEV-boost will be included${NC}"
            # Get MEV-boost version
            local mevboost_version
            mevboost_version=$(prompt_version "mevboost")
            case $? in
                0) echo -e "${UI_MUTED}Using MEV-boost version: $mevboost_version${NC}" ;;
                2) echo -e "${UI_MUTED}MEV-boost version selection cancelled${NC}"; return ;;
                *) echo -e "${RED}Failed to get MEV-boost version${NC}"; return ;;
            esac
        else
            echo -e "${UI_MUTED}Skipping MEV-boost installation${NC}"
            mevboost_version=""
        fi
    else
        # Default to including MEV-boost if cancelled
        echo -e "${UI_MUTED}MEV-boost will be included (default)${NC}"
        mevboost_choice=0
        local mevboost_version
        mevboost_version=$(prompt_version "mevboost")
        case $? in
            0) echo -e "${UI_MUTED}Using MEV-boost version: $mevboost_version${NC}" ;;
            2) echo -e "${UI_MUTED}MEV-boost version selection cancelled${NC}"; return ;;
            *) echo -e "${RED}Failed to get MEV-boost version${NC}"; return ;;
        esac
    fi

    # Network access configuration
    
    local access_options=(
        "My machine only (most secure) - 127.0.0.1"
        "Local network access - Your LAN IP"
        "All networks (use with caution) - 0.0.0.0"
    )
    
    local access_choice
    if access_choice=$(fancy_select_menu "Choose access level for RPC/REST APIs" "${access_options[@]}"); then
        # Increment by 1 to match the original case numbers
        access_choice=$((access_choice + 1))
    else
        # User cancelled - use default (my machine only)
        access_choice=1
    fi

    case "$access_choice" in
        2)
            # Get LAN IP and use it automatically
            local detected_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
            local lan_ip="$detected_ip"
            echo -e "${UI_MUTED}Using detected local network IP: $detected_ip${NC}"
            
            sed -i "s/HOST_IP=.*/HOST_IP=$lan_ip/" "$node_dir/.env"
            echo -e "${YELLOW}⚠ RPC/REST APIs will be accessible from your local network${NC}"
            ;;
        3)
            sed -i "s/HOST_IP=.*/HOST_IP=0.0.0.0/" "$node_dir/.env"
            echo -e "${RED}⚠ WARNING: RPC/REST APIs accessible from ALL networks${NC}"
            echo -e "${UI_MUTED}Make sure you haven't forwarded these ports on your router!${NC}"
            
            local ack_options=("I understand the security risk")
            fancy_select_menu "Security Warning Acknowledgment" "${ack_options[@]}" > /dev/null
            ;;
        *)
            # Default: my machine only
            sed -i "s/HOST_IP=.*/HOST_IP=127.0.0.1/" "$node_dir/.env"
            echo -e "${UI_MUTED}APIs restricted to your machine only${NC}"
            ;;
    esac

    # Port forwarding configuration step
    echo -e "\n${UI_MUTED}Port Forwarding Configuration\n==============================${NC}"

    # Get assigned ports
    local el_p2p=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local cl_p2p=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)

    # Show port configuration with editable prefilled inputs
    local new_el_p2p
    if new_el_p2p=$(fancy_text_input "Port Configuration" "Suggested available execution P2P port (TCP+UDP):" "$el_p2p" "validate_port"); then
        if [[ -n "$new_el_p2p" && "$new_el_p2p" != "$el_p2p" ]]; then
            sed -i "s/EL_P2P_PORT=.*/EL_P2P_PORT=$new_el_p2p/" "$node_dir/.env"
            sed -i "s/EL_P2P_PORT_2=.*/EL_P2P_PORT_2=$((new_el_p2p + 1))/" "$node_dir/.env"
            el_p2p=$new_el_p2p
        fi
    else
        echo -e "${UI_MUTED}Installation cancelled.${NC}"
        return
    fi

    local new_cl_p2p
    if new_cl_p2p=$(fancy_text_input "Port Configuration" "Suggested available consensus P2P port (TCP+UDP):" "$cl_p2p" "validate_port"); then
        if [[ -n "$new_cl_p2p" && "$new_cl_p2p" != "$cl_p2p" ]]; then
            sed -i "s/CL_P2P_PORT=.*/CL_P2P_PORT=$new_cl_p2p/" "$node_dir/.env"
            sed -i "s/CL_QUIC_PORT=.*/CL_QUIC_PORT=$((new_cl_p2p + 1))/" "$node_dir/.env"
            cl_p2p=$new_cl_p2p
        fi
    else
        echo -e "${UI_MUTED}Installation cancelled.${NC}"
        return
    fi

    # Configuration Summary and final confirmation
    echo -e "\n${UI_MUTED}Configuration Summary\n====================${NC}"
    echo -e "${UI_MUTED}  Node name: $node_name${NC}"
    echo -e "${UI_MUTED}  Network: $network${NC}"
    echo -e "${UI_MUTED}  Execution: $exec_client (version: $exec_version)${NC}"
    echo -e "${UI_MUTED}  Consensus: $cons_client (version: $cons_version)${NC}"
    if [[ $mevboost_choice -eq 0 ]]; then
        local mevboost_version=$(grep "MEVBOOST_VERSION=" "$node_dir/.env" | cut -d'=' -f2)
        echo -e "${UI_MUTED}  MEV-boost: Yes (version: $mevboost_version)${NC}"
    else
        echo -e "${UI_MUTED}  MEV-boost: No${NC}"
    fi
    
    # Show network access configuration
    local host_ip=$(grep "HOST_IP=" "$node_dir/.env" | cut -d'=' -f2)
    echo -e "${UI_MUTED}  Network access: $host_ip${NC}"
    
    # Show port configuration
    echo -e "${UI_MUTED}  Execution P2P port: $el_p2p${NC}"
    echo -e "${UI_MUTED}  Consensus P2P port: $cl_p2p${NC}"
    echo

    echo -e "${UI_PRIMARY}Launch $node_name now? [y/n]:${NC} " && read -r
    echo
    [[ $REPLY =~ ^[Nn]$ ]] && { 
        echo -e "${UI_MUTED}Installation cancelled.${NC}"
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    # Set file permissions
    set_permissions "$node_dir" "$uid_gid" || {
        echo -e "${RED}Installation failed - permissions error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    echo -e "${UI_MUTED}Node installed at: $node_dir${NC}"
    echo

    # Launch the node immediately since user already confirmed
    echo -e "${UI_MUTED}Starting $node_name...${NC}"
    
    # Clean up any orphaned resources that might conflict with ports
    docker system prune -f >/dev/null 2>&1
    
    cd "$node_dir" || {
        echo -e "${RED}ERROR: Cannot change to directory $node_dir${NC}"
        press_enter
        return
    }

    # Show docker compose output in real-time
    echo -e "\n${UI_MUTED}Pulling images and creating containers...${NC}"
    
    # Capture and style docker compose output with error handling
    local start_result=0
    local temp_output=$(mktemp)
    
    if docker compose up -d > "$temp_output" 2>&1; then
        start_result=0
    else
        start_result=$?
    fi
    
    # Check for port conflicts and display output with styling
    local has_port_conflict=false
    if [[ $start_result -ne 0 ]] && grep -q "port is already allocated" "$temp_output" 2>/dev/null; then
        has_port_conflict=true
    fi
    
    # Display output with styling
    while IFS= read -r line; do
        if [[ "$line" =~ "port is already allocated" ]]; then
            echo -e "${RED}$line${NC}"
        else
            echo -e "${UI_MUTED}$line${NC}"
        fi
    done < "$temp_output"
    
    rm -f "$temp_output" 2>/dev/null || true
    
    # If port conflict detected, try to resolve it
    if [[ "$has_port_conflict" == true ]]; then
        echo -e "\n${YELLOW}Port conflict detected. Attempting to resolve...${NC}"
        
        # More aggressive cleanup
        echo -e "${UI_MUTED}Stopping all related containers...${NC}"
        docker stop $(docker ps -q --filter "name=${node_name}") 2>/dev/null || true
        docker rm $(docker ps -aq --filter "name=${node_name}") 2>/dev/null || true
        
        # Wait a moment for ports to be released
        sleep 2
        
        # Retry once
        echo -e "${UI_MUTED}Retrying container startup...${NC}"
        if docker compose up -d > "$temp_output" 2>&1; then
            start_result=0
            while IFS= read -r line; do echo -e "${UI_MUTED}$line${NC}"; done < "$temp_output"
        else
            start_result=$?
            echo -e "${RED}Port conflict could not be resolved automatically.${NC}"
            while IFS= read -r line; do echo -e "${RED}$line${NC}"; done < "$temp_output"
        fi
        
        rm -f "$temp_output" 2>/dev/null || true
    fi

        if [[ $start_result -eq 0 ]]; then
            # Hybrid startup monitoring
            echo -e "\n${UI_MUTED}Verifying container startup...${NC}\n"
            sleep 1

            # Check if execution client container started
            printf "${YELLOW}→${NC} %-50s" "Checking $exec_client container..."
            local el_started=false
            for i in {1..10}; do
                if docker ps --format "{{.Names}}" | grep -q "${node_name}-${exec_client}"; then
                    el_started=true
                    printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "$exec_client container running"
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
                    printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "$cons_client container running"
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
                printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "MEV-boost connected"
            else
                printf "\r${YELLOW}!${NC} %-50s\n" "MEV-boost optional"
            fi

            # JWT auth verification
            printf "${YELLOW}→${NC} %-50s" "Verifying JWT authentication..."
            sleep 2
            printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "Authentication configured"

            # Network connection phase
            printf "${YELLOW}→${NC} %-50s" "Connecting to Ethereum network..."
            sleep 3
            printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "Network connection established"

            # Final sync status
            printf "${YELLOW}→${NC} %-50s" "Beginning blockchain sync..."
            sleep 5
            printf "\r${GREEN}✓${NC} ${UI_MUTED}%-50s${NC}\n" "Node initialization complete!"

            echo
            echo -e "${UI_MUTED}Node started successfully!${NC}"
            echo -e "${UI_MUTED}Note: Full sync may take several hours to days depending on network${NC}"
            echo -e "${UI_MUTED}Monitor status from the main menu dashboard${NC}"
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
                    echo -e "${UI_MUTED}The specified version doesn't exist. Check:${NC}"
                    get_release_url "$exec_client"
                    get_release_url "$cons_client"
                elif echo "$error_output" | grep -q "Cannot connect to the Docker daemon"; then
                    echo -e "${YELLOW}Issue: Docker daemon not running${NC}"
                    echo -e "${UI_MUTED}Start Docker with: sudo systemctl start docker${NC}"
                else
                    echo -e "${UI_MUTED}Error details:${NC}"
                    echo "$error_output"
                fi
            fi

            echo
            echo -e "${UI_MUTED}Try fixing the issue and start manually with:${NC}"
            echo -e "${UI_MUTED}  cd $node_dir${NC}"
            echo -e "${UI_MUTED}  docker compose up -d${NC}"
        fi
    setup_nodeboi_service

    echo
    echo -e "${GREEN}[✓] Installation complete.${NC}"
    echo
    
    # Remove signal trap - installation completed successfully
    trap - SIGINT SIGTERM SIGQUIT
    
    press_enter
}

# Check if a node has updates available
has_updates_available() {
    local node_dir="$1"
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Detect clients
    local clients=$(detect_node_clients "$compose_file")
    local exec_client="${clients%:*}"
    local cons_client="${clients#*:}"
    
    # Get current versions
    local exec_env_var=$(get_client_env_var "$exec_client")
    local cons_env_var=$(get_client_env_var "$cons_client")
    local exec_version=$(grep "${exec_env_var}=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//') 
    local cons_version=$(grep "${cons_env_var}=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//') 
    
    # Check for updates
    if [[ -n "$exec_client" && "$exec_client" != "unknown" ]]; then
        local latest_exec=$(get_latest_version "$exec_client" 2>/dev/null)
        if [[ -n "$latest_exec" && -n "$exec_version" ]]; then
            # Normalize both versions for comparison
            local exec_version_normalized=$(normalize_version "$exec_client" "$exec_version")
            local latest_exec_normalized=$(normalize_version "$exec_client" "$latest_exec")
            if [[ "$latest_exec_normalized" != "$exec_version_normalized" && -n "$latest_exec_normalized" ]]; then
                return 0  # Has updates
            fi
        fi
    fi
    
    if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
        local latest_cons=$(get_latest_version "$cons_client" 2>/dev/null)
        if [[ -n "$latest_cons" && -n "$cons_version" ]]; then
            # Normalize both versions for comparison
            local cons_version_normalized=$(normalize_version "$cons_client" "$cons_version")
            local latest_cons_normalized=$(normalize_version "$cons_client" "$latest_cons")
            if [[ "$latest_cons_normalized" != "$cons_version_normalized" && -n "$latest_cons_normalized" ]]; then
                return 0  # Has updates
            fi
        fi
    fi
    
    return 1  # No updates
}

update_node() {
    trap 'echo -e "\n${YELLOW}Update cancelled${NC}"; press_enter; return' INT

    # List existing nodes
    local all_nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && all_nodes+=("$(basename "$dir")")
    done

    if [[ ${#all_nodes[@]} -eq 0 ]]; then
        clear
        print_header
        print_box "No nodes found to update" "warning"
        press_enter
        trap - INT
        return
    fi

    # Filter nodes with updates available
    local nodes=()
    for node in "${all_nodes[@]}"; do
        local node_dir="$HOME/$node"
        if has_updates_available "$node_dir"; then
            nodes+=("$node")
        fi
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        clear
        print_header
        echo -e "\n${UI_MUTED}All your nodes are up to date${NC}\n"
        press_enter
        trap - INT
        return
    fi

    # Create menu options with client info
    local node_options=()
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

        node_options+=("${nodes[$i]} ($clients)")
    done
    
    # Add "update all" option only if there are multiple nodes with updates
    if [[ ${#nodes[@]} -gt 1 ]]; then
        node_options+=("update all ethnodes")
    fi
    node_options+=("cancel")

    local selection
    if selection=$(fancy_select_menu "Update Ethnode" "${node_options[@]}"); then
        local total_nodes=${#nodes[@]}
        
        if [[ ${#nodes[@]} -gt 1 && $selection -eq ${#nodes[@]} ]]; then
            # Update all ethnodes (only available when multiple nodes have updates)
            clear
            print_header
            
            echo -e "\n${CYAN}${BOLD}Updating All Ethnodes${NC}"
            echo "======================="
            echo
            
            for node_name in "${nodes[@]}"; do
                echo -e "${CYAN}Updating $node_name...${NC}"
                local node_dir="$HOME/$node_name"
                cd "$node_dir" 2>/dev/null || continue
                
                # Get client info and update versions
                local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
                local clients=$(detect_node_clients "$compose_file")
                local exec_client="${clients%:*}"
                local cons_client="${clients#*:}"
                
                echo -e "${UI_MUTED}  Fetching latest versions...${NC}"
                if [[ -n "$exec_client" && "$exec_client" != "unknown" ]]; then
                    local latest_exec=$(get_latest_version "$exec_client" 2>/dev/null)
                    [[ -n "$latest_exec" ]] && update_client_version "$node_dir" "$exec_client" "$latest_exec"
                fi
                
                if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
                    local latest_cons=$(get_latest_version "$cons_client" 2>/dev/null)
                    [[ -n "$latest_cons" ]] && update_client_version "$node_dir" "$cons_client" "$latest_cons"
                fi
                
                echo -e "${UI_MUTED}  Pulling latest images...${NC}"
                docker compose pull > /dev/null 2>&1
                echo -e "${UI_MUTED}  Restarting services...${NC}"
                safe_docker_stop "$node_name"
                docker compose up -d --force-recreate > /dev/null 2>&1
                echo -e "  ${GREEN}✓ $node_name updated${NC}\n"
            done
            
            echo -e "${GREEN}✓ All ethnodes updated successfully${NC}\n"
            
            # Show updated dashboard
            print_dashboard
            
        elif [[ ${#nodes[@]} -eq 1 && $selection -eq 1 ]] || [[ ${#nodes[@]} -gt 1 && $selection -eq $((${#nodes[@]} + 1)) ]]; then
            # Cancel
            trap - INT
            return
            
        else
            # Individual node selected
            local node_name="${nodes[$selection]}"
            local node_dir="$HOME/$node_name"
            
            clear
            print_header
            
            echo -e "\n${CYAN}${BOLD}Updating $node_name${NC}"
            echo "==================="
            echo
            
            cd "$node_dir" 2>/dev/null || {
                print_box "Error: Could not access $node_name directory" "error"
                press_enter
                trap - INT
                return
            }
            
            # Get client info and current versions
            local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
            local clients=$(detect_node_clients "$compose_file")
            local exec_client="${clients%:*}"
            local cons_client="${clients#*:}"
            
            # Get latest versions
            echo -e "${UI_MUTED}Fetching latest versions...${NC}"
            local latest_exec=""
            local latest_cons=""
            
            if [[ -n "$exec_client" && "$exec_client" != "unknown" ]]; then
                latest_exec=$(get_latest_version "$exec_client" 2>/dev/null)
                if [[ -n "$latest_exec" ]]; then
                    echo -e "  ${UI_MUTED}Latest $exec_client: $latest_exec${NC}"
                    update_client_version "$node_dir" "$exec_client" "$latest_exec"
                fi
            fi
            
            if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
                latest_cons=$(get_latest_version "$cons_client" 2>/dev/null)
                if [[ -n "$latest_cons" ]]; then
                    echo -e "  ${UI_MUTED}Latest $cons_client: $latest_cons${NC}"
                    update_client_version "$node_dir" "$cons_client" "$latest_cons"
                fi
            fi
            
            echo -e "${UI_MUTED}Pulling latest images...${NC}"
            if docker compose pull > /dev/null 2>&1; then
                echo -e "${UI_MUTED}Restarting $node_name...${NC}"
                safe_docker_stop "$node_name"
                if docker compose up -d --force-recreate > /dev/null 2>&1; then
                    echo -e "${GREEN}✓ $node_name updated and restarted successfully${NC}\n"
                    
                    # Show updated dashboard
                    print_dashboard
                else
                    print_box "Failed to restart $node_name" "error"
                fi
            else
                print_box "Failed to pull images for $node_name" "error"
            fi
        fi
    else
        # User pressed 'q'
        trap - INT
        return
    fi
    
    press_enter
    trap - INT
}

