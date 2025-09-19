#!/bin/bash
# dashboard-template-fix.sh - Universal dashboard template processing for all client types

# Improved dashboard template processing function
process_dashboard_template_universal() {
    local template_file="$1"
    local output_file="$2" 
    local job_name="$3"          # e.g., "ethnode2-lodestar"
    local client_name="$4"       # e.g., "lodestar"
    
    if [[ ! -f "$template_file" ]]; then
        echo "Template file not found: $template_file"
        return 1
    fi
    
    echo "Processing dashboard template: $(basename "$template_file") -> $(basename "$output_file")"
    echo "  Job name: $job_name"
    echo "  Client: $client_name"
    
    # Copy template to temp file
    cp "$template_file" "$output_file.tmp"
    
    # Fix common datasource references
    sed -i 's/\${DS_PROMETHEUS}/prometheus/g' "$output_file.tmp"
    sed -i 's/"uid": "prometheus"/"uid": ""/g' "$output_file.tmp"
    sed -i 's/"uid": "\${datasource}"/"uid": ""/g' "$output_file.tmp"
    
    # Client-specific template variable fixes
    case "${client_name,,}" in
        "lodestar"|"teku"|"grandine"|"lighthouse")
            # Consensus clients - fix beacon job variables
            sed -i "s/\"value\": \"beacon\"/\"value\": \"$job_name\"/g" "$output_file.tmp"
            sed -i "s/\"value\": \"validator\"/\"value\": \"$job_name\"/g" "$output_file.tmp"
            ;;
        "besu"|"reth"|"nethermind"|"geth")
            # Execution clients - fix execution job variables and metric queries
            sed -i "s/\"value\": \"execution\"/\"value\": \"$job_name\"/g" "$output_file.tmp"
            
            # For Nethermind specifically, fix the complex variable system
            if [[ "${client_name,,}" == "nethermind" ]]; then
                # Get the actual instance label from the running metrics
                local instance_label="${job_name/:*/}:6060"  # e.g. ethnode2-nethermind:6060
                
                # Fix the network variable to match actual labels
                # First check what Network label value Nethermind is actually using
                local network_value=$(curl -s "http://localhost:9090/api/v1/query?query=nethermind_au_ra_step" | jq -r '.data.result[0].metric.Network // "Hoodi"' 2>/dev/null || echo "Hoodi")
                
                # Replace the network variable default value
                jq --arg network "$network_value" '
                (.templating.list[] | select(.name == "network") | .current.value) |= [$network] |
                (.templating.list[] | select(.name == "network") | .current.text) |= [$network]
                ' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp"
                
                # Fix the enode variable to use the correct instance
                local instance_value=$(curl -s "http://localhost:9090/api/v1/query?query=nethermind_au_ra_step" | jq -r '.data.result[0].metric.Instance // "Hoodi"' 2>/dev/null || echo "Hoodi")
                
                jq --arg instance "$instance_value" '
                (.templating.list[] | select(.name == "enode") | .current.value) |= [$instance] |
                (.templating.list[] | select(.name == "enode") | .current.text) |= [$instance]
                ' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp"
            fi
            ;;
        "vero")
            # Validator clients
            sed -i "s/\"value\": \"validator\"/\"value\": \"$job_name\"/g" "$output_file.tmp"
            ;;
    esac
    
    # Set unique dashboard properties
    local dashboard_title="${job_name//-/ | }"
    dashboard_title="${dashboard_title^}"  # Capitalize first letter
    
    local unique_uid=$(echo -n "$(basename "$output_file" .json)" | md5sum | cut -c1-9)
    
    # Update dashboard metadata
    jq --arg title "$dashboard_title" --arg uid "$unique_uid" '
    .title = $title |
    .uid = $uid |
    .tags = ["monitoring", "ethereum"]
    ' "$output_file.tmp" > "$output_file.tmp2" && mv "$output_file.tmp2" "$output_file.tmp"
    
    # Move final file
    mv "$output_file.tmp" "$output_file"
    
    echo "  ✓ Dashboard processed successfully"
    return 0
}

# Function to regenerate all dashboards with proper template processing
regenerate_all_dashboards() {
    local dashboard_dir="$HOME/monitoring/grafana/dashboards"
    local template_dir="/home/floris/.nodeboi/grafana-dashboards"
    
    echo "Regenerating all dashboards with improved template processing..."
    
    # Remove old dashboards
    rm -f "$dashboard_dir"/*.json
    
    # Process each running service
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local ethnode_name=$(basename "$dir")
            local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)
            
            echo "Processing $ethnode_name (compose: $compose_file)..."
            
            # Determine which clients are running
            if [[ "$compose_file" == *"besu"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/execution/besu-overview.json" \
                    "$dashboard_dir/${ethnode_name}-besu-overview.json" \
                    "${ethnode_name}-besu" \
                    "besu"
            fi
            
            if [[ "$compose_file" == *"reth"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/execution/reth-overview.json" \
                    "$dashboard_dir/${ethnode_name}-reth-overview.json" \
                    "${ethnode_name}-reth" \
                    "reth"
            fi
            
            if [[ "$compose_file" == *"nethermind"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/execution/nethermind-overview.json" \
                    "$dashboard_dir/${ethnode_name}-nethermind-overview.json" \
                    "${ethnode_name}-nethermind" \
                    "nethermind"
            fi
            
            if [[ "$compose_file" == *"teku"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/consensus/teku-overview.json" \
                    "$dashboard_dir/${ethnode_name}-teku-overview.json" \
                    "${ethnode_name}-teku" \
                    "teku"
            fi
            
            if [[ "$compose_file" == *"grandine"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/consensus/grandine-overview.json" \
                    "$dashboard_dir/${ethnode_name}-grandine-overview.json" \
                    "${ethnode_name}-grandine" \
                    "grandine"
            fi
            
            if [[ "$compose_file" == *"lodestar"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/consensus/lodestar-summary.json" \
                    "$dashboard_dir/${ethnode_name}-lodestar-summary.json" \
                    "${ethnode_name}-lodestar" \
                    "lodestar"
            fi
            
            if [[ "$compose_file" == *"lighthouse"* ]]; then
                process_dashboard_template_universal \
                    "$template_dir/consensus/lighthouse-overview.json" \
                    "$dashboard_dir/${ethnode_name}-lighthouse-overview.json" \
                    "${ethnode_name}-lighthouse" \
                    "lighthouse"
            fi
        fi
    done
    
    # Process validator services
    if [[ -d "$HOME/vero" && -f "$HOME/vero/.env" ]]; then
        process_dashboard_template_universal \
            "$template_dir/validators/vero-detailed.json" \
            "$dashboard_dir/vero-detailed.json" \
            "vero" \
            "vero"
    fi
    
    # Add system monitoring
    if [[ -f "$template_dir/system/node-exporter-full.json" ]]; then
        process_dashboard_template_universal \
            "$template_dir/system/node-exporter-full.json" \
            "$dashboard_dir/node-exporter-full.json" \
            "node-exporter" \
            "node-exporter"
    fi
    
    echo "✓ All dashboards regenerated with improved template processing"
}