#!/bin/bash

#=============================================================================
# Network Manager - Nodeboi Service Network Integration
#=============================================================================
# Handles automatic network discovery, creation, and service interconnection
# Replaces the former "DICKS" (Docker Intelligent Connecting Kontainer System)

# Load dependencies
[[ -f "${NODEBOI_LIB}/common.sh" ]] && source "${NODEBOI_LIB}/common.sh"
[[ -f "${NODEBOI_LIB}/ulcs.sh" ]] && source "${NODEBOI_LIB}/ulcs.sh"
[[ -f "${NODEBOI_LIB}/templates.sh" ]] && source "${NODEBOI_LIB}/templates.sh"

#=============================================================================
# NETWORK DISCOVERY
#=============================================================================

# Discover all nodeboi managed networks and their services
discover_nodeboi_networks() {
    local networks=()
    
    # Check for isolated network architecture (modern setup)
    if docker network ls --format "{{.Name}}" | grep -q "ethnode.*-net$"; then
        # Scan for ethnode networks
        for dir in "$HOME"/ethnode*; do
            [[ -d "$dir" ]] || continue
            local ethnode_name=$(basename "$dir")
            local network_name="${ethnode_name}-net"
            if docker network inspect "$network_name" >/dev/null 2>&1; then
                networks+=("$network_name")
            fi
        done
        
        # Add other service networks if they exist
        for service_net in "monitoring-net" "validator-net" "web3signer-net"; do
            if docker network inspect "$service_net" >/dev/null 2>&1; then
                networks+=("$service_net")
            fi
        done
    else
        # Legacy architecture fallback
        networks+=("monitoring-net")
    fi
    
    printf '%s\n' "${networks[@]}"
}

#=============================================================================
# CORE NETWORK MANAGEMENT
#=============================================================================

# Main network management function - handles service network integration
manage_service_networks() {
    local operation="${1:-sync}"  # sync, status, force-rebuild
    local silent_mode="$2"        # "silent" to suppress output
    
    [[ "$silent_mode" != "silent" ]] && echo "Configuring dynamic network connections..."
    
    # Discover all isolated networks and their requirements
    local ethnode_networks=()
    local ethnode_services=()
    
    # Scan for all ethnodes and ensure their networks exist
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local ethnode_name=$(basename "$dir")
            local network_name="${ethnode_name}-net"
            
            ethnode_services+=("$ethnode_name")
            ethnode_networks+=("$network_name")
            
            # Ensure ethnode network exists
            if ! docker network inspect "$network_name" >/dev/null 2>&1; then
                [[ "$silent_mode" != "silent" ]] && echo "  → Creating $network_name..."
                docker network create "$network_name" >/dev/null 2>&1
            fi
        fi
    done
    
    # Ensure core service networks exist
    local monitoring_net="monitoring-net"
    local validator_net="validator-net"
    local web3signer_net="web3signer-net"
    
    # Create monitoring network if monitoring exists
    if [[ -d "$HOME/monitoring" ]] && ! docker network inspect "$monitoring_net" >/dev/null 2>&1; then
        [[ "$silent_mode" != "silent" ]] && echo "  → Creating $monitoring_net..."
        docker network create "$monitoring_net" >/dev/null 2>&1
    fi
    
    # Create validator network if validator exists
    if [[ -d "$HOME/vero" || -d "$HOME/teku-validator" ]] && ! docker network inspect "$validator_net" >/dev/null 2>&1; then
        [[ "$silent_mode" != "silent" ]] && echo "  → Creating $validator_net..."
        docker network create "$validator_net" >/dev/null 2>&1
    fi
    
    # Create web3signer network if web3signer exists  
    if [[ -d "$HOME/web3signer" ]] && ! docker network inspect "$web3signer_net" >/dev/null 2>&1; then
        [[ "$silent_mode" != "silent" ]] && echo "  → Creating $web3signer_net..."
        docker network create "$web3signer_net" >/dev/null 2>&1
    fi
    
    local changes_made=false
    local services_to_restart=()
    
    # Rebuild monitoring compose.yml with multi-network prometheus access
    if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" ]]; then
        rebuild_monitoring_compose_yml_isolated "$monitoring_net" "${ethnode_networks[@]}" "$validator_net"
        if [[ $? -eq 0 ]]; then
            services_to_restart+=("$HOME/monitoring")
            changes_made=true
            [[ "$silent_mode" != "silent" ]] && echo "  → Updated monitoring for isolated networks"
        fi
    fi
    
    # Rebuild Vero compose.yml with multi-network access
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        rebuild_vero_compose_yml_isolated "$validator_net" "${ethnode_networks[@]}" "$web3signer_net"
        if [[ $? -eq 0 ]]; then
            services_to_restart+=("vero")
            changes_made=true  
            [[ "$silent_mode" != "silent" ]] && echo "  → Updated Vero for isolated networks"
        fi
    fi
    
    # Rebuild Teku validator compose.yml with multi-network access
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        rebuild_teku_validator_compose_yml_isolated "$validator_net" "${ethnode_networks[@]}" "$web3signer_net"
        if [[ $? -eq 0 ]]; then
            services_to_restart+=("teku-validator")
            changes_made=true  
            [[ "$silent_mode" != "silent" ]] && echo "  → Updated Teku validator for isolated networks"
        fi
    fi
    
    # Rebuild ethnode compose.yml files to use isolated networks
    for ethnode in "${ethnode_services[@]}"; do
        if [[ -d "$HOME/$ethnode" && -f "$HOME/$ethnode/.env" ]]; then
            rebuild_ethnode_compose_yml_isolated "$ethnode"
            if [[ $? -eq 0 ]]; then
                services_to_restart+=("$ethnode")
                changes_made=true
                [[ "$silent_mode" != "silent" ]] && echo "  → Updated $ethnode for isolated network"
            fi
        fi
    done
    
    # Restart services that had configuration changes
    if [[ "$changes_made" == true ]]; then
        for service in "${services_to_restart[@]}"; do
            [[ "$silent_mode" != "silent" ]] && echo "  → Restarting $service to apply changes"
            case "$service" in
                "$HOME/monitoring")
                    # Use Universal Lifecycle System for monitoring
                    if declare -f stop_service_universal >/dev/null 2>&1 && declare -f start_service_universal >/dev/null 2>&1; then
                        stop_service_universal "monitoring" && start_service_universal "monitoring"
                    else
                        manage_service "restart" "$HOME/monitoring"
                    fi
                    ;;
                "vero")  
                    # Use Universal Lifecycle System for vero
                    if declare -f stop_service_universal >/dev/null 2>&1 && declare -f start_service_universal >/dev/null 2>&1; then
                        stop_service_universal "vero" && start_service_universal "vero"
                    else
                        manage_service "restart" "vero"
                    fi
                    ;;
                "teku-validator")
                    # Use Universal Lifecycle System for teku-validator
                    if declare -f stop_service_universal >/dev/null 2>&1 && declare -f start_service_universal >/dev/null 2>&1; then
                        stop_service_universal "teku-validator" && start_service_universal "teku-validator"
                    else
                        manage_service "restart" "teku-validator"
                    fi
                    ;;
                ethnode*)
                    # Use Universal Lifecycle System for ethnodes
                    local ethnode_name=$(basename "$service")
                    if declare -f stop_service_universal >/dev/null 2>&1 && declare -f start_service_universal >/dev/null 2>&1; then
                        stop_service_universal "$ethnode_name" && start_service_universal "$ethnode_name"
                    else
                        manage_service "restart" "$service"
                    fi
                    ;;
            esac
        done
    fi
    
    # Report results
    if [[ "$changes_made" == true ]]; then
        if [[ "$silent_mode" != "silent" ]]; then
            echo "✓ Network configuration updated and services restarted"
        fi
    else
        if [[ "$silent_mode" != "silent" ]]; then
            echo "✓ Network configurations verified and optimal"
        fi
    fi
}

#=============================================================================
# SERVICE COMPOSE FILE REBUILDERS
#=============================================================================

# Generic function to rebuild any service's compose file with network connections
rebuild_service_compose_yml() {
    local service_type="$1"
    local service_dir="$2"
    shift 2
    local networks=("$@")
    
    local compose_file="$service_dir/compose.yml"
    local temp_file="$compose_file.tmp"
    
    # Generate service-specific compose content
    case "$service_type" in
        monitoring)
            generate_network_monitoring_compose "$temp_file" "${networks[@]}"
            ;;
        vero)
            # Convert networks array to ethnodes for centralized template
            local ethnodes=()
            for net in "${networks[@]}"; do
                if [[ "$net" =~ ^ethnode[0-9]+-net$ ]]; then
                    local ethnode_name="${net%-net}"
                    ethnodes+=("$ethnode_name")
                fi
            done
            generate_vero_compose "$temp_file" "${ethnodes[@]}"
            ;;
        teku-validator)
            generate_network_teku_validator_compose "$temp_file" "${networks[@]}"
            ;;
        ethnode)
            update_ethnode_compose_networks "$temp_file" "$service_dir" "${networks[@]}"
            ;;
        *)
            echo "Error: Unknown service type '$service_type'"
            return 1
            ;;
    esac
    
    # Replace original file if different
    if ! diff "$compose_file" "$temp_file" >/dev/null 2>&1; then
        mv "$temp_file" "$compose_file"
        return 0  # Changed
    else
        rm -f "$temp_file"
        return 1  # No change
    fi
}

# Generate monitoring compose.yml with network connections
generate_network_monitoring_compose() {
    local temp_file="$1"
    shift
    local networks=("$@")
    
    # Extract network types
    local monitoring_net=""
    local ethnode_networks=()
    local validator_net=""
    
    for net in "${networks[@]}"; do
        case "$net" in
            monitoring-net) monitoring_net="$net" ;;
            validator-net) validator_net="$net" ;;
            ethnode*-net) ethnode_networks+=("$net") ;;
        esac
    done
    
    cat > "$temp_file" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:\${PROMETHEUS_VERSION}
    container_name: monitoring-prometheus
    hostname: prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - --storage.tsdb.retention.time=30d
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --web.console.libraries=/etc/prometheus/console_libraries
      - --web.console.templates=/etc/prometheus/consoles
      - --web.enable-lifecycle
      - --web.enable-admin-api
    networks:
      - $monitoring_net
EOF
    
    # Add ethnode networks to prometheus
    for network in "${ethnode_networks[@]}"; do
        echo "      - $network" >> "$temp_file"
    done
    
    # Add validator network if present
    [[ -n "$validator_net" ]] && echo "      - $validator_net" >> "$temp_file"
    
    cat >> "$temp_file" <<EOF
    ports:
      - \${HOST_IP:-}:\${PROMETHEUS_PORT}:9090
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    <<: *logging

  grafana:
    image: grafana/grafana:\${GRAFANA_VERSION}
    container_name: monitoring-grafana
    hostname: grafana
    restart: unless-stopped
    user: "\${NODE_UID}:\${NODE_GID}"
    networks:
      - $monitoring_net
    ports:
      - \${HOST_IP:-}:\${GRAFANA_PORT}:3000
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_PATHS_PROVISIONING=/etc/grafana/provisioning
    <<: *logging

  node-exporter:
    image: prom/node-exporter:\${NODE_EXPORTER_VERSION}
    container_name: monitoring-node-exporter
    hostname: node-exporter
    restart: unless-stopped
    networks:
      - $monitoring_net
    ports:
      - \${HOST_IP:-}:\${NODE_EXPORTER_PORT}:9100
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - --path.procfs=/host/proc
      - --path.rootfs=/rootfs
      - --path.sysfs=/host/sys
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    <<: *logging

volumes:
  prometheus-data:
  grafana-data:

networks:
  $monitoring_net:
    external: true
    name: $monitoring_net
EOF
    
    # Add external network definitions
    for network in "${ethnode_networks[@]}"; do
        cat >> "$temp_file" <<EOF
  $network:
    external: true
    name: $network
EOF
    done
    
    # Add validator network if present
    if [[ -n "$validator_net" ]]; then
        cat >> "$temp_file" <<EOF
  $validator_net:
    external: true
    name: $validator_net
EOF
    fi
}


# Generate Teku validator compose.yml with network connections  
generate_network_teku_validator_compose() {
    local temp_file="$1"
    shift
    local networks=("$@")
    
    cat > "$temp_file" <<EOF
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  teku-validator:
    image: consensys/teku:\${TEKU_VERSION}
    container_name: teku-validator
    restart: unless-stopped
    user: "\${TEKU_UID}:\${TEKU_GID}"
    stop_grace_period: 30s
    environment:
      - JAVA_OPTS=\${TEKU_HEAP}
    networks:
EOF

    # Add networks
    for network in "${networks[@]}"; do
        echo "      - $network" >> "$temp_file"
    done
    
    cat >> "$temp_file" <<EOF
    ports:
      - "\${HOST_BIND_IP}:\${TEKU_METRICS_PORT}:8008"
    volumes:
      - ./data:/var/lib/teku
      - /etc/localtime:/etc/localtime:ro
    <<: *logging
    command:
      - validator-client
      - --network=\${ETH2_NETWORK}
      - --data-path=/var/lib/teku
      - --beacon-node-api-endpoint=\${BEACON_NODE_URL}
      - --validators-external-signer-url=\${WEB3SIGNER_URL}
      - --validators-external-signer-public-keys=external-signer
      - --validators-proposer-default-fee-recipient=\${FEE_RECIPIENT}
      - --validators-graffiti=\${GRAFFITI}
      - --logging=\${LOG_LEVEL}
      - --log-destination=CONSOLE
      - --metrics-enabled=true
      - --metrics-port=8008
      - --metrics-interface=0.0.0.0
      - --metrics-host-allowlist=*
      - --doppelganger-detection-enabled=true
      - --shut-down-when-validator-slashed-enabled=true

networks:
EOF

    # Add network definitions
    for network in "${networks[@]}"; do
        cat >> "$temp_file" <<EOF
  $network:
    external: true
    name: $network
EOF
    done
}

# Generate ethnode compose.yml for isolated network (simpler case)
update_ethnode_compose_networks() {
    local temp_file="$1"
    local service_dir="$2"
    shift 2
    local networks=("$@")
    
    local ethnode_net="${networks[0]}"  # Assume first network is the ethnode network
    local compose_file="$service_dir/compose.yml"
    
    # For ethnode, we just need to ensure it uses its isolated network
    # Copy existing compose and update network references
    if [[ -f "$compose_file" ]]; then
        # Replace generic network with ethnode-specific network
        sed "s/validator-net/$ethnode_net/g" "$compose_file" > "$temp_file"
        
        # Ensure external network definition exists
        if ! grep -q "external: true" "$temp_file"; then
            cat >> "$temp_file" <<EOF

networks:
  $ethnode_net:
    external: true
    name: $ethnode_net
EOF
        fi
    fi
}

# Convenience functions that match the old API for backward compatibility
rebuild_monitoring_compose_yml_isolated() {
    # Use Docker network discovery instead of passed parameters for robust network detection
    local discovered_ethnode_networks=$(docker network ls --format "{{.Name}}" | grep "^ethnode[0-9]*-net$" | sort -V)
    local all_networks=("monitoring-net")
    
    # Add discovered ethnode networks
    for network in $discovered_ethnode_networks; do
        all_networks+=("$network")
    done
    all_networks+=("validator-net")
    
    rebuild_service_compose_yml "monitoring" "$HOME/monitoring" "${all_networks[@]}"
}

rebuild_vero_compose_yml_isolated() {
    local validator_net="$1"
    shift
    local ethnode_networks=("$@")
    local web3signer_net="${ethnode_networks[-1]}"
    if [[ "$web3signer_net" == "web3signer-net" ]]; then
        unset 'ethnode_networks[-1]'
    fi
    
    # Determine which specific ethnode networks vero should connect to
    # based on its BEACON_NODE_URLS configuration (can be multiple)
    local target_ethnode_networks=()
    if [[ -f "$HOME/vero/.env" ]]; then
        local beacon_urls=$(grep "^BEACON_NODE_URLS=" "$HOME/vero/.env" | cut -d'=' -f2)
        # Parse comma-separated URLs (e.g., "http://ethnode1-grandine:5052,http://ethnode2-teku:5052")
        if [[ -n "$beacon_urls" ]]; then
            # Convert comma-separated URLs to array
            IFS=',' read -ra url_array <<< "$beacon_urls"
            for url in "${url_array[@]}"; do
                # Extract ethnode name from each URL (e.g., "http://ethnode1-grandine:5052" -> "ethnode1")
                if [[ "$url" =~ http://([^-]+)-.* ]]; then
                    local ethnode_name="${BASH_REMATCH[1]}"
                    local target_network="${ethnode_name}-net"
                    # Add to target networks if not already present
                    if [[ ! " ${target_ethnode_networks[*]} " =~ " ${target_network} " ]]; then
                        target_ethnode_networks+=("$target_network")
                    fi
                fi
            done
        fi
    fi
    
    # Only connect to the specific ethnode networks that vero is configured for
    local all_networks=("$validator_net")
    for target_net in "${target_ethnode_networks[@]}"; do
        # Verify the target network exists in our available networks
        for net in "${ethnode_networks[@]}"; do
            if [[ "$net" == "$target_net" ]]; then
                all_networks+=("$target_net")
                break
            fi
        done
    done
    [[ -n "$web3signer_net" ]] && all_networks+=("$web3signer_net")
    
    rebuild_service_compose_yml "vero" "$HOME/vero" "${all_networks[@]}"
}

rebuild_teku_validator_compose_yml_isolated() {
    local validator_net="$1"
    shift
    local ethnode_networks=("$@")
    local web3signer_net="${ethnode_networks[-1]}"
    if [[ "$web3signer_net" == "web3signer-net" ]]; then
        unset 'ethnode_networks[-1]'
    fi
    
    # Determine which specific ethnode network teku-validator should connect to
    # based on its BEACON_NODE_URL configuration
    local target_ethnode_network=""
    if [[ -f "$HOME/teku-validator/.env" ]]; then
        local beacon_url=$(grep "^BEACON_NODE_URL=" "$HOME/teku-validator/.env" | cut -d'=' -f2)
        # Extract ethnode name from URL (e.g., "http://ethnode1-grandine:5052" -> "ethnode1")
        if [[ "$beacon_url" =~ http://([^-]+)-.* ]]; then
            local ethnode_name="${BASH_REMATCH[1]}"
            target_ethnode_network="${ethnode_name}-net"
        fi
    fi
    
    # Only connect to the specific ethnode network the validator is configured for
    local all_networks=("$validator_net")
    if [[ -n "$target_ethnode_network" ]]; then
        # Verify the target network exists in our available networks
        for net in "${ethnode_networks[@]}"; do
            if [[ "$net" == "$target_ethnode_network" ]]; then
                all_networks+=("$target_ethnode_network")
                break
            fi
        done
    fi
    [[ -n "$web3signer_net" ]] && all_networks+=("$web3signer_net")
    
    rebuild_service_compose_yml "teku-validator" "$HOME/teku-validator" "${all_networks[@]}"
}

rebuild_ethnode_compose_yml_isolated() {
    local ethnode="$1"
    local ethnode_net="${ethnode}-net"
    rebuild_service_compose_yml "ethnode" "$HOME/$ethnode" "$ethnode_net"
}