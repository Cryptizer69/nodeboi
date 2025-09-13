#!/bin/bash
# lib/ethnode-manager.sh - Ethereum node installation, updates, and management

# Source dependencies
[[ -f "${NODEBOI_LIB}/port-manager.sh" ]] && source "${NODEBOI_LIB}/port-manager.sh"
[[ -f "${NODEBOI_LIB}/ui.sh" ]] && source "${NODEBOI_LIB}/ui.sh"

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
    echo "$default_name"
    return 0
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
# Get default version for pre-filling manual input
get_default_version() {
    local client_type="$1"
    case "${client_type,,}" in  # Convert to lowercase
        "reth") echo "v1.7.0" ;;
        "besu") echo "25.8.0" ;;
        "nethermind") echo "1.32.4" ;;
        "teku") echo "25.9.2" ;;
        "lodestar") echo "v1.34.1" ;;
        "grandine") echo "1.1.4" ;;
        "mevboost"|"mev-boost") echo "1.9" ;;
        *) echo "" ;;  # No default for unknown clients
    esac
}

prompt_version() {
    local client_type=$1
    local category=$2
    local selected_version=""

    local version_options=(
        "Enter version number (recommended)"
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
            
            # Get default version for pre-fill
            local default_version=$(get_default_version "$client_type")
            selected_version=$(fancy_text_input "Version Selection for $client_type" \
                "Enter version (e.g., v2.0.27 or 25.7.0):" \
                "$default_version" \
                "validate_version_for_client")
            
            if [[ -z "$selected_version" ]]; then
                echo -e "${UI_MUTED}Using default version from .env file${NC}" >&2
            fi
            ;;
        2)
            echo -e "${UI_MUTED}Fetching latest version...${NC}" >&2
            selected_version=$(get_latest_version "$client_type" 2>/dev/null)
            if [[ -z "$selected_version" ]]; then
                echo -e "${YELLOW}⚠ Could not fetch latest version from GitHub API${NC}" >&2
                echo -e "${UI_MUTED}This may be due to network issues or GitHub being unavailable${NC}" >&2
                echo
                echo -e "${UI_MUTED}Please enter a version manually. Check GitHub releases for current versions:${NC}"
                echo -e "${UI_MUTED}  $(get_release_url "$client_type")${NC}"
                echo
                echo -e "${UI_MUTED}Version format examples:${NC}"
                case "$client_type" in
                    reth|lodestar) echo -e "${UI_MUTED}  • With 'v' prefix: v1.1.4, v1.25.0${NC}" ;;
                    *) echo -e "${UI_MUTED}  • Without 'v' prefix: 24.12.0, 1.30.0${NC}" ;;
                esac
                echo
                while [[ -z "$selected_version" ]]; do
                    read -r -p "Enter version: " selected_version
                    if [[ -z "$selected_version" ]]; then
                        echo -e "${UI_MUTED}Version cannot be empty!${NC}" >&2
                    else
                        # Validate the format
                        if validate_client_version "$client_type" "$selected_version"; then
                            echo -e "${GREEN}✓ Version $selected_version is available${NC}" >&2
                        else
                            echo -e "${YELLOW}⚠ Warning: Could not verify Docker image availability${NC}" >&2
                            if fancy_confirm "Use version $selected_version anyway?" "n"; then
                                echo -e "${UI_MUTED}Using unverified version: $selected_version${NC}" >&2
                            else
                                selected_version=""
                                continue
                            fi
                        fi
                    fi
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

# Create directories in staging location for atomic installation
create_directories_in_staging() {
    local staging_dir="$1"
    local node_name="$2"

    [[ -z "$staging_dir" ]] && { echo "Error: Staging directory is empty" >&2; return 1; }
    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }

    echo -e "${UI_MUTED}Creating staging directory structure...${NC}" >&2
    mkdir -p "$staging_dir"/{data/{execution,consensus},jwt} || { 
        echo "Error: Failed to create staging directories" >&2; return 1; 
    }

    echo "$staging_dir"
}

# Create compose.yml file with 2-network model for atomic installation
create_atomic_compose_file() {
    local node_dir="$1"
    
    [[ -z "$node_dir" ]] && { echo "Error: Node directory is empty" >&2; return 1; }
    
    # Create compose.yml with proper 2-network configuration
    cat > "$node_dir/compose.yml" <<'EOF'
x-logging: &logging
 logging:
   driver: json-file
   options:
     max-size: 100m
     max-file: "3"
     tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

networks:
  default:
    external: true
    name: nodeboi-net
    enable_ipv6: ${IPV6:-false}
EOF
    
    echo -e "${UI_MUTED}Created compose.yml with nodeboi-net configuration${NC}" >&2
}

create_user() {
    local node_name="$1"

    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }

    # Use current user (eth-docker pattern - no system user needed)
    local node_uid=$(id -u)
    local node_gid=$(id -g)
    
    echo -e "${UI_MUTED}Using current user: UID=${node_uid}, GID=${node_gid}${NC}" >&2

    echo "${node_uid}:${node_gid}"
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

    echo -e "${UI_MUTED}Setting permissions...${NC}" >&2
    # Using current user - permissions should already be correct, but ensure directory access
    chmod 755 "$node_dir/data"
    chmod 755 "$node_dir/data/execution" "$node_dir/data/consensus"
    chmod 700 "$node_dir/jwt"
    chmod 600 "$node_dir/jwt/jwtsecret"
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
    # No system user cleanup needed - using current user
}

install_node() {
    # Enable strict error handling for atomic installation
    set -eE
    set -o pipefail
    
    local node_name=""
    local staging_dir=""
    local final_dir=""
    local installation_success=false
    
    # Comprehensive cleanup for atomic installation
    atomic_installation_cleanup() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "\n${RED}✗${NC} Ethnode installation failed"
        echo -e "${UI_MUTED}Performing complete cleanup...${NC}"
        
        # Stop and remove any Docker resources
        if [[ -d "$staging_dir" && -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>/dev/null || true
        fi
        
        # Remove containers by name pattern
        if [[ -n "$node_name" ]]; then
            docker ps -aq --filter "name=${node_name}" | xargs -r docker rm -f 2>/dev/null || true
            # Remove any networks created
            # Note: Using shared nodeboi-net, no individual network to remove
        fi
        
        # Remove staging directory
        [[ -n "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
        
        # Never remove final_dir in cleanup - only staging
        
        echo -e "${GREEN}✓ Cleanup completed${NC}"
        echo -e "${UI_MUTED}Installation aborted - no partial installation left behind${NC}"
        
        press_enter
        return $exit_code
    }
    
    # Get configuration (without error trap yet to handle cancellations gracefully)
    node_name=$(prompt_node_name)
    [[ -z "$node_name" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
        echo -e "${RED}Error: Failed to get node name${NC}" >&2; press_enter; return 
    }
    
    # Set up staging and final directories
    staging_dir="$HOME/.${node_name}-install-$$"  # Temporary staging area
    final_dir="$HOME/$node_name"  # Final installation location
    
    # Check for existing installation
    if [[ -d "$final_dir" ]]; then
        echo -e "${YELLOW}${node_name} is already installed at $final_dir${NC}"
        echo -e "${UI_MUTED}Please remove it first if you want to reinstall${NC}"
        press_enter
        return 1
    fi

    local network=$(prompt_network)
    [[ -z "$network" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
        return  # Just return silently - user pressed q or backspace
    }
    
    local exec_client=$(prompt_execution_client)
    [[ -z "$exec_client" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local exec_version=$(prompt_version "$exec_client" "execution")
    [[ -z "$exec_version" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local cons_client=$(prompt_consensus_client)
    [[ -z "$cons_client" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
        echo -e "${RED}Installation cancelled${NC}" >&2; press_enter; return 
    }
    
    local cons_version=$(prompt_version "$cons_client" "consensus")
    [[ -z "$cons_version" ]] && { 
        trap - ERR INT TERM  # Remove trap before returning
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
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo -e "${UI_MUTED}Continuing with installation...${NC}"
            else
                echo -e "${UI_MUTED}Installation cancelled. Try again with different versions.${NC}"
                press_enter
                return
            fi
        fi
    fi

    # Create staging directory structure
    echo -e "${UI_MUTED}Creating staging environment...${NC}"
    mkdir -p "$staging_dir"
    
    # Create directory structure in staging
    local node_dir=$(create_directories_in_staging "$staging_dir" "$node_name")
    [[ -z "$node_dir" ]] && {
        echo -e "${RED}Installation failed - could not create staging directories${NC}" >&2
        return 1
    }

    # Get current user UID/GID
    local uid_gid=$(create_user "$node_name")
    [[ -z "$uid_gid" ]] && {
        echo -e "${RED}Installation failed - could not get user info${NC}" >&2
        return 1
    }

    # Generate JWT secret in staging
    echo -e "${UI_MUTED}Generating JWT secret...${NC}"
    generate_jwt "$node_dir"

    # Copy configuration files to staging
    echo -e "${UI_MUTED}Creating configuration files...${NC}"
    copy_config_files "$node_dir" "$exec_client" "$cons_client"
    
    # Update compose.yml to use 2-network model (nodeboi-net)
    echo -e "${UI_MUTED}Configuring for 2-network architecture...${NC}"
    create_atomic_compose_file "$node_dir"

    # Update versions if specified
    [[ -n "$exec_version" ]] && update_client_version "$node_dir" "$exec_client" "$exec_version"
    [[ -n "$cons_version" ]] && update_client_version "$node_dir" "$cons_client" "$cons_version"
    [[ -n "$mevboost_version" ]] && update_client_version "$node_dir" "mevboost" "$mevboost_version"

    # Configure environment file with ports
    echo -e "${UI_MUTED}Configuring environment file...${NC}"
    configure_env_file "$node_dir" "$node_name" "$uid_gid" "$exec_client" "$cons_client" "$network"

    # MEV-boost installation choice
    local mevboost_options=("Install with MEV-boost" "Skip MEV-boost")
    local mevboost_choice
    
    # Temporarily disable error trap for interactive menu
    set +e
    mevboost_choice=$(fancy_select_menu "MEV-boost Configuration" "${mevboost_options[@]}")
    local menu_result=$?
    set -e
    
    if [[ $menu_result -eq 0 ]]; then
        # Handle MEV-boost choice
        if [[ $mevboost_choice -eq 0 ]]; then
            echo -e "${UI_MUTED}MEV-boost will be included${NC}"
            # Get MEV-boost version
            local mevboost_version
            set +e
            mevboost_version=$(prompt_version "mevboost" "mevboost")
            local version_result=$?
            set -e
            case $version_result in
                0) echo -e "${UI_MUTED}Using MEV-boost version: $mevboost_version${NC}" ;;
                *) echo -e "${UI_MUTED}Installation cancelled${NC}"; return ;;
            esac
        else
            echo -e "${UI_MUTED}Skipping MEV-boost installation${NC}"
            mevboost_version=""
        fi
    else
        # User cancelled - return gracefully
        echo -e "${UI_MUTED}Installation cancelled${NC}"
        return
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
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z "$REPLY" ]]; then
        echo -e "${UI_MUTED}Launching $node_name...${NC}"
    else
        echo -e "${UI_MUTED}Installation cancelled.${NC}"
        cleanup_failed_installation "$node_name"
        press_enter
        return
    fi

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
    
    # Ensure nodeboi-net exists with explicit creation and debugging
    echo -e "${UI_MUTED}Ensuring nodeboi-net exists...${NC}"
    
    # Debug: List current networks
    echo -e "${UI_MUTED}Current Docker networks:${NC}"
    docker network ls --format "{{.Name}}" | head -5 | while read network; do 
        echo -e "${UI_MUTED}  $network${NC}"
    done
    
    if ! docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
        echo -e "${UI_MUTED}Network not found, creating nodeboi-net...${NC}"
        if docker network create nodeboi-net 2>&1; then
            echo -e "${UI_MUTED}✓ nodeboi-net created successfully${NC}"
        else
            echo -e "${RED}Failed to create nodeboi-net${NC}"
            cleanup_failed_installation "$node_name"
            press_enter
            return
        fi
    else
        echo -e "${UI_MUTED}✓ nodeboi-net already exists${NC}"
    fi
    
    # Final verification
    echo -e "${UI_MUTED}Final network verification:${NC}"
    if docker network inspect nodeboi-net >/dev/null 2>&1; then
        echo -e "${UI_MUTED}✓ nodeboi-net is ready for use${NC}"
    else
        echo -e "${RED}✗ nodeboi-net verification failed${NC}"
        cleanup_failed_installation "$node_name"
        press_enter
        return
    fi
    
    # Note: Removed aggressive system prune as it removes newly created networks
    
    cd "$node_dir" || {
        echo -e "${RED}ERROR: Cannot change to directory $node_dir${NC}"
        press_enter
        return
    }

    # Check for existing monitoring network and connect if it exists
    if docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
        echo -e "${UI_MUTED}Detected monitoring - connecting to nodeboi network...${NC}"
        
        # Add nodeboi network to compose.yml
        cat >> compose.yml << 'EOF'
  nodeboi-net:
    external: true
    name: nodeboi-net
EOF
        
        # Update all services to connect to nodeboi network
        # This uses a temporary file to modify the compose.yml
        sed -i '/^services:/,/^networks:/ { 
            /^    networks:/ { 
                a\      - nodeboi-net
            }
            /^    network_mode:/ {
                c\    networks:\
      - default\
      - nodeboi-net
            }
        }' compose.yml
    fi

    # Configuration complete - ready for atomic move
    echo -e "\n${UI_MUTED}Configuration prepared for atomic installation${NC}"
    
    setup_nodeboi_service

    # ATOMIC OPERATION: Move from staging to final location
    echo -e "${UI_MUTED}Finalizing installation...${NC}"
    echo -e "${UI_MUTED}Moving from staging to final location...${NC}"
    
    # This is the atomic operation - either it all succeeds or fails
    mv "$staging_dir" "$final_dir"
    
    # Mark installation as successful to prevent cleanup
    installation_success=true
    
    # Remove error trap now that installation is complete
    trap - ERR INT TERM
    
    # NOW start containers in final location (after atomic move)
    echo -e "${UI_MUTED}Starting services...${NC}"
    cd "$final_dir"
    
    # Re-verify nodeboi-net exists in final location context
    echo -e "${UI_MUTED}Checking nodeboi-net before container startup...${NC}"
    if ! docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
        echo -e "${UI_MUTED}Network missing! Re-creating nodeboi-net in final context...${NC}"
        docker network create nodeboi-net || echo -e "${YELLOW}Warning: Network creation failed${NC}"
    else
        echo -e "${UI_MUTED}✓ nodeboi-net confirmed present before startup${NC}"
    fi
    
    # Final check right before Docker Compose
    echo -e "${UI_MUTED}Final network verification before Docker Compose...${NC}"
    docker network ls --format "{{.Name}}" | grep nodeboi || echo -e "${YELLOW}WARNING: nodeboi-net not found!${NC}"
    
    # Start containers with proper error handling
    local temp_output=$(mktemp)
    if docker compose up -d > "$temp_output" 2>&1; then
        echo -e "${UI_MUTED}✓ All services started successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Some services may have startup issues${NC}"
        echo -e "${UI_MUTED}Error details:${NC}"
        cat "$temp_output"
        echo
        echo -e "${UI_MUTED}Services can be restarted manually with:${NC}"
        echo -e "${UI_MUTED}  cd $final_dir && docker compose up -d${NC}"
    fi
    rm -f "$temp_output" 2>/dev/null || true

    # Force immediate dashboard refresh to show new node
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    # Schedule additional refreshes to pick up health status as services initialize
    (
        sleep 5
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        sleep 5  
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    ) &

    echo
    echo -e "${GREEN}[✓] Installation complete.${NC}"
    echo
    
    # Check if Vero is installed and offer to connect the new beacon node
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        echo -e "${BLUE}Vero Integration${NC}"
        echo "================"
        echo
        echo "Vero validator is installed and can connect to this new beacon node."
        echo "This will add $node_name to Vero's beacon node list for redundancy."
        echo
        if fancy_confirm "Connect $node_name to Vero validator?" "y"; then
            # Source validator manager functions
            [[ -f "${NODEBOI_LIB}/validator-manager.sh" ]] && source "${NODEBOI_LIB}/validator-manager.sh"
            
            # Add the new beacon node to Vero's configuration
            local current_beacon_urls=$(grep "BEACON_NODE_URLS=" "$HOME/vero/.env" | cut -d'=' -f2)
            
            # Detect beacon client for the new node
            local beacon_client=""
            if docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${node_name}-grandine"; then
                beacon_client="grandine"
            elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${node_name}-lodestar"; then
                beacon_client="lodestar"
            elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${node_name}-lighthouse"; then
                beacon_client="lighthouse"
            elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${node_name}-teku"; then
                beacon_client="teku"
            else
                beacon_client="lodestar" # fallback
            fi
            
            # For container-to-container communication, always use internal port 5052
            local new_beacon_url="http://${node_name}-${beacon_client}:5052"
            local updated_beacon_urls="${current_beacon_urls},${new_beacon_url}"
            
            # Update Vero configuration
            sed -i "s|BEACON_NODE_URLS=.*|BEACON_NODE_URLS=${updated_beacon_urls}|g" "$HOME/vero/.env"
            
            # Add network connection to Vero compose file if not already present
            if ! grep -q "nodeboi-net:" "$HOME/vero/compose.yml"; then
                # Add to networks section in compose file
                sed -i "/web3signer-net: {}/a\\      nodeboi-net: {}" "$HOME/vero/compose.yml"
                # Add to external networks section  
                sed -i "/name: web3signer-net/a\\  nodeboi-net:\n    external: true\n    name: nodeboi-net" "$HOME/vero/compose.yml"
            fi
            
            echo -e "${GREEN}✓ Connected $node_name to Vero${NC}"
            echo "Vero uses majority threshold - with 3+ beacon nodes, 2 must agree for attestation signing."
            echo
            echo "Restarting Vero to apply changes..."
            cd "$HOME/vero" && docker compose down vero && docker compose up -d vero
            echo -e "${GREEN}✓ Vero restarted with new beacon node connection${NC}"
            
            # Refresh dashboard again to show Vero integration
            [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        fi
        echo
    fi
    
    # Update monitoring integration if installed (DICKS)
    if [[ -d "$HOME/monitoring" ]] && [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Updating monitoring integration...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" 
        docker_intelligent_connecting_kontainer_system --auto
        sync_grafana_dashboards
        echo -e "${GREEN}✓ Monitoring integration updated${NC}"
        echo
        
        # Final dashboard refresh to show monitoring updates
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    fi
    
    # Remove signal trap - installation completed successfully
    trap - SIGINT SIGTERM SIGQUIT
    
    # Sync monitoring integration if installed
    if [[ -d "$HOME/monitoring" ]] && [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${UI_MUTED}Updating monitoring integration...${NC}"
        source "${NODEBOI_LIB}/monitoring.sh" 
        docker_intelligent_connecting_kontainer_system --auto
        sync_grafana_dashboards
        echo -e "${GREEN}✓ Monitoring integration updated${NC}"
        echo
    fi
    
    # Health check confirmation step
    echo -e "${UI_MUTED}Checking service health...${NC}"
    cd "$final_dir"
    
    # Wait for containers to be running first
    local max_wait=30
    local wait_count=0
    while [[ $wait_count -lt $max_wait ]]; do
        local container_count=$(docker compose ps --services | wc -l)
        local running_count=$(docker compose ps --status running | wc -l)
        
        if [[ "$running_count" -eq "$container_count" ]]; then
            echo -e "${GREEN}✓ All containers are running${NC}"
            break
        else
            echo -e "${UI_MUTED}⏳ Waiting for containers to start ($wait_count/$max_wait)...${NC}"
            sleep 2
            ((wait_count+=2))
        fi
    done
    
    # Now wait for actual syncing status
    echo -e "${UI_MUTED}Waiting for blockchain sync to begin...${NC}"
    local sync_check_wait=60
    local sync_wait_count=0
    local exec_port=""
    local cons_port=""
    
    # Extract ports from .env file
    if [[ -f ".env" ]]; then
        exec_port=$(grep "EL_RPC=" .env | cut -d'=' -f2)
        cons_port=$(grep "CL_REST=" .env | cut -d'=' -f2)
    fi
    
    # Check execution client sync status
    if [[ -n "$exec_port" ]]; then
        while [[ $sync_wait_count -lt $sync_check_wait ]]; do
            local sync_response=$(curl -s -X POST "http://localhost:${exec_port}" \
                -H "Content-Type: application/json" \
                -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
                --max-time 3 2>/dev/null)
            
            if [[ -n "$sync_response" ]]; then
                # Check if syncing (result is not false)
                if ! echo "$sync_response" | grep -q '"result":false'; then
                    echo -e "${GREEN}✓ Execution client is syncing${NC}"
                    break
                elif echo "$sync_response" | grep -q '"result":false'; then
                    # Check if waiting for peers or already synced
                    local block_response=$(curl -s -X POST "http://localhost:${exec_port}" \
                        -H "Content-Type: application/json" \
                        -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                        --max-time 3 2>/dev/null)
                    
                    if echo "$block_response" | grep -q '"result":"0x0"'; then
                        echo -e "${YELLOW}⏳ Execution client waiting for peers ($sync_wait_count/$sync_check_wait)...${NC}"
                    else
                        echo -e "${GREEN}✓ Execution client is ready${NC}"
                        break
                    fi
                fi
            else
                echo -e "${YELLOW}⏳ Execution client starting up ($sync_wait_count/$sync_check_wait)...${NC}"
            fi
            
            sleep 3
            ((sync_wait_count+=3))
        done
    fi
    
    # Check consensus client sync status  
    if [[ -n "$cons_port" ]]; then
        sync_wait_count=0
        while [[ $sync_wait_count -lt $sync_check_wait ]]; do
            local cl_sync_response=$(curl -s "http://localhost:${cons_port}/eth/v1/node/syncing" --max-time 3 2>/dev/null)
            local cl_health_code=$(curl -s -w "%{http_code}" -o /dev/null "http://localhost:${cons_port}/eth/v1/node/health" --max-time 3 2>/dev/null)
            
            if [[ -n "$cl_sync_response" ]]; then
                if echo "$cl_sync_response" | grep -q '"is_syncing":true' || [[ "$cl_health_code" == "206" ]]; then
                    echo -e "${GREEN}✓ Consensus client is syncing${NC}"
                    break
                elif echo "$cl_sync_response" | grep -q '"el_offline":true'; then
                    echo -e "${YELLOW}⏳ Consensus client waiting for execution layer ($sync_wait_count/$sync_check_wait)...${NC}"
                else
                    echo -e "${GREEN}✓ Consensus client is ready${NC}"
                    break
                fi
            elif [[ "$cl_health_code" == "206" ]]; then
                echo -e "${GREEN}✓ Consensus client is syncing${NC}"
                break
            else
                echo -e "${YELLOW}⏳ Consensus client starting up ($sync_wait_count/$sync_check_wait)...${NC}"
            fi
            
            sleep 3
            ((sync_wait_count+=3))
        done
    fi
    
    echo -e "${GREEN}✓ Ethnode installation completed successfully!${NC}"
    echo
    
    # Integrate with existing services
    integrate_new_ethnode_with_services "$node_name"
    
    # Ensure we're back in the nodeboi directory
    cd "${NODEBOI_DIR}" 2>/dev/null || cd "$HOME/.nodeboi" 2>/dev/null || true
    
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

# Integrate newly installed ethnode with existing services
integrate_new_ethnode_with_services() {
    local new_node="$1"
    
    echo
    echo -e "${CYAN}${BOLD}Service Integration${NC}"
    echo "=================="
    echo
    
    # Check if Vero exists and offer to add this beacon node
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        echo -e "${GREEN}Found existing Vero validator service${NC}"
        
        # Check if this ethnode should be added to Vero's beacon nodes
        if fancy_confirm "Add this beacon node to Vero's configuration?" "y"; then
            echo -e "${UI_MUTED}Updating Vero beacon node configuration...${NC}"
            add_ethnode_to_vero "$new_node"
        else
            echo -e "${UI_MUTED}Skipping Vero integration${NC}"
        fi
        echo
    fi
    
    # Check if monitoring exists and add dashboards
    if [[ -d "$HOME/monitoring" ]] && [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        echo -e "${GREEN}Found existing monitoring service${NC}"
        echo -e "${UI_MUTED}Adding dashboards for new ethnode...${NC}"
        
        # Source monitoring functions and sync dashboards
        (
            source "${NODEBOI_LIB}/monitoring.sh" 2>/dev/null || true
            if command -v sync_grafana_dashboards >/dev/null 2>&1; then
                sync_grafana_dashboards >/dev/null 2>&1 || true
            fi
            
            # Update monitoring configuration to include new ethnode
            if command -v update_monitoring_targets >/dev/null 2>&1; then
                update_monitoring_targets >/dev/null 2>&1 || true
            fi
        )
        echo -e "${UI_MUTED}✓ Monitoring integration updated${NC}"
        echo
    fi
    
    echo -e "${GREEN}✓ Service integration completed${NC}"
    
    # Ensure clean terminal state for menu return
    stty sane 2>/dev/null || true
    tput sgr0 2>/dev/null || true
}

# Add ethnode to Vero's beacon node configuration
add_ethnode_to_vero() {
    local new_node="$1"
    local env_file="$HOME/vero/.env"
    
    # Validate environment file exists
    if [[ ! -f "$env_file" ]]; then
        echo -e "${RED}  → Error: Vero .env file not found at $env_file${NC}"
        return 1
    fi
    
    # Detect the beacon client for this new node
    local beacon_client=""
    if docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${new_node}-grandine"; then
        beacon_client="grandine"
    elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${new_node}-lodestar"; then
        beacon_client="lodestar"
    elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${new_node}-lighthouse"; then
        beacon_client="lighthouse"
    elif docker network inspect "nodeboi-net" --format '{{range $id, $config := .Containers}}{{$config.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -q "${new_node}-teku"; then
        beacon_client="teku"
    else
        echo -e "${YELLOW}  → Warning: Could not detect beacon client for ${new_node}${NC}"
        return 1
    fi
    
    # Get current beacon URLs with better parsing
    local current_urls=""
    if [[ -f "$env_file" ]]; then
        current_urls=$(grep "^BEACON_NODE_URLS=" "$env_file" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
    fi
    
    # Create new beacon URL for container-to-container communication
    local new_url="http://${new_node}-${beacon_client}:5052"
    
    # Check if URL is already present
    if [[ -n "$current_urls" && "$current_urls" == *"$new_url"* ]]; then
        echo -e "${UI_MUTED}  → Beacon node already in Vero configuration${NC}"
        return 0
    fi
    
    # Build updated URLs list
    local updated_urls=""
    if [[ -z "$current_urls" || "$current_urls" == "" ]]; then
        updated_urls="$new_url"
    else
        updated_urls="${current_urls},${new_url}"
    fi
    
    # Validate updated_urls is not empty
    if [[ -z "$updated_urls" ]]; then
        echo -e "${RED}  → Error: Failed to build updated beacon URLs${NC}"
        return 1
    fi
    
    # Create backup of original file
    cp "$env_file" "${env_file}.backup" || {
        echo -e "${RED}  → Error: Failed to create backup of .env file${NC}"
        return 1
    }
    
    # Update the .env file with safer approach
    local temp_file="$env_file.tmp"
    
    # Use a more robust sed approach with proper escaping
    if awk -v new_urls="$updated_urls" '
        /^BEACON_NODE_URLS=/ { print "BEACON_NODE_URLS=" new_urls; next }
        { print }
    ' "$env_file" > "$temp_file"; then
        
        # Validate the temp file was created successfully and contains the expected line
        if [[ -s "$temp_file" ]] && grep -q "^BEACON_NODE_URLS=$updated_urls" "$temp_file"; then
            mv "$temp_file" "$env_file"
            echo -e "${UI_MUTED}  → Added beacon node: $new_url${NC}"
            echo -e "${UI_MUTED}  → Updated beacon URLs: $updated_urls${NC}"
            
            # Remove backup on success
            rm -f "${env_file}.backup"
        else
            echo -e "${RED}  → Error: Failed to validate updated .env file${NC}"
            # Restore from backup
            mv "${env_file}.backup" "$env_file" 2>/dev/null || true
            rm -f "$temp_file"
            return 1
        fi
    else
        echo -e "${RED}  → Error: Failed to update .env file${NC}"
        # Restore from backup
        mv "${env_file}.backup" "$env_file" 2>/dev/null || true
        rm -f "$temp_file"
        return 1
    fi
    
    # Restart Vero to apply changes using down/up for full reload
    (
        if cd "$HOME/vero" 2>/dev/null; then
            echo -e "${UI_MUTED}  → Restarting Vero to apply changes...${NC}"
            docker compose down > /dev/null 2>&1 || true
            sleep 2
            docker compose up -d > /dev/null 2>&1 || true
            echo -e "${UI_MUTED}  → Vero restarted successfully${NC}"
        fi
    )
}

