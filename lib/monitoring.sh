#!/bin/bash
# lib/monitoring.sh - Monitoring management for NODEBOI

# Load dependencies
[[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh"

# Process dashboard template by replacing template variables
process_dashboard_template() {
    local template_file="$1"
    local output_file="$2"
    
    if [[ -f "$template_file" ]]; then
        # Determine dynamic tags and titles based on instance
        local node_name=""
        local client_type=""
        local client_name=""
        local dynamic_tags=""
        local dynamic_title=""
        
        if [[ "$template_file" == *"besu"* ]]; then
            node_name="ethnode2"
            client_type="execution"
            client_name="Besu"
            dynamic_tags="\"ethnode2\", \"execution\", \"besu\""
            dynamic_title="ethnode2-Besu"
        elif [[ "$template_file" == *"reth"* ]]; then
            node_name="ethnode1"
            client_type="execution"
            client_name="Reth"
            dynamic_tags="\"ethnode1\", \"execution\", \"reth\""
            dynamic_title="ethnode1-Reth"
        elif [[ "$template_file" == *"teku"* ]]; then
            node_name="ethnode1"
            client_type="consensus"
            client_name="Teku"
            dynamic_tags="\"ethnode1\", \"consensus\", \"teku\""
            dynamic_title="ethnode1-Teku"
        elif [[ "$template_file" == *"grandine"* ]]; then
            node_name="ethnode2"
            client_type="consensus"
            client_name="Grandine"
            dynamic_tags="\"ethnode2\", \"consensus\", \"grandine\""
            dynamic_title="ethnode2-Grandine"
        elif [[ "$template_file" == *"vero"* ]]; then
            node_name="validators"
            client_type="validator"
            client_name="Vero"
            dynamic_tags="\"validators\", \"validator\", \"vero\""
            dynamic_title="validators-Vero"
        elif [[ "$template_file" == *"nethermind"* ]]; then
            node_name="ethnode1"  # Will be detected dynamically below
            client_type="execution"
            client_name="Nethermind"
            dynamic_tags="\"ethnode1\", \"execution\", \"nethermind\""
            dynamic_title="ethnode1-Nethermind"
        elif [[ "$template_file" == *"lodestar"* ]]; then
            node_name="ethnode1"  # Will be detected dynamically below
            client_type="consensus"
            client_name="Lodestar"
            dynamic_tags="\"ethnode1\", \"consensus\", \"lodestar\""
            dynamic_title="ethnode1-Lodestar"
        elif [[ "$template_file" == *"lighthouse"* ]]; then
            node_name="ethnode1"  # Will be detected dynamically below
            client_type="consensus"
            client_name="Lighthouse"
            dynamic_tags="\"ethnode1\", \"consensus\", \"lighthouse\""
            dynamic_title="ethnode1-Lighthouse"
        elif [[ "$template_file" == *"node-exporter"* ]]; then
            node_name="system"
            client_type="monitoring"
            client_name="System metrics"
            dynamic_tags="\"system\", \"monitoring\", \"node-exporter\""
            dynamic_title="System metrics"
        fi
        
        # Dynamic node detection - find which ethnode is actually running this client
        if [[ "$client_type" == "execution" || "$client_type" == "consensus" ]] && [[ "$template_file" != *"besu"* && "$template_file" != *"grandine"* ]]; then
            for ethnode_dir in "$HOME"/ethnode*; do
                if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
                    local compose_file=$(grep "COMPOSE_FILE=" "$ethnode_dir/.env" 2>/dev/null | cut -d'=' -f2)
                    local actual_node_name=$(basename "$ethnode_dir")
                    if [[ "$compose_file" == *"${client_name,,}"* ]]; then
                        node_name="$actual_node_name"
                        dynamic_tags="\"$actual_node_name\", \"$client_type\", \"${client_name,,}\""
                        dynamic_title="$actual_node_name-$client_name"
                        break
                    fi
                fi
            done
        fi
        
        # Replace template variables with actual datasource name and fix variable queries
        # Hardcode instance values directly in queries - bypass template variables entirely
        if [[ "$template_file" == *"besu"* ]]; then
            # For Besu dashboard, hardcode ethnode2-besu:6060 in all queries
            sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                -e 's/"uid": "prometheus"/"uid": ""/g' \
                -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                -e 's/\$system/ethnode2-besu:6060/g' \
                -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                "$template_file" > "$output_file.tmp" 2>/dev/null || true
        elif [[ "$template_file" == *"reth"* ]]; then
            # For Reth dashboard, hardcode ethnode1-reth:9001 in all queries
            sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                -e 's/"uid": "prometheus"/"uid": ""/g' \
                -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                -e 's/\$instance/ethnode1-reth:9001/g' \
                -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                "$template_file" > "$output_file.tmp" 2>/dev/null || true
        elif [[ "$template_file" == *"teku"* ]]; then
            # For Teku dashboard, hardcode ethnode1-teku:8008 in all queries
            sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                -e 's/"uid": "prometheus"/"uid": ""/g' \
                -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                -e 's/{instance="\$system"}/{instance="ethnode1-teku:8008"}/g' \
                -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                "$template_file" > "$output_file.tmp" 2>/dev/null || true
        else
            # For other dashboards, use default processing
            sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                -e 's/"uid": "prometheus"/"uid": ""/g' \
                -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                "$template_file" > "$output_file.tmp" 2>/dev/null || true
        fi
        
        # Update tags and title if dynamic values are set
        if [[ -n "$dynamic_tags" && -f "$output_file.tmp" ]]; then
            # Use jq to reliably update JSON tags and title
            jq --argjson tags "[$dynamic_tags]" --arg title "$dynamic_title" '.tags = $tags | .title = $title' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp" 2>/dev/null || true
        elif [[ -f "$output_file.tmp" ]]; then
            # Clear existing tags if no dynamic tags specified
            jq '.tags = []' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp" 2>/dev/null || true
        fi
        
        # Move temp file to final output
        mv "$output_file.tmp" "$output_file" 2>/dev/null || true
    fi
}

# Clean up old dashboards and sync with running services
sync_dashboards_with_services() {
    local dashboards_dir="$1"
    shift
    local networks=("$@")
    
    # Clean up existing dashboards first
    rm -f "$dashboards_dir"/*.json 2>/dev/null || true
    
    # Always copy node-exporter dashboard (system monitoring)
    if [[ -f "$HOME/.nodeboi/templates/system/node-exporter-full.json" ]]; then
        process_dashboard_template "$HOME/.nodeboi/templates/system/node-exporter-full.json" "$dashboards_dir/node-exporter-full.json"
    fi
    
    # Detect active services across all selected networks
    for network in "${networks[@]}"; do
        detect_and_copy_client_dashboards "$dashboards_dir" "$network"
    done
    
    # Copy vero dashboard if vero is running
    if [[ -d "$HOME/vero" ]] && (cd "$HOME/vero" && docker compose ps --services --filter "status=running" | grep -q "vero"); then
        if [[ -f "$HOME/.nodeboi/templates/validators/vero-detailed.json" ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/validators/vero-detailed.json" "$dashboards_dir/vero-detailed.json"
            echo "  ✓ vero dashboard created"
        fi
    fi
    
    # Also regenerate Prometheus configuration to match current services
    local monitoring_dir=$(dirname "$dashboards_dir")
    regenerate_prometheus_config "$monitoring_dir" "${networks[@]}"
    
    echo "Dashboard and Prometheus sync complete"
}

# Regenerate Prometheus configuration to match current running services
regenerate_prometheus_config() {
    local monitoring_dir="$1"
    shift
    local networks=("$@")
    
    echo "Regenerating Prometheus configuration..."
    
    # Generate new Prometheus targets
    local prometheus_targets=$(generate_prometheus_targets "${networks[@]}")
    
    # Create new prometheus.yml
    cat > "$monitoring_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

${prometheus_targets}
EOF
    
    echo "  ✓ prometheus.yml regenerated"
}

# Legacy function name for compatibility
copy_relevant_dashboards() {
    sync_dashboards_with_services "$@"
}

# Detect client types and copy corresponding dashboards
detect_and_copy_client_dashboards() {
    local dashboards_dir="$1"
    local network="$2"
    
    # Check for ethnode directories
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            # For nodeboi-net, include ALL ethnodes regardless of their individual network
            # For specific networks, match the network name
            if [[ "$network" == "nodeboi-net" ]]; then
                # Always copy dashboards for nodeboi-net (includes all ethnodes) if running
                local compose_file="$ethnode_dir/compose.yml"
                if [[ ! -f "$compose_file" ]]; then
                    compose_file="$ethnode_dir/docker-compose.yml"
                fi
                if [[ -f "$compose_file" ]] && (cd "$ethnode_dir" && docker compose ps --services --filter "status=running" | grep -q .); then
                    copy_dashboards_for_ethnode "$dashboards_dir" "$ethnode_dir"
                fi
            else
                # Check if this ethnode is on the target network
                local ethnode_network=$(grep "^NETWORK=" "$ethnode_dir/.env" | cut -d'=' -f2)
                if [[ "$ethnode_network" == "$network" ]]; then
                    # Check if ethnode is running (try both compose.yml and docker-compose.yml)
                    local compose_file="$ethnode_dir/compose.yml"
                    if [[ ! -f "$compose_file" ]]; then
                        compose_file="$ethnode_dir/docker-compose.yml"
                    fi
                    if [[ -f "$compose_file" ]] && (cd "$ethnode_dir" && docker compose ps --services --filter "status=running" | grep -q .); then
                        copy_dashboards_for_ethnode "$dashboards_dir" "$ethnode_dir"
                    fi
                fi
            fi
        fi
    done
}

# Copy dashboards for a specific ethnode based on its client configuration
copy_dashboards_for_ethnode() {
    local dashboards_dir="$1"
    local ethnode_dir="$2"
    
    if [[ -f "$ethnode_dir/.env" ]]; then
        # Parse COMPOSE_FILE to detect clients (format: compose.yml:client1.yml:client2.yml)
        local compose_file=$(grep "^COMPOSE_FILE=" "$ethnode_dir/.env" | cut -d'=' -f2)
        local ethnode_name=$(basename "$ethnode_dir")
        
        # Detect execution clients
        if [[ "$compose_file" == *"reth"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/execution/reth-overview.json" "$dashboards_dir/reth-overview.json"
            echo "  ✓ ${ethnode_name}-reth dashboard created"
        fi
        if [[ "$compose_file" == *"besu"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/execution/besu-overview.json" "$dashboards_dir/besu-overview.json"
            echo "  ✓ ${ethnode_name}-besu dashboard created"
        fi
        if [[ "$compose_file" == *"nethermind"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/execution/nethermind-overview.json" "$dashboards_dir/nethermind-overview.json"
            echo "  ✓ ${ethnode_name}-nethermind dashboard created"
        fi
        
        # Detect consensus clients
        if [[ "$compose_file" == *"teku"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/consensus/teku-overview.json" "$dashboards_dir/teku-overview.json"
            echo "  ✓ ${ethnode_name}-teku dashboard created"
        fi
        if [[ "$compose_file" == *"lighthouse"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/consensus/lighthouse-overview.json" "$dashboards_dir/lighthouse-overview.json"
            process_dashboard_template "$HOME/.nodeboi/templates/consensus/lighthouse-summary.json" "$dashboards_dir/lighthouse-summary.json"
            echo "  ✓ ${ethnode_name}-lighthouse dashboard created"
        fi
        if [[ "$compose_file" == *"grandine"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/consensus/grandine-overview.json" "$dashboards_dir/grandine-overview.json"
            echo "  ✓ ${ethnode_name}-grandine dashboard created"
        fi
        if [[ "$compose_file" == *"lodestar"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/templates/consensus/lodestar-summary.json" "$dashboards_dir/lodestar-summary.json"
            echo "  ✓ ${ethnode_name}-lodestar dashboard created"
        fi
    fi
}

# Refresh dashboards and Prometheus config for existing monitoring installation
refresh_monitoring_dashboards() {
    local monitoring_dir="$HOME/monitoring"
    
    if [[ -d "$monitoring_dir" && -f "$monitoring_dir/docker-compose.yml" ]]; then
        echo -e "${UI_MUTED}Refreshing monitoring configuration...${NC}"
        
        # Regenerate Prometheus configuration with current ethnodes
        regenerate_prometheus_config
        
        # Clear existing dashboards
        rm -f "$monitoring_dir/grafana/dashboards"/*.json 2>/dev/null || true
        
        # Detect current ethnode networks
        local networks=("nodeboi-net")  # Always use nodeboi-net for auto-discovery
        
        # Copy relevant dashboards
        copy_relevant_dashboards "$monitoring_dir/grafana/dashboards" "${networks[@]}"
        
        # Restart services to pick up new config
        echo -e "${UI_MUTED}Restarting monitoring services...${NC}"
        cd "$monitoring_dir" && docker compose restart prometheus grafana
        cd "$HOME/.nodeboi"
    fi
}

# Regenerate Prometheus configuration for existing installation
regenerate_prometheus_config() {
    local monitoring_dir="$HOME/monitoring"
    local prometheus_config="$monitoring_dir/prometheus.yml"
    
    if [[ ! -d "$monitoring_dir" ]]; then
        return 1
    fi
    
    # Generate new targets
    local networks=("nodeboi-net")  # Use nodeboi-net for auto-discovery
    local prometheus_targets=$(generate_prometheus_targets "${networks[@]}")
    
    # Create new prometheus.yml
    cat > "$prometheus_config" << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

${prometheus_targets}
EOF
    
    return 0
}

# Discover NODEBOI Docker networks
discover_nodeboi_networks() {
    local networks=()
    
    # Check for shared nodeboi-net first (newer architecture)
    if docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
        # Check if there are any ethnodes using this network
        local ethnode_count=0
        for dir in "$HOME"/ethnode*; do
            if [[ -d "$dir" && -f "$dir/.env" ]]; then
                ((ethnode_count++))
            fi
        done
        
        if [[ $ethnode_count -gt 0 ]]; then
            local running_containers=$(docker network inspect nodeboi-net --format='{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
            if [[ -n "$running_containers" ]]; then
                networks+=("nodeboi-net:$running_containers")
            else
                networks+=("nodeboi-net:no running containers")
            fi
        fi
    fi
    
    # Find individual ethnode networks (older architecture)
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            local network_name="${node_name}-net"
            
            # Skip if this is part of shared nodeboi-net architecture
            if docker network ls --format "{{.Name}}" | grep -q "^nodeboi-net$"; then
                continue
            fi
            
            # Check if network exists
            if docker network ls --format "{{.Name}}" | grep -q "^${network_name}$"; then
                # Get running containers in this network
                local containers=$(docker ps --filter "network=${network_name}" --format "{{.Names}}" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
                
                if [[ -n "$containers" ]]; then
                    networks+=("${network_name}:${containers}")
                else
                    networks+=("${network_name}:no running containers")
                fi
            fi
        fi
    done
    
    # Note: Validator service networks (web3signer-net, etc.) are intentionally excluded
    # for security isolation. Monitoring only connects to nodeboi-net.
    
    printf '%s\n' "${networks[@]}"
}

# Generate Prometheus scrape configs for discovered services
# Remove a specific ethnode network from monitoring configuration
remove_ethnode_from_monitoring() {
    local node_name="$1"
    local monitoring_dir="$HOME/monitoring"
    
    # Check if monitoring exists
    if [[ ! -d "$monitoring_dir" ]]; then
        return 0  # No monitoring, nothing to do
    fi
    
    echo -e "${UI_MUTED}  Removing $node_name from monitoring configuration...${NC}" >&2
    
    # Get current networks that monitoring is connected to
    local current_networks=()
    if [[ -f "$monitoring_dir/compose.yml" ]]; then
        # Extract external networks from compose.yml
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*name:[[:space:]]*(.+)-net$ ]]; then
                local network_name="${BASH_REMATCH[1]}"
                if [[ "$network_name" != "monitoring" && "$network_name" != "$node_name" ]]; then
                    current_networks+=("${network_name}-net")
                fi
            fi
        done < "$monitoring_dir/compose.yml"
    fi
    
    # Regenerate Prometheus config without the removed node
    if [[ ${#current_networks[@]} -gt 0 ]]; then
        echo -e "${UI_MUTED}    Updating Prometheus configuration...${NC}" >&2
        
        # Recreate prometheus.yml without the removed node
        cat > "$monitoring_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
        
        # Add remaining targets
        local prometheus_targets=$(generate_prometheus_targets "${current_networks[@]}")
        echo "$prometheus_targets" >> "$monitoring_dir/prometheus.yml"
        
        # Regenerate monitoring compose.yml with updated networks
        if docker ps -q --filter "name=monitoring-" >/dev/null 2>&1; then
            echo -e "${UI_MUTED}    Updating monitoring configuration to remove ${node_name}-net...${NC}" >&2
            cd "$monitoring_dir" && docker compose down >/dev/null 2>&1 || true
            
            # Get current configuration from .env
            local bind_ip=$(grep "BIND_IP=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
            local grafana_password=$(grep "GRAFANA_PASSWORD=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            # Regenerate the entire compose.yml with remaining networks
            echo -e "${UI_MUTED}    Regenerating compose.yml with remaining networks...${NC}" >&2
            
            # Create new compose.yml (simplified version for network update)
            cat > "$monitoring_dir/compose.yml" <<EOF
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
    restart: unless-stopped
    user: "65534:65534"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
      - '--web.enable-admin-api'
      - '--web.external-url=http://localhost:\${PROMETHEUS_PORT}'
    ports:
      - "\${BIND_IP}:\${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - nodeboi-net
EOF

            # Add remaining ethnode networks to services
            for network in "${current_networks[@]}"; do
                echo "      - $network" >> "$monitoring_dir/compose.yml"
            done

            # Continue with rest of compose.yml
            cat >> "$monitoring_dir/compose.yml" <<EOF
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:\${GRAFANA_VERSION}
    container_name: monitoring-grafana
    restart: unless-stopped
    user: "\${NODE_UID}:\${NODE_GID}"
    ports:
      - "\${BIND_IP}:\${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=\${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:\${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    networks:
      - nodeboi-net
EOF

            # Add remaining ethnode networks to grafana
            for network in "${current_networks[@]}"; do
                echo "      - $network" >> "$monitoring_dir/compose.yml"
            done

            # Finish compose.yml
            cat >> "$monitoring_dir/compose.yml" <<EOF
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:\${NODE_EXPORTER_VERSION}
    container_name: monitoring-node-exporter
    restart: unless-stopped
    user: "root"
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$|/)'
    ports:
      - "127.0.0.1:\${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - nodeboi-net
    cap_drop:
      - ALL
    cap_add:
      - SYS_TIME
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: monitoring_prometheus_data
  grafana_data:
    name: monitoring_grafana_data

networks:
  nodeboi-net:
    external: true
    name: nodeboi-net
EOF

            # Add external network definitions
            for network in "${current_networks[@]}"; do
                cat >> "$monitoring_dir/compose.yml" <<EOF
  $network:
    external: true
    name: $network
EOF
            done

            echo -e "${UI_MUTED}    Restarting monitoring with updated configuration...${NC}" >&2
            docker compose up -d >/dev/null 2>&1 || true
        fi
    else
        echo -e "${UI_MUTED}    No other networks to monitor${NC}" >&2
    fi
}

generate_prometheus_targets() {
    local selected_networks=("$@")
    local prometheus_configs=""
    
    # Get the monitoring name from .env
    local monitoring_name="${MONITORING_NAME:-monitoring}"
    prometheus_configs+="  - job_name: 'node-exporter'
    static_configs:
      - targets: ['${monitoring_name}-node-exporter:9100']

"
    
    # Process each selected network
    for network in "${selected_networks[@]}"; do
        if [[ "$network" == "nodeboi-net" ]]; then
            # For nodeboi-net, discover all ethnode services
            for dir in "$HOME"/ethnode*; do
                if [[ -d "$dir" && -f "$dir/.env" ]]; then
                    local node_name=$(basename "$dir")
                    local node_dir="$dir"
                    
                    # Generate targets for this ethnode
                    generate_targets_for_node "$node_name" "$node_dir" prometheus_configs
                fi
            done
            
            # ADD: Check for Vero and add it to targets
            if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
                prometheus_configs+="  - job_name: 'vero'
    static_configs:
      - targets: ['vero:9010']

"
            fi
        else
            # Legacy individual network support
            local node_name="${network%-net}"
            local node_dir="$HOME/$node_name"
            
            if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
                generate_targets_for_node "$node_name" "$node_dir" prometheus_configs
            fi
        fi
    done
    
    
    echo "$prometheus_configs"
}

# Helper function to generate targets for a specific node
generate_targets_for_node() {
    local node_name="$1"
    local node_dir="$2"
    local -n configs_ref="$3"
    
    if [[ -d "$node_dir" && -f "$node_dir/.env" ]]; then
        # Parse client types from compose file directly
        local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
        
        # Detect execution client
        local exec_client=""
        if [[ "$compose_file" == *"reth"* ]]; then
            exec_client="reth"
        elif [[ "$compose_file" == *"besu"* ]]; then
            exec_client="besu"
        elif [[ "$compose_file" == *"nethermind"* ]]; then
            exec_client="nethermind"
        fi
        
        # Detect consensus client
        local cons_client=""
        if [[ "$compose_file" == *"teku"* ]]; then
            cons_client="teku"
        elif [[ "$compose_file" == *"grandine"* ]]; then
            cons_client="grandine"
        elif [[ "$compose_file" == *"lodestar"* ]]; then
            cons_client="lodestar"
        elif [[ "$compose_file" == *"lighthouse"* ]]; then
            cons_client="lighthouse"
        fi
        
        # Get metrics ports from .env
        if [[ "$exec_client" == "reth" ]]; then
            configs_ref+="  - job_name: '${node_name}-reth'
    static_configs:
      - targets: ['${node_name}-reth:9001']
        labels:
          node: '${node_name}'
          client: 'reth'
          instance: '${node_name}-reth:9001'

"
        elif [[ "$exec_client" == "besu" ]]; then
            # Add proper labels for Besu dashboard compatibility
            configs_ref+="  - job_name: '${node_name}-besu'
    static_configs:
      - targets: ['${node_name}-besu:6060']
        labels:
          node: '${node_name}'
          client: 'besu'
          instance: '${node_name}-besu:6060'
          system: '${node_name}-besu:6060'  # For dashboard compatibility

"
        elif [[ "$exec_client" == "nethermind" ]]; then
            configs_ref+="  - job_name: '${node_name}-nethermind'
    static_configs:
      - targets: ['${node_name}-nethermind:6060']
        labels:
          node: '${node_name}'
          client: 'nethermind'
          instance: '${node_name}-nethermind:6060'

"
        fi
        
        # Consensus clients all use port 8008
        if [[ -n "$cons_client" && "$cons_client" != "unknown" ]]; then
            configs_ref+="  - job_name: '${node_name}-${cons_client}'
    static_configs:
      - targets: ['${node_name}-${cons_client}:8008']
        labels:
          node: '${node_name}'
          client: '${cons_client}'
          instance: '${node_name}-${cons_client}:8008'

"
        fi
    fi
}
# Install monitoring
install_monitoring_stack() {
    # Enable strict error handling for atomic installation
    set -eE
    set -o pipefail
    
    local preselected_networks=("$@")  # Accept networks as parameters
    local final_dir="$HOME/monitoring"  # Final installation location
    local staging_dir="$HOME/.monitoring-install-$$"  # Temporary staging area
    local installation_success=false
    
    # Comprehensive cleanup for atomic installation
    atomic_monitoring_cleanup() {
        local exit_code=$?
        set +e  # Disable error exit for cleanup
        
        # Prevent double cleanup
        if [[ "${installation_success:-false}" == "true" ]]; then
            return 0
        fi
        
        echo -e "\n${RED}✗${NC} Monitoring installation failed"
        echo -e "${UI_MUTED}Performing complete cleanup...${NC}"
        
        # Clean up service registration - remove monitoring directory to prevent phantom service
        if [[ -d "$final_dir" ]]; then
            echo -e "${UI_MUTED}Removing service registration...${NC}"
            rm -rf "$final_dir"
        fi
        
        # Stop and remove any Docker resources
        if [[ -d "$staging_dir" && -f "$staging_dir/compose.yml" ]]; then
            cd "$staging_dir" && docker compose down -v --remove-orphans 2>/dev/null || true
        fi
        
        # Remove containers by name pattern
        docker ps -aq --filter "name=monitoring" | xargs -r docker rm -f 2>/dev/null || true
        
        # Remove volumes and networks
        docker volume ls -q --filter "name=monitoring" | xargs -r docker volume rm -f 2>/dev/null || true
        
        # Remove staging directory
        [[ -n "$staging_dir" ]] && rm -rf "$staging_dir" 2>/dev/null || true
        
        echo -e "${GREEN}✓ Cleanup completed${NC}"
        echo -e "${UI_MUTED}Installation aborted - no partial installation left behind${NC}"
        
        press_enter
        return $exit_code
    }
    
    # Set error trap
    trap atomic_monitoring_cleanup ERR INT TERM
    
    echo -e "\n${CYAN}${BOLD}Install Monitoring${NC}"
    echo "========================="
    echo
    echo -e "${UI_MUTED}This will install:${NC}"
    echo -e "${UI_MUTED}  • Prometheus - Metrics collection and storage${NC}"
    echo -e "${UI_MUTED}  • Grafana - Visual dashboards and analytics${NC}"
    echo -e "${UI_MUTED}  • Node Exporter - System metrics (CPU/Memory/Disk)${NC}"
    echo
    
    # Check if already installed
    if [[ -d "$final_dir" ]]; then
        if [[ ${#preselected_networks[@]} -gt 0 ]]; then
            # Services installation - remove existing installation
            echo -e "${UI_MUTED}Removing existing installation...${NC}"
            cd "$final_dir" 2>/dev/null && docker compose down -v 2>/dev/null || true
            if ! rm -rf "$final_dir" 2>/dev/null; then
                echo -e "${YELLOW}Some files require admin permissions to remove${NC}"
                echo -e "${UI_MUTED}You may be prompted for your password...${NC}"
                sudo rm -rf "$final_dir"
            fi
        else
            # Manual installation - show message and return
            echo -e "${YELLOW}The monitoring stack is already installed${NC}"
            echo -e "${UI_MUTED}Press Enter to continue...${NC}"
            read -r
            trap - ERR INT TERM
            return
        fi
    fi
    
    # Create staging environment
    echo -e "${UI_MUTED}Creating staging environment...${NC}"
    mkdir -p "$staging_dir/grafana/provisioning/datasources"
    
    # Setup user info
    echo -e "${UI_MUTED}Setting up user configuration...${NC}"
    
    # Use current user (eth-docker pattern - no system user needed)
    local NODE_UID=$(id -u)
    local NODE_GID=$(id -g)
    echo -e "${UI_MUTED}  Using current user: UID=${NODE_UID}, GID=${NODE_GID}${NC}"
    
    # Step 2: Get Grafana password
    echo
    local grafana_password
    grafana_password=$(fancy_text_input "Grafana Setup" \
        "Set Grafana admin password (or press Enter for random):" \
        "" \
        "")
    
    if [[ -z "$grafana_password" ]]; then
        # Generate random password
        grafana_password=$(openssl rand -base64 12)
        echo -e "${UI_MUTED}Generated password: ${GREEN}$grafana_password${NC}"
    fi
    
    # Step 3: Network access configuration
    local bind_ip
    if [[ ${#preselected_networks[@]} -gt 0 ]]; then
        # Services installation - use 0.0.0.0 automatically
        bind_ip="0.0.0.0"
        echo -e "${UI_MUTED}Setting network access to all networks (0.0.0.0)...${NC}"
    else
        # Manual installation - prompt for choice
        echo
        local access_options=(
            "My machine only (127.0.0.1) - Most secure"
            "Local network access (auto-detect IP)"
            "All networks (0.0.0.0) - Use with caution"
        )
        
        bind_ip="127.0.0.1"
        local access_choice
        if access_choice=$(fancy_select_menu "Monitoring Access Level" "${access_options[@]}"); then
            case $access_choice in
                0) bind_ip="127.0.0.1" ;;
                1) 
                    bind_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
                    echo -e "${UI_MUTED}Using local network IP: $bind_ip${NC}"
                    ;;
                2) 
                    bind_ip="0.0.0.0"
                    echo -e "${YELLOW}⚠ WARNING: Accessible from all networks${NC}"
                    ;;
            esac
        fi
    fi
    
    # Step 4: Auto-discover and connect to all ethnode networks
    echo
    local selected_networks=()
    
    if [[ ${#preselected_networks[@]} -gt 0 ]]; then
        # Use pre-selected networks (from services installation)
        echo -e "${UI_MUTED}Using pre-selected networks: ${preselected_networks[*]}${NC}"
        selected_networks=("${preselected_networks[@]}")
    else
        # Auto-discover and prompt for selection
        echo -e "${UI_MUTED}Auto-discovering ethnode networks...${NC}"
        local available_networks=($(discover_nodeboi_networks))
        
        # Auto-select all ethnode networks
        for network_info in "${available_networks[@]}"; do
            local network_name="${network_info%%:*}"
            local containers="${network_info#*:}"
        
        # Only include ethnode networks, not other service networks
        if [[ "$network_name" =~ ^ethnode.*-net$ ]]; then
            selected_networks+=("$network_name")
            if [[ "$containers" == "no running containers" ]]; then
                echo -e "${UI_MUTED}  Found: $network_name (stopped)${NC}"
            else
                echo -e "${UI_MUTED}  Found: $network_name [${containers}]${NC}"
            fi
        fi
        done
        
        if [[ ${#selected_networks[@]} -eq 0 ]]; then
            echo -e "${UI_MUTED}  No ethnode networks found. Monitoring will only collect system metrics.${NC}"
        else
            echo -e "${UI_MUTED}  Auto-connecting to: ${selected_networks[*]}${NC}"
        fi
    fi
    
    # Step 5: Find available ports
    echo -e "${UI_MUTED}Allocating ports...${NC}"
    init_port_management >/dev/null 2>&1
    
    local used_ports=$(get_all_used_ports)
    local prometheus_port=$(find_available_port 9090 1 "$used_ports")
    local grafana_port=$(find_available_port 3000 1 "$used_ports") 
    local node_exporter_port=$(find_available_port 9100 1 "$used_ports")
    
    # Step 6: Create .env file
    cat > "$staging_dir/.env" <<EOF
#============================================================================
# MONITORING CONFIGURATION
# Generated: $(date)
#============================================================================
COMPOSE_FILE=compose.yml
MONITORING_NAME=monitoring
NODE_UID=${NODE_UID}
NODE_GID=${NODE_GID}

# Monitoring Ports
PROMETHEUS_PORT=${prometheus_port}
GRAFANA_PORT=${grafana_port}
NODE_EXPORTER_PORT=${node_exporter_port}

# Grafana Configuration
GRAFANA_PASSWORD=${grafana_password}

# Monitoring Versions
PROMETHEUS_VERSION=v3.5.0
GRAFANA_VERSION=12.1.0
NODE_EXPORTER_VERSION=v1.9.1

# Network Access
BIND_IP=${bind_ip}

# Connected Networks
MONITORED_NETWORKS="${selected_networks[*]}"
EOF

    # Step 7: Create compose.yml with selected networks
    cat > "$staging_dir/compose.yml" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: ${MONITORING_NAME}-prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    ports:
      - "${BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - nodeboi-net
EOF

    # Continue with rest of compose.yml
    cat >> "$staging_dir/compose.yml" <<'EOF'
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: ${MONITORING_NAME}-grafana
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${BIND_IP}:${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    networks:
      - nodeboi-net
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: ${MONITORING_NAME}-node-exporter
    restart: unless-stopped
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
    ports:
      - "127.0.0.1:${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - nodeboi-net
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: ${MONITORING_NAME}_prometheus_data
  grafana_data:
    name: ${MONITORING_NAME}_grafana_data

networks:
  nodeboi-net:
    external: true
    name: nodeboi-net
EOF
    
    # nodeboi-net is already defined above, no additional networks needed

    # Step 8: Create Prometheus configuration
    echo -e "${UI_MUTED}Generating Prometheus configuration...${NC}"
    
    cat > "$staging_dir/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
    
    # Add discovered targets
    local prometheus_targets=$(generate_prometheus_targets "${selected_networks[@]}")
    echo "$prometheus_targets" >> "$staging_dir/prometheus.yml"
    
    # Step 9: Create Grafana provisioning configuration
    # Create datasource configuration
    cat > "$staging_dir/grafana/provisioning/datasources/prometheus.yml" <<EOF
apiVersion: 1

datasources:
  - name: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
    
    # Create dashboard provisioning directories
    mkdir -p "$staging_dir/grafana/provisioning/dashboards"
    mkdir -p "$staging_dir/grafana/dashboards"
    
    # Create dashboard provisioning configuration
    cat > "$staging_dir/grafana/provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /etc/grafana/dashboards
EOF
    
    # Copy relevant dashboard templates based on active services
    echo -e "${UI_MUTED}Copying dashboard templates for active services...${NC}"
    copy_relevant_dashboards "$staging_dir/grafana/dashboards" "${selected_networks[@]}"
    
    # Step 10: Set permissions
    echo -e "${UI_MUTED}Setting permissions...${NC}"
    # Ensure proper permissions on directories (already owned by current user)
    chmod 755 "$staging_dir/"
    chmod 755 "$staging_dir/grafana/provisioning/"
    chmod 755 "$staging_dir/grafana/provisioning/datasources/"
    
    # Step 11: Launch monitoring
    echo -e "${UI_MUTED}Starting monitoring...${NC}"
    # ATOMIC OPERATION: Move from staging to final location
    echo -e "${UI_MUTED}Finalizing monitoring installation...${NC}"
    echo -e "${UI_MUTED}Moving from staging to final location...${NC}"
    
    # This is the atomic operation - either it all succeeds or fails
    mv "$staging_dir" "$final_dir"
    
    # Mark installation as successful to prevent cleanup
    installation_success=true
    
    # Remove error trap now that installation is complete
    trap - ERR INT TERM
    
    cd "$final_dir"
    
    # Pre-validate networks before starting containers
    echo -e "${UI_MUTED}Validating external network dependencies...${NC}"
    local network_validation_failed=false
    for network in "${selected_networks[@]}"; do
        if ! docker network inspect "$network" >/dev/null 2>&1; then
            echo -e "${RED}✗ Network '$network' does not exist${NC}"
            network_validation_failed=true
        else
            echo -e "${UI_MUTED}✓ $network already exists${NC}"
        fi
    done
    
    if [[ "$network_validation_failed" == "true" ]]; then
        echo -e "${RED}Network validation failed - aborting installation${NC}"
        press_enter
        return 1
    fi
    
    if docker compose up -d; then
        echo
        sleep 2
        
        # Verify containers are running
        if docker compose ps --services --filter status=running | grep -q prometheus; then
            echo -e "${GREEN}✓ Monitoring installed successfully!${NC}"
            echo
            echo -e "${BOLD}Access Information:${NC}"
            echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            
            if [[ "$bind_ip" == "127.0.0.1" ]]; then
                echo -e "Grafana:     ${GREEN}http://localhost:${grafana_port}${NC}"
            else
                echo -e "Grafana:     ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
            fi
            
            echo
            echo -e "${BOLD}Login Credentials:${NC}"
            echo -e "${UI_MUTED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "Username: ${GREEN}admin${NC}"
            echo -e "Password: ${GREEN}${grafana_password}${NC}"
            echo
            echo -e "${UI_MUTED}Import dashboards from Grafana web UI:${NC}"
            echo -e "${UI_MUTED}  • Node Exporter Full: ID 1860${NC}"
            echo -e "${UI_MUTED}  • Reth: ID 22941${NC}"
            echo -e "${UI_MUTED}  • Besu: ID 10273${NC}"
            echo
            echo -e "${YELLOW}💡 Tip: You can view these credentials later in:${NC}"
            echo -e "${UI_MUTED}   Main Menu → Manage services → Manage monitoring → See Grafana login information${NC}"
            
            press_enter
            return 0
        else
            echo -e "${RED}Failed to start monitoring containers${NC}"
            docker compose logs --tail=20
            press_enter
            return 1
        fi
    else
        echo -e "${RED}Failed to launch monitoring${NC}"
        press_enter
        return 1
    fi
}

# View Grafana credentials
view_grafana_credentials() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Grafana Access Information${NC}"
    echo "=========================="
    
    local bind_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local grafana_port=$(grep "^GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local grafana_password=$(grep "^GRAFANA_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    local prometheus_port=$(grep "^PROMETHEUS_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    
    echo
    echo -e "${BOLD}URLs:${NC}"
    if [[ "$bind_ip" == "127.0.0.1" ]]; then
        echo -e "  Grafana:    ${GREEN}http://localhost:${grafana_port}${NC}"
    elif [[ "$bind_ip" == "0.0.0.0" ]]; then
        local actual_ip=$(hostname -I | awk '{print $1}')
        echo -e "  Grafana:    ${GREEN}http://${actual_ip}:${grafana_port}${NC}"
    else
        echo -e "  Grafana:    ${GREEN}http://${bind_ip}:${grafana_port}${NC}"
    fi
    echo -e "              Username: ${GREEN}admin${NC}"
    echo -e "              Password: ${GREEN}${grafana_password}${NC}"
    
    # Refresh dashboard to show monitoring
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard

    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Change monitoring network access level
change_monitoring_access_level() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Change Network Access Level${NC}"
    echo "==========================="
    
    local current_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    echo -e "\nCurrent setting: ${GREEN}$current_ip${NC}"
    
    local access_options=(
        "My machine only (127.0.0.1)"
        "Local network access (auto-detect IP)"
        "All networks (0.0.0.0)"
        "Cancel"
    )
    
    local new_ip=""
    local access_choice
    if access_choice=$(fancy_select_menu "Select New Access Level" "${access_options[@]}"); then
        case $access_choice in
            0) new_ip="127.0.0.1" ;;
            1) 
                new_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
                echo -e "${UI_MUTED}Detected local IP: $new_ip${NC}"
                ;;
            2) 
                new_ip="0.0.0.0"
                echo -e "${YELLOW}⚠ WARNING: This will make monitoring accessible from all networks${NC}"
                ;;
            3) return ;;
        esac
    else
        return
    fi
    
    if [[ -n "$new_ip" && "$new_ip" != "$current_ip" ]]; then
        sed -i "s/^BIND_IP=.*/BIND_IP=${new_ip}/" "$HOME/monitoring/.env"
        echo -e "${UI_MUTED}Restarting monitoring...${NC}"
        cd "$HOME/monitoring"
        docker compose down && docker compose up -d
        echo -e "${GREEN}✓ Access level changed to: $new_ip${NC}"
    fi
    
    press_enter
}

# Update monitored networks
update_monitoring_networks() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Update Monitored Networks${NC}"
    echo "========================"
    
    # Get current monitored networks
    local current_networks=$(grep "^MONITORED_NETWORKS=" "$HOME/monitoring/.env" | cut -d'=' -f2 | tr -d '"')
    echo -e "\nCurrently monitoring: ${GREEN}${current_networks}${NC}"
    
    # Discover available networks
    echo -e "\n${UI_MUTED}Discovering Docker networks...${NC}"
    local available_networks=($(discover_nodeboi_networks))
    
    if [[ ${#available_networks[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No NODEBOI networks found${NC}"
        press_enter
        return
    fi
    
    # Display available networks
    local network_options=()
    local network_names=()
    
    for network_info in "${available_networks[@]}"; do
        local network_name="${network_info%%:*}"
        local containers="${network_info#*:}"
        network_names+=("$network_name")
        
        # Check if already monitored
        local status=""
        if echo " $current_networks " | grep -q " $network_name "; then
            status=" [MONITORED]"
        fi
        
        if [[ "$containers" == "no running containers" ]]; then
            network_options+=("$network_name (stopped)$status")
        else
            if [[ ${#containers} -gt 40 ]]; then
                containers="${containers:0:37}..."
            fi
            network_options+=("$network_name [$containers]$status")
        fi
    done
    
    echo
    echo -e "${BOLD}Select networks to monitor:${NC}"
    echo -e "${UI_MUTED}Currently monitored networks are marked${NC}"
    echo
    
    for i in "${!network_options[@]}"; do
        echo -e "  $((i+1))) ${network_options[$i]}"
    done
    echo -e "  A) Select all"
    echo -e "  C) Cancel"
    echo
    
    read -p "Enter numbers separated by spaces: " selections
    
    [[ "${selections,,}" == "c" ]] && return
    
    local selected_networks=()
    if [[ "${selections,,}" == "a" ]]; then
        selected_networks=("${network_names[@]}")
    else
        for num in $selections; do
            if [[ $num -ge 1 && $num -le ${#network_names[@]} ]]; then
                selected_networks+=("${network_names[$((num-1))]}")
            fi
        done
    fi
    
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${YELLOW}No networks selected${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${UI_MUTED}Updating configuration...${NC}"
    
    # Update .env (use sudo since files are owned by monitoring user)
    sudo sed -i "s/^MONITORED_NETWORKS=.*/MONITORED_NETWORKS=\"${selected_networks[*]}\"/" "$HOME/monitoring/.env"
    
    # Regenerate compose.yml networks section
    cd "$HOME/monitoring"
    
    # Remove old network definitions (everything after "networks:" at root level)
    sudo sed -i '/^networks:/,$d' compose.yml
    
    # Add networks section (use sudo since files are owned by monitoring user)
    sudo tee -a compose.yml > /dev/null <<EOF
networks:
  nodeboi-net:
    external: true
    name: nodeboi-net
EOF
    
    for network in "${selected_networks[@]}"; do
        sudo tee -a compose.yml > /dev/null <<EOF
  ${network}:
    external: true
    name: ${network}
EOF
    done
    
    # Regenerate Prometheus config
    echo -e "${UI_MUTED}Regenerating Prometheus configuration...${NC}"
    
    sudo tee prometheus.yml > /dev/null <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
    
    local prometheus_targets=$(generate_prometheus_targets "${selected_networks[@]}")
    echo "$prometheus_targets" | sudo tee -a prometheus.yml > /dev/null
    
    # Restart stack
    echo -e "${UI_MUTED}Restarting monitoring stack...${NC}"
    docker compose down
    docker compose up -d
    
    echo -e "${GREEN}✓ Monitoring configuration updated${NC}"
    echo -e "${UI_MUTED}Now monitoring: ${selected_networks[*]}${NC}"
    
    press_enter
}

# Remove monitoring
remove_monitoring_stack() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    echo -e "\n${CYAN}${BOLD}Remove Monitoring${NC}"
    echo "======================="
    
    echo -e "${UI_MUTED}Stopping monitoring containers...${NC}"
    cd "$HOME/monitoring" 2>/dev/null && docker compose down -v 2>/dev/null || true
    
    echo -e "${UI_MUTED}Removing monitoring files...${NC}"
    # Use sudo for files that might be owned by the old monitoring user
    if ! rm -rf "$HOME/monitoring" 2>/dev/null; then
        echo -e "${YELLOW}Some files require admin permissions to remove${NC}"
        echo -e "${UI_MUTED}You may be prompted for your password...${NC}"
        sudo rm -rf "$HOME/monitoring"
    fi
    
    # No system user cleanup needed - using current user
    
    echo -e "${GREEN}✅ Monitoring removed successfully${NC}"
    
    # Refresh dashboard cache to remove monitoring from display
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
    
    press_enter
}



# Network Management Interface - Clean and Simple
manage_monitoring_networks() {
    if [[ ! -f "$HOME/monitoring/.env" ]]; then
        echo -e "${YELLOW}Monitoring stack not installed${NC}"
        press_enter
        return
    fi
    
    # Define colors for this function (don't redeclare UI_MUTED if it exists)
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[0;33m'
    local CYAN='\033[0;36m'
    local BOLD='\033[1m'
    local NC='\033[0m'
    local PINK='\033[38;5;213m'
    [[ -z "$UI_MUTED" ]] && UI_MUTED='\033[38;5;240m'
    
    # Load required libraries for dashboard functionality
    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" 2>/dev/null
    [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null
    
    # Clear initialization flags for fresh start
    unset TEMP_SELECTED_NETWORKS
    unset TEMP_STATE_INITIALIZED
    
    while true; do
        clear
        
        # Print header
        echo -e "${PINK}${BOLD}"
        echo "      ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗"
        echo "      ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║"
        echo "      ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║"
        echo "      ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║"
        echo "      ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║"
        echo "      ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝"
        echo -e "${NC}"
        echo -e "                      ${CYAN}ETHEREUM NODE AUTOMATION${NC}"
        echo -e "                             ${YELLOW}v0.3.1${NC}"
        echo
        
        # Show dashboard if available
        if declare -f print_dashboard >/dev/null; then
            print_dashboard
            echo
        else
            echo -e "${BOLD}NODEBOI Dashboard${NC}"
            echo -e "${BOLD}=================${NC}"
            echo
        fi
        
        echo -e "${CYAN}${BOLD}🔗 Docker Network Connections${NC}"
        echo -e "${CYAN}${BOLD}==============================${NC}"
        echo
        echo -e "${UI_MUTED}Networks available for monitoring connection:${NC}"
        echo
        
        # Get available networks using DICKS discovery
        local discovered_networks=($(docker_intelligent_connecting_kontainer_system --discover-networks | grep -v "^monitoring$"))
        local available_networks=()
        
        # Format networks with container count for UI display
        for network_name in "${discovered_networks[@]}"; do
            local containers=$(docker ps --filter "network=${network_name}" --format "{{.Names}}" | wc -l)
            if [[ $containers -gt 0 ]]; then
                available_networks+=("${network_name}:${containers}")
            fi
        done
        
        if [[ ${#available_networks[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No running ethnode networks found${NC}"
            echo -e "${UI_MUTED}Start some ethnode instances first${NC}"
            echo
            press_enter
            return
        fi
        
        # Get currently connected networks from compose.yml
        local current_networks=""
        if [[ -f "$HOME/monitoring/compose.yml" ]]; then
            # Extract external network names from compose.yml
            current_networks=$(grep -A1 "external: true" "$HOME/monitoring/compose.yml" | grep "name:" | awk '{print $2}' | tr '\n' ' ')
        fi
        
        # Initialize temporary selection state with current compose.yml state (only on first loop)
        if [[ -z "$TEMP_SELECTED_NETWORKS" && -z "$TEMP_STATE_INITIALIZED" ]]; then
            TEMP_SELECTED_NETWORKS="$current_networks"
            TEMP_STATE_INITIALIZED="true"
        fi
        
        # Display available networks with current selection status
        for i in "${!available_networks[@]}"; do
            local network_info="${available_networks[$i]}"
            local network_name="${network_info%%:*}"
            local node_name="${network_name%-net}"
            local service_count="${network_info#*:}"
            
            # Check if currently selected in temporary state
            local checkbox="[ ]"
            if [[ -n "$TEMP_SELECTED_NETWORKS" ]] && echo " $TEMP_SELECTED_NETWORKS " | grep -q " $network_name "; then
                checkbox="[x]"
            fi
            
            echo -e "  $((i+1))) $checkbox $node_name ($service_count services)"
        done
        
        echo
        echo -e "${BOLD}Actions:${NC}"
        echo -e "  Enter numbers to toggle networks (e.g., '1' to toggle ethnode1, '1 2' for both)"
        echo -e "  A) Select all networks"
        echo -e "  D) Deselect all networks"
        echo -e "  S) Save current selection"
        echo -e "  Q) Back to monitoring menu"
        echo
        
        read -p "Your choice: " choice
        
        case "$choice" in
            [1-9]*)
                # Toggle networks: each number toggles that network on/off
                local current_selection=()
                if [[ -n "$TEMP_SELECTED_NETWORKS" ]]; then
                    read -ra current_selection <<< "$TEMP_SELECTED_NETWORKS"
                fi
                
                # Process each number in the input
                for num in $choice; do
                    if [[ $num =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#available_networks[@]} ]]; then
                        local network_name="${available_networks[$((num-1))]%%:*}"
                        
                        # Check if network is already selected
                        local found=false
                        local new_selection=()
                        
                        for selected in "${current_selection[@]}"; do
                            if [[ "$selected" == "$network_name" ]]; then
                                found=true
                                # Skip this network (remove it)
                            else
                                new_selection+=("$selected")
                            fi
                        done
                        
                        # If not found, add it
                        if [[ "$found" == false ]]; then
                            new_selection+=("$network_name")
                        fi
                        
                        current_selection=("${new_selection[@]}")
                    fi
                done
                
                # Update temporary selection
                TEMP_SELECTED_NETWORKS="${current_selection[*]}"
                
                if [[ ${#current_selection[@]} -eq 0 ]]; then
                    echo -e "${UI_MUTED}No networks selected${NC}"
                else
                    local node_names=()
                    for network in "${current_selection[@]}"; do
                        node_names+=("${network%-net}")
                    done
                    echo -e "${GREEN}Selected: ${node_names[*]}${NC}"
                fi
                sleep 1
                ;;
                
            [Aa])
                # Select all networks
                local all_networks=()
                for network_info in "${available_networks[@]}"; do
                    all_networks+=("${network_info%%:*}")
                done
                TEMP_SELECTED_NETWORKS="${all_networks[*]}"
                echo -e "${GREEN}All networks selected${NC}"
                sleep 1
                ;;
                
            [Dd])
                # Deselect all networks
                TEMP_SELECTED_NETWORKS=""
                echo -e "${UI_MUTED}All networks deselected${NC}"
                sleep 1
                ;;
                
            [Ss])
                # Save and apply network connections using DICKS
                apply_network_connections
                return
                ;;
                
            [Qq]|'')
                return
                ;;
                
            *)
                echo -e "${YELLOW}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Apply network connections using DICKS backend
apply_network_connections() {
    clear
    echo -e "${CYAN}${BOLD}💾 Applying Network Connections${NC}"
    echo "================================"
    echo
    
    # Get the selected networks from temporary variable (no .env file involved)
    local selected_networks=($TEMP_SELECTED_NETWORKS)
    
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${UI_MUTED}No networks selected - monitoring will be isolated${NC}"
    else
        echo -e "${UI_MUTED}Connecting to networks:${NC}"
        for network in "${selected_networks[@]}"; do
            local node_name="${network%-net}"
            echo -e "  • $node_name"
        done
    fi
    
    echo
    echo -e "${UI_MUTED}Using DICKS to apply network connections...${NC}"
    
    # Use DICKS to apply network connections with UI feedback
    docker_intelligent_connecting_kontainer_system --apply --service=monitoring --networks="${selected_networks[*]}" --ui
    
    echo
    if [[ ${#selected_networks[@]} -eq 0 ]]; then
        echo -e "${GREEN}✅ Monitoring network is now isolated${NC}"
    else
        local node_names=()
        for network in "${selected_networks[@]}"; do
            node_names+=("${network%-net}")
        done
        echo -e "${GREEN}✅ Monitoring connected to: ${node_names[*]}${NC}"
    fi
    
    echo -e "${UI_MUTED}Changes applied successfully. Network connections are now active.${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Monitoring management menu
manage_monitoring_menu() {
    while true; do
        # Check monitoring status dynamically
        local monitoring_status=""
        if cd ~/monitoring 2>/dev/null; then
            local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
            local all_running=true
            for service in prometheus grafana node-exporter; do
                if ! echo "$running_services" | grep -q "$service"; then
                    all_running=false
                    break
                fi
            done
            
            if [[ "$all_running" == true ]]; then
                monitoring_status="Stop monitoring"
            else
                monitoring_status="Start monitoring"
            fi
        else
            monitoring_status="Start monitoring"
        fi
        
        local menu_options=(
            "$monitoring_status"
            "See Grafana login information"
            "View logs"
            "Update monitoring"
            "Remove monitoring"
            "Back to main menu"
        )
        
        local selection
        if selection=$(fancy_select_menu "Manage Monitoring" "${menu_options[@]}"); then
            case "${menu_options[$selection]}" in
                "Start monitoring")
                    echo -e "${UI_MUTED}Starting monitoring services...${NC}"
                    cd ~/monitoring && docker compose up -d
                    echo -e "${GREEN}✓ Monitoring services started${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
                    press_enter
                    ;;
                "Stop monitoring")
                    echo -e "${UI_MUTED}Stopping monitoring services...${NC}"
                    cd ~/monitoring && docker compose down
                    echo -e "${GREEN}✓ Monitoring services stopped${NC}"
                    [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
                    press_enter
                    ;;
                "Start/stop monitoring")
                    manage_monitoring_state
                    ;;
                "See Grafana login information")
                    view_grafana_credentials
                    ;;
                "View logs")
                    view_monitoring_logs
                    ;;
                "Update monitoring")
                    update_monitoring_services
                    ;;
                "Remove monitoring")
                    remove_monitoring_stack
                    ;;
                "Back to main menu")
                    return
                    ;;
            esac
        else
            return
        fi
    done
}

# Check monitoring health exactly like ethnodes
check_monitoring_health() {
    local monitoring_dir="$HOME/monitoring"
    
    # Check if containers running
    local containers_running=false
    if cd "$monitoring_dir" 2>/dev/null; then
        local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
        if echo "$running_services" | grep -q "prometheus" && echo "$running_services" | grep -q "grafana"; then
            containers_running=true
        fi
    fi
    
    # Get bind IP and access level indicator
    local bind_ip=$(grep "^BIND_IP=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local display_ip="$bind_ip"
    local access_indicator=""
    case "$bind_ip" in
        "127.0.0.1") 
            access_indicator=" ${GREEN}[M]${NC}" 
            display_ip="localhost"
            ;;
        "0.0.0.0") 
            access_indicator=" ${RED}[A]${NC}"
            # Get actual machine IP for display
            display_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || ip route get 1 2>/dev/null | awk '/src/ {print $7}' || echo "localhost")
            ;;
        *) 
            access_indicator=" ${YELLOW}[L]${NC}" 
            display_ip="$bind_ip"
            ;;
    esac
    
    # Get versions from .env
    local grafana_version=$(grep "^GRAFANA_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local prometheus_version=$(grep "^PROMETHEUS_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local node_exporter_version=$(grep "^NODE_EXPORTER_VERSION=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Get ports
    local grafana_port=$(grep "^GRAFANA_PORT=" "$monitoring_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Check for updates (add update indicators like ethnodes)
    local grafana_update_indicator=""
    local prometheus_update_indicator=""  
    local node_exporter_update_indicator=""
    
    # Only check for updates if monitoring is running (to avoid slowdown)
    if [[ "$containers_running" == true ]]; then
        # Check updates using unified function
        grafana_update_indicator=$(check_service_update "grafana" "$grafana_version")
        prometheus_update_indicator=$(check_service_update "prometheus" "$prometheus_version")
        node_exporter_update_indicator=$(check_service_update "node-exporter" "$node_exporter_version")
    fi
    
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} monitoring${access_indicator}"
        
        # Check individual service status
        local grafana_status="${GREEN}✓${NC}"
        local prometheus_status="${GREEN}✓${NC}"
        local node_exporter_status="${GREEN}✓${NC}"
        
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "grafana"; then
            grafana_status="${RED}✗${NC}"
        fi
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "prometheus"; then
            prometheus_status="${RED}✗${NC}"
        fi
        if ! docker compose ps --services --filter status=running 2>/dev/null | grep -q "node-exporter"; then
            node_exporter_status="${RED}✗${NC}"
        fi
        
        printf "     %b %-20s (%s)%b\t     http://%s:%s\n" "$grafana_status" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %b %-20s (%s)%b\n" "$prometheus_status" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator"
        printf "     %b %-20s (%s)%b\n" "$node_exporter_status" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    else
        echo -e "  ${RED}●${NC} monitoring - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\t     http://%s:%s\n" "Grafana" "$(display_version "grafana" "$grafana_version")" "$grafana_update_indicator" "$display_ip" "$grafana_port"
        printf "     %-20s (%s)%b\n" "Prometheus" "$(display_version "prometheus" "$prometheus_version")" "$prometheus_update_indicator"
        printf "     %-20s (%s)%b\n" "Node Exporter" "$(display_version "node-exporter" "$node_exporter_version")" "$node_exporter_update_indicator"
    fi
    echo
    echo
}

# Helper function to find available port
find_available_port() {
    local start_port=$1
    local increment=${2:-1}
    local used_ports="${3:-}"
    
    [[ -z "$used_ports" ]] && used_ports=$(get_all_used_ports)
    
    local port=$start_port
    while echo " $used_ports " | grep -q " $port "; do
        port=$((port + increment))
    done
    
    echo $port
}


# Services installation menu
manage_services_menu() {
    while true; do
        clear
        print_header
        
        
        # Check if monitoring is installed
        local monitoring_installed=false
        if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" ]]; then
            monitoring_installed=true
        fi
        
        local menu_options=()
        if [[ "$monitoring_installed" == true ]]; then
            menu_options+=("Uninstall monitoring services")
        else
            menu_options+=("Install monitoring services (with DICKS)")
        fi
        
        menu_options+=("Back to main menu")
        
        local selection
        if selection=$(fancy_select_menu "Available Services" "${menu_options[@]}"); then
            if [[ "$monitoring_installed" == true ]]; then
                case $selection in
                    0) remove_monitoring_stack ;;
                    1) return ;;
                esac
            else
                case $selection in
                    0) install_monitoring_services_with_dicks ;;
                    1) return ;;
                esac
            fi
        else
            return
        fi
    done
}
# Install monitoring services with automatic DICKS network setup
install_monitoring_services_with_dicks() {
    clear
    print_header
    
    # Show dashboard if available
    if declare -f print_dashboard >/dev/null; then
        print_dashboard
        echo
    fi
    
    # Check if monitoring is already installed
    if [[ -d "$HOME/monitoring" ]]; then
        echo -e "${YELLOW}The monitoring stack is already installed${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi

    echo -e "${CYAN}${BOLD}🔌 Installing Monitoring Services with DICKS${NC}"
    echo -e "${CYAN}${BOLD}===========================================${NC}"
    echo
    echo -e "${UI_MUTED}This will install monitoring (Prometheus + Grafana) and"
    echo -e "automatically connect it to all available ethnode networks.${NC}"
    echo
    
    # Get list of available ethnode networks for preview
    # Use proper discovery that checks for actual ethnodes, not just Docker networks
    local available_networks=($(discover_nodeboi_networks | cut -d':' -f1))
    if [[ ${#available_networks[@]} -gt 0 ]]; then
        echo -e "${BOLD}Networks that will be connected:${NC}"
        for network in "${available_networks[@]}"; do
            local node_name="${network%-net}"
            echo -e "  • $node_name"
        done
        echo
    else
        echo -e "${YELLOW}⚠️  No active ethnodes found. Monitoring will be installed in isolated mode.${NC}"
        echo
    fi
    
    echo -e "${UI_MUTED}Starting automatic installation...${NC}"
    echo
    
    # Install monitoring with all networks pre-selected
    if install_monitoring_stack "${available_networks[@]}"; then
        echo -e "${GREEN}✅ Monitoring services installed successfully!${NC}"
        
        # Ensure dashboard cache is refreshed to show new monitoring
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" && force_refresh_dashboard
        
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    else
        echo -e "${RED}❌ Failed to install monitoring services${NC}"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    fi
}

# Update monitoring services - similar to ethnode update
update_monitoring_services() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    # Go directly to dashboard and show update options
    clear
    print_header
    echo
    
    # Show monitoring status without full dashboard to avoid hanging
    local prometheus_version="unknown"
    local grafana_version="unknown"
    local node_exporter_version="unknown"
    
    if cd "$HOME/monitoring" 2>/dev/null; then
        if [[ -f .env ]]; then
            prometheus_version=$(grep "^PROMETHEUS_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
            grafana_version=$(grep "^GRAFANA_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
            node_exporter_version=$(grep "^NODE_EXPORTER_VERSION=" .env 2>/dev/null | cut -d'=' -f2 || echo "unknown")
        fi
    fi
    
    echo -e "${CYAN}${BOLD}Current Monitoring${NC}"
    echo "========================"
    echo
    echo -e "  • Prometheus: ${YELLOW}${prometheus_version}${NC}"
    echo -e "  • Grafana:    ${YELLOW}${grafana_version}${NC}"
    echo -e "  • Node Exporter: ${YELLOW}${node_exporter_version}${NC}"
    echo
    
    # Update options similar to ethnode update
    local update_options=(
        "Update all to latest versions"
        "Update services to specific versions" 
        "Back to monitoring menu"
    )
    
    local selection
    if selection=$(fancy_select_menu "Update Options" "${update_options[@]}"); then
        case $selection in
            0) update_all_monitoring_services ;;
            1) update_monitoring_to_specific_versions ;;
            2) return ;;
        esac
    fi
}

# Update all monitoring services to latest versions
update_all_monitoring_services() {
    # Source clients library for version fetching
    [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Updating All Monitoring Services${NC}"
    echo "================================="
    echo
    echo -e "${UI_MUTED}This will update to the latest stable versions:${NC}"
    
    # Fetch latest versions dynamically
    echo -e "${UI_MUTED}Checking for latest versions...${NC}"
    local latest_prometheus=$(get_latest_version "prometheus" 2>/dev/null || echo "v3.5.0")
    local latest_grafana=$(get_latest_version "grafana" 2>/dev/null || echo "12.1.0") 
    local latest_node_exporter=$(get_latest_version "node-exporter" 2>/dev/null || echo "v1.9.1")
    
    # Normalize versions for Docker image compatibility
    latest_prometheus=$(normalize_version "prometheus" "$latest_prometheus")
    latest_grafana=$(normalize_version "grafana" "$latest_grafana")
    latest_node_exporter=$(normalize_version "node-exporter" "$latest_node_exporter")
    
    echo -e "  • Prometheus: ${GREEN}${latest_prometheus}${NC}"
    echo -e "  • Grafana: ${GREEN}${latest_grafana}${NC}"
    echo -e "  • Node Exporter: ${GREEN}${latest_node_exporter}${NC}"
    echo
    echo -e "${YELLOW}⚠️  Services will be restarted${NC}"
    echo
    
    echo -e "${UI_MUTED}Press Enter to continue or Ctrl+C to cancel...${NC}"
    read -r
    
    cd "$HOME/monitoring"
    
    echo -e "${UI_MUTED}Updating .env file with latest versions...${NC}"
    sudo sed -i "s/^PROMETHEUS_VERSION=.*/PROMETHEUS_VERSION=${latest_prometheus}/" .env
    sudo sed -i "s/^GRAFANA_VERSION=.*/GRAFANA_VERSION=${latest_grafana}/" .env
    sudo sed -i "s/^NODE_EXPORTER_VERSION=.*/NODE_EXPORTER_VERSION=${latest_node_exporter}/" .env
    
    echo -e "${UI_MUTED}Stopping services...${NC}"
    docker compose down
    
    echo -e "${UI_MUTED}Pulling latest images...${NC}"
    docker compose pull
    
    echo -e "${UI_MUTED}Starting updated services...${NC}"
    docker compose up -d
    
    echo -e "${GREEN}✅ All monitoring services updated successfully${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

# Update monitoring services to specific versions
update_monitoring_to_specific_versions() {
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Update Services to Specific Versions${NC}"
    echo "===================================="
    echo
    
    cd "$HOME/monitoring"
    source .env
    
    echo -e "${UI_MUTED}Current versions:${NC}"
    echo -e "  • Prometheus: ${YELLOW}${PROMETHEUS_VERSION}${NC}"
    echo -e "  • Grafana:    ${YELLOW}${GRAFANA_VERSION}${NC}" 
    echo -e "  • Node Exporter: ${YELLOW}${NODE_EXPORTER_VERSION}${NC}"
    echo
    
    echo -e "${UI_MUTED}Enter new versions (press Enter to keep current):${NC}"
    echo
    
    # Get new versions from user
    echo -n "Prometheus version (current: ${PROMETHEUS_VERSION}): "
    read new_prometheus_version
    [[ -z "$new_prometheus_version" ]] && new_prometheus_version="$PROMETHEUS_VERSION"
    
    echo -n "Grafana version (current: ${GRAFANA_VERSION}): "
    read new_grafana_version
    [[ -z "$new_grafana_version" ]] && new_grafana_version="$GRAFANA_VERSION"
    
    echo -n "Node Exporter version (current: ${NODE_EXPORTER_VERSION}): "
    read new_node_exporter_version
    [[ -z "$new_node_exporter_version" ]] && new_node_exporter_version="$NODE_EXPORTER_VERSION"
    
    echo
    echo -e "${UI_MUTED}Will update to:${NC}"
    echo -e "  • Prometheus: ${GREEN}${new_prometheus_version}${NC}"
    echo -e "  • Grafana: ${GREEN}${new_grafana_version}${NC}"
    echo -e "  • Node Exporter: ${GREEN}${new_node_exporter_version}${NC}"
    echo
    
    echo -e "${UI_MUTED}Press Enter to continue or Ctrl+C to cancel...${NC}"
    read -r
    
    # Update .env file with new versions
    sed -i "s/PROMETHEUS_VERSION=.*/PROMETHEUS_VERSION=${new_prometheus_version}/" .env
    sed -i "s/GRAFANA_VERSION=.*/GRAFANA_VERSION=${new_grafana_version}/" .env
    sed -i "s/NODE_EXPORTER_VERSION=.*/NODE_EXPORTER_VERSION=${new_node_exporter_version}/" .env
    
    echo -e "${UI_MUTED}Stopping services...${NC}"
    docker compose down
    
    echo -e "${UI_MUTED}Pulling specified versions...${NC}"
    docker compose pull
    
    echo -e "${UI_MUTED}Starting updated services...${NC}"
    docker compose up -d
    
    echo -e "${GREEN}✅ All services updated to specified versions${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}


# Start/stop monitoring services
manage_monitoring_state() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    cd "$HOME/monitoring"
    local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Monitoring Services Status${NC}"
    echo "=========================="
    echo
    
    # Check service status
    local all_running=true
    for service in prometheus grafana node-exporter; do
        if echo "$running_services" | grep -q "$service"; then
            echo -e "  ✓ $service: ${GREEN}Running${NC}"
        else
            echo -e "  ✗ $service: ${RED}Stopped${NC}"
            all_running=false
        fi
    done
    
    echo
    
    local action_options=()
    if [[ "$all_running" == true ]]; then
        action_options+=("Stop all services")
        action_options+=("Restart all services")
    else
        action_options+=("Start all services")
        if [[ -n "$running_services" ]]; then
            action_options+=("Stop all services")
            action_options+=("Restart all services")
        fi
    fi
    action_options+=("Back to monitoring menu")
    
    local selection
    if selection=$(fancy_select_menu "Service Management" "${action_options[@]}"); then
        case "${action_options[$selection]}" in
            "Start all services")
                echo -e "${UI_MUTED}Starting monitoring services...${NC}"
                docker compose up -d
                echo -e "${GREEN}✅ Services started${NC}"
                ;;
            "Stop all services")
                echo -e "${UI_MUTED}Stopping monitoring services...${NC}"
                docker compose down
                echo -e "${YELLOW}⏹️  Services stopped${NC}"
                ;;
            "Restart all services")
                echo -e "${UI_MUTED}Restarting monitoring services...${NC}"
                docker compose down && docker compose up -d
                echo -e "${GREEN}🔄 Services restarted${NC}"
                ;;
            "Back to monitoring menu")
                return
                ;;
        esac
        echo
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
    fi
}

# View monitoring service logs
view_monitoring_logs() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    cd "$HOME/monitoring"
    local running_services=$(docker compose ps --services --filter status=running 2>/dev/null)
    
    if [[ -z "$running_services" ]]; then
        clear
        print_header
        print_box "No monitoring services are currently running" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}View Monitoring Logs${NC}"
    echo "===================="
    echo
    
    # Build log options for running services
    local log_options=()
    for service in prometheus grafana node-exporter; do
        if echo "$running_services" | grep -q "$service"; then
            log_options+=("View $service logs")
        fi
    done
    log_options+=("View all logs (split screen)")
    log_options+=("Back to monitoring menu")
    
    local selection
    if selection=$(fancy_select_menu "Log Viewer" "${log_options[@]}"); then
        if [[ $selection -lt 3 ]]; then
            # Individual service logs
            local service_name=""
            local service_index=0
            for service in prometheus grafana node-exporter; do
                if echo "$running_services" | grep -q "$service"; then
                    if [[ $service_index -eq $selection ]]; then
                        service_name="$service"
                        break
                    fi
                    ((service_index++))
                fi
            done
            
            if [[ -n "$service_name" ]]; then
                clear
                echo -e "${CYAN}${BOLD}$service_name Logs${NC} (Press Ctrl+C to exit)"
                echo "===================="
                echo
                docker compose logs -f "$service_name"
            fi
        elif [[ "${log_options[$selection]}" == "View all logs (split screen)" ]]; then
            # Split screen logs
            clear
            echo -e "${CYAN}${BOLD}All Monitoring Logs${NC} (Press Ctrl+C to exit)"
            echo "========================"
            echo
            docker compose logs -f
        fi
    fi
}

#============================================================================
# Unified Dashboard Management - Template-based Only
#============================================================================

# Get currently installed services
get_installed_services() {
    local services=()
    
    # Always include node-exporter if monitoring is installed
    if [[ -d "$HOME/monitoring" ]]; then
        services+=("node-exporter")
    fi
    
    # Scan ethnode directories
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local compose_files=$(grep "COMPOSE_FILE=" "$ethnode_dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            # Parse compose files to determine clients
            if [[ -n "$compose_files" ]]; then
                # Check for execution clients
                if echo "$compose_files" | grep -q "besu.yml"; then
                    services+=("besu")
                elif echo "$compose_files" | grep -q "reth.yml"; then
                    services+=("reth")
                elif echo "$compose_files" | grep -q "nethermind.yml"; then
                    services+=("nethermind")
                fi
                
                # Check for consensus clients
                if echo "$compose_files" | grep -q "grandine"; then
                    services+=("grandine")
                elif echo "$compose_files" | grep -q "lodestar"; then
                    services+=("lodestar")
                elif echo "$compose_files" | grep -q "teku"; then
                    services+=("teku")
                elif echo "$compose_files" | grep -q "lighthouse"; then
                    services+=("lighthouse")
                fi
            fi
        fi
    done
    
    # Check validator services
    [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]] && services+=("vero")
    [[ -d "$HOME/web3signer" && -f "$HOME/web3signer/.env" ]] && services+=("web3signer")
    
    printf "%s\n" "${services[@]}" | sort -u
}

#============================================================================
# Unified Grafana Dashboard Management
#============================================================================

# Sync dashboards with current services - unified approach
sync_dashboards() {
    local dashboard_dir="$1"
    [[ ! -d "$dashboard_dir" ]] && return 1
    
    echo "Syncing dashboards with current services..."
    
    # Clear existing dashboards
    rm -f "$dashboard_dir"/*.json 2>/dev/null || true
    
    # Copy dashboards based on installed services and networks using existing copy_relevant_dashboards
    local current_networks_raw=($(discover_nodeboi_networks))
    local network_names=()
    
    # Extract just the network names (before colon)
    for network_info in "${current_networks_raw[@]}"; do
        local network_name="${network_info%%:*}"
        # Avoid duplicates
        if [[ ! " ${network_names[@]} " =~ " $network_name " ]]; then
            network_names+=("$network_name")
        fi
    done
    
    copy_relevant_dashboards "$dashboard_dir" "${network_names[@]}" || true
    
    # Also regenerate prometheus targets
    local monitoring_dir="$HOME/monitoring"
    if [[ -d "$monitoring_dir" ]]; then
        echo "Updating Prometheus targets..."
        regenerate_prometheus_config || true
    fi
    
    echo "✓ Dashboard and target sync complete"
    return 0
}

# Sync monitoring integration with current network state  
sync_monitoring_integration() {
    local silent_mode="${1:-normal}"
    local actions_taken=""
    
    # Check if monitoring is installed
    [[ ! -d "$HOME/monitoring" ]] && return 0
    
    # Sync dashboards using unified system
    sync_dashboards "$HOME/monitoring/grafana/dashboards" >/dev/null 2>&1
    actions_taken="dashboards"
    
    # Sync network connections if ethnodes changed
    local current_ethnode_networks=($(discover_nodeboi_networks))
    local monitoring_networks_file="$HOME/monitoring/.monitoring_networks"
    local stored_networks=""
    
    # Check if network configuration changed
    if [[ -f "$monitoring_networks_file" ]]; then
        stored_networks=$(cat "$monitoring_networks_file")
    fi
    
    local current_networks_str=$(printf "%s\n" "${current_ethnode_networks[@]}" | sort | tr '\n' ' ')
    if [[ "$stored_networks" != "$current_networks_str" ]]; then
        # Networks changed, update monitoring
        if rebuild_vero_beacon_urls "${current_ethnode_networks[@]}"; then
            [[ -n "$actions_taken" ]] && actions_taken="${actions_taken}, networks" || actions_taken="networks"
            echo "$current_networks_str" > "$monitoring_networks_file"
        fi
    fi
    
    # Output result unless silent
    if [[ "$silent_mode" != "silent" && -n "$actions_taken" ]]; then
        echo "✓ Monitoring integration updated ($actions_taken)"
    fi
}

#============================================================================
# DICKS - Docker Intelligent Connecting Kontainer System
#============================================================================

# Unified network connection management for all NodeBoi services
# DICKS rebuilds compose.yml and .env files instead of runtime network changes
docker_intelligent_connecting_kontainer_system() {
    local operation="${1:-sync}"  # sync, status, force-rebuild
    local silent_mode="$2"        # "silent" to suppress output
    
    [[ "$silent_mode" != "silent" ]] && echo "DICKS: Rebuilding configuration files..."
    
    # Use nodeboi-net for all ethnode monitoring (2-network architecture)
    local ethnode_networks=()
    local ethnode_services=()
    
    # Check if any ethnodes exist and if nodeboi-net exists
    local has_ethnodes=false
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            has_ethnodes=true
            ethnode_services+=("$(basename "$dir")")
        fi
    done
    
    # If ethnodes exist and nodeboi-net exists, monitoring should connect to nodeboi-net
    if [[ "$has_ethnodes" == true ]] && docker network inspect "nodeboi-net" >/dev/null 2>&1; then
        ethnode_networks+=("nodeboi-net")
    fi
    
    # Track what needs to be restarted
    local services_to_restart=()
    local changes_made=false
    
    # Rebuild monitoring compose.yml if monitoring exists
    if [[ -d "$HOME/monitoring" && -f "$HOME/monitoring/.env" ]]; then
        rebuild_monitoring_compose_yml "${ethnode_networks[@]}"
        if [[ $? -eq 0 ]]; then
            services_to_restart+=("monitoring")
            changes_made=true
            [[ "$silent_mode" != "silent" ]] && echo "  → Updated monitoring compose.yml"
        fi
    fi
    
    # Rebuild Vero .env if Vero exists
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        rebuild_vero_beacon_urls "${ethnode_networks[@]}"
        if [[ $? -eq 0 ]]; then
            services_to_restart+=("vero")
            changes_made=true  
            [[ "$silent_mode" != "silent" ]] && echo "  → Updated Vero beacon node URLs"
        fi
    fi
    
    # Restart services that had configuration changes
    if [[ "$changes_made" == true ]]; then
        for service in "${services_to_restart[@]}"; do
            [[ "$silent_mode" != "silent" ]] && echo "  → Restarting $service to apply changes"
            case "$service" in
                "monitoring")
                    cd "$HOME/monitoring" && docker compose down && docker compose up -d
                    ;;
                "vero")  
                    cd "$HOME/vero" && docker compose down vero && docker compose up -d vero
                    ;;
            esac
        done
    fi
    
    # Sync dashboards based on current services
    if command -v sync_grafana_dashboards >/dev/null 2>&1; then
        sync_grafana_dashboards >/dev/null 2>&1
    fi
    
    # Report results
    if [[ "$changes_made" == true ]]; then
        if [[ "$silent_mode" != "silent" ]]; then
            echo "✓ DICKS updated configuration files and restarted services"
        fi
    else
        if [[ "$silent_mode" != "silent" ]]; then
            echo "✓ DICKS verified all configurations are optimal"
        fi
    fi
    
    return 0
}

# Rebuild monitoring compose.yml with current ethnode networks
rebuild_monitoring_compose_yml() {
    local ethnode_networks=("$@")
    local compose_file="$HOME/monitoring/compose.yml"
    local temp_file="$compose_file.tmp"
    
    # Check if current compose.yml already has all networks
    local current_networks=()
    if [[ -f "$compose_file" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(ethnode[0-9]+-net)$ ]]; then
                current_networks+=("${BASH_REMATCH[1]}")
            fi
        done < "$compose_file"
    fi
    
    # Check if networks match
    local networks_match=true
    if [[ ${#current_networks[@]} -ne ${#ethnode_networks[@]} ]]; then
        networks_match=false
    else
        for network in "${ethnode_networks[@]}"; do
            if [[ ! " ${current_networks[*]} " =~ " ${network} " ]]; then
                networks_match=false
                break
            fi
        done
    fi
    
    # If networks match, no rebuild needed
    [[ "$networks_match" == true ]] && return 1
    
    # Read current compose.yml and rebuild with updated networks
    cat > "$temp_file" <<'EOF'
x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: "3"
      tag: '{{.ImageName}}|{{.Name}}|{{.ImageFullID}}|{{.FullID}}'

services:
  prometheus:
    image: prom/prometheus:${PROMETHEUS_VERSION}
    container_name: monitoring-prometheus
    restart: unless-stopped
    user: "65534:65534"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    ports:
      - "${BIND_IP}:${PROMETHEUS_PORT}:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - nodeboi-net
EOF
    
    cat >> "$temp_file" <<'EOF'
    depends_on:
      - node-exporter
    security_opt:
      - no-new-privileges:true
    <<: *logging

  grafana:
    image: grafana/grafana:${GRAFANA_VERSION}
    container_name: monitoring-grafana
    restart: unless-stopped
    user: "${NODE_UID}:${NODE_GID}"
    ports:
      - "${BIND_IP}:${GRAFANA_PORT}:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://localhost:${GRAFANA_PORT}
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
    networks:
      - nodeboi-net
EOF
    
    cat >> "$temp_file" <<'EOF'
    depends_on:
      - prometheus
    security_opt:
      - no-new-privileges:true
    <<: *logging

  node-exporter:
    image: prom/node-exporter:${NODE_EXPORTER_VERSION}
    container_name: monitoring-node-exporter
    restart: unless-stopped
    user: "root"
    command:
      - '--path.procfs=/host/proc'
      - '--path.rootfs=/rootfs'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(.*|/)($|/)'
    ports:
      - "${BIND_IP}:${NODE_EXPORTER_PORT}:9100"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    networks:
      - nodeboi-net
    security_opt:
      - no-new-privileges:true
    <<: *logging

volumes:
  prometheus_data:
    name: monitoring_prometheus_data
  grafana_data:
    name: monitoring_grafana_data

networks:
  nodeboi-net:
    external: true
    name: nodeboi-net
EOF

    # Replace original file
    mv "$temp_file" "$compose_file"
    return 0
}

# Rebuild Vero beacon node URLs with current ethnode networks  
rebuild_vero_beacon_urls() {
    local ethnode_networks=("$@")
    local env_file="$HOME/vero/.env"
    local temp_file="$env_file.tmp"
    
    # Build new beacon URLs list
    local beacon_urls=()
    
    # Detect all beacon nodes from ethnodes
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            
            # Detect beacon client for this node
            local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)
            local beacon_client="lodestar"  # default
            
            if [[ "$compose_file" == *"grandine"* ]]; then
                beacon_client="grandine"
            elif [[ "$compose_file" == *"lighthouse"* ]]; then
                beacon_client="lighthouse"
            elif [[ "$compose_file" == *"teku"* ]]; then
                beacon_client="teku"
            elif [[ "$compose_file" == *"lodestar"* ]]; then
                beacon_client="lodestar"
            fi
            
            # CRITICAL: Always use port 5052 for internal communication
            beacon_urls+=("http://$node_name-$beacon_client:5052")
        fi
    done
    
    # Get current beacon URLs
    local current_urls=""
    if [[ -f "$env_file" ]]; then
        current_urls=$(grep "BEACON_NODE_URLS=" "$env_file" | cut -d'=' -f2)
    fi
    
    # Check if URLs need updating
    local new_urls_str=$(IFS=','; echo "${beacon_urls[*]}")
    [[ "$current_urls" == "$new_urls_str" ]] && return 1
    
    # Update .env file
    if [[ -f "$env_file" ]]; then
        # Update existing file
        sed "s|BEACON_NODE_URLS=.*|BEACON_NODE_URLS=$new_urls_str|g" "$env_file" > "$temp_file"
        mv "$temp_file" "$env_file"
    fi
    
    return 0
}
