#!/bin/bash
# lib/simple_ui.sh - Working fancy select menu

# Colors 
readonly UI_PRIMARY='\033[0;36m'
readonly UI_SUCCESS='\033[38;5;46m'
readonly UI_WARNING='\033[38;5;226m'
readonly UI_ERROR='\033[38;5;196m'
readonly UI_MUTED='\033[38;5;240m'
readonly UI_BOLD='\033[1m'
readonly UI_DIM='\033[2m'
readonly UI_RESET='\033[0m'

# Working fancy menu
fancy_select_menu() {
    local title="$1"
    shift
    local options=("$@")
    local selected=0
    local total=${#options[@]}
    
    # ALWAYS show dashboard consistently - no exceptions
    local dashboard_cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    
    # Hide cursor
    printf '\033[?25l' >&2
    
    # Function to show cursor on exit
    show_cursor() {
        printf '\033[?25h' >&2
    }
    
    # Trap to restore cursor
    trap show_cursor EXIT INT TERM
    
    while true; do
        clear >&2
        
        # Show header if available
        if declare -f print_header >/dev/null; then
            print_header >&2
        fi
        
        # Show fresh dashboard for all menus - read from cache file each time
        local current_dashboard=""
        local refresh_indicator=""
        local lock_file="${DASHBOARD_CACHE_LOCK:-$HOME/.nodeboi/cache/dashboard.lock}"
        
        # Check if background refresh is running
        if [[ -f "$lock_file" ]]; then
            local lock_pid=$(cat "$lock_file" 2>/dev/null)
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                refresh_indicator="${UI_MUTED}◐ Refreshing...${UI_RESET}"
            fi
        fi
        
        if [[ -f "$dashboard_cache_file" ]]; then
            current_dashboard=$(cat "$dashboard_cache_file" 2>/dev/null)
        else
            current_dashboard="NODEBOI Dashboard
=================

  Dashboard loading...
"
        fi
        
        if [[ -n "$current_dashboard" ]]; then
            # If refreshing, show indicator right after the dashboard title
            if [[ -n "$refresh_indicator" ]]; then
                # Split dashboard content to insert refresh indicator after title
                local dashboard_lines
                readarray -t dashboard_lines <<< "$current_dashboard"
                
                # Show first two lines (title and separator)
                for i in 0 1; do
                    [[ ${dashboard_lines[i]+set} ]] && echo -e "${dashboard_lines[i]}" >&2
                done
                
                # Show refresh indicator
                echo -e "$refresh_indicator" >&2
                
                # Show the rest of the dashboard
                for (( i=2; i<${#dashboard_lines[@]}; i++ )); do
                    echo -e "${dashboard_lines[i]}" >&2
                done
            else
                echo -e "$current_dashboard" >&2
            fi
            echo >&2  # Add blank line after dashboard
        fi
        
        if [[ -n "$title" ]]; then
            echo -e "\n${UI_BOLD}${UI_PRIMARY}$title${UI_RESET}" >&2
            printf "${UI_MUTED}%*s${UI_RESET}\n" "${#title}" '' | tr ' ' '=' >&2
            echo >&2
        fi
        
        # Display options
        for i in "${!options[@]}"; do
            local option="${options[$i]}"
            if [[ $i -eq $selected ]]; then
                echo -e "  ${UI_PRIMARY}▶${UI_RESET} ${UI_BOLD}${UI_PRIMARY}$option${UI_RESET}" >&2
            else
                echo -e "    ${UI_MUTED}$option${UI_RESET}" >&2
            fi
        done
        
        echo -e "\n${UI_DIM}Use ↑/↓ arrows or j/k, Enter to select, 'q' to quit${UI_RESET}" >&2
        
        # Read key with timeout to allow auto-refresh when background processes complete
        local was_refreshing="$refresh_indicator"
        if ! IFS= read -rsn1 -t 2 key; then
            # Timeout occurred - check if refresh status changed and redraw if needed
            local lock_file="${DASHBOARD_CACHE_LOCK:-$HOME/.nodeboi/cache/dashboard.lock}"
            local current_refresh=""
            if [[ -f "$lock_file" ]]; then
                local lock_pid=$(cat "$lock_file" 2>/dev/null)
                if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                    current_refresh="${UI_MUTED}◐ Refreshing...${UI_RESET}"
                fi
            fi
            # If refresh status changed, continue loop to redraw
            [[ "$was_refreshing" != "$current_refresh" ]] && continue
            # If no change, continue loop anyway to keep checking
            continue
        fi
        
        case "$key" in
            $'\033')
                IFS= read -rsn2 -t 0.1 key
                case "$key" in
                    '[A')
                        [[ $selected -gt 0 ]] && ((selected--))
                        ;;
                    '[B')
                        [[ $selected -lt $((total-1)) ]] && ((selected++))
                        ;;
                esac
                ;;
            '')
                show_cursor
                echo $selected
                return 0
                ;;
            'q'|'Q')
                show_cursor
                return 255
                ;;
            $'\177'|$'\b'|$'\010'|$'\x7f'|$'\x08')  # Multiple backspace/delete codes
                show_cursor  
                return 254  # Different code for backspace
                ;;
            'j')
                [[ $selected -lt $((total-1)) ]] && ((selected++))
                ;;
            'k')
                [[ $selected -gt 0 ]] && ((selected--))
                ;;
            [1-9])
                local num=$((key - 1))
                [[ $num -ge 0 && $num -lt $total ]] && selected=$num
                ;;
        esac
    done
}

# Enhanced confirmation using fancy menu
fancy_confirm() {
    local message="$1"
    local default="${2:-n}"
    
    local options=("yes" "no")
    
    local selection
    if selection=$(fancy_select_menu "$message" "${options[@]}"); then
        case $selection in
            0) return 0 ;;  # Yes
            1) return 1 ;;  # No
        esac
    else
        return 255  # User pressed 'q' - return special quit code
    fi
}

# Fancy text input function
fancy_text_input() {
    local title="$1"
    local prompt_text="$2"
    local default_value="$3"
    local validation_func="$4"  # Optional validation function
    local is_password="${5:-}"   # Optional: true for password input (masked)
    
    # Cache dashboard content for all text input  
    local cached_dashboard=""
    # Show dashboard for ALL text inputs to maintain consistency
    local dashboard_cache_file="$HOME/.nodeboi/cache/dashboard.cache"
    
    if declare -f print_dashboard >/dev/null 2>&1; then
        # If we have access to print_dashboard, use it directly
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" 2>/dev/null
        [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" 2>/dev/null
        cached_dashboard=$(print_dashboard 2>/dev/null)
    elif [[ -f "$dashboard_cache_file" ]]; then
        # Fallback: use the cached dashboard file (for scripts called from nodeboi)
        cached_dashboard=$(cat "$dashboard_cache_file" 2>/dev/null)
    fi
    
    while true; do
        clear >&2
        
        # Show header if available
        if declare -f print_header >/dev/null; then
            print_header >&2
        fi
        
        # Show cached dashboard for all text input
        if [[ -n "$cached_dashboard" ]]; then
            echo -e "$cached_dashboard" >&2
            echo >&2  # Add blank line after dashboard
        fi
        
        if [[ -n "$title" ]]; then
            echo -e "\n${UI_BOLD}${UI_PRIMARY}$title${UI_RESET}" >&2
            printf "${UI_MUTED}%*s${UI_RESET}\n" "${#title}" '' | tr ' ' '=' >&2
            echo >&2
        fi
        
        echo -e "${UI_MUTED}$prompt_text${UI_RESET}" >&2
        echo >&2
        
        # Show input prompt with pre-filled default value that can be edited
        if [[ "$is_password" == "true" ]]; then
            # Password input - always masked, no default value support
            printf "${UI_PRIMARY}▶${UI_RESET} " >&2
            read -r -s input_value  # -s flag masks the input
            echo >&2  # New line after masked input
        elif [[ -n "$default_value" ]]; then
            # Always try readline pre-fill first - this puts default text in the input buffer
            printf "${UI_PRIMARY}▶${UI_RESET} " >&2
            
            # The -e flag enables readline editing, -i pre-fills the input buffer
            # This allows users to backspace and edit the default value
            if read -r -e -i "$default_value" input_value; then
                # Pre-fill worked - user can edit the default text with backspace/arrows
                :
            else
                # Pre-fill failed, fall back to regular input with clear instructions
                echo -e "\r${UI_PRIMARY}▶${UI_RESET} ${UI_MUTED}[Default: $default_value - Press Enter to use, or type your own]${UI_RESET}" >&2
                printf "${UI_PRIMARY}▶${UI_RESET} " >&2
                read -r input_value
            fi
        else
            printf "${UI_PRIMARY}▶${UI_RESET} " >&2
            read -r input_value
        fi
        
        # Check for quit command
        if [[ "$input_value" == "q" ]]; then
            return 255
        fi
        
        # Use the input value (which could be the edited default or user input)
        [[ -z "$input_value" ]] && input_value="$default_value"
        
        # Run validation if provided
        if [[ -n "$validation_func" ]] && declare -f "$validation_func" >/dev/null; then
            local error_msg
            if error_msg=$($validation_func "$input_value" 2>&1); then
                echo "$input_value"
                return 0
            else
                echo >&2
                echo -e "${UI_ERROR}✗ $error_msg${UI_RESET}" >&2
                echo >&2
                read -p "Press Enter to try again..." >&2
                continue
            fi
        else
            echo "$input_value"
            return 0
        fi
    done
}

# Message box
print_box() {
    local message="$1"
    local type="${2:-info}"
    local color="$UI_PRIMARY"
    
    case "$type" in
        "success") color="$UI_SUCCESS" ;;
        "warning") color="$UI_WARNING" ;;
        "error") color="$UI_ERROR" ;;
    esac
    
    local width=$((${#message} + 4))
    echo -e "\n${color}+$(printf '%*s' $width '' | tr ' ' '-')+"
    echo -e "|  ${UI_BOLD}$message${UI_RESET}${color}  |"
    echo -e "+$(printf '%*s' $width '' | tr ' ' '-')+${UI_RESET}\n"
}