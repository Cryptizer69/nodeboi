#!/bin/bash
# Quick access script to the new network management interface

# Set up environment
NODEBOI_LIB="/home/floris/.nodeboi/lib"

# Source all required libraries
source "$NODEBOI_LIB/ui.sh"
source "$NODEBOI_LIB/manage.sh" 2>/dev/null
source "$NODEBOI_LIB/clients.sh" 2>/dev/null
source "$NODEBOI_LIB/monitoring.sh"

# Load color definitions if they exist
if [[ -f "$NODEBOI_LIB/ui.sh" ]]; then
    # Colors should be loaded from ui.sh
    :
else
    # Fallback colors if ui.sh is missing
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
    UI_MUTED='\033[38;5;240m'
fi

# Run the network management interface
manage_monitoring_networks