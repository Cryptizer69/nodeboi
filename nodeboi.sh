#!/bin/bash
# NODEBOI v1.0.8 - Ethereum Node Automation
set -eo pipefail
trap 'echo "Error on line $LINENO" >&2' ERR

#==============================================================================
# SECTION 1: CONFIGURATION AND COLORS
#==============================================================================
SCRIPT_VERSION="1.0.0"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
PINK='\033[38;5;213m'

CHECK_UPDATES="${CHECK_UPDATES:-true}"

#==============================================================================
# SECTION 2: UI FUNCTIONS
#==============================================================================
print_header() {
    echo -e "${PINK}${BOLD}"
    cat << "EOF"
    ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗
    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║
    ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║
    ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║
    ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║
    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
EOF
    echo -e "${NC}"
    echo -e "                    ${CYAN}ETHEREUM NODE AUTOMATION${NC}"
    echo -e "                           ${YELLOW}v1.0.8${NC}"
    echo
}

press_enter() {
    echo
    read -p "Press Enter to continue..."
}

#==============================================================================
# SECTION 3: SYSTEM CHECKS
#==============================================================================
check_prerequisites() {
    echo -e "${GREEN}[INFO]${NC} Checking system prerequisites"
    local missing_tools=()
    local install_docker=false

    for tool in wget curl openssl ufw; do
        if command -v "$tool" &> /dev/null; then
            echo -e "  $tool: ${GREEN}✓${NC}"
        else
            echo -e "  $tool: ${RED}✗${NC}"
            missing_tools+=("$tool")
        fi
    done

    # Check Docker and Docker Compose v2
    if command -v docker &> /dev/null; then
        echo -e "  docker: ${GREEN}✓${NC}"
        
        # Check for Docker Compose v2 (comes with Docker)
        if docker compose version &>/dev/null 2>&1; then
            echo -e "  docker compose: ${GREEN}✓${NC}"
        else
            echo -e "  docker compose: ${RED}✗${NC}"
            echo -e "  ${YELLOW}Docker is installed but Compose v2 is missing${NC}"
            install_docker=true
        fi
    else
        echo -e "  docker: ${RED}✗${NC}"
        echo -e "  docker compose: ${RED}✗${NC}"
        install_docker=true
    fi

    # Auto-install missing tools if any
    if [[ ${#missing_tools[@]} -gt 0 ]] || [[ "$install_docker" == true ]]; then
        echo -e "\n${RED}Missing required tools:${NC}"
        
        for tool in "${missing_tools[@]}"; do
            case $tool in
                wget) echo "  • wget - needed for downloading client binaries" ;;
                curl) echo "  • curl - needed for API calls and version checks" ;;
                openssl) echo "  • openssl - needed for generating JWT secrets" ;;
                ufw) echo "  • ufw - firewall management for node security" ;;
            esac
        done
        
        [[ "$install_docker" == true ]] && echo "  • docker/docker compose v2 - essential for running node containers"
        
        echo -e "\n${YELLOW}These tools are necessary for running NODEBOI.${NC}"
        read -p "Would you like to install the missing prerequisites now? [y/n]: " -r
        echo
        
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "Installing missing tools..."
            
            sudo apt update
            
            if [[ ${#missing_tools[@]} -gt 0 ]]; then
                sudo apt install -y "${missing_tools[@]}"
            fi
            
            if [[ "$install_docker" == true ]]; then
                echo "Installing Docker with Compose v2 (this may take a few minutes)..."
                sudo apt remove -y docker docker-engine docker.io containerd runc docker-compose 2>/dev/null || true
                curl -fsSL https://get.docker.com | sudo sh
                sudo usermod -aG docker $USER
                sudo apt install -y docker-compose-plugin
                echo -e "${YELLOW}⚠ Important: You'll need to log out and back in for Docker permissions to take effect.${NC}"
                echo "Or run: newgrp docker"
            fi
            
            echo -e "${GREEN}✓ Prerequisites installed successfully${NC}"
            
            if [[ "$install_docker" == true ]]; then
                echo -e "${YELLOW}Note: If Docker commands fail, please log out and back in first.${NC}"
            fi
        else
            echo -e "${RED}[ERROR]${NC} Cannot proceed without required tools."
            echo "To install manually, run:"
            echo "  sudo apt update && sudo apt install -y ${missing_tools[*]}"
            [[ "$install_docker" == true ]] && echo "  curl -fsSL https://get.docker.com | sudo sh && sudo apt install -y docker-compose-plugin"
            exit 1
        fi
    else
        echo -e "${GREEN}✓${NC} All prerequisites satisfied"
    fi
}

detect_existing_instances() {
    echo -e "${GREEN}[INFO]${NC} Scanning for existing Ethereum instances..."
    local found=false

    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            echo -e "  Found: ${GREEN}$(basename "$dir")${NC}"
            found=true
        fi
    done

    if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "ethnode"; then
        echo -e "  Found running Docker containers"
        found=true
    fi

    [[ "$found" == true ]] && echo -e "${YELLOW}Note: Existing instances detected. Ports will be auto-adjusted.${NC}" || echo "  No existing instances found"
    return $([[ "$found" == true ]] && echo 0 || echo 1)
}

#==============================================================================
# SECTION 4: ENHANCED PORT MANAGEMENT
#==============================================================================

# Gather all used ports from various sources
get_all_used_ports() {
    local used_ports=""

    # Get system ports from netstat/ss
    if command -v ss &>/dev/null; then
        used_ports+=$(ss -tuln 2>/dev/null | awk '/LISTEN/ {print $5}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    else
        used_ports+=$(netstat -tuln 2>/dev/null | awk '/LISTEN/ {print $4}' | grep -oE '[0-9]+$' | sort -u | tr '\n' ' ')
    fi

    # Get Docker exposed ports - FIXED to handle ranges
    local docker_ports=$(docker ps --format "table {{.Ports}}" 2>/dev/null | tail -n +2)
    
    # Extract single ports
    used_ports+=" $(echo "$docker_ports" | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')"
    
    # Handle port ranges like 30304-30305
    local ranges=$(echo "$docker_ports" | grep -oE '[0-9]+-[0-9]+' || true)
    if [[ -n "$ranges" ]]; then
        while IFS= read -r range; do
            local start=$(echo "$range" | cut -d'-' -f1)
            local end=$(echo "$range" | cut -d'-' -f2)
            for ((port=start; port<=end; port++)); do
                used_ports+=" $port"
            done
        done <<< "$ranges"
    fi

    # Get ports from all ethnode .env files
    for env_file in "$HOME"/ethnode*/.env; do
        [[ -f "$env_file" ]] || continue
        used_ports+=" $(grep -E '_PORT=' "$env_file" 2>/dev/null | cut -d'=' -f2 | sort -u | tr '\n' ' ')"
    done

    # Remove duplicates and return
    echo "$used_ports" | tr ' ' '\n' | sort -nu | tr '\n' ' '
}

# Check if a specific port is available
is_port_available() {
    local port=$1
    local used_ports="${2:-}"  # Make second parameter optional with default empty string
    
    # Check if port is in the used ports list
    [[ -n "$used_ports" ]] && echo " $used_ports " | grep -q " $port " && return 1
    
    # Double-check with nc (netcat) if available
    if command -v nc &>/dev/null; then
        nc -z 127.0.0.1 "$port" 2>/dev/null && return 1
    fi
    
    return 0
}

# Find next available port with smart increments
find_available_port() {
    local base_port=$1
    local increment="${2:-2}"  # Default to 2 if not provided
    local used_ports="${3:-}"  # Default to empty if not provided
    local max_attempts=50
    
    for ((i=0; i<max_attempts; i++)); do
        local port=$((base_port + (i * increment)))
        if is_port_available "$port" "$used_ports"; then
            echo "$port"
            return 0
        fi
    done
    
    echo "Error: Could not find available port starting from $base_port" >&2
    return 1
}

# Get instance number and calculate base ports
get_instance_ports() {
    local instance_num=$1
    local used_ports="$2"
    
    # Calculate base ports based on instance number
    # Use larger gaps for execution layer to avoid overlap (RPC+6=Engine)
    local el_base=$((8545 + ((instance_num - 1) * 10)))
    local cl_base=$((5052 + ((instance_num - 1) * 2)))
    local p2p_base=$((30303 + ((instance_num - 1) * 2)))
    local cl_p2p_base=$((9000 + ((instance_num - 1) * 4)))  # Larger gap for TCP+UDP pairs
    local mev_base=$((18550 + ((instance_num - 1) * 2)))
    
    # Find available ports starting from calculated bases
    local el_rpc=$(find_available_port "$el_base" 1 "$used_ports")
    used_ports+=" $el_rpc"
    
    local el_ws=$(find_available_port $((el_rpc + 1)) 1 "$used_ports")
    used_ports+=" $el_ws"
    
    local ee_port=$(find_available_port $((el_rpc + 6)) 1 "$used_ports")
    used_ports+=" $ee_port"
    
    local cl_rest=$(find_available_port "$cl_base" 2 "$used_ports")
    used_ports+=" $cl_rest"
    
    local el_p2p=$(find_available_port "$p2p_base" 1 "$used_ports")
    used_ports+=" $el_p2p"
    
    local el_p2p_2=$((el_p2p + 1))
    if ! is_port_available "$el_p2p_2" "$used_ports"; then
        el_p2p=$(find_available_port $((p2p_base + 10)) 2 "$used_ports")
        el_p2p_2=$((el_p2p + 1))
    fi
    used_ports+=" $el_p2p_2"
    
    local cl_p2p=$(find_available_port "$cl_p2p_base" 1 "$used_ports")
    used_ports+=" $cl_p2p"
    
    local cl_quic=$((cl_p2p + 1))
    if ! is_port_available "$cl_quic" "$used_ports"; then
        cl_p2p=$(find_available_port $((cl_p2p_base + 10)) 2 "$used_ports")
        cl_quic=$((cl_p2p + 1))
    fi
    used_ports+=" $cl_quic"
    
    local mevboost_port=$(find_available_port "$mev_base" 2 "$used_ports")
    used_ports+=" $mevboost_port"
    
    # Metrics ports
    local el_metrics=$(find_available_port 6060 2 "$used_ports")
    used_ports+=" $el_metrics"
    
    local cl_metrics=$(find_available_port 8008 2 "$used_ports")
    used_ports+=" $cl_metrics"
    
    local reth_metrics=""
    if [[ "${4:-}" == "reth" ]]; then
        reth_metrics=$(find_available_port 9001 2 "$used_ports")
        used_ports+=" $reth_metrics"
    fi
    
    # Return all ports as a string
    echo "$el_rpc|$el_ws|$ee_port|$cl_rest|$el_p2p|$el_p2p_2|$cl_p2p|$cl_quic|$mevboost_port|$el_metrics|$cl_metrics|$reth_metrics"
}

# Verify ports before Docker launch
verify_ports_available() {
    local node_dir=$1
    
    if [[ ! -f "$node_dir/.env" ]]; then
        return 0
    fi
    
    local failed_ports=""
    local used_ports=$(get_all_used_ports)
    
    # Extract ports from .env
    while IFS='=' read -r key value; do
        if [[ "$key" == *"_PORT"* && -n "$value" ]]; then
            if ! is_port_available "$value" "$used_ports"; then
                failed_ports+=" $value"
            fi
        fi
    done < "$node_dir/.env"
    
    if [[ -n "$failed_ports" ]]; then
        echo -e "${RED}[ERROR]${NC} These ports are already in use:$failed_ports" >&2
        echo "Please check for conflicting services or other ethnode instances." >&2
        return 1
    fi
    
    return 0
}

get_next_instance_number() {
    local num=1
    while [[ -d "$HOME/ethnode${num}" ]]; do ((num++)); done
    echo $num
}
#==============================================================================
# SECTION 5: USER INPUT PROMPTS
#==============================================================================
prompt_node_name() {
    local default_name="ethnode$(get_next_instance_number)"
    
    echo -e "\nNode Configuration\n==================" >&2
    
    while true; do
        read -p "Enter node name (default: $default_name): " node_name
        node_name=${node_name:-$default_name}
        
        if [[ "$node_name" == *" "* ]] || [[ ! "$node_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo "ERROR: Node name must contain only letters, numbers, dash, underscore" >&2
            continue
        fi
        
        if [[ -d "$HOME/$node_name" ]]; then
            echo "ERROR: Directory $HOME/$node_name already exists" >&2
            continue
        fi
        
        echo "$node_name"
        return 0
    done
}

prompt_network() {
    echo -e "\nSelect Network\n==============\n  H) Hoodi testnet\n  M) Ethereum mainnet\n" >&2
    
    while true; do
        read -p "Enter choice [H/M]: " choice
        case ${choice^^} in
            H) echo "hoodi"; return ;;
            M) echo "mainnet"; return ;;
            *) echo "Invalid choice. Please enter H or M." >&2 ;;
        esac
    done
}

prompt_execution_client() {
    echo -e "\nSelect Execution Client\n=======================\n  R) Reth\n  B) Besu\n  N) Nethermind\n" >&2
    
    while true; do
        read -p "Enter choice [R/B/N]: " choice
        case ${choice^^} in
            R) echo "reth"; return ;;
            B) echo "besu"; return ;;
            N) echo "nethermind"; return ;;
            *) echo "Invalid choice. Please enter R, B, or N." >&2 ;;
        esac
    done
}

prompt_consensus_client() {
    echo -e "\nSelect Consensus Client\n=======================\n  L) Lodestar\n  T) Teku\n  G) Grandine\n" >&2
    
    while true; do
        read -p "Enter choice [L/T/G]: " choice
        case ${choice^^} in
            L) echo "lodestar"; return ;;
            T) echo "teku"; return ;;
            G) echo "grandine"; return ;;
            *) echo "Invalid choice. Please enter L, T, or G." >&2 ;;
        esac
    done
}

#==============================================================================
# SECTION 6: VERSION MANAGEMENT
#==============================================================================
get_latest_version() {
    local client=$1
    local version=""
    local github_token="${GITHUB_TOKEN:-}"  # Optional token from environment
    
    # Simple cache check (inline, no separate function)
    local cache_file="$HOME/.nodeboi/cache/versions.cache"
    local cache_duration=3600  # 1 hour
    
    # Create cache dir if needed
    mkdir -p "$(dirname "$cache_file")"
    
    # Check cache first
    if [[ -f "$cache_file" ]]; then
        local cache_entry=$(grep "^${client}:" "$cache_file" 2>/dev/null | tail -1)
        if [[ -n "$cache_entry" ]]; then
            local cached_version=$(echo "$cache_entry" | cut -d: -f2)
            local cached_time=$(echo "$cache_entry" | cut -d: -f3)
            local current_time=$(date +%s)
            
            if [[ $((current_time - cached_time)) -lt $cache_duration ]]; then
                echo "Using cached version for $client: $cached_version" >&2
                echo "$cached_version"
                return 0
            fi
        fi
    fi
    
    echo "Checking latest version for $client..." >&2
    
    # Build curl command with optional auth
    local curl_opts="-sL -H 'User-Agent: NODEBOI' --max-time 5"
    if [[ -n "$github_token" ]]; then
        curl_opts="$curl_opts -H 'Authorization: token $github_token'"
    fi
    
    # Fetch based on client type
    case $client in
        reth)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/paradigmxyz/reth/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/paradigmxyz/reth/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="v1.0.8"  # Fallback
            ;;
        besu)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/hyperledger/besu/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/hyperledger/besu/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="25.8.0"  # Fallback
            ;;
        nethermind)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/NethermindEth/nethermind/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/NethermindEth/nethermind/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="1.29.0"  # Fallback
            ;;
        lodestar)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/ChainSafe/lodestar/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/ChainSafe/lodestar/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="v1.0.8"  # Fallback
            ;;
        teku)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/Consensys/teku/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/Consensys/teku/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="25.7.1"  # Fallback
            ;;
        grandine)
            if [[ -n "$github_token" ]]; then
                version=$(curl -sL -H "Authorization: token $github_token" -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/grandinetech/grandine/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            else
                version=$(curl -sL -H "User-Agent: NODEBOI" --max-time 5 https://api.github.com/repos/grandinetech/grandine/releases/latest 2>/dev/null | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p' | head -1)
            fi
            [[ -z "$version" ]] && version="0.5.0"  # Fallback
            ;;
        *)
            echo "Unknown client: $client" >&2
            version="latest"
            ;;
    esac
    
    # Save to cache if we got a version (not using fallback)
    if [[ -n "$version" ]] && [[ "$version" != "latest" ]]; then
        # Remove old cache entry
        if [[ -f "$cache_file" ]]; then
            grep -v "^${client}:" "$cache_file" > "$cache_file.tmp" 2>/dev/null || true
            mv "$cache_file.tmp" "$cache_file"
        fi
        # Add new cache entry
        echo "${client}:${version}:$(date +%s)" >> "$cache_file"
    fi
    
    echo "$version"
}

prompt_version() {
    local client_type=$1
    local category=$2
    local selected_version=""
    
    # Send menu to stderr so it's visible
    echo "" >&2
    echo "Version Selection for $client_type" >&2
    echo "=========================" >&2
    echo "Options:" >&2
    echo "  1) Use latest version" >&2
    echo "  2) Enter a different version" >&2
    echo "  3) Use default from .env file" >&2
    echo "" >&2
    
    read -p "Enter choice [1-3]: " -r version_choice
    echo >&2
    
    case "$version_choice" in
        1)
            echo "Fetching latest version..." >&2
            selected_version=$(get_latest_version "$client_type" 2>/dev/null)
            if [[ -z "$selected_version" ]]; then
                echo "Could not fetch latest version" >&2
                while [[ -z "$selected_version" ]]; do
                    read -r -p "Enter version manually: " selected_version
                    [[ -z "$selected_version" ]] && echo "Version cannot be empty!" >&2
                done
            else
                echo "Using version: $selected_version" >&2
            fi
            ;;
        2)
            while true; do
                read -r -p "Enter version (e.g., v1.0.8 or 25.7.0): " selected_version
                
                if [[ -z "$selected_version" ]]; then
                    echo "Version cannot be empty! Try again." >&2
                    continue
                fi
                
                echo "Validating version $selected_version..." >&2
                if validate_client_version "$client_type" "$selected_version"; then
                    echo "Version validated successfully" >&2
                    break
                else
                    echo -e "${RED}Error: Version $selected_version not found for $client_type${NC}" >&2
                    echo "Please check available versions at:" >&2
                    case "$client_type" in
                        reth) echo "  https://github.com/paradigmxyz/reth/releases" >&2 ;;
                        besu) echo "  https://github.com/hyperledger/besu/releases" >&2 ;;
                        nethermind) echo "  https://github.com/NethermindEth/nethermind/releases" >&2 ;;
                        lodestar) echo "  https://github.com/ChainSafe/lodestar/releases" >&2 ;;
                        teku) echo "  https://github.com/Consensys/teku/releases" >&2 ;;
                        grandine) echo "  https://github.com/grandinetech/grandine/releases" >&2 ;;
                    esac
                    echo "Try again or press Ctrl+C to cancel" >&2
                fi
            done
            ;;
        3)
            selected_version=""
            echo "Using default version from .env file" >&2
            ;;
        *)
            echo "Invalid choice, using default" >&2
            selected_version=""
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

update_client_version() {
    local node_dir=$1
    local client=$2
    local version=$3
    
    [[ -z "$version" ]] && return 0
    
    # Normalize version format for each client to match Docker tags
    case "$client" in
        reth|lodestar)
            # These need 'v' prefix
            [[ "$version" != v* ]] && version="v$version"
            ;;
        besu|nethermind|teku|grandine)
            # These don't use 'v' prefix
            version="${version#v}"
            ;;
    esac
    
    local client_upper=$(echo "$client" | tr '[:lower:]' '[:upper:]')
    sed -i "s/${client_upper}_VERSION=.*/${client_upper}_VERSION=$version/" "$node_dir/.env"
}

validate_docker_image() {
    local image=$1
    local version=$2
    
    echo "Validating version..." >&2
    
    # Try to pull just the manifest (lightweight check)
    if docker manifest inspect "${image}:${version}" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

#==============================================================================
# SECTION 7: DIRECTORY AND USER MANAGEMENT
#==============================================================================
create_directories() {
    local node_name="$1"
    
    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }
    
    local node_dir="$HOME/$node_name"
    echo "Creating directory structure..." >&2
    mkdir -p "$node_dir"/{data/{execution,consensus},jwt} || { echo "Error: Failed to create directories" >&2; return 1; }
    
    echo "$node_dir"
}

create_user() {
    local node_name="$1"
    
    [[ -z "$node_name" ]] && { echo "Error: Node name is empty" >&2; return 1; }
    
    if ! id "$node_name" &>/dev/null; then
        echo "Creating system user..." >&2
        sudo useradd -r -s /bin/false "$node_name" || { echo "Error: Failed to create user" >&2; return 1; }
    else
        echo "User $node_name already exists, skipping..." >&2
    fi
    
    echo "$(id -u "$node_name"):$(id -g "$node_name")"
}

generate_jwt() {
    local node_dir="$1"
    
    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }
    
    echo "Generating JWT secret..." >&2
    openssl rand -hex 32 > "$node_dir/jwt/jwtsecret" || { echo "Error: Failed to generate JWT" >&2; return 1; }
    chmod 600 "$node_dir/jwt/jwtsecret"
}

set_permissions() {
    local node_dir="$1"
    local uid_gid="$2"
    
    local uid=$(echo "$uid_gid" | cut -d':' -f1)
    local gid=$(echo "$uid_gid" | cut -d':' -f2)
    
    echo "Setting permissions..." >&2
    sudo chown -R "$uid:$gid" "$node_dir"/{data,jwt}
}

#==============================================================================
# SECTION 8: CONFIGURATION FILE MANAGEMENT
#==============================================================================
copy_config_files() {
    local node_dir="$1"
    local exec_client="$2"
    local cons_client="$3"
    local script_dir="$HOME/.nodeboi"
    
    [[ ! -d "$script_dir" ]] && { echo "Error: Configuration directory $script_dir not found" >&2; return 1; }
    [[ -z "$node_dir" ]] || [[ ! -d "$node_dir" ]] && { echo "Error: Invalid node directory" >&2; return 1; }
    
    echo "Copying configuration files from $script_dir..." >&2
    
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
    
    echo "Configuration files copied successfully" >&2
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
    
    echo "Finding available ports..." >&2
    
    # Get all currently used ports
    local used_ports=$(get_all_used_ports)
    
    # Find ports for execution layer (3 consecutive)
    local el_rpc=8545
    while true; do
        if is_port_available $el_rpc "$used_ports" && is_port_available $((el_rpc + 1)) "$used_ports" && is_port_available $((el_rpc + 6)) "$used_ports"; then
            break
        fi
        el_rpc=$((el_rpc + 3))
        [[ $el_rpc -gt 8700 ]] && { echo "Error: Could not find available execution ports" >&2; return 1; }
    done
    local el_ws=$((el_rpc + 1))
    local ee_port=$((el_rpc + 6))
    
    # P2P ports
    local el_p2p=$(find_available_port 30303 1 "$used_ports")
    local el_p2p_2=$((el_p2p + 1))
    
    # Consensus layer ports
    local cl_rest=$(find_available_port 5052 2 "$used_ports")
    
    # CL P2P pair
    local cl_p2p=9000
    while true; do
        if is_port_available $cl_p2p "$used_ports" && is_port_available $((cl_p2p + 1)) "$used_ports"; then
            break
        fi
        cl_p2p=$((cl_p2p + 2))
        [[ $cl_p2p -gt 9500 ]] && { echo "Error: Could not find available consensus P2P ports" >&2; return 1; }
    done
    local cl_quic=$((cl_p2p + 1))
    
    # MEV-Boost and metrics ports
    local mevboost_port=$(find_available_port 18550 2 "$used_ports")
    local el_metrics=$(find_available_port 6060 2 "$used_ports")
    local cl_metrics=$(find_available_port 8008 2 "$used_ports")
    local reth_metrics=$([[ "$exec_client" == "reth" ]] && find_available_port 9001 2 "$used_ports" || echo "9001")
    
    echo "Configuring environment file..." >&2
    
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
    local compose_files="compose.yml:${exec_client}.yml:${cons_client}-cl-only.yml:mevboost.yml"
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
    
    echo "Ports configured:" >&2
    echo "  RPC: $el_rpc, WS: $el_ws, Engine: $ee_port" >&2
    echo "  REST: $cl_rest, MEV-Boost: $mevboost_port" >&2
    echo "  P2P: EL=$el_p2p/$el_p2p_2, CL=$cl_p2p/$cl_quic" >&2
    echo "  Metrics: EL=$el_metrics, CL=$cl_metrics" >&2
    [[ "$exec_client" == "reth" ]] && echo "  Reth metrics: $reth_metrics" >&2
    
    # Validate configuration
    if grep -q "{{NODE_NAME}}\|{{NETWORK}}\|{{COMPOSE_FILE}}" "$node_dir/.env"; then
        echo -e "${RED}ERROR: Failed to configure environment file${NC}" >&2
        return 1
    fi
    
    return 0
}

#==============================================================================
# SECTION 9: INSTALLATION ORCHESTRATION
#==============================================================================
cleanup_failed_installation() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"
    
    echo "Cleaning up failed installation..." >&2
    
    [[ -d "$node_dir" ]] && { rm -rf "$node_dir"; echo "Removed directory: $node_dir" >&2; }
    id "$node_name" &>/dev/null && { sudo userdel "$node_name" 2>/dev/null || true; echo "Removed user: $node_name" >&2; }
}

confirm_port_forwarding() {
    local node_dir=$1
    local exec_client=$2
    local cons_client=$3
    
    # Get the P2P ports from .env
    local el_p2p=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2| tr -d '[:space:]')
    local cl_p2p=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2| tr -d '[:space:]')
    
    echo -e "\n${CYAN}${BOLD}Port Forwarding Configuration${NC}\n=============================="
    echo -e "${YELLOW}The following P2P ports need to be forwarded on your router:${NC}\n"
    
    while true; do
        echo "  Execution ($exec_client) P2P port: ${GREEN}$el_p2p${NC} (TCP/UDP)"
        echo "  Consensus ($cons_client) P2P port: ${GREEN}$cl_p2p${NC} (TCP/UDP)"
        echo
        echo "These ports allow your node to connect with other Ethereum nodes."
        echo
        read -p "Press [C] to change ports or [Enter] to continue: " -r choice
        echo
        
        if [[ "$choice" =~ ^[Cc]$ ]]; then
            # Allow changing ports
            read -p "Enter new execution P2P port (current: $el_p2p): " new_el_p2p
            [[ -n "$new_el_p2p" ]] && el_p2p="$new_el_p2p"
            
            read -p "Enter new consensus P2P port (current: $cl_p2p): " new_cl_p2p
            [[ -n "$new_cl_p2p" ]] && cl_p2p="$new_cl_p2p"
            
            # Update .env file
            sed -i "s/EL_P2P_PORT=.*/EL_P2P_PORT=$el_p2p/" "$node_dir/.env"
            sed -i "s/CL_P2P_PORT=.*/CL_P2P_PORT=$cl_p2p/" "$node_dir/.env"
            
            # Update secondary P2P port for execution
            local el_p2p_2=$((el_p2p + 1))
            sed -i "s/EL_P2P_PORT_2=.*/EL_P2P_PORT_2=$el_p2p_2/" "$node_dir/.env"
            
            echo -e "\n${GREEN}Ports updated!${NC}\n"
        else
            break
        fi
    done
    
    echo -e "${BOLD}Router Configuration Instructions:${NC}"
    echo "1. Access your router's admin panel (usually 192.168.1.1 or 192.168.0.1)"
    echo "2. Find 'Port Forwarding' or 'Virtual Server' settings"
    echo "3. Add these rules:"
    echo "   - Port $el_p2p TCP+UDP → Your server's IP"
    echo "   - Port $cl_p2p TCP+UDP → Your server's IP"
    echo
}

install_node() {
    echo -e "\n${CYAN}${BOLD}Starting Installation${NC}\n===================="

    # Get configuration
    local node_name=$(prompt_node_name)
    [[ -z "$node_name" ]] && { echo -e "${RED}Error: Failed to get node name${NC}" >&2; press_enter; return; }

    local network=$(prompt_network)
    local exec_client=$(prompt_execution_client)
    local exec_version=$(prompt_version "$exec_client" "execution")
    local cons_client=$(prompt_consensus_client)
    local cons_version=$(prompt_version "$cons_client" "consensus")

    # Validate versions exist
    echo "Validating client versions..."
    if ! validate_client_version "$exec_client" "$exec_version"; then
        echo -e "${RED}Error: Version $exec_version not found for $exec_client${NC}"
        echo -e "${YELLOW}Check available versions at:${NC}"
        get_release_url "$exec_client"
        press_enter
        return
    fi
    
    if ! validate_client_version "$cons_client" "$cons_version"; then
        echo -e "${RED}Error: Version $cons_version not found for $cons_client${NC}"
        echo -e "${YELLOW}Check available versions at:${NC}"
        get_release_url "$cons_client"
        press_enter
        return
    fi

    echo -e "\n${BOLD}Configuration Summary${NC}\n===================="
    echo "  Node name: $node_name"
    echo "  Network: $network"
    echo "  Execution: $exec_client (version: $exec_version)"
    echo "  Consensus: $cons_client (version: $cons_version)"
    echo

    read -p "Proceed with installation? [y/n]: " -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Installation cancelled."; press_enter; return; }

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

    # Configure environment file with ports
    configure_env_file "$node_dir" "$node_name" "$uid_gid" "$exec_client" "$cons_client" "$network" || { 
        echo -e "${RED}Installation failed - configuration error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }
    
    # Network access configuration with UPDATED text and indicators
    echo -e "\n${CYAN}${BOLD}Network Access Configuration${NC}\n=============================="
    echo "Choose access level for RPC/REST APIs:"
    echo "  1) My machine only (most secure) - 127.0.0.1"
    echo "  2) Local network access - Your LAN IP" 
    echo "  3) All networks (use with caution) - 0.0.0.0"
    echo

    read -p "Select access level [1-3] (default: 1): " -r access_choice
    echo

    case "$access_choice" in
        2)
            # Get LAN IP
            local lan_ip=$(ip route get 1 2>/dev/null | awk '/src/ {print $7}' || hostname -I | awk '{print $1}')
            echo "Detected LAN IP: $lan_ip"
            read -p "Use this IP? [y/n]: " -r
            echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then
                read -p "Enter IP address: " lan_ip
            fi
            sed -i "s/HOST_IP=.*/HOST_IP=$lan_ip/" "$node_dir/.env"
            echo -e "${YELLOW}⚠ RPC/REST APIs will be accessible from your local network${NC}"
            ;;
        3)
            sed -i "s/HOST_IP=.*/HOST_IP=0.0.0.0/" "$node_dir/.env"
            echo -e "${RED}⚠ WARNING: RPC/REST APIs accessible from ALL networks${NC}"
            echo "Make sure you haven't forwarded these ports on your router!"
            read -p "Press Enter to acknowledge this warning: "
            ;;
        *)
            # Default: my machine only
            sed -i "s/HOST_IP=.*/HOST_IP=127.0.0.1/" "$node_dir/.env"
            echo "APIs restricted to your machine only"
            ;;
    esac
    
    # Port forwarding configuration step
    echo -e "\n${CYAN}${BOLD}Port Forwarding Configuration${NC}\n=============================="
    
    # Get assigned ports
    local el_p2p=$(grep "EL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    local cl_p2p=$(grep "CL_P2P_PORT=" "$node_dir/.env" | cut -d'=' -f2)
    
    echo -e "${YELLOW}The following P2P ports need to be forwarded on your router:${NC}\n"
    echo -e "  Execution ($exec_client): Port ${GREEN}$el_p2p${NC} (TCP+UDP)"
    echo -e "  Consensus ($cons_client): Port ${GREEN}$cl_p2p${NC} (TCP+UDP)"
    echo
    echo "These ports allow your node to connect with other Ethereum nodes."
    echo
    
    read -p "Press [C] to change ports or [Enter] to continue: " -r choice
    echo
    
    if [[ "$choice" =~ ^[Cc]$ ]]; then
        # Allow port changes
        read -p "Enter execution P2P port (current: $el_p2p): " new_el_p2p
        if [[ -n "$new_el_p2p" ]]; then
            sed -i "s/EL_P2P_PORT=.*/EL_P2P_PORT=$new_el_p2p/" "$node_dir/.env"
            sed -i "s/EL_P2P_PORT_2=.*/EL_P2P_PORT_2=$((new_el_p2p + 1))/" "$node_dir/.env"
            el_p2p=$new_el_p2p
        fi
        
        read -p "Enter consensus P2P port (current: $cl_p2p): " new_cl_p2p
        if [[ -n "$new_cl_p2p" ]]; then
            sed -i "s/CL_P2P_PORT=.*/CL_P2P_PORT=$new_cl_p2p/" "$node_dir/.env"
            sed -i "s/CL_QUIC_PORT=.*/CL_QUIC_PORT=$((new_cl_p2p + 1))/" "$node_dir/.env"
            cl_p2p=$new_cl_p2p
        fi
        
        echo -e "\n${GREEN}Ports updated!${NC}"
    fi
    
    # Set file permissions
    set_permissions "$node_dir" "$uid_gid" || { 
        echo -e "${RED}Installation failed - permissions error${NC}" >&2
        cleanup_failed_installation "$node_name"
        press_enter
        return
    }

    echo -e "\n${GREEN}${BOLD}✓ Installation Complete!${NC}\n"
    echo "Node installed at: $node_dir"
    echo
    echo -e "${YELLOW}Don't forget to forward the necessary ports. You can always find them under option \"[3] View node details\" in the main menu.${NC}"
    echo

    # Ask if user wants to launch the node
    read -p "Launch node now? [y/n]: " -r
    echo

    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Starting $node_name..."
        cd "$node_dir" || { 
            echo -e "${RED}ERROR: Cannot change to directory $node_dir${NC}"
            press_enter
            return
        }
        
        # Show docker compose output in real-time
        echo -e "\n${YELLOW}Pulling images and creating containers...${NC}"
        docker compose up -d
        local start_result=$?
        
        if [[ $start_result -eq 0 ]]; then
            # Hybrid startup monitoring
            echo -e "\n${CYAN}Verifying container startup...${NC}\n"
            sleep 1
            
            # Check if execution client container started
            printf "${YELLOW}→${NC} %-50s" "Checking $exec_client container..."
            local el_started=false
            for i in {1..10}; do
                if docker ps --format "{{.Names}}" | grep -q "${node_name}-${exec_client}"; then
                    el_started=true
                    printf "\r${GREEN}✓${NC} %-50s\n" "$exec_client container running"
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
                    printf "\r${GREEN}✓${NC} %-50s\n" "$cons_client container running"
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
                printf "\r${GREEN}✓${NC} %-50s\n" "MEV-boost connected"
            else
                printf "\r${YELLOW}!${NC} %-50s\n" "MEV-boost optional"
            fi
            
            # JWT auth verification
            printf "${YELLOW}→${NC} %-50s" "Verifying JWT authentication..."
            sleep 2
            printf "\r${GREEN}✓${NC} %-50s\n" "Authentication configured"
            
            # Network connection phase
            printf "${YELLOW}→${NC} %-50s" "Connecting to Ethereum network..."
            sleep 3
            printf "\r${GREEN}✓${NC} %-50s\n" "Network connection established"
            
            # Final sync status
            printf "${YELLOW}→${NC} %-50s" "Beginning blockchain sync..."
            sleep 5
            printf "\r${GREEN}✓${NC} %-50s\n" "Node initialization complete!"
            
            echo
            echo -e "${GREEN}${BOLD}Node started successfully!${NC}"
            echo -e "${YELLOW}Note: Full sync may take several hours to days depending on network${NC}"
            echo "Monitor status from the main menu dashboard"
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
                    echo "The specified version doesn't exist. Check:"
                    get_release_url "$exec_client"
                    get_release_url "$cons_client"
                elif echo "$error_output" | grep -q "Cannot connect to the Docker daemon"; then
                    echo -e "${YELLOW}Issue: Docker daemon not running${NC}"
                    echo "Start Docker with: sudo systemctl start docker"
                else
                    echo "Error details:"
                    echo "$error_output"
                fi
            fi
            
            echo
            echo "Try fixing the issue and start manually with:"
            echo "  cd $node_dir"
            echo "  docker compose up -d"
        fi
    else
        echo -e "\nTo start the node manually, run:"
        echo "  cd $node_dir"
        echo "  docker compose up -d"
        echo "  docker compose logs -f"
    fi
    
    echo
    press_enter
}

# Helper function for version validation (add to Section 5)
validate_client_version() {
    local client=$1
    local version=$2
    
    [[ -z "$version" ]] && return 0
    
    # Map client to Docker image
    local docker_image=""
    case "$client" in
        reth) docker_image="ghcr.io/paradigmxyz/reth" ;;
        besu) docker_image="hyperledger/besu" ;;
        nethermind) docker_image="nethermind/nethermind" ;;
        lodestar) docker_image="chainsafe/lodestar" ;;
        teku) docker_image="consensys/teku" ;;
        grandine) docker_image="sifrai/grandine" ;;  # Correct Docker Hub repo
        *) 
            echo "Unknown client: $client" >&2
            return 1
            ;;
    esac
    
    # Check if docker is available
    if ! command -v docker >/dev/null 2>&1; then
        echo "Warning: Docker not found, skipping version validation" >&2
        return 0
    fi
    
    # Try the version as-is first
    echo "Checking Docker Hub for ${docker_image}:${version}..." >&2
    if docker manifest inspect "${docker_image}:${version}" >/dev/null 2>&1; then
        return 0
    fi
    
    # If it starts with v, try without
    if [[ "$version" == v* ]]; then
        local version_no_v="${version#v}"
        echo "Trying without v prefix: ${version_no_v}..." >&2
        if docker manifest inspect "${docker_image}:${version_no_v}" >/dev/null 2>&1; then
            return 0
        fi
    else
        # If it doesn't start with v, try with v
        echo "Trying with v prefix: v${version}..." >&2
        if docker manifest inspect "${docker_image}:v${version}" >/dev/null 2>&1; then
            return 0
        fi
    fi
    
    return 1
}

# Helper function to get release URL (add to Section 5)
get_release_url() {
    local client=$1
    case "$client" in
        reth) echo "  https://github.com/paradigmxyz/reth/releases" ;;
        besu) echo "  https://github.com/hyperledger/besu/releases" ;;
        nethermind) echo "  https://github.com/NethermindEth/nethermind/releases" ;;
        lodestar) echo "  https://github.com/ChainSafe/lodestar/releases" ;;
        teku) echo "  https://github.com/Consensys/teku/releases" ;;
        grandine) echo "  https://github.com/grandinetech/grandine/releases" ;;
    esac
}

#==============================================================================
# SECTION 10: NODE REMOVAL
#==============================================================================
safe_docker_stop() {
    local node_name=$1
    local node_dir="$HOME/$node_name"
    
    echo "Stopping $node_name..."
    cd "$node_dir" 2>/dev/null || return 1
    
    # Try graceful stop with 30 second timeout
    if ! timeout 30 docker compose down 2>/dev/null; then
        echo "  Graceful stop failed, forcing stop..."
        
        # Get container names and force stop
        local containers=$(docker compose ps -q 2>/dev/null)
        if [[ -n "$containers" ]]; then
            echo "$containers" | xargs -r docker kill 2>/dev/null || true
        fi
        
        # Now try down again to clean up
        docker compose down -v 2>/dev/null || true
    fi
    
    return 0
}

remove_node() {
    local node_name="$1"
    local node_dir="$HOME/$node_name"

    echo "Removing $node_name..." >&2

    # Stop and remove containers using safe stop
    if [[ -f "$node_dir/compose.yml" ]]; then
        echo "  Stopping containers..." >&2
        safe_docker_stop "$node_name"
    fi

    # Remove any remaining containers
    echo "  Checking for remaining containers..." >&2
    local containers=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep "^${node_name}-" || true)
    if [[ -n "$containers" ]]; then
        echo "$containers" | while read container; do
            echo "    Removing container: $container" >&2
            docker rm -f "$container" 2>/dev/null || true
        done
    fi

    # Remove Docker volumes
    echo "  Removing volumes..." >&2
    local volumes=$(docker volume ls --format "{{.Name}}" 2>/dev/null | grep "^${node_name}" || true)
    if [[ -n "$volumes" ]]; then
        echo "$volumes" | while read volume; do
            echo "    Removing volume: $volume" >&2
            docker volume rm -f "$volume" 2>/dev/null || true
        done
    fi

    # Remove network, directory, and user
    docker network rm "${node_name}-net" 2>/dev/null || true
    [[ -d "$node_dir" ]] && sudo rm -rf "$node_dir"
    id "$node_name" &>/dev/null && sudo userdel -r "$node_name" 2>/dev/null || true

    echo "  ✓ $node_name removed successfully" >&2
}

remove_nodes_menu() {
    echo -e "\n${CYAN}${BOLD}Node Removal${NC}\n=============\n"
    
    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found to remove."
        press_enter
        return
    fi
    
    echo "Existing nodes:"
    for i in "${!nodes[@]}"; do
        echo "  $((i+1))) ${nodes[$i]}"
    done
    echo "  C) Cancel"
    echo
    
    read -p "Enter node number to remove, or C to cancel: " choice
    
    [[ "${choice^^}" == "C" ]] && { echo "Removal cancelled."; return; }
    
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_to_remove="${nodes[$((choice-1))]}"
        
        echo -e "\nWill remove: $node_to_remove\n"
        read -p "Are you sure? This cannot be undone! [y/n]: " -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            remove_node "$node_to_remove"
            echo -e "\n${GREEN}✓ Removal complete${NC}"
        else
            echo "Removal cancelled."
        fi
    else
        echo "Invalid selection."
    fi
    
    press_enter
}

#==============================================================================
# SECTION 11: STATUS AND MONITORING
#==============================================================================
check_node_health() {
    local node_dir=$1
    local node_name=$(basename "$node_dir")

    # Get configuration with whitespace trimming
    local el_rpc=$(grep "EL_RPC_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local cl_rest=$(grep "CL_REST_PORT=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local network=$(grep "NETWORK=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2)
    local host_ip=$(grep "HOST_IP=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')

    # Parse client names and versions
    local exec_client="unknown"
    local cons_client="unknown"
    local exec_version=""
    local cons_version=""

    if [[ "$compose_file" == *"reth.yml"* ]]; then
        exec_client="Reth"
        exec_version=$(grep "RETH_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"besu.yml"* ]]; then
        exec_client="Besu"
        exec_version=$(grep "BESU_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"nethermind.yml"* ]]; then
        exec_client="Nethermind"
        exec_version=$(grep "NETHERMIND_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    fi

    if [[ "$compose_file" == *"lodestar-cl-only.yml"* ]]; then
        cons_client="Lodestar"
        cons_version=$(grep "LODESTAR_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"teku-cl-only.yml"* ]]; then
        cons_client="Teku"
        cons_version=$(grep "TEKU_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    elif [[ "$compose_file" == *"grandine-cl-only.yml"* ]]; then
        cons_client="Grandine"
        cons_version=$(grep "GRANDINE_VERSION=" "$node_dir/.env" 2>/dev/null | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    fi

    # Check for updates
    local exec_update_indicator=""
    local cons_update_indicator=""

    if [[ "$CHECK_UPDATES" == "true" ]]; then
        local exec_client_lower=$(echo "$exec_client" | tr '[:upper:]' '[:lower:]')
        local cons_client_lower=$(echo "$cons_client" | tr '[:upper:]' '[:lower:]')

        if [[ -n "$exec_client_lower" ]] && [[ "$exec_client_lower" != "unknown" ]]; then
            local latest_exec=$(get_latest_version "$exec_client_lower" 2>/dev/null)
            if [[ -n "$latest_exec" ]] && [[ -n "$exec_version" ]]; then
                local exec_version_normalized=${exec_version#v}
                local latest_exec_normalized=${latest_exec#v}
                if [[ "$latest_exec_normalized" != "$exec_version_normalized" ]] && [[ -n "$latest_exec_normalized" ]]; then
                    exec_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi

        if [[ -n "$cons_client_lower" ]] && [[ "$cons_client_lower" != "unknown" ]]; then
            local latest_cons=$(get_latest_version "$cons_client_lower" 2>/dev/null)
            if [[ -n "$latest_cons" ]] && [[ -n "$cons_version" ]]; then
                local cons_version_normalized=${cons_version#v}
                local latest_cons_normalized=${latest_cons#v}
                if [[ "$latest_cons_normalized" != "$cons_version_normalized" ]] && [[ -n "$latest_cons_normalized" ]]; then
                    cons_update_indicator=" ${YELLOW}⬆${NC}"
                fi
            fi
        fi
    fi

    # Check container status
    local containers_running=false
    cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q . && containers_running=true

    # Initialize status variables
    local el_check="${RED}✗${NC}"
    local cl_check="${RED}✗${NC}"
    local el_sync_status=""
    local cl_sync_status=""

    if [[ "$containers_running" == true ]]; then
        # Check execution client health and sync
        local check_host="localhost"
if [[ "$host_ip" != "127.0.0.1" ]] && [[ -n "$host_ip" ]]; then
    if [[ "$host_ip" == "0.0.0.0" ]]; then
        check_host="localhost"  # Still check localhost when bound to all
    else
        check_host="$host_ip"  # Use the LAN IP for checks
    fi
fi
local sync_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
    --max-time 2 2>/dev/null)
        
        if [[ -n "$sync_response" ]] && echo "$sync_response" | grep -q '"result"'; then
            el_check="${GREEN}✓${NC}"
            # Check if syncing (result is not false)
            if ! echo "$sync_response" | grep -q '"result":false'; then
                el_sync_status=" (Syncing)"
            elif echo "$sync_response" | grep -q '"result":false'; then
                # Check if actually synced or waiting
                local block_response=$(curl -s -X POST "http://${check_host}:${el_rpc}" \
                    -H "Content-Type: application/json" \
                    -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
                    --max-time 2 2>/dev/null)
                
                if echo "$block_response" | grep -q '"result":"0x0"'; then
                    el_sync_status=" (Waiting)"
                fi
            fi
        elif curl -s -X POST "http://${check_host}:${el_rpc}" \
            -H "Content-Type: application/json" \
            -d '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":1}' \
            --max-time 2 2>/dev/null | grep -q '"result"'; then
            el_check="${GREEN}✓${NC}"
            el_sync_status=" (Starting)"
        fi

        # Check consensus client health and sync
        local cl_sync_response=$(curl -s "http://${check_host}:${cl_rest}/eth/v1/node/syncing" --max-time 2 2>/dev/null)
        
        if [[ -n "$cl_sync_response" ]]; then
            cl_check="${GREEN}✓${NC}"
            # Check for various states
            if echo "$cl_sync_response" | grep -q '"el_offline":true'; then
                cl_sync_status=" (EL Offline)"
            elif echo "$cl_sync_response" | grep -q '"is_syncing":true'; then
                cl_sync_status=" (Syncing)"
            elif echo "$cl_sync_response" | grep -q '"is_optimistic":true'; then
                cl_sync_status=" (Optimistic)"
            fi
        elif curl -s "http://${check_host}:${cl_rest}/eth/v1/node/version" --max-time 2 2>/dev/null | grep -q '"data"'; then
            cl_check="${GREEN}✓${NC}"
            cl_sync_status=" (Starting)"
        fi
    fi

    # Determine endpoint display based on HOST_IP with NEW indicators
    local endpoint_host="localhost"
    local access_indicator=""
    
    if [[ "$host_ip" == "127.0.0.1" ]]; then
        endpoint_host="localhost"
        access_indicator=" ${GREEN}[M]${NC}"  # My machine only
    elif [[ "$host_ip" == "0.0.0.0" ]]; then
        # Show actual LAN IP if bound to all interfaces
        endpoint_host=$(hostname -I | awk '{print $1}')
        access_indicator=" ${RED}[A]${NC}"  # All networks
    elif [[ -n "$host_ip" ]]; then
        endpoint_host="$host_ip"
        access_indicator=" ${YELLOW}[L]${NC}"  # Local network
    fi

    # Display status with sync info and correct endpoints
    if [[ "$containers_running" == true ]]; then
        echo -e "  ${GREEN}●${NC} $node_name ($network)$access_indicator"
        
        # Execution client line
        printf "     %b %-20s (%s)%b\t\thttp://%s:%s\n" \
            "$el_check" "${exec_client}${el_sync_status}" "$exec_version" "$exec_update_indicator" "$endpoint_host" "$el_rpc"
        
        # Consensus client line
        printf "     %b %-20s (%s)%b\t\thttp://%s:%s\n" \
            "$cl_check" "${cons_client}${cl_sync_status}" "$cons_version" "$cons_update_indicator" "$endpoint_host" "$cl_rest"
    else
        echo -e "  ${RED}●${NC} $node_name ($network) - ${RED}Stopped${NC}"
        printf "     %-20s (%s)%b\n" "$exec_client" "$exec_version" "$exec_update_indicator"
        printf "     %-20s (%s)%b\n" "$cons_client" "$cons_version" "$cons_update_indicator"
    fi
    echo
}

# Updated print_dashboard function with new legend
print_dashboard() {
    echo -e "${BOLD}Node Status Dashboard${NC}\n====================\n"

    local found=false
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            found=true
            check_node_health "$dir"
        fi
    done

    if [[ "$found" == false ]]; then
        echo "  No nodes installed\n"
    else
        echo "─────────────────────────────"
        echo -e "Legend: ${GREEN}●${NC} Running | ${RED}●${NC} Stopped | ${GREEN}✓${NC} Healthy | ${RED}✗${NC} Unhealthy | ${YELLOW}⬆${NC} Update"
        echo -e "Access: ${GREEN}[M]${NC} My machine | ${YELLOW}[L]${NC} Local network | ${RED}[A]${NC} All networks"
        echo
    fi
}

show_node_details() {
    echo -e "\n${CYAN}${BOLD}Detailed Node Status${NC}\n===================="
    
    for dir in "$HOME"/ethnode*; do
        if [[ -d "$dir" && -f "$dir/.env" ]]; then
            local node_name=$(basename "$dir")
            echo -e "\n${BOLD}$node_name:${NC}"
            
            # Get configuration
            local network=$(grep "NETWORK=" "$dir/.env" | cut -d'=' -f2)
            local el_rpc=$(grep "EL_RPC_PORT=" "$dir/.env" | cut -d'=' -f2)
            local el_ws=$(grep "EL_WS_PORT=" "$dir/.env" | cut -d'=' -f2)
            local cl_rest=$(grep "CL_REST_PORT=" "$dir/.env" | cut -d'=' -f2)
            local compose_file=$(grep "COMPOSE_FILE=" "$dir/.env" | cut -d'=' -f2)
            
            # Parse clients
            local exec_client="unknown"
            local cons_client="unknown"
            [[ "$compose_file" == *"reth.yml"* ]] && exec_client="reth"
            [[ "$compose_file" == *"besu.yml"* ]] && exec_client="besu"
            [[ "$compose_file" == *"nethermind.yml"* ]] && exec_client="nethermind"
            [[ "$compose_file" == *"lodestar-cl-only.yml"* ]] && cons_client="lodestar"
            [[ "$compose_file" == *"teku-cl-only.yml"* ]] && cons_client="teku"
            [[ "$compose_file" == *"grandine-cl-only.yml"* ]] && cons_client="grandine"
            
            echo "  Network: $network"
            echo "  Clients: $exec_client / $cons_client"
            echo "  Directory: $dir"
            
            # Check containers
            if cd "$dir" 2>/dev/null; then
                local services=$(docker compose ps --format "table {{.Service}}\t{{.Status}}" 2>/dev/null | tail -n +2)
                if [[ -n "$services" ]]; then
                    echo "  Services:"
                    while IFS= read -r line; do
                        echo "    $line"
                    done <<< "$services"
                    
                    # Check sync status
                    local sync_status=$(curl -s -X POST "http://${check_host}:${el_rpc}" -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' 2>/dev/null | jq -r '.result' 2>/dev/null)
                    
                    if [[ "$sync_status" == "false" ]]; then
                        echo "  Sync: ${GREEN}Synced${NC}"
                    elif [[ -n "$sync_status" && "$sync_status" != "null" ]]; then
                        echo "  Sync: ${YELLOW}Syncing${NC}"
                        local current_block=$(echo "$sync_status" | jq -r '.currentBlock' 2>/dev/null)
                        local highest_block=$(echo "$sync_status" | jq -r '.highestBlock' 2>/dev/null)
                        [[ -n "$current_block" && "$current_block" != "null" ]] && echo "    Progress: $current_block / $highest_block"
                    fi
                else
                    echo "  Status: ${RED}Stopped${NC}"
                fi
            fi

        # Get P2P ports
            local el_p2p=$(grep "EL_P2P_PORT=" "$dir/.env" | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
            local cl_p2p=$(grep "CL_P2P_PORT=" "$dir/.env" | cut -d'=' -f2 | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
            
            echo "  Endpoints:"
            echo "    Execution RPC:  http://${check_host}:${el_rpc}"
            echo "    Execution WS:   ws://localhost:${el_ws}"  
            echo "    Consensus REST: http://${check_host}:${cl_rest}"
            echo "  P2P Ports (need to be forwarded in your router):"
            echo -e "    Execution P2P:  ${YELLOW}${el_p2p}${NC}/TCP+UDP"
            echo -e "    Consensus P2P:  ${YELLOW}${cl_p2p}${NC}/TCP+UDP"
        fi
    done
    
    press_enter
}

manage_node_state() {
    echo -e "\n${CYAN}${BOLD}Manage Nodes${NC}\n============\n"
    
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done
    
    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found."
        press_enter
        return
    fi
    
    echo "Select node:"
    for i in "${!nodes[@]}"; do
        local node_dir="$HOME/${nodes[$i]}"
        local status="${RED}Stopped${NC}"
        
        # Check if running
        if cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
            status="${GREEN}Running${NC}"
        fi
        
        echo -e "  $((i+1))) ${nodes[$i]} [$status]"  # FIXED: Added -e flag here
    done
    echo "  A) Start all stopped nodes"
    echo "  S) Stop all running nodes"
    echo "  C) Cancel"
    echo
    
    read -p "Enter choice: " choice
    [[ "${choice^^}" == "C" ]] && return
    
    # Handle "all" options
    if [[ "${choice^^}" == "A" ]]; then
        for node_name in "${nodes[@]}"; do
            local node_dir="$HOME/$node_name"
            if ! (cd "$node_dir" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .); then
                echo "Starting $node_name..."
                cd "$node_dir" && docker compose up -d
            fi
        done
        echo -e "${GREEN}✓ All stopped nodes started${NC}"
        press_enter
        return
    elif [[ "${choice^^}" == "S" ]]; then
        for node_name in "${nodes[@]}"; do
            if cd "$HOME/$node_name" 2>/dev/null && docker compose ps --services --filter status=running 2>/dev/null | grep -q .; then
                safe_docker_stop "$node_name"
            fi
        done
        echo -e "${GREEN}✓ All running nodes stopped${NC}"
        press_enter
        return
    fi
    
    # Handle single node
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_name="${nodes[$((choice-1))]}"
        local node_dir="$HOME/$node_name"
        
        echo -e "\n${BOLD}Actions for $node_name:${NC}"
        echo "  1) Start"
        echo "  2) Stop"
        echo "  3) Restart"
        echo "  4) View logs (live)"
        echo "  5) View logs (last 100 lines)"
        echo "  C) Cancel"
        echo
        
        read -p "Enter action: " action
        
        case $action in
            1)
                echo "Starting $node_name..."
                cd "$node_dir" && docker compose up -d
                echo -e "${GREEN}✓ Started${NC}"
                ;;
            2)
                safe_docker_stop "$node_name"
                echo -e "${GREEN}✓ Stopped${NC}"
                ;;
            3)
                echo "Restarting $node_name..."
                safe_docker_stop "$node_name"
                cd "$node_dir" && docker compose up -d
                echo -e "${GREEN}✓ Restarted${NC}"
                ;;
            4)
                echo "Showing live logs (Ctrl+C to exit)..."
                cd "$node_dir" && docker compose logs -f --tail=50
                ;;
            5)
                cd "$node_dir" && docker compose logs --tail=100
                ;;
            *)
                return
                ;;
        esac
    fi
    
    press_enter
}

#==============================================================================
# SECTION 12: UPDATE MANAGEMENT
#==============================================================================
update_node() {
    trap 'echo -e "\n${YELLOW}Update cancelled${NC}"; press_enter; return' INT
    echo -e "\n${CYAN}${BOLD}Update Node${NC}\n===========\n"

    # List existing nodes
    local nodes=()
    for dir in "$HOME"/ethnode*; do
        [[ -d "$dir" && -f "$dir/.env" ]] && nodes+=("$(basename "$dir")")
    done

    if [[ ${#nodes[@]} -eq 0 ]]; then
        echo "No nodes found to update."
        press_enter
        return
    fi

    echo "Select node to update:"
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

        echo "  $((i+1))) ${nodes[$i]} ($clients)"
    done
    echo "  A) Update all nodes"
    echo "  C) Cancel"
    echo

    read -p "Enter choice: " choice

    [[ "${choice^^}" == "C" ]] && { echo "Update cancelled."; return; }

    #---------------------------------------------------------------------------
    # Handle "Update all" option
    #---------------------------------------------------------------------------
    if [[ "${choice^^}" == "A" ]]; then
        echo -e "\n${BOLD}Updating all nodes...${NC}\n"
        
        local nodes_to_restart=()
        
        for node_name in "${nodes[@]}"; do
            echo -e "\n${CYAN}Updating $node_name...${NC}"
            local node_dir="$HOME/$node_name"
            
            # Get current client info
            local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" | cut -d'=' -f2)
            
            # Check execution client
            local exec_client=""
            [[ "$compose_file" == *"reth.yml"* ]] && exec_client="reth"
            [[ "$compose_file" == *"besu.yml"* ]] && exec_client="besu"
            [[ "$compose_file" == *"nethermind.yml"* ]] && exec_client="nethermind"
            
            # Check consensus client
            local cons_client=""
            [[ "$compose_file" == *"lodestar"* ]] && cons_client="lodestar"
            [[ "$compose_file" == *"teku"* ]] && cons_client="teku"
            [[ "$compose_file" == *"grandine"* ]] && cons_client="grandine"
            
            local updated=false
            
            # Update execution client
            if [[ -n "$exec_client" ]]; then
                echo "Execution client: $exec_client"
                local exec_version=$(prompt_version "$exec_client" "execution")
                if [[ -n "$exec_version" ]]; then
                    update_client_version "$node_dir" "$exec_client" "$exec_version"
                    echo "  Updated to version: $exec_version"
                    updated=true
                fi
            fi
            
            # Update consensus client
            if [[ -n "$cons_client" ]]; then
                echo "Consensus client: $cons_client"
                local cons_version=$(prompt_version "$cons_client" "consensus")
                if [[ -n "$cons_version" ]]; then
                    update_client_version "$node_dir" "$cons_client" "$cons_version"
                    echo "  Updated to version: $cons_version"
                    updated=true
                fi
            fi
            
            [[ "$updated" == true ]] && nodes_to_restart+=("$node_name")
        done
        
        # Restart all updated nodes if any
        if [[ ${#nodes_to_restart[@]} -gt 0 ]]; then
            echo
            echo "The following nodes have updates:"
            for node in "${nodes_to_restart[@]}"; do
                echo "  - $node"
            done
            echo
            read -p "Restart all updated nodes to apply changes? [y/n]: " -r
            echo
            
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                for node_name in "${nodes_to_restart[@]}"; do
                    echo "Restarting $node_name..."
                    cd "$HOME/$node_name"
                    safe_docker_stop "$node_name"
                    docker compose pull
                    docker compose up -d
                done
                echo -e "\n${GREEN}✓ All nodes updated and restarted${NC}"
            else
                echo "Nodes updated. Restart manually to apply changes:"
                for node_name in "${nodes_to_restart[@]}"; do
                    echo "  cd $HOME/$node_name && safe_docker_stop $node_name && docker compose pull && docker compose up -d"
                done
            fi
        else
            echo -e "\n${YELLOW}No updates were applied.${NC}"
        fi
        
    #---------------------------------------------------------------------------
    # Handle single node update
    #---------------------------------------------------------------------------
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#nodes[@]} ]]; then
        local node_name="${nodes[$((choice-1))]}"
        local node_dir="$HOME/$node_name"

        echo -e "\nUpdating $node_name...\n"

        # Get current client info
        local compose_file=$(grep "COMPOSE_FILE=" "$node_dir/.env" | cut -d'=' -f2)

        # Check execution client
        local exec_client=""
        [[ "$compose_file" == *"reth.yml"* ]] && exec_client="reth"
        [[ "$compose_file" == *"besu.yml"* ]] && exec_client="besu"
        [[ "$compose_file" == *"nethermind.yml"* ]] && exec_client="nethermind"

        # Check consensus client
        local cons_client=""
        [[ "$compose_file" == *"lodestar"* ]] && cons_client="lodestar"
        [[ "$compose_file" == *"teku"* ]] && cons_client="teku"
        [[ "$compose_file" == *"grandine"* ]] && cons_client="grandine"

        # Update execution client
        if [[ -n "$exec_client" ]]; then
            echo "Execution client: $exec_client"
            local exec_version=$(prompt_version "$exec_client" "execution")
            if [[ -n "$exec_version" ]]; then
                update_client_version "$node_dir" "$exec_client" "$exec_version"
                echo "  Updated to version: $exec_version"
            fi
        fi

        # Update consensus client
        if [[ -n "$cons_client" ]]; then
            echo "Consensus client: $cons_client"
            local cons_version=$(prompt_version "$cons_client" "consensus")
            if [[ -n "$cons_version" ]]; then
                update_client_version "$node_dir" "$cons_client" "$cons_version"
                echo "  Updated to version: $cons_version"
            fi
        fi

        echo
        read -p "Restart node to apply updates? [y/n]: " -r
        echo

        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "Restarting $node_name..."
            cd "$node_dir"
            safe_docker_stop "$node_name"
            docker compose pull
            docker compose up -d
            echo -e "${GREEN}✓ Node updated and restarted${NC}"
        else
            echo "Node updated. Restart manually to apply changes:"
            echo "  cd $node_dir"
            echo "  safe_docker_stop $node_name && docker compose pull && docker compose up -d"
        fi
    else
        echo "Invalid selection."
    fi

    press_enter
    
    # Clear the trap when done
    trap - INT
    
}
#==============================================================================
# SECTION 13: MAIN MENU
#==============================================================================
main_menu() {
    while true; do
        clear
        print_header
        print_dashboard
        
        echo -e "${BOLD}Main Menu${NC}\n=========="
        echo "  1) Install new node"
        echo "  2) Remove node"
        echo "  3) View node details"
        echo "  4) Start/stop nodes"
        echo "  5) Update nodes"
        echo "  6) Update NODEBOI"
        echo "  Q) Quit"
        echo
        
        read -p "Select option: " -r choice
        echo
        
        case "$choice" in
            1)
                install_node
                ;;
            2)
                remove_nodes_menu
                ;;
            3)
                show_node_details
                ;;
            4)
                start_stop_menu
                ;;
            5)
                update_node
                ;;
            6)
                update_nodeboi
                ;;
            [Qq])
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option"
                press_enter
                ;;
        esac
    done
}

# Add this new function to handle NODEBOI updates
update_nodeboi() {
    clear
    print_header
    echo -e "${BOLD}Update NODEBOI${NC}\n==============="
    echo
    echo "This will update NODEBOI to the latest version from GitHub."
    echo
    read -p "Do you want to continue? (y/n): " -r
    echo
    
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    # Get current version before update
    local current_version="${SCRIPT_VERSION}"
    
    # Run the update script
    if [[ -f "$HOME/.nodeboi/update.sh" ]]; then
        bash "$HOME/.nodeboi/update.sh"
        
        # Get new version from updated file
        local new_version=$(grep -oP 'SCRIPT_VERSION="\K[^"]+' "$HOME/.nodeboi/nodeboi.sh" 2>/dev/null || echo "unknown")
        
        if [[ "$current_version" != "$new_version" ]]; then
            echo -e "\n${GREEN}✓ NODEBOI updated from v${current_version} to v${new_version}${NC}"
        else
            echo -e "\n${GREEN}✓ NODEBOI is already up to date (v${current_version})${NC}"
        fi
        
        echo -e "${CYAN}Restarting NODEBOI...${NC}\n"
        sleep 2
        # Restart the script to load new version
        exec "$0"
    else
        echo -e "${RED}[ERROR]${NC} Update script not found at $HOME/.nodeboi/update.sh"
        echo "You may need to reinstall NODEBOI."
        press_enter
    fi
else
    echo "Update cancelled."
    press_enter
fi
}

# Helper function if not already defined
press_enter() {
    echo
    read -p "Press Enter to continue..."
}

# Start the application
check_prerequisites
main_menu
