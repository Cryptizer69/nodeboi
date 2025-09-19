#!/bin/bash
# lib/simple_ui.sh - Working fancy select menu

# Colors (only define if not already defined)
[[ -z "$UI_PRIMARY" ]] && readonly UI_PRIMARY='\033[0;36m'
[[ -z "$UI_SUCCESS" ]] && readonly UI_SUCCESS='\033[38;5;46m'
[[ -z "$UI_WARNING" ]] && readonly UI_WARNING='\033[38;5;226m'
[[ -z "$UI_ERROR" ]] && readonly UI_ERROR='\033[38;5;196m'
[[ -z "$UI_MUTED" ]] && readonly UI_MUTED='\033[38;5;240m'
[[ -z "$UI_BOLD" ]] && readonly UI_BOLD='\033[1m'
[[ -z "$UI_DIM" ]] && readonly UI_DIM='\033[2m'
[[ -z "$UI_RESET" ]] && readonly UI_RESET='\033[0m'

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
        
        # Check if background refresh is running - with better race condition handling
        if [[ -f "$lock_file" ]]; then
            local lock_pid=$(cat "$lock_file" 2>/dev/null)
            if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                refresh_indicator="${UI_MUTED}◐ Refreshing...${UI_RESET}"
            else
                # Clean up stale lock file
                rm -f "$lock_file" 2>/dev/null || true
            fi
        fi
        
        if [[ -f "$dashboard_cache_file" ]]; then
            # Read file content safely to avoid null byte warnings with Unicode characters
            current_dashboard=""
            if [[ -s "$dashboard_cache_file" ]]; then
                # Use while loop to read file content without null byte warnings
                {
                    local line
                    while IFS= read -r line || [[ -n "$line" ]]; do
                        current_dashboard+="$line"$'\n'
                    done
                } < "$dashboard_cache_file" 2>/dev/null
                # Remove trailing newline
                current_dashboard="${current_dashboard%$'\n'}"
            fi
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
        
        # Read key with longer timeout to prevent excessive redrawing
        local timeout=10  # Fixed timeout - no special handling for background processes
        
        if ! IFS= read -rsn1 -t "$timeout" key; then
            # Timeout occurred - only refresh if dashboard content might have changed
            # This reduces the frequency of unnecessary redraws that cause flickering
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
        [[ -f "${NODEBOI_LIB}/manage.sh" ]] && source "${NODEBOI_LIB}/manage.sh" >/dev/null 2>&1
        [[ -f "${NODEBOI_LIB}/clients.sh" ]] && source "${NODEBOI_LIB}/clients.sh" >/dev/null 2>&1
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
            # Password input with asterisk feedback
            printf "${UI_PRIMARY}▶${UI_RESET} " >&2
            input_value=""
            while IFS= read -r -n1 -s char; do
                if [[ $char == $'\0' ]]; then
                    # Enter key pressed
                    break
                elif [[ $char == $'\177' ]] || [[ $char == $'\b' ]]; then
                    # Backspace or Delete pressed
                    if [[ ${#input_value} -gt 0 ]]; then
                        input_value="${input_value%?}"
                        printf '\b \b' >&2  # Erase one character on screen
                    fi
                elif [[ $char == $'\x03' ]]; then
                    # Ctrl+C pressed
                    echo >&2
                    return 255
                else
                    # Regular character
                    input_value+="$char"
                    printf '*' >&2  # Show asterisk for each character
                fi
            done
            echo >&2  # New line after password input
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