#!/bin/bash
# NODEBOI Detection Functions

GLOBAL_USED_PORTS=()

# Comprehensive Ethereum instance detection
detect_all_ethereum_instances() {
    log_info "Scanning for existing Ethereum instances"
    
    local instances=()
    local detection_details=()
    local all_used_ports=()
    
    # Method 1: Directory scanning
    echo "  Scanning directories for Ethereum configurations..."
    local dir_count=0
    for dir in "$HOME"/*; do
        if [[ -d "$dir" ]]; then
            ((dir_count++))
            local dir_name=$(basename "$dir")
            local found_eth=false
            local client_types=()
            
            for config_file in "$dir"/{.env,docker-compose.yml,compose.yml,*.yml}; do
                if [[ -f "$config_file" ]]; then
                    local clients=$(grep -oE "(reth|besu|nethermind|geth|erigon|lodestar|lighthouse|teku|prysm|nimbus|grandine)" "$config_file" 2>/dev/null | sort -u || true)
                    if [[ -n "$clients" ]]; then
                        found_eth=true
                        while read -r client; do
                            [[ -n "$client" ]] && client_types+=("$client")
                        done <<< "$clients"
                        
                        # Extract ports
                        local ports=$(grep -oE ":[0-9]{4,5}" "$config_file" 2>/dev/null | sed 's/://' | sort -n -u || true)
                        while read -r port; do
                            [[ -n "$port" ]] && all_used_ports+=("$port")
                        done <<< "$ports"
                    fi
                fi
            done
            
            if [[ "$found_eth" == true ]]; then
                instances+=("$dir_name")
                local client_list=$(printf '%s,' "${client_types[@]}" | sed 's/,$//')
                detection_details+=("$dir_name: Config files ($client_list)")
                echo -e "    Found: ${GREEN}$dir_name${NC} ($client_list)"
            fi
        fi
    done
    echo "    Scanned $dir_count directories"
    
    # Method 2: Docker containers
    echo "  Checking Docker containers..."
    if command -v docker &> /dev/null && docker ps &> /dev/null; then
        local container_count=0
        local eth_containers=$(docker ps -a --format "{{.Names}}\t{{.Image}}\t{{.Status}}" | grep -iE "(reth|besu|nethermind|geth|erigon|lodestar|lighthouse|teku|prysm|nimbus|grandine)" || true)
        
        while IFS=$'\t' read -r container_name image status; do
            if [[ -n "$container_name" ]]; then
                ((container_count++))
                local base_name=$(echo "$container_name" | sed 's/-\(reth\|besu\|nethermind\|geth\|erigon\|lodestar\|lighthouse\|teku\|prysm\|nimbus\|grandine\).*//')
                local client_type=$(echo "$container_name $image" | grep -oE "(reth|besu|nethermind|geth|erigon|lodestar|lighthouse|teku|prysm|nimbus|grandine)" | head -1)
                
                if [[ ! " ${instances[*]} " =~ " ${base_name} " ]]; then
                    instances+=("$base_name")
                fi
                
                local status_color="${RED}stopped${NC}"
                [[ "$status" == *"Up"* ]] && status_color="${GREEN}running${NC}"
                
                detection_details+=("$container_name: Docker container ($client_type) - $status_color")
                echo -e "    Found: ${GREEN}$container_name${NC} ($client_type) - $status_color"
            fi
        done <<< "$eth_containers"
        echo "    Found $container_count Ethereum containers"
    else
        echo -e "    Docker: ${YELLOW}not accessible${NC}"
    fi
    
    # Method 3: System users
    echo "  Checking system users..."
    local user_count=0
    local eth_users=$(getent passwd | grep -E "ethnode|eth-|ethereum" | cut -d':' -f1 || true)
    while read -r user; do
        if [[ -n "$user" ]]; then
            ((user_count++))
            if [[ ! " ${instances[*]} " =~ " ${user} " ]]; then
                instances+=("$user")
            fi
            detection_details+=("$user: System user exists")
            echo -e "    Found: ${GREEN}$user${NC} (system user)"
        fi
    done <<< "$eth_users"
    echo "    Found $user_count Ethereum users"
    
    # Method 4: Port scanning
    echo "  Scanning for used Ethereum ports..."
    local port_ranges=("8545-8560" "30303-30320" "9000-9020" "5052-5070")
    for range in "${port_ranges[@]}"; do
        local start_port=$(echo "$range" | cut -d'-' -f1)
        local end_port=$(echo "$range" | cut -d'-' -f2)
        for ((port=$start_port; port<=$end_port; port++)); do
            if ! is_port_available "$port"; then
                all_used_ports+=("$port")
            fi
        done
    done
    
    # Results summary
    local unique_instances=($(printf '%s\n' "${instances[@]}" | sort -u))
    local unique_ports=($(printf '%s\n' "${all_used_ports[@]}" | sort -n -u))
    
    echo
    if [[ ${#unique_instances[@]} -gt 0 ]] || [[ ${#unique_ports[@]} -gt 5 ]]; then
        echo -e "${GREEN}✓${NC} Detection completed"
        echo -e "  ${BOLD}Summary:${NC}"
        echo "    Instances: ${#unique_instances[@]} (${unique_instances[*]})"
        echo "    Used ports: ${#unique_ports[@]} ports detected"
        
        GLOBAL_USED_PORTS=("${unique_ports[@]}")
        return 0
    else
        echo -e "${GREEN}✓${NC} Detection completed - system is clean"
        echo "    No existing Ethereum instances found"
        return 1
    fi
}

# Port availability checking
is_port_available() {
    local port=$1
    ! netstat -tuln 2>/dev/null | grep -q ":${port} "
}

# Find next available port
find_next_available_port() {
    local base_port=$1
    local port=$base_port
    
    while ! is_port_available $port || [[ " ${GLOBAL_USED_PORTS[*]} " =~ " ${port} " ]]; do
        ((port++))
        if ((port > 65535)); then
            log_error "No available ports found starting from $base_port"
            return 1
        fi
    done
    
    echo $port
}
