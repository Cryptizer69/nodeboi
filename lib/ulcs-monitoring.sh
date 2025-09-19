#!/bin/bash
# lib/ulcs-monitoring.sh - ULCS Native Monitoring Integration
# Single Source of Truth for Prometheus and Grafana Management

# ULCS Monitoring Logger
log_ulcs_monitoring() {
    echo "[ULCS-MONITORING] $1" >&2
}

log_ulcs_monitoring_success() {
    echo "[ULCS-MONITORING] ✓ $1" >&2
}

log_ulcs_monitoring_error() {
    echo "[ULCS-MONITORING] ✗ $1" >&2
}

#============================================================================
# ULCS NATIVE PROMETHEUS MANAGEMENT
#============================================================================

# ULCS Native Prometheus Configuration Generator
# This is the ONLY function that should generate prometheus.yml
ulcs_generate_prometheus_config() {
    local monitoring_dir="${1:-/home/$(whoami)/monitoring}"
    local config_file="$monitoring_dir/prometheus.yml"
    local temp_file="$config_file.tmp"
    
    log_ulcs_monitoring "Generating prometheus configuration (ULCS native)"
    
    # Create base prometheus configuration
    cat > "$temp_file" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'node-exporter'
    static_configs:
      - targets: ['monitoring-node-exporter:9100']

EOF

    # Discover and add all running services
    local services_added=0
    
    # Add ethnode services
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            if ulcs_add_ethnode_targets "$temp_file" "$node_name" "$ethnode_dir"; then
                ((services_added++))
            fi
        fi
    done
    
    # Add validator services
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if ulcs_add_validator_targets "$temp_file" "vero"; then
            ((services_added++))
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if ulcs_add_validator_targets "$temp_file" "teku-validator"; then
            ((services_added++))
        fi
    fi
    
    # Validate generated configuration
    if ! ulcs_validate_prometheus_config "$temp_file"; then
        log_ulcs_monitoring_error "Generated prometheus config is invalid"
        rm -f "$temp_file"
        return 1
    fi
    
    # Atomically replace the configuration
    if mv "$temp_file" "$config_file"; then
        log_ulcs_monitoring_success "Prometheus config updated ($services_added services)"
        return 0
    else
        log_ulcs_monitoring_error "Failed to update prometheus config"
        rm -f "$temp_file"
        return 1
    fi
}

# Add ethnode targets to prometheus config
ulcs_add_ethnode_targets() {
    local config_file="$1"
    local node_name="$2"
    local node_dir="$3"
    
    # Parse compose file to detect clients
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    
    # Detect execution client and add targets
    if [[ "$compose_file" == *"nethermind"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-nethermind'
    static_configs:
      - targets: ['${node_name}-nethermind:6060']
        labels:
          node: '${node_name}'
          client: 'nethermind'
          type: 'execution'

EOF
        log_ulcs_monitoring "Added ${node_name}-nethermind:6060"
    elif [[ "$compose_file" == *"besu"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-besu'
    static_configs:
      - targets: ['${node_name}-besu:9545']
        labels:
          node: '${node_name}'
          client: 'besu'
          type: 'execution'

EOF
        log_ulcs_monitoring "Added ${node_name}-besu:9545"
    elif [[ "$compose_file" == *"reth"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-reth'
    static_configs:
      - targets: ['${node_name}-reth:9001']
        labels:
          node: '${node_name}'
          client: 'reth'
          type: 'execution'

EOF
        log_ulcs_monitoring "Added ${node_name}-reth:9001"
    fi
    
    # Detect consensus client and add targets
    if [[ "$compose_file" == *"lodestar"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-lodestar'
    static_configs:
      - targets: ['${node_name}-lodestar:8008']
        labels:
          node: '${node_name}'
          client: 'lodestar'
          type: 'consensus'

EOF
        log_ulcs_monitoring "Added ${node_name}-lodestar:8008"
    elif [[ "$compose_file" == *"teku"* ]] && [[ "$compose_file" == *"cl-only"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-teku'
    static_configs:
      - targets: ['${node_name}-teku:8008']
        labels:
          node: '${node_name}'
          client: 'teku'
          type: 'consensus'

EOF
        log_ulcs_monitoring "Added ${node_name}-teku:8008"
    elif [[ "$compose_file" == *"grandine"* ]]; then
        cat >> "$config_file" <<EOF
  - job_name: '${node_name}-grandine'
    static_configs:
      - targets: ['${node_name}-grandine:8008']
        labels:
          node: '${node_name}'
          client: 'grandine'
          type: 'consensus'

EOF
        log_ulcs_monitoring "Added ${node_name}-grandine:8008"
    fi
    
    return 0
}

# Add validator targets to prometheus config
ulcs_add_validator_targets() {
    local config_file="$1"
    local validator_name="$2"
    
    case "$validator_name" in
        "vero")
            cat >> "$config_file" <<EOF
  - job_name: 'vero'
    static_configs:
      - targets: ['vero:9010']
        labels:
          service: 'vero'
          type: 'validator'

EOF
            log_ulcs_monitoring "Added vero:9010"
            ;;
        "teku-validator")
            cat >> "$config_file" <<EOF
  - job_name: 'teku-validator'
    static_configs:
      - targets: ['teku-validator:8008']
        labels:
          service: 'teku-validator'
          type: 'validator'

EOF
            log_ulcs_monitoring "Added teku-validator:8008"
            ;;
    esac
    
    return 0
}

# Validate prometheus configuration
ulcs_validate_prometheus_config() {
    local config_file="$1"
    
    # Check if file exists and is not empty
    if [[ ! -f "$config_file" || ! -s "$config_file" ]]; then
        log_ulcs_monitoring_error "Config file missing or empty"
        return 1
    fi
    
    # Check for basic required sections
    if ! grep -q "global:" "$config_file" || ! grep -q "scrape_configs:" "$config_file"; then
        log_ulcs_monitoring_error "Config missing required sections"
        return 1
    fi
    
    # Validate YAML syntax if python3 is available
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
            log_ulcs_monitoring_error "Config has invalid YAML syntax"
            return 1
        fi
    fi
    
    log_ulcs_monitoring "Config validation passed"
    return 0
}

#============================================================================
# ULCS NATIVE GRAFANA DASHBOARD MANAGEMENT  
#============================================================================

# ULCS Native Dashboard Sync
ulcs_sync_dashboards() {
    local dashboards_dir="${1:-/home/$(whoami)/monitoring/grafana/dashboards}"
    
    log_ulcs_monitoring "Syncing Grafana dashboards (ULCS native)"
    
    if [[ ! -d "$dashboards_dir" ]]; then
        log_ulcs_monitoring_error "Dashboard directory does not exist: $dashboards_dir"
        return 1
    fi
    
    # Remove all existing dashboards to start fresh
    rm -f "$dashboards_dir"/*.json 2>/dev/null
    
    local dashboards_added=0
    
    # Add dashboards for each running ethnode
    for ethnode_dir in "$HOME"/ethnode*; do
        if [[ -d "$ethnode_dir" && -f "$ethnode_dir/.env" ]]; then
            local node_name=$(basename "$ethnode_dir")
            if ulcs_copy_ethnode_dashboards "$dashboards_dir" "$node_name" "$ethnode_dir"; then
                ((dashboards_added++))
            fi
        fi
    done
    
    # Add validator dashboards
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        if ulcs_copy_validator_dashboard "$dashboards_dir" "vero"; then
            ((dashboards_added++))
        fi
    fi
    
    if [[ -d "$HOME/teku-validator" && -f "$HOME/teku-validator/.env" ]]; then
        if ulcs_copy_validator_dashboard "$dashboards_dir" "teku-validator"; then
            ((dashboards_added++))
        fi
    fi
    
    # Always add node-exporter dashboard
    if ulcs_copy_system_dashboards "$dashboards_dir"; then
        ((dashboards_added++))
    fi
    
    log_ulcs_monitoring_success "Dashboards synced ($dashboards_added total)"
    return 0
}

# Copy dashboards for an ethnode based on its client configuration
ulcs_copy_ethnode_dashboards() {
    local dashboards_dir="$1"
    local node_name="$2"
    local node_dir="$3"
    
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local template_dir="/home/floris/.nodeboi/grafana-dashboards"
    
    # Copy execution client dashboard
    if [[ "$compose_file" == *"nethermind"* ]]; then
        if [[ -f "$template_dir/execution/nethermind-overview.json" ]]; then
            cp "$template_dir/execution/nethermind-overview.json" "$dashboards_dir/${node_name}-nethermind-overview.json"
            log_ulcs_monitoring "Added ${node_name}-nethermind dashboard"
        fi
    elif [[ "$compose_file" == *"besu"* ]]; then
        if [[ -f "$template_dir/execution/besu-overview.json" ]]; then
            cp "$template_dir/execution/besu-overview.json" "$dashboards_dir/${node_name}-besu-overview.json"
            log_ulcs_monitoring "Added ${node_name}-besu dashboard"
        fi
    elif [[ "$compose_file" == *"reth"* ]]; then
        if [[ -f "$template_dir/execution/reth-overview.json" ]]; then
            cp "$template_dir/execution/reth-overview.json" "$dashboards_dir/${node_name}-reth-overview.json"
            log_ulcs_monitoring "Added ${node_name}-reth dashboard"
        fi
    fi
    
    # Copy consensus client dashboard
    if [[ "$compose_file" == *"lodestar"* ]]; then
        if [[ -f "$template_dir/consensus/lodestar-summary.json" ]]; then
            cp "$template_dir/consensus/lodestar-summary.json" "$dashboards_dir/${node_name}-lodestar-summary.json"
            log_ulcs_monitoring "Added ${node_name}-lodestar dashboard"
        fi
    elif [[ "$compose_file" == *"teku"* ]] && [[ "$compose_file" == *"cl-only"* ]]; then
        if [[ -f "$template_dir/consensus/teku-overview.json" ]]; then
            cp "$template_dir/consensus/teku-overview.json" "$dashboards_dir/${node_name}-teku-overview.json"
            log_ulcs_monitoring "Added ${node_name}-teku dashboard"
        fi
    elif [[ "$compose_file" == *"grandine"* ]]; then
        if [[ -f "$template_dir/consensus/grandine-overview.json" ]]; then
            cp "$template_dir/consensus/grandine-overview.json" "$dashboards_dir/${node_name}-grandine-overview.json"
            log_ulcs_monitoring "Added ${node_name}-grandine dashboard"
        fi
    fi
    
    return 0
}

# Copy validator dashboards
ulcs_copy_validator_dashboard() {
    local dashboards_dir="$1"
    local validator_name="$2"
    local template_dir="/home/floris/.nodeboi/grafana-dashboards"
    
    case "$validator_name" in
        "vero")
            if [[ -f "$template_dir/validators/vero-overview.json" ]]; then
                cp "$template_dir/validators/vero-overview.json" "$dashboards_dir/vero-overview.json"
                log_ulcs_monitoring "Added vero dashboard"
            fi
            ;;
        "teku-validator")
            if [[ -f "$template_dir/validators/teku-validator-overview.json" ]]; then
                cp "$template_dir/validators/teku-validator-overview.json" "$dashboards_dir/teku-validator-overview.json"
                log_ulcs_monitoring "Added teku-validator dashboard"
            fi
            ;;
    esac
    
    return 0
}

# Copy system dashboards (node-exporter, etc.)
ulcs_copy_system_dashboards() {
    local dashboards_dir="$1"
    local template_dir="/home/floris/.nodeboi/grafana-dashboards"
    
    if [[ -f "$template_dir/system/node-exporter-full.json" ]]; then
        cp "$template_dir/system/node-exporter-full.json" "$dashboards_dir/node-exporter-full.json"
        log_ulcs_monitoring "Added node-exporter dashboard"
        return 0
    fi
    
    return 1
}

#============================================================================
# ULCS NATIVE INTEGRATION HOOKS
#============================================================================

# ULCS Native Monitoring Integration (called by ULCS integrate step)
ulcs_integrate_monitoring() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs_monitoring "Integrating $service_name ($service_type) with monitoring"
    
    # Check if monitoring service exists
    if [[ ! -d "/home/$(whoami)/monitoring" ]]; then
        log_ulcs_monitoring "No monitoring service found - skipping integration"
        return 0
    fi
    
    # Regenerate prometheus configuration
    if ! ulcs_generate_prometheus_config; then
        log_ulcs_monitoring_error "Failed to update prometheus configuration"
        return 1
    fi
    
    # Sync dashboards
    if ! ulcs_sync_dashboards; then
        log_ulcs_monitoring_error "Failed to sync dashboards"
        return 1
    fi
    
    # Restart prometheus to pick up new config
    if ulcs_restart_prometheus; then
        log_ulcs_monitoring_success "Prometheus restarted with new configuration"
    else
        log_ulcs_monitoring_error "Failed to restart prometheus"
        return 1
    fi
    
    log_ulcs_monitoring_success "$service_name monitoring integration complete"
    return 0
}

# ULCS Native Monitoring Cleanup (called by ULCS cleanup_integrations step)
ulcs_cleanup_monitoring() {
    local service_name="$1"
    local service_type="$2"
    
    log_ulcs_monitoring "Cleaning up monitoring for $service_name ($service_type)"
    
    # Check if monitoring service exists
    if [[ ! -d "/home/$(whoami)/monitoring" ]]; then
        log_ulcs_monitoring "No monitoring service found - skipping cleanup"
        return 0
    fi
    
    # Regenerate prometheus configuration (will exclude the removed service)
    if ! ulcs_generate_prometheus_config; then
        log_ulcs_monitoring_error "Failed to update prometheus configuration"
        return 1
    fi
    
    # Sync dashboards (will exclude the removed service)
    if ! ulcs_sync_dashboards; then
        log_ulcs_monitoring_error "Failed to sync dashboards"  
        return 1
    fi
    
    # Restart prometheus to pick up new config
    if ulcs_restart_prometheus; then
        log_ulcs_monitoring_success "Prometheus restarted with updated configuration"
    else
        log_ulcs_monitoring_error "Failed to restart prometheus"
        return 1
    fi
    
    log_ulcs_monitoring_success "$service_name monitoring cleanup complete"
    return 0
}

# Restart prometheus service
ulcs_restart_prometheus() {
    local monitoring_dir="/home/$(whoami)/monitoring"
    
    if [[ -d "$monitoring_dir" ]]; then
        log_ulcs_monitoring "Restarting prometheus service"
        if cd "$monitoring_dir" && docker compose restart prometheus >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

#============================================================================
# ULCS MONITORING VALIDATION AND DEBUGGING
#============================================================================

# Validate that monitoring integration is working
ulcs_validate_monitoring_integration() {
    local service_name="$1"
    
    log_ulcs_monitoring "Validating monitoring integration for $service_name"
    
    local monitoring_dir="/home/$(whoami)/monitoring"
    local config_file="$monitoring_dir/prometheus.yml"
    
    # Check prometheus config exists and contains service
    if [[ ! -f "$config_file" ]]; then
        log_ulcs_monitoring_error "Prometheus config file missing"
        return 1
    fi
    
    if ! grep -q "$service_name" "$config_file"; then
        log_ulcs_monitoring_error "$service_name not found in prometheus config"
        return 1
    fi
    
    # Check dashboards exist
    local dashboards_dir="$monitoring_dir/grafana/dashboards"
    local dashboard_count=$(find "$dashboards_dir" -name "${service_name}*.json" 2>/dev/null | wc -l)
    
    if [[ $dashboard_count -eq 0 ]]; then
        log_ulcs_monitoring_error "No dashboards found for $service_name"
        return 1
    fi
    
    log_ulcs_monitoring_success "Monitoring integration validated for $service_name"
    return 0
}

# Debug monitoring state
ulcs_debug_monitoring() {
    log_ulcs_monitoring "=== MONITORING DEBUG INFO ==="
    
    local monitoring_dir="/home/$(whoami)/monitoring"
    local config_file="$monitoring_dir/prometheus.yml"
    
    echo "Prometheus config:" >&2
    if [[ -f "$config_file" ]]; then
        echo "  File exists: $config_file" >&2
        echo "  Job count: $(grep -c 'job_name:' "$config_file" 2>/dev/null || echo 0)" >&2
        echo "  Jobs: $(grep 'job_name:' "$config_file" 2>/dev/null | sed "s/.*job_name: '\([^']*\)'.*/\1/" | tr '\n' ' ')" >&2
    else
        echo "  File missing: $config_file" >&2
    fi
    
    echo "Dashboards:" >&2
    local dashboards_dir="$monitoring_dir/grafana/dashboards"
    if [[ -d "$dashboards_dir" ]]; then
        echo "  Directory exists: $dashboards_dir" >&2
        echo "  Dashboard count: $(find "$dashboards_dir" -name "*.json" 2>/dev/null | wc -l)" >&2
        echo "  Dashboards: $(find "$dashboards_dir" -name "*.json" -exec basename {} \; 2>/dev/null | tr '\n' ' ')" >&2
    else
        echo "  Directory missing: $dashboards_dir" >&2
    fi
    
    log_ulcs_monitoring "=== END DEBUG INFO ==="
}

#============================================================================
# ULCS NATIVE SERVICE INTEGRATION ORCHESTRATION
#============================================================================

# ULCS Native Service Integration (replaces integrate_service)
ulcs_integrate_service() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    log_ulcs_monitoring "Integrating $service_name ($service_type) with all services"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                ulcs_integrate_monitoring "$service_name" "$service_type"
                ;;
            "validators")
                # Call existing validator integration functions (not monitoring-related)
                if declare -f integrate_with_validators >/dev/null 2>&1; then
                    integrate_with_validators "$service_name" "$service_type"
                fi
                ;;
            "ethnodes")
                # Call existing ethnode integration functions (not monitoring-related)  
                if declare -f integrate_with_ethnodes >/dev/null 2>&1; then
                    integrate_with_ethnodes "$service_name" "$service_type"
                fi
                ;;
            "web3signer")
                # Call existing web3signer integration functions (not monitoring-related)
                if declare -f integrate_with_web3signer >/dev/null 2>&1; then
                    integrate_with_web3signer "$service_name" "$service_type"
                fi
                ;;
        esac
    done
    
    log_ulcs_monitoring_success "$service_name integration complete"
    return 0
}

# ULCS Native Service Integration Cleanup (replaces cleanup_service_integrations)
ulcs_cleanup_service_integrations() {
    local service_name="$1"
    local service_type="$2"
    local flow_def="$3"
    
    log_ulcs_monitoring "Cleaning up integrations for $service_name ($service_type)"
    
    # Extract integrations from flow definition
    local integrations=$(echo "$flow_def" | jq -r '.resources.integrations[]?' 2>/dev/null)
    
    for integration in $integrations; do
        case "$integration" in
            "monitoring")
                ulcs_cleanup_monitoring "$service_name" "$service_type"
                ;;
            "validators")
                # Call existing validator cleanup functions (not monitoring-related)
                if declare -f cleanup_validator_integration >/dev/null 2>&1; then
                    cleanup_validator_integration "$service_name" "$service_type"
                fi
                ;;
            "ethnodes")
                # Call existing ethnode cleanup functions (not monitoring-related)
                if declare -f cleanup_ethnode_integration >/dev/null 2>&1; then
                    cleanup_ethnode_integration "$service_name" "$service_type"
                fi
                ;;
            "web3signer")
                # Call existing web3signer cleanup functions (not monitoring-related)
                if declare -f cleanup_web3signer_integration >/dev/null 2>&1; then
                    cleanup_web3signer_integration "$service_name" "$service_type"
                fi
                ;;
        esac
    done
    
    log_ulcs_monitoring_success "$service_name integration cleanup complete"
    return 0
}

# Export ULCS monitoring functions
export -f ulcs_generate_prometheus_config
export -f ulcs_sync_dashboards
export -f ulcs_integrate_monitoring
export -f ulcs_cleanup_monitoring
export -f ulcs_integrate_service
export -f ulcs_cleanup_service_integrations
export -f ulcs_validate_monitoring_integration
export -f ulcs_debug_monitoring