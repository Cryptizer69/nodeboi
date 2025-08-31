#!/bin/bash
# NODEBOI Core Functions

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# ASCII art header
print_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
    ███╗   ██╗ ██████╗ ██████╗ ███████╗██████╗  ██████╗ ██╗
    ████╗  ██║██╔═══██╗██╔══██╗██╔════╝██╔══██╗██╔═══██╗██║
    ██╔██╗ ██║██║   ██║██║  ██║█████╗  ██████╔╝██║   ██║██║
    ██║╚██╗██║██║   ██║██║  ██║██╔══╝  ██╔══██╗██║   ██║██║
    ██║ ╚████║╚██████╔╝██████╔╝███████╗██████╔╝╚██████╔╝██║
    ╚═╝  ╚═══╝ ╚═════╝ ╚═════╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
                                                            
      ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
     ░░░░░░░░░░░░░░░ ETHEREUM NODE AUTOMATION ░░░░░░░░░░░░░░░
      ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
                            Version 1.0.0                  
                        Multi-Instance Manager              
EOF
    echo -e "${NC}"
    echo
}

# Progress animation with timing
show_working() {
    local message="$1"
    local work_time="${2:-2}"
    
    echo -n -e "${BLUE}⚡${NC} $message"
    
    local i=0
    local spin='-\|/'
    while [ $i -lt $(($work_time * 4)) ]; do
        i=$(( (i+1) %4 ))
        printf "\r${BLUE}⚡${NC} $message ${spin:$i:1}"
        sleep 0.25
    done
    
    printf "\r${GREEN}✓${NC} $message... Complete\n"
    echo
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking system prerequisites"
    
    local missing_tools=()
    
    echo "  Checking required tools..."
    for tool in docker docker-compose wget curl openssl ufw; do
        echo -n "    $tool: "
        if command -v "$tool" &> /dev/null; then
            echo -e "${GREEN}found${NC}"
        else
            echo -e "${RED}missing${NC}"
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing tools: ${missing_tools[*]}"
        echo
        echo -e "${YELLOW}Installation commands:${NC}"
        echo "Ubuntu/Debian: sudo apt update && sudo apt install -y docker.io docker-compose wget curl openssl ufw"
        echo "CentOS/RHEL: sudo yum install -y docker docker-compose wget curl openssl firewalld"
        exit 1
    fi
    
    # Check Docker daemon
    echo "  Checking Docker daemon..."
    if docker ps &> /dev/null; then
        echo -e "    Docker: ${GREEN}running${NC}"
    else
        log_error "Docker daemon not running or permission denied"
        echo
        echo -e "${YELLOW}Troubleshooting:${NC}"
        echo "1. Start Docker: sudo systemctl start docker"
        echo "2. Add user to docker group: sudo usermod -aG docker $USER"
        echo "3. Logout and login again"
        exit 1
    fi
    
    echo -e "${GREEN}✓${NC} System prerequisites satisfied"
}

# Get next instance number
get_next_instance_number() {
    local num=1
    while [[ -d "$HOME/ethnode${num}" ]]; do
        ((num++))
    done
    echo $num
}

# Get latest client version
get_latest_version() {
    local client="$1"
    
    case "$client" in
        "reth") echo "v1.6.0" ;;
        "besu") echo "25.7.0" ;;
        "nethermind") echo "v1.32.4" ;;
        "lodestar") echo "v1.33.0" ;;
        "teku") echo "25.7.1" ;;
        "grandine") echo "1.1.4" ;;
        *) echo "latest" ;;
    esac
}

# Create convenience scripts
create_convenience_scripts() {
    local node_dir="$1"
    local node_name="$2"
    
    # Create start script
    cat > "$node_dir/start.sh" << EOF
#!/bin/bash
cd "$node_dir"
docker compose up -d
echo "Node $node_name started. Check logs with: docker compose logs -f"
EOF
    chmod +x "$node_dir/start.sh"
    
    # Create stop script
    cat > "$node_dir/stop.sh" << EOF
#!/bin/bash
cd "$node_dir"
docker compose down
echo "Node $node_name stopped."
EOF
    chmod +x "$node_dir/stop.sh"
}
