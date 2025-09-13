#!/bin/bash
# lib/port-manager.sh - Intelligent Port Management System
# Centralized port allocation for all nodeboi services

# Port ranges for different service types
declare -A PORT_RANGES=(
    ["execution_rpc"]="8545:8600"      # Execution RPC/WS/Auth ports
    ["consensus_api"]="5052:5100"      # Consensus REST API ports  
    ["p2p_execution"]="30303:30400"    # Execution P2P ports
    ["p2p_consensus"]="9000:9100"      # Consensus P2P ports
    ["mevboost"]="18550:18650"         # MEV-Boost ports
    ["metrics"]="6060:6200"            # Prometheus metrics ports
    ["monitoring"]="3000:3100"         # Grafana, dashboards
    ["validator"]="7500:7600"          # Validator client ports
    ["plugins"]="19000:19200"          # Plugin services (SSV, etc)
    ["general"]="20000:25000"          # General purpose ports
)

# Service port requirements configuration
declare -A SERVICE_CONFIGS=(
    # Format: "service_name:port_count:consecutive:base_increment:category"
    ["execution_client"]="3:true:1:execution_rpc"     # RPC, WS, Auth (consecutive)
    ["execution_p2p"]="2:true:1:p2p_execution"        # TCP, UDP (consecutive) 
    ["consensus_client"]="1:false:2:consensus_api"    # REST API
    ["consensus_p2p"]="2:true:1:p2p_consensus"        # TCP, UDP (consecutive)
    ["mevboost"]="1:false:2:mevboost"                 # MEV-Boost port
    ["prometheus"]="1:false:10:metrics"               # Metrics scraping
    ["grafana"]="1:false:10:monitoring"               # Dashboard
    ["loki"]="1:false:10:monitoring"                  # Log aggregation
    ["validator_api"]="2:false:2:validator"           # Validator API ports
    ["ssv_operator"]="4:false:5:plugins"              # SSV operator ports
    ["vero_monitor"]="1:false:10:monitoring"          # Vero monitoring
    ["web3signer"]="1:false:10:validator"             # Web3signer HTTP API
    # Note: Vero uses fixed port 9010 for metrics (singleton service)
)

# Get all currently used ports from system and docker
get_all_used_ports() {
    local used_ports=""

    # Get system listening ports
    if command -v ss &>/dev/null; then
        used_ports+=$(ss -tuln 2>/dev/null | awk '/LISTEN/ {print $5}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    else
        used_ports+=$(netstat -tuln 2>/dev/null | awk '/LISTEN/ {print $4}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    fi

    # Get Docker container ports (running and stopped) - extract only HOST ports
    local docker_ports=$(docker ps -a --format "table {{.Ports}}" 2>/dev/null | tail -n +2)

    # Extract only host ports (before -> or standalone ports), not container ports (after ->)
    # Use sed to remove everything after -> first, then extract ports
    used_ports+=" $(echo "$docker_ports" | sed 's/->[^,]*//g' | grep -oE '(127\.0\.0\.1:|0\.0\.0\.0:)?[0-9]+(-[0-9]+)?' | grep -oE '[0-9]+(-[0-9]+)?' | sort -u | tr '\n' ' ')"
    
    # Handle port ranges like 30304-30305 from the extracted host ports
    local ranges=$(echo "$docker_ports" | sed 's/->[^,]*//g' | grep -oE '(127\.0\.0\.1:|0\.0\.0\.0:)?[0-9]+-[0-9]+' | grep -oE '[0-9]+-[0-9]+' || true)
    if [[ -n "$ranges" ]]; then
        while IFS= read -r range; do
            local start=$(echo "$range" | cut -d'-' -f1)
            local end=$(echo "$range" | cut -d'-' -f2)
            for ((port=start; port<=end; port++)); do
                used_ports+=" $port"
            done
        done <<< "$ranges"
    fi

    # Get ports from all service .env files
    for env_file in "$HOME"/{ethnode*,ssv*,vero-monitor}/.env; do
        [[ -f "$env_file" ]] || continue
        used_ports+=" $(grep -E '_PORT=' "$env_file" 2>/dev/null | cut -d'=' -f2 | sort -u | tr '\n' ' ')"
    done

    # Remove duplicates and return sorted
    echo "$used_ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' '
}

# Check if a single port is available
is_port_available() {
    local port=$1
    local used_ports_list="${2:-}"

    # Validate port number
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [[ $port -ge 1 && $port -le 65535 ]] || return 1

    # Check against used ports list if provided
    if [[ -n "$used_ports_list" ]]; then
        echo " $used_ports_list " | grep -q " $port " && return 1
    fi

    # Multi-method availability check
    # Method 1: netcat
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 "$port" 2>/dev/null && return 1
    fi
    
    # Method 2: ss/netstat
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":${port} " && return 1
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":${port} " && return 1
    fi
    
    # Method 3: lsof
    if command -v lsof &>/dev/null; then
        lsof -i :$port >/dev/null 2>&1 && return 1
    fi

    return 0
}

# Parse port range string "start:end" 
parse_port_range() {
    local range_str="$1"
    echo "${range_str%:*}" "${range_str#*:}"
}

# Allocate ports for a service
# Usage: allocate_service_ports <service_name> [used_ports_cache]
allocate_service_ports() {
    local service_name="$1"
    local used_ports_cache="${2:-}"
    
    # Get used ports if not cached
    [[ -z "$used_ports_cache" ]] && used_ports_cache=$(get_all_used_ports)
    
    # Get service configuration
    local config="${SERVICE_CONFIGS[$service_name]:-}"
    if [[ -z "$config" ]]; then
        echo "ERROR: Unknown service '$service_name'" >&2
        return 1
    fi

    # Parse configuration
    local port_count=$(echo "$config" | cut -d':' -f1)
    local consecutive=$(echo "$config" | cut -d':' -f2)
    local increment=$(echo "$config" | cut -d':' -f3)
    local category=$(echo "$config" | cut -d':' -f4)
    
    # Get port range for category
    local range="${PORT_RANGES[$category]:-}"
    if [[ -z "$range" ]]; then
        echo "ERROR: Unknown port category '$category'" >&2
        return 1
    fi
    
    read -r range_start range_end <<< "$(parse_port_range "$range")"
    
    # Allocate ports with intelligent reuse - find lowest available ports first
    local allocated_ports=()
    
    if [[ "$consecutive" == "true" ]]; then
        # Need consecutive ports - find the first available block
        for ((current_port=range_start; current_port+port_count-1 <= range_end; current_port+=increment)); do
            local consecutive_available=true
            for ((i=0; i<port_count; i++)); do
                if ! is_port_available $((current_port + i)) "$used_ports_cache"; then
                    consecutive_available=false
                    break
                fi
            done
            
            if [[ "$consecutive_available" == "true" ]]; then
                for ((i=0; i<port_count; i++)); do
                    allocated_ports+=($((current_port + i)))
                done
                break
            fi
        done
    else
        # Individual ports - find lowest available ports in range
        for ((current_port=range_start; current_port <= range_end && ${#allocated_ports[@]} < port_count; current_port+=increment)); do
            if is_port_available "$current_port" "$used_ports_cache"; then
                allocated_ports+=("$current_port")
                # Update cache to prevent double allocation in same call
                used_ports_cache+=" $current_port"
            fi
        done
    fi
    
    # Check if we got all required ports
    if [[ ${#allocated_ports[@]} -ne $port_count ]]; then
        echo "ERROR: Could not allocate $port_count ports for $service_name in range $range" >&2
        return 1
    fi
    
    # Return allocated ports
    printf '%s\n' "${allocated_ports[@]}"
    return 0
}

# Allocate all ports for a complete node setup
# Usage: allocate_node_ports <node_name> <exec_client> <cons_client> [include_mevboost]
allocate_node_ports() {
    local node_name="$1"
    local exec_client="$2" 
    local cons_client="$3"
    local include_mevboost="${4:-true}"
    
    echo "# Port allocation for $node_name ($exec_client + $cons_client)" >&2
    
    # Get used ports once for efficiency
    local used_ports_cache=$(get_all_used_ports)
    
    # Allocate execution client ports (RPC, WS, Auth)
    local exec_ports=($(allocate_service_ports "execution_client" "$used_ports_cache"))
    [[ ${#exec_ports[@]} -eq 3 ]] || { echo "Failed to allocate execution client ports" >&2; return 1; }
    used_ports_cache+=" ${exec_ports[*]}"
    
    # Allocate execution P2P ports
    local exec_p2p_ports=($(allocate_service_ports "execution_p2p" "$used_ports_cache"))
    [[ ${#exec_p2p_ports[@]} -eq 2 ]] || { echo "Failed to allocate execution P2P ports" >&2; return 1; }
    used_ports_cache+=" ${exec_p2p_ports[*]}"
    
    # Allocate consensus client port
    local cons_ports=($(allocate_service_ports "consensus_client" "$used_ports_cache"))
    [[ ${#cons_ports[@]} -eq 1 ]] || { echo "Failed to allocate consensus client port" >&2; return 1; }
    used_ports_cache+=" ${cons_ports[*]}"
    
    # Allocate consensus P2P ports  
    local cons_p2p_ports=($(allocate_service_ports "consensus_p2p" "$used_ports_cache"))
    [[ ${#cons_p2p_ports[@]} -eq 2 ]] || { echo "Failed to allocate consensus P2P ports" >&2; return 1; }
    used_ports_cache+=" ${cons_p2p_ports[*]}"
    
    # Allocate MEV-Boost port if needed
    local mevboost_port=""
    if [[ "$include_mevboost" == "true" ]]; then
        local mevboost_ports=($(allocate_service_ports "mevboost" "$used_ports_cache"))
        [[ ${#mevboost_ports[@]} -eq 1 ]] || { echo "Failed to allocate MEV-Boost port" >&2; return 1; }
        mevboost_port="${mevboost_ports[0]}"
        used_ports_cache+=" $mevboost_port"
    fi
    
    # Allocate metrics port
    local metrics_ports=($(allocate_service_ports "prometheus" "$used_ports_cache"))
    [[ ${#metrics_ports[@]} -eq 1 ]] || { echo "Failed to allocate metrics port" >&2; return 1; }
    local metrics_port="${metrics_ports[0]}"
    
    # Output port assignments
    cat << EOF
EL_RPC_PORT=${exec_ports[0]}
EL_WS_PORT=${exec_ports[1]}
EE_PORT=${exec_ports[2]}
EL_P2P_PORT=${exec_p2p_ports[0]}
EL_P2P_PORT_2=${exec_p2p_ports[1]}
CL_REST_PORT=${cons_ports[0]}
CL_P2P_PORT=${cons_p2p_ports[0]}
CL_QUIC_PORT=${cons_p2p_ports[1]}
METRICS_PORT=${metrics_port}
EOF
    
    [[ -n "$mevboost_port" ]] && echo "MEVBOOST_PORT=${mevboost_port}"
}

# Reserve ports for future use (creates a reservation file)
reserve_ports() {
    local service_name="$1"
    shift
    local ports=("$@")
    
    local reservation_file="/tmp/nodeboi_port_reservations"
    echo "# Reserved ports for $service_name at $(date)" >> "$reservation_file"
    printf '%s:%s\n' "$service_name" "${ports[*]}" >> "$reservation_file"
}

# Release reserved ports
release_ports() {
    local service_name="$1"
    local reservation_file="/tmp/nodeboi_port_reservations"
    
    if [[ -f "$reservation_file" ]]; then
        sed -i "/^${service_name}:/d" "$reservation_file"
    fi
}

# Get summary of current port usage
show_port_summary() {
    echo "=== NODEBOI PORT ALLOCATION SUMMARY ==="
    echo
    
    for category in "${!PORT_RANGES[@]}"; do
        echo "$category: ${PORT_RANGES[$category]}"
    done
    
    echo
    echo "Currently allocated ports:"
    local used_ports=$(get_all_used_ports)
    echo "$used_ports" | tr ' ' '\n' | sort -n | head -20
    echo "... (showing first 20)"
}

# Validate port configuration
validate_port_config() {
    local errors=0
    
    echo -e "${UI_MUTED}Validating port management configuration...${NC}" >&2
    
    # Check for overlapping ranges
    declare -A range_starts range_ends
    for category in "${!PORT_RANGES[@]}"; do
        read -r start end <<< "$(parse_port_range "${PORT_RANGES[$category]}")"
        range_starts["$category"]=$start
        range_ends["$category"]=$end
        
        # Check range validity
        if [[ $start -ge $end ]]; then
            echo "ERROR: Invalid range for $category: $start >= $end" >&2
            ((errors++))
        fi
    done
    
    # Check service configs reference valid categories
    for service in "${!SERVICE_CONFIGS[@]}"; do
        local category=$(echo "${SERVICE_CONFIGS[$service]}" | cut -d':' -f4)
        if [[ -z "${PORT_RANGES[$category]:-}" ]]; then
            echo "ERROR: Service $service references unknown category '$category'" >&2
            ((errors++))
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        echo "✓ Port configuration validation passed" >&2
    else
        echo "✗ Found $errors configuration errors" >&2
        return 1
    fi
}

# Initialize port management system
init_port_management() {
    validate_port_config || return 1
    echo "✓ Port management system initialized" >&2
}