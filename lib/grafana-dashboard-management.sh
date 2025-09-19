#!/bin/bash
# lib/grafana-dashboard-management.sh - Grafana Dashboard System (GDS) for NODEBOI
# Handles dashboard lifecycle management, template processing, and dynamic dashboard updates

# Import required modules
[[ -f "${NODEBOI_LIB}/network-manager.sh" ]] && source "${NODEBOI_LIB}/network-manager.sh"

#============================================================================
# PROMETHEUS TARGET GENERATION
#============================================================================

# Generate Prometheus scrape configs for discovered services
# REMOVED: Legacy wrapper function - use generate_prometheus_targets_authoritative directly

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

#============================================================================
# DASHBOARD TEMPLATE PROCESSING
#============================================================================

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
            node_name=""  # Will be detected dynamically below
            client_type="execution"
            client_name="Besu"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"reth"* ]]; then
            node_name=""  # Will be detected dynamically below
            client_type="execution"
            client_name="Reth"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"teku"* ]]; then
            # Dynamic Teku detection - check if it's validator or consensus client based on output filename
            if [[ "$output_file" == *"validator"* ]]; then
                # Teku validator
                node_name="validators"
                client_type="validator"
                client_name="Teku"
                dynamic_tags="\"validators\", \"validator\", \"teku\""
                dynamic_title="validators-Teku"
            else
                # Teku consensus client (will be detected dynamically below)
                node_name=""
                client_type="consensus"
                client_name="Teku"
                dynamic_tags=""
                dynamic_title=""
            fi
        elif [[ "$template_file" == *"grandine"* ]]; then
            node_name=""  # Will be detected dynamically below
            client_type="consensus"
            client_name="Grandine"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"vero"* ]]; then
            node_name="validators"
            client_type="validator"
            client_name="Vero"
            dynamic_tags="\"validators\", \"validator\", \"vero\""
            dynamic_title="validators-Vero"
        elif [[ "$template_file" == *"nethermind"* ]]; then
            node_name=""  # Will be detected dynamically below
            client_type="execution"
            client_name="Nethermind"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"lodestar"* ]]; then
            node_name=""  # Will be detected dynamically below
            client_type="consensus"
            client_name="Lodestar"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"lighthouse"* ]]; then
            node_name=""  # Will be detected dynamically below
            client_type="consensus"
            client_name="Lighthouse"
            dynamic_tags=""
            dynamic_title=""
        elif [[ "$template_file" == *"node-exporter"* ]]; then
            node_name="system"
            client_type="monitoring"
            client_name="System metrics"
            dynamic_tags="\"system\", \"monitoring\", \"node-exporter\""
            dynamic_title="System metrics"
        fi
        
        # Dynamic node detection - extract ethnode name from output filename if present
        if [[ "$client_type" == "execution" || "$client_type" == "consensus" ]]; then
            local ethnode_from_filename=$(basename "$output_file" | sed -n 's/^\(ethnode[0-9]\+\)-.*/\1/p')
            if [[ -n "$ethnode_from_filename" && -d "$HOME/$ethnode_from_filename" && -f "$HOME/$ethnode_from_filename/.env" ]]; then
                # Use the ethnode specified in the filename
                local compose_file=$(grep "COMPOSE_FILE=" "$HOME/$ethnode_from_filename/.env" 2>/dev/null | cut -d'=' -f2)
                if [[ "$compose_file" == *"${client_name,,}"* ]]; then
                    node_name="$ethnode_from_filename"
                    dynamic_tags="\"$ethnode_from_filename\", \"$client_type\", \"${client_name,,}\""
                    dynamic_title="$ethnode_from_filename-$client_name"
                fi
            else
                # Fallback: search all ethnode directories (original behavior)
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
        fi
        
        # Replace template variables with dynamic instance values
        if [[ "$client_type" == "execution" || "$client_type" == "consensus" || "$client_type" == "validator" ]]; then
            # Determine the metric port based on client type
            local metric_port=""
            case "${client_name,,}" in
                "besu") metric_port="6060" ;;
                "reth") metric_port="9001" ;;
                "teku") metric_port="8008" ;;
                "grandine") metric_port="8008" ;;
                "lodestar") metric_port="8008" ;;
                "lighthouse") metric_port="8008" ;;
                "nethermind") metric_port="6060" ;;
                "vero") metric_port="9010" ;;
                *) metric_port="8008" ;;
            esac
            
            # Special case for Vero - use simple name pattern like other validators
            if [[ "${client_name,,}" == "vero" ]]; then
                local instance_name="vero:${metric_port}"
            else
                local instance_name="${node_name}-${client_name,,}:${metric_port}"
            fi
            
            # For combined Teku dashboards, use regex pattern to match both services
            local instance_pattern="$instance_name"
            if [[ "$output_file" == *"teku+teku-validator"* ]]; then
                # Combined dashboard should match both ethnode-teku and teku-validator
                instance_pattern="(ethnode[0-9]+-teku:8008|teku-validator:8008)"
            elif [[ "$output_file" == *"teku-validator"* ]]; then
                # Validator-only dashboard
                instance_pattern="teku-validator:8008"
            elif [[ "$output_file" == *"-teku"* && "$output_file" != *"validator"* ]]; then
                # Consensus-only dashboard (like ethnode2-teku)
                local ethnode_name=$(echo "$output_file" | sed -n 's|.*/\([^/]*\)-teku\.json|\1|p')
                if [[ -n "$ethnode_name" ]]; then
                    instance_pattern="${ethnode_name}-teku:8008"
                fi
            fi
            
            # Apply dynamic replacements based on client type
            if [[ "${client_name,,}" == "nethermind" ]]; then
                # Nethermind uses different variable pattern ($enode instead of $system/$instance)
                # Nethermind metrics use "Hoodi" as the Instance label value (network name)
                sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                    -e 's/"uid": "prometheus"/"uid": ""/g' \
                    -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                    -e 's/"uid": "\${prometheus_ds}"/"uid": ""/g' \
                    -e "s/\\\$enode/Hoodi/g" \
                    -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                    -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                    "$template_file" > "$output_file.tmp" 2>/dev/null || true
            else
                # Standard processing for other clients
                sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                    -e 's/"uid": "prometheus"/"uid": ""/g' \
                    -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                    -e "s/\$system/${instance_pattern}/g" \
                    -e "s/\$instance/${instance_pattern}/g" \
                    -e "s/{instance=\"\$system\"}/{instance=~\"${instance_pattern}\"}/g" \
                    -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                    -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                    "$template_file" > "$output_file.tmp" 2>/dev/null || true
            fi
        else
            # For other dashboards, use default processing
            sed -e 's/\${DS_PROMETHEUS}/prometheus/g' \
                -e 's/"uid": "prometheus"/"uid": ""/g' \
                -e 's/"uid": "\${datasource}"/"uid": ""/g' \
                -e 's/"query_result(ethereum_blockchain_height or besu_blockchain_height)"/"label_values(ethereum_blockchain_height,instance)"/g' \
                -e 's/"query_result(beacon_slot)"/"label_values(beacon_slot,instance)"/g' \
                "$template_file" > "$output_file.tmp" 2>/dev/null || true
        fi
        
        # Generate unique UID based on output filename
        local dashboard_basename=$(basename "$output_file" .json)
        local unique_uid=$(echo -n "$dashboard_basename" | md5sum | cut -c1-9)
        
        # Update tags, main dashboard title, and UID (preserving panel titles)
        if [[ -n "$dynamic_tags" && -f "$output_file.tmp" ]]; then
            # Use jq to update JSON tags, main dashboard title only, and UID
            jq --argjson tags "[$dynamic_tags]" --arg title "$dynamic_title" --arg uid "$unique_uid" \
               '.tags = $tags | .title = $title | .uid = $uid' \
               "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp" 2>/dev/null || true
        elif [[ -f "$output_file.tmp" ]]; then
            # Clear existing tags and update UID only
            jq --arg uid "$unique_uid" '.tags = [] | .uid = $uid' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp" 2>/dev/null || true
        fi
        
        # Move temp file to final output
        mv "$output_file.tmp" "$output_file" 2>/dev/null || true
    fi
}

#============================================================================
# GDS - Grafana Dashboard System (Event-Driven)
# Intelligent dashboard lifecycle management with event-based updates
#============================================================================

# GDS event handlers
gds_on_container_start() {
    local container_name="$1"
    local dashboards_dir="${2:-$HOME/monitoring/grafana/dashboards}"
    
    case "$container_name" in
        "vero")
            gds_add_dashboard "vero-detailed" "$dashboards_dir"
            ;;
        "teku-validator")
            gds_add_dashboard "teku-validator-overview" "$dashboards_dir"
            ;;
        *"-teku")
            gds_add_dashboard "teku-overview" "$dashboards_dir"
            ;;
        *"-lodestar")
            gds_add_dashboard "lodestar-summary" "$dashboards_dir"
            ;;
        *"-lighthouse")
            gds_add_dashboard "lighthouse-overview" "$dashboards_dir"
            ;;
        *"-grandine")
            gds_add_dashboard "grandine-overview" "$dashboards_dir"
            ;;
        *"-nethermind")
            gds_add_dashboard "nethermind-overview" "$dashboards_dir"
            ;;
        *"-reth")
            gds_add_dashboard "reth-overview" "$dashboards_dir"
            ;;
        *"-besu")
            gds_add_dashboard "besu-overview" "$dashboards_dir"
            ;;
    esac
}

gds_on_container_stop() {
    local container_name="$1"
    local dashboards_dir="${2:-$HOME/monitoring/grafana/dashboards}"
    
    case "$container_name" in
        "vero")
            gds_remove_dashboard "vero-detailed" "$dashboards_dir"
            ;;
        "teku-validator")
            gds_remove_dashboard "teku-validator-overview" "$dashboards_dir"
            ;;
        *"-teku")
            gds_remove_dashboard "teku-overview" "$dashboards_dir"
            ;;
        *"-lodestar")
            gds_remove_dashboard "lodestar-summary" "$dashboards_dir"
            ;;
        *"-lighthouse")
            gds_remove_dashboard "lighthouse-overview" "$dashboards_dir"
            ;;
        *"-grandine")
            gds_remove_dashboard "grandine-overview" "$dashboards_dir"
            ;;
        *"-nethermind")
            gds_remove_dashboard "nethermind-overview" "$dashboards_dir"
            ;;
        *"-reth")
            gds_remove_dashboard "reth-overview" "$dashboards_dir"
            ;;
        *"-besu")
            gds_remove_dashboard "besu-overview" "$dashboards_dir"
            ;;
    esac
}

# GDS incremental operations
gds_add_dashboard() {
    local dashboard_name="$1"
    local dashboards_dir="$2"
    local template_path=""
    
    # Map dashboard name to template path
    case "$dashboard_name" in
        "vero-detailed")
            template_path="$HOME/.nodeboi/grafana-dashboards/validators/vero-detailed.json"
            ;;
        "teku-detailed")
            template_path="$HOME/.nodeboi/grafana-dashboards/consensus/teku-detailed.json"
            ;;
        "teku-validator"|"teku-validator-overview"|*"-teku"|*"-teku+teku-validator")
            # All Teku dashboard variants use the same detailed template
            template_path="$HOME/.nodeboi/grafana-dashboards/consensus/teku-detailed.json"
            ;;
        "lodestar-summary")
            template_path="$HOME/.nodeboi/grafana-dashboards/consensus/lodestar-summary.json"
            ;;
        "lighthouse-overview")
            template_path="$HOME/.nodeboi/grafana-dashboards/consensus/lighthouse-overview.json"
            ;;
        "grandine-overview")
            template_path="$HOME/.nodeboi/grafana-dashboards/consensus/grandine-overview.json"
            ;;
        "nethermind-overview")
            template_path="$HOME/.nodeboi/grafana-dashboards/execution/nethermind-overview.json"
            ;;
        "reth-overview")
            template_path="$HOME/.nodeboi/grafana-dashboards/execution/reth-overview.json"
            ;;
        "besu-overview")
            template_path="$HOME/.nodeboi/grafana-dashboards/execution/besu-overview.json"
            ;;
    esac
    
    if [[ -f "$template_path" && ! -f "$dashboards_dir/$dashboard_name.json" ]]; then
        process_dashboard_template "$template_path" "$dashboards_dir/$dashboard_name.json"
        
        # Update main dashboard title only (preserve panel titles)
        if [[ -f "$dashboards_dir/$dashboard_name.json" ]]; then
            # Use jq to update only the root-level title, preserving all other titles
            jq --arg title "$dashboard_name" '.title = $title' "$dashboards_dir/$dashboard_name.json" > "$dashboards_dir/$dashboard_name.json.tmp" && \
            mv "$dashboards_dir/$dashboard_name.json.tmp" "$dashboards_dir/$dashboard_name.json"
        fi
        
        echo "GDS: ✓ Added $dashboard_name dashboard"
        gds_reload_grafana
    fi
}

gds_remove_dashboard() {
    local dashboard_name="$1"
    local dashboards_dir="$2"
    
    if [[ -f "$dashboards_dir/$dashboard_name.json" ]]; then
        rm -f "$dashboards_dir/$dashboard_name.json"
        echo "GDS: ✗ Removed $dashboard_name dashboard"
        gds_reload_grafana
    fi
}

gds_reload_grafana() {
    # Hot reload Grafana dashboards without full restart
    if command -v curl >/dev/null 2>&1; then
        # Try API reload first (faster)
        curl -s -X POST "http://localhost:${GRAFANA_PORT:-3000}/api/admin/provisioning/dashboards/reload" \
             -H "Content-Type: application/json" >/dev/null 2>&1 || {
            # Fallback to container restart
            (cd "$HOME/monitoring" && docker compose down grafana && docker compose up -d grafana >/dev/null 2>&1)
        }
    else
        # Fallback to container restart
        (cd "$HOME/monitoring" && docker compose down grafana && docker compose up -d grafana >/dev/null 2>&1)
    fi
}

# Dynamic Teku dashboard naming based on running containers
gds_update_teku_dashboard() {
    local dashboards_dir="$1"
    local stopping_service="${2:-}"
    
    # Get currently running Teku containers (exclude the one being stopped)
    local running_teku_containers
    if [[ -n "$stopping_service" ]]; then
        running_teku_containers=$(docker ps --format "{{.Names}}" | grep -E "(teku-validator|.*-teku)" | grep -v "^$stopping_service$" || true)
    else
        running_teku_containers=$(docker ps --format "{{.Names}}" | grep -E "(teku-validator|.*-teku)" || true)
    fi
    
    # Remove any existing Teku dashboards first
    gds_remove_dashboard "teku-validator" "$dashboards_dir" >/dev/null 2>&1
    local ethnode_pattern=$(echo "$running_teku_containers" | grep -E ".*-teku$" | head -1 || true)
    if [[ -n "$ethnode_pattern" ]]; then
        local ethnode_name=$(echo "$ethnode_pattern" | sed 's/-teku$//')
        gds_remove_dashboard "${ethnode_name}-teku" "$dashboards_dir" >/dev/null 2>&1
        gds_remove_dashboard "${ethnode_name}-teku+teku-validator" "$dashboards_dir" >/dev/null 2>&1
    fi
    
    # Determine new dashboard name based on running containers
    local has_beacon=$(echo "$running_teku_containers" | grep -E ".*-teku$" || true)
    local has_validator=$(echo "$running_teku_containers" | grep "^teku-validator$" || true)
    
    if [[ -n "$has_beacon" && -n "$has_validator" ]]; then
        # Both beacon and validator running
        local ethnode_name=$(echo "$has_beacon" | sed 's/-teku$//')
        local dashboard_name="${ethnode_name}-teku+teku-validator"
        gds_add_dashboard "$dashboard_name" "$dashboards_dir"
    elif [[ -n "$has_beacon" ]]; then
        # Only beacon running
        local ethnode_name=$(echo "$has_beacon" | sed 's/-teku$//')
        local dashboard_name="${ethnode_name}-teku"
        gds_add_dashboard "$dashboard_name" "$dashboards_dir"
    elif [[ -n "$has_validator" ]]; then
        # Only validator running
        gds_add_dashboard "teku-validator" "$dashboards_dir"
    fi
    # If no Teku containers running, no dashboard is added
}

# GDS service lifecycle hooks - called from common.sh safe_docker_compose
gds_on_service_start() {
    local service_name="$1"
    local service_dir="$2"
    
    # Only handle services if monitoring exists
    if [[ ! -d "$HOME/monitoring/grafana/dashboards" ]]; then
        return 0
    fi
    
    local dashboards_dir="$HOME/monitoring/grafana/dashboards"
    
    # Map service to dashboard based on service name and directory
    case "$service_name" in
        "vero")
            gds_add_dashboard "vero-detailed" "$dashboards_dir"
            ;;
        "teku-validator"|*"-teku")
            # Dynamic Teku dashboard naming based on running containers
            gds_update_teku_dashboard "$dashboards_dir"
            ;;
        *"-lodestar")
            gds_add_dashboard "lodestar-summary" "$dashboards_dir"
            ;;
        *"-lighthouse")
            gds_add_dashboard "lighthouse-overview" "$dashboards_dir"
            ;;
        *"-grandine")
            gds_add_dashboard "grandine-overview" "$dashboards_dir"
            ;;
        *"-nethermind")
            gds_add_dashboard "nethermind-overview" "$dashboards_dir"
            ;;
        *"-reth")
            gds_add_dashboard "reth-overview" "$dashboards_dir"
            ;;
        *"-besu")
            gds_add_dashboard "besu-overview" "$dashboards_dir"
            ;;
    esac
}

gds_on_service_stop() {
    local service_name="$1"
    local service_dir="$2"
    
    # Only handle services if monitoring exists
    if [[ ! -d "$HOME/monitoring/grafana/dashboards" ]]; then
        return 0
    fi
    
    local dashboards_dir="$HOME/monitoring/grafana/dashboards"
    
    # Map service to dashboard based on service name and directory
    case "$service_name" in
        "vero")
            gds_remove_dashboard "vero-detailed" "$dashboards_dir"
            ;;
        "teku-validator"|*"-teku")
            # Dynamic Teku dashboard naming - update after container removal
            gds_update_teku_dashboard "$dashboards_dir" "$service_name"
            ;;
        *"-lodestar")
            gds_remove_dashboard "lodestar-summary" "$dashboards_dir"
            ;;
        *"-lighthouse")
            gds_remove_dashboard "lighthouse-overview" "$dashboards_dir"
            ;;
        *"-grandine")
            gds_remove_dashboard "grandine-overview" "$dashboards_dir"
            ;;
        *"-nethermind")
            gds_remove_dashboard "nethermind-overview" "$dashboards_dir"
            ;;
        *"-reth")
            gds_remove_dashboard "reth-overview" "$dashboards_dir"
            ;;
        *"-besu")
            gds_remove_dashboard "besu-overview" "$dashboards_dir"
            ;;
    esac
}

# GDS main function - sync dashboards with currently running services
grafana_dashboard_system() {
    local dashboards_dir="$1"
    shift
    local networks=("$@")
    
    # Clean up existing dashboards first
    rm -f "$dashboards_dir"/*.json 2>/dev/null || true
    
    # Always copy node-exporter dashboard (system monitoring)
    if [[ -f "$HOME/.nodeboi/grafana-dashboards/system/node-exporter-full.json" ]]; then
        process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/system/node-exporter-full.json" "$dashboards_dir/node-exporter-full.json"
    fi
    
    # Detect active services across all selected networks
    for network in "${networks[@]}"; do
        detect_and_copy_client_dashboards "$dashboards_dir" "$network"
    done
    
    # Copy vero dashboard if vero is running
    if [[ -d "$HOME/vero" ]] && (cd "$HOME/vero" && docker compose ps --services --filter "status=running" | grep -q "vero"); then
        if [[ -f "$HOME/.nodeboi/grafana-dashboards/validators/vero-detailed.json" ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/validators/vero-detailed.json" "$dashboards_dir/vero-detailed.json"
            echo "  ✓ vero dashboard created"
        fi
    fi
    
    # Copy teku validator dashboard if teku-validator is running
    if [[ -d "$HOME/teku-validator" ]] && (cd "$HOME/teku-validator" && docker compose ps --services --filter "status=running" | grep -q "teku-validator"); then
        if [[ -f "$HOME/.nodeboi/grafana-dashboards/consensus/teku-overview.json" ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/teku-overview.json" "$dashboards_dir/teku-validator-overview.json"
            echo "  ✓ teku validator dashboard created"
        fi
    fi
    
    # Also regenerate Prometheus configuration to match current services
    local monitoring_dir=$(dirname "$dashboards_dir")
    regenerate_prometheus_config "$monitoring_dir" "${networks[@]}"
    
    echo "Dashboard and Prometheus sync complete"
}

# GDS status - show active dashboards and their service status
gds_status() {
    local dashboards_dir="${1:-$HOME/monitoring/grafana/dashboards}"
    
    if [[ ! -d "$dashboards_dir" ]]; then
        echo "No dashboards directory found"
        return 1
    fi
    
    echo "GDS (Grafana Dashboard System) Status:"
    echo "======================================"
    
    local dashboard_count=$(ls -1 "$dashboards_dir"/*.json 2>/dev/null | wc -l)
    echo "Active dashboards: $dashboard_count"
    echo ""
    
    for dashboard in "$dashboards_dir"/*.json; do
        if [[ -f "$dashboard" ]]; then
            local name=$(basename "$dashboard" .json)
            local status="●"  # Active (green dot)
            
            # Check service status for specific dashboards
            case "$name" in
                "vero-detailed")
                    if [[ -d "$HOME/vero" ]] && (cd "$HOME/vero" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "vero"); then
                        status="🟢"
                    else
                        status="🔴"  # Service not running
                    fi
                    ;;
                "teku-overview"|"teku-validator-overview")
                    if [[ -d "$HOME/teku-validator" ]] && (cd "$HOME/teku-validator" && docker compose ps --services --filter "status=running" 2>/dev/null | grep -q "teku-validator"); then
                        status="🟢"
                    else
                        status="🔴"
                    fi
                    ;;
                *)
                    status="🟢"  # System dashboards (always active)
                    ;;
            esac
            
            echo "$status $name"
        fi
    done
    echo ""
    echo "Legend: 🟢=Service Running  🔴=Service Stopped  ●=System Dashboard"
}

# GDS manual sync - force dashboard refresh
gds_sync() {
    echo "GDS: Syncing dashboards with running services..."
    
    if [[ -d "$HOME/monitoring/grafana/dashboards" ]]; then
        grafana_dashboard_system "$HOME/monitoring/grafana/dashboards" "monitoring-net"
        
        # Restart Grafana to reload dashboards
        if [[ -f "$HOME/monitoring/compose.yml" ]]; then
            echo "GDS: Restarting Grafana to apply changes..."
            (cd "$HOME/monitoring" && docker compose down grafana && docker compose up -d grafana >/dev/null 2>&1)
        fi
        
        echo "GDS: Dashboard sync complete!"
        echo ""
        gds_status
    else
        echo "GDS: No monitoring directory found"
        return 1
    fi
}

# Legacy function names for compatibility
copy_relevant_dashboards() {
    grafana_dashboard_system "$@"
}

# DEPRECATED: Use ULCS native monitoring instead (ulcs_sync_dashboards)
# This function exists only for legacy compatibility  
sync_dashboards_with_services() {
    # Ensure monitoring.sh is sourced for prometheus functions
    if [[ -f "${NODEBOI_LIB}/monitoring.sh" ]]; then
        source "${NODEBOI_LIB}/monitoring.sh"
    fi
    
    local dashboards_dir="/home/$(whoami)/monitoring/grafana/dashboards"
    
    # If no networks specified, default to monitoring-net to include all ethnodes
    if [[ $# -eq 0 ]]; then
        grafana_dashboard_system "$dashboards_dir" "monitoring-net"
    else
        grafana_dashboard_system "$@"
    fi
}

# Detect client types and copy corresponding dashboards
detect_and_copy_client_dashboards() {
    local dashboards_dir="$1"
    local network="$2"
    
    # Check for ethnode directories
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            # For monitoring-net, include ALL ethnodes regardless of their individual network
            # For specific networks, match the network name
            if [[ "$network" == "monitoring-net" ]]; then
                # Always copy dashboards for monitoring-net (includes all ethnodes) if running
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
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/execution/reth-overview.json" "$dashboards_dir/${ethnode_name}-reth-overview.json"
            echo "  ✓ ${ethnode_name}-reth dashboard created"
        fi
        if [[ "$compose_file" == *"besu"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/execution/besu-overview.json" "$dashboards_dir/${ethnode_name}-besu-overview.json"
            echo "  ✓ ${ethnode_name}-besu dashboard created"
        fi
        if [[ "$compose_file" == *"nethermind"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/execution/nethermind-overview.json" "$dashboards_dir/${ethnode_name}-nethermind-overview.json"
            echo "  ✓ ${ethnode_name}-nethermind dashboard created"
        fi
        
        # Detect consensus clients
        if [[ "$compose_file" == *"teku"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/teku-overview.json" "$dashboards_dir/${ethnode_name}-teku-overview.json"
            echo "  ✓ ${ethnode_name}-teku dashboard created"
        fi
        if [[ "$compose_file" == *"lighthouse"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/lighthouse-overview.json" "$dashboards_dir/${ethnode_name}-lighthouse-overview.json"
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/lighthouse-summary.json" "$dashboards_dir/${ethnode_name}-lighthouse-summary.json"
            echo "  ✓ ${ethnode_name}-lighthouse dashboard created"
        fi
        if [[ "$compose_file" == *"grandine"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/grandine-overview.json" "$dashboards_dir/${ethnode_name}-grandine-overview.json"
            echo "  ✓ ${ethnode_name}-grandine dashboard created"
        fi
        if [[ "$compose_file" == *"lodestar"* ]]; then
            process_dashboard_template "$HOME/.nodeboi/grafana-dashboards/consensus/lodestar-summary.json" "$dashboards_dir/${ethnode_name}-lodestar-summary.json"
            echo "  ✓ ${ethnode_name}-lodestar dashboard created"
        fi
    fi
}

# Refresh dashboards and Prometheus config for existing monitoring installation
refresh_monitoring_dashboards() {
    local monitoring_dir="$HOME/monitoring"
    
    if [[ -d "$monitoring_dir" && -f "$monitoring_dir/docker-compose.yml" ]]; then
        echo -e "${UI_MUTED}Refreshing monitoring configuration...${NC}"
        
        # Clear existing dashboards
        rm -f "$monitoring_dir/grafana/dashboards"/*.json 2>/dev/null || true
        
        # Detect current ethnode networks using DICKS
        local networks=("monitoring-net")
        if declare -f discover_nodeboi_networks >/dev/null 2>&1; then
            mapfile -t discovered_networks < <(discover_nodeboi_networks)
            networks+=("${discovered_networks[@]}")
        else
            # Fallback: discover running ethnodes
            for dir in "$HOME"/ethnode*; do
                if [[ -d "$dir" && -f "$dir/.env" ]]; then
                    local node_name=$(basename "$dir")
                    networks+=("${node_name}-net")
                fi
            done
            # Add validator networks only if they exist
            [[ -d "$HOME/vero" ]] && networks+=("validator-net") 
            [[ -d "$HOME/teku-validator" ]] && networks+=("validator-net")
            [[ -d "$HOME/web3signer" ]] && networks+=("validator-net")
        fi
        
        # Regenerate Prometheus configuration with discovered networks
        regenerate_prometheus_config "$monitoring_dir" "${networks[@]}"
        
        # Copy relevant dashboards
        copy_relevant_dashboards "$monitoring_dir/grafana/dashboards" "${networks[@]}"
        
        # Restart services to pick up new config
        echo -e "${UI_MUTED}Restarting monitoring services...${NC}"
        cd "$monitoring_dir" && docker compose down prometheus grafana && docker compose up -d prometheus grafana
        cd "$HOME/.nodeboi"
    fi
}

#============================================================================
# GRAFANA CREDENTIALS AND ACCESS
#============================================================================

# View Grafana credentials
view_grafana_credentials() {
    if [[ ! -d "$HOME/monitoring" ]]; then
        clear
        print_header
        print_box "Monitoring not installed" "warning"
        echo -e "${UI_MUTED}Press Enter to continue...${NC}"
        read -r
        return
    fi
    
    clear
    print_header
    
    echo -e "${CYAN}${BOLD}Grafana Login Information${NC}"
    echo "========================="
    echo
    
    # Extract info from .env file
    local grafana_port="3000"
    local grafana_password=""
    local bind_ip="127.0.0.1"
    
    if [[ -f "$HOME/monitoring/.env" ]]; then
        grafana_port=$(grep "^GRAFANA_PORT=" "$HOME/monitoring/.env" | cut -d'=' -f2)
        grafana_password=$(grep "^GRAFANA_PASSWORD=" "$HOME/monitoring/.env" | cut -d'=' -f2)
        bind_ip=$(grep "^BIND_IP=" "$HOME/monitoring/.env" | cut -d'=' -f2)
    fi
    
    echo -e "${BOLD}Access URL:${NC}"
    if [[ "$bind_ip" == "0.0.0.0" ]]; then
        local local_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
        echo -e "  Local:   ${GREEN}http://localhost:${grafana_port}/dashboards${NC}"
        echo -e "  Network: ${GREEN}http://${local_ip}:${grafana_port}/dashboards${NC}"
    else
        echo -e "  ${GREEN}http://${bind_ip}:${grafana_port}/dashboards${NC}"
    fi
    
    echo
    echo -e "${BOLD}Login Credentials:${NC}"
    echo -e "  Username: ${GREEN}admin${NC}"
    echo -e "  Password: ${GREEN}${grafana_password}${NC}"
    
    echo
    echo -e "${UI_MUTED}Tip: You can bookmark this page for quick access${NC}"
    echo
    echo -e "${UI_MUTED}Press Enter to continue...${NC}"
    read -r
}

#============================================================================
# UNIFIED DASHBOARD SYNC FUNCTIONS
#============================================================================

# Load the improved dashboard template processing
[[ -f "${NODEBOI_LIB}/dashboard-template-fix.sh" ]] && source "${NODEBOI_LIB}/dashboard-template-fix.sh"

sync_dashboards() {
    local dashboards_dir="$1"
    
    if [[ ! -d "$dashboards_dir" ]]; then
        return 1
    fi
    
    # Use improved template processing if available
    if declare -f regenerate_all_dashboards >/dev/null 2>&1; then
        echo "Syncing dashboards with improved template processing..."
        regenerate_all_dashboards
        echo "Regenerating Prometheus configuration..."
        # Use the existing regenerate_prometheus_config function instead of a missing one
        if declare -f regenerate_prometheus_config >/dev/null 2>&1; then
            regenerate_prometheus_config "/home/floris/monitoring" "monitoring-net"
        else
            # Fallback: Manually regenerate prometheus.yml
            generate_prometheus_targets_authoritative "monitoring-net" > /tmp/prometheus_targets.yml
            cat > "/home/floris/monitoring/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

EOF
            cat /tmp/prometheus_targets.yml >> "/home/floris/monitoring/prometheus.yml"
            rm -f /tmp/prometheus_targets.yml
        fi
        echo "Dashboard and Prometheus sync complete"
    else
        # Fall back to existing GDS system
        echo "Syncing dashboards based on currently running services..."
        grafana_dashboard_system "$dashboards_dir" "monitoring-net"
        echo "Dashboard sync complete"
    fi
}

#============================================================================
# PROMETHEUS CONFIGURATION
#============================================================================

# Regenerate Prometheus configuration to match current running services
# DEPRECATED: Use ULCS native monitoring instead (ulcs_generate_prometheus_config)
# This function exists only for legacy compatibility
regenerate_prometheus_config() {
    local monitoring_dir="$1"
    shift
    local networks=("$@")
    
    echo "Regenerating Prometheus configuration..."
    
    # Extract current job names from existing config (if it exists)
    local current_jobs=()
    if [[ -f "$monitoring_dir/prometheus.yml" ]]; then
        mapfile -t current_jobs < <(grep "job_name:" "$monitoring_dir/prometheus.yml" | sed "s/.*job_name: '\([^']*\)'.*/\1/" | grep -vE "^(prometheus|node-exporter)$")
    fi
    
    # Generate new Prometheus targets
    local prometheus_targets=$(generate_prometheus_targets_authoritative "${networks[@]}")
    
    # Extract new job names from generated config
    local new_jobs=()
    mapfile -t new_jobs < <(echo "$prometheus_targets" | grep "job_name:" | sed "s/.*job_name: '\([^']*\)'.*/\1/" | grep -vE "^(prometheus|node-exporter)$")
    
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
    
    # Show what changed
    for job in "${new_jobs[@]}"; do
        if [[ ! " ${current_jobs[*]} " =~ " ${job} " ]]; then
            echo "  ✓ Added $job to prometheus.yml"
        fi
    done
    
    for job in "${current_jobs[@]}"; do
        if [[ ! " ${new_jobs[*]} " =~ " ${job} " ]]; then
            echo "  ✗ Removed $job from prometheus.yml"
        fi
    done
    
    echo "  ✓ prometheus.yml regenerated"
}