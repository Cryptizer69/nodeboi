#!/bin/bash
# lib/clients.sh - THE ONLY PLACE for client configuration
# To add a new client: just update these arrays!

# ============ CLIENT REGISTRY (ADD NEW CLIENTS HERE) ============
EXECUTION_CLIENTS=("reth" "besu" "nethermind")
CONSENSUS_CLIENTS=("teku" "lodestar" "grandine")

# Docker images for each client
declare -gA DOCKER_IMAGES=(
    # Execution
    ["reth"]="ghcr.io/paradigmxyz/reth"
    ["besu"]="hyperledger/besu"
    ["nethermind"]="nethermind/nethermind"
    # Consensus
    ["teku"]="consensys/teku"
    ["lodestar"]="chainsafe/lodestar"
    ["grandine"]="sifrai/grandine"
)

# GitHub repos for version checking
declare -gA GITHUB_REPOS=(
    # Execution
    ["reth"]="paradigmxyz/reth"
    ["besu"]="hyperledger/besu"
    ["nethermind"]="NethermindEth/nethermind"
    # Consensus
    ["teku"]="Consensys/teku"
    ["lodestar"]="ChainSafe/lodestar"
    ["grandine"]="grandinetech/grandine"
)

# Version format (some need 'v' prefix, some don't)
declare -gA VERSION_PREFIX=(
    ["reth"]="v"
    ["besu"]=""
    ["nethermind"]=""
    ["teku"]=""
    ["lodestar"]="v"
    ["grandine"]=""
)

# Fallback versions when API fails
declare -gA FALLBACK_VERSIONS=(
    ["reth"]="v1.1.0"
    ["besu"]="24.10.0"
    ["nethermind"]="1.29.0"
    ["teku"]="24.10.3"
    ["lodestar"]="v1.22.0"
    ["grandine"]="0.5.0"
)

# ============ DEDUPLICATED FUNCTIONS ============

# Detect clients from compose file (replaces 6 duplicate blocks!)
detect_node_clients() {
    local compose_file="$1"
    local exec_client=""
    local cons_client=""

    for client in "${EXECUTION_CLIENTS[@]}"; do
        [[ "$compose_file" == *"${client}.yml"* ]] && exec_client="$client" && break
    done

    for client in "${CONSENSUS_CLIENTS[@]}"; do
        [[ "$compose_file" == *"${client}"* ]] && cons_client="$client" && break
    done

    echo "${exec_client}:${cons_client}"
}

# Get docker image (replaces all case statements!)
get_docker_image() {
    echo "${DOCKER_IMAGES[$1]:-unknown}"
}

# Get GitHub repo
get_github_repo() {
    echo "${GITHUB_REPOS[$1]:-unknown}"
}

# Normalize version (replaces 8 duplicate blocks!)
normalize_version() {
    local client=$1
    local version=$2
    local prefix="${VERSION_PREFIX[$client]}"

    if [[ "$prefix" == "v" ]]; then
        [[ "$version" != v* ]] && version="v${version}"
    else
        version="${version#v}"
    fi
    echo "$version"
}

# Get environment variable name for client
get_client_env_var() {
    echo "${1^^}_VERSION"
}

# Update any client version (generic!)
update_client_version() {
    local node_dir=$1
    local client=$2
    local version=$3

    [[ -z "$version" ]] && return 0

    version=$(normalize_version "$client" "$version")
    local env_var=$(get_client_env_var "$client")
    sed -i "s/${env_var}=.*/${env_var}=$version/" "$node_dir/.env"
}

# Get latest version from GitHub
get_latest_version() {
    local client=$1
    local repo="${GITHUB_REPOS[$client]}"

    # Check cache first
    local cache_file="$HOME/.nodeboi/cache/versions.cache"
    local cache_duration=3600

    mkdir -p "$(dirname "$cache_file")"

    if [[ -f "$cache_file" ]]; then
        local cache_entry=$(grep "^${client}:" "$cache_file" 2>/dev/null | tail -1)
        if [[ -n "$cache_entry" ]]; then
            local cached_version=$(echo "$cache_entry" | cut -d: -f2)
            local cached_time=$(echo "$cache_entry" | cut -d: -f3)
            local current_time=$(date +%s)

            if [[ $((current_time - cached_time)) -lt $cache_duration ]]; then
                echo "$cached_version"
                return 0
            fi
        fi
    fi

    # Fetch from GitHub
    local version=$(curl -sL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
                   grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -n "$version" ]]; then
        # Update cache
        grep -v "^${client}:" "$cache_file" > "$cache_file.tmp" 2>/dev/null || true
        mv "$cache_file.tmp" "$cache_file" 2>/dev/null || true
        echo "${client}:${version}:$(date +%s)" >> "$cache_file"
        echo "$version"
    else
        echo "${FALLBACK_VERSIONS[$client]}"
    fi
}

# Validate Docker image exists
validate_client_version() {
    local client=$1
    local version=$2

    [[ -z "$version" ]] && return 0

    local image=$(get_docker_image "$client")
    [[ "$image" == "unknown" ]] && return 1

    version=$(normalize_version "$client" "$version")

    echo "Checking Docker Hub for ${image}:${version}..." >&2

    if docker manifest inspect "${image}:${version}" >/dev/null 2>&1; then
        echo "✓ Found ${image}:${version}" >&2
        return 0
    else
        echo "✗ Image not found: ${image}:${version}" >&2
        return 1
    fi
}

# Menu functions
prompt_execution_client() {
    echo -e "\nSelect Execution Client:" >&2
    echo "========================" >&2
    local i=1
    for client in "${EXECUTION_CLIENTS[@]}"; do
        echo "  $i) ${client^}" >&2
        ((i++))
    done
    echo >&2

    read -p "Enter choice [1-${#EXECUTION_CLIENTS[@]}]: " choice

    if [[ $choice -ge 1 && $choice -le ${#EXECUTION_CLIENTS[@]} ]]; then
        echo "${EXECUTION_CLIENTS[$((choice-1))]}"
    fi
}

prompt_consensus_client() {
    echo -e "\nSelect Consensus Client:" >&2
    echo "========================" >&2
    local i=1
    for client in "${CONSENSUS_CLIENTS[@]}"; do
        echo "  $i) ${client^}" >&2
        ((i++))
    done
    echo >&2

    read -p "Enter choice [1-${#CONSENSUS_CLIENTS[@]}]: " choice

    if [[ $choice -ge 1 && $choice -le ${#CONSENSUS_CLIENTS[@]} ]]; then
        echo "${CONSENSUS_CLIENTS[$((choice-1))]}"
    fi
}

# Release URL helper
get_release_url() {
    local client=$1
    local repo="${GITHUB_REPOS[$client]}"
    [[ "$repo" != "unknown" ]] && echo "https://github.com/${repo}/releases"
}

# Clean up stale cache entries
cleanup_version_cache() {
    local cache_file="$HOME/.nodeboi/cache/versions.cache"
    local current_time=$(date +%s)
    local temp_file="${cache_file}.tmp"
    
    [[ -f "$cache_file" ]] || return 0
    
    while IFS=':' read -r client version timestamp; do
        if [[ $((current_time - timestamp)) -lt 300 ]]; then
            echo "${client}:${version}:${timestamp}" >> "$temp_file"
        fi
    done < "$cache_file"
    
    mv "$temp_file" "$cache_file" 2>/dev/null || true
}
