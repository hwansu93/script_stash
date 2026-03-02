#!/bin/bash

# ── tmux-connect.sh ──────────────────────────────────────────────────────────
# Startup launcher for SSH sessions on the NUC.
# Manages tmux sessions scoped to project and service folders.
# Single-screen UX: sessions always visible, toggle picker for projects/services.
# ─────────────────────────────────────────────────────────────────────────────

PROJECTS_DIR="/mnt/data/projects"
SERVICES_DIR="/mnt/data/services"

# ── Colors ───────────────────────────────────────────────────────────────────

BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"
CYAN="\033[36m"
GREEN="\033[32m"
MAGENTA="\033[35m"
BLUE="\033[34m"
WHITE="\033[37m"
RED="\033[31m"

# ── Exclude patterns for directory listing ───────────────────────────────────

EXCLUDE_DIRS=(
    '.*'
    'node_modules'
    '.claude'
    'docs'
    'dotfiles'
    'script_stash'
)

# ── State ────────────────────────────────────────────────────────────────────

CURRENT_MODE="projects"
STATUS_MSG=""
STATUS_COLOR=""
declare -A SESSION_DIRS

# Session arrays
ALL_DISPLAY_NAMES=()
ALL_DISPLAY_TYPES=()
ALL_DISPLAY_ATTACHED=()
TOTAL_SESSIONS=0

# Picker arrays
AVAILABLE_ITEMS=()
TOTAL_PICKER_ITEMS=0

# ── Guard: already inside tmux ───────────────────────────────────────────────

if [ -n "$TMUX" ]; then
    echo -e "  ${RED}Already inside a tmux session.${RESET}"
    exit 0
fi

# ── Guard: projects directory exists ─────────────────────────────────────────

if [ ! -d "$PROJECTS_DIR" ]; then
    echo -e "  ${RED}$PROJECTS_DIR not found.${RESET}"
    exit 1
fi

# Create services dir if it doesn't exist
mkdir -p "$SERVICES_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────

load_sessions() {
    local proj_names=()
    local svc_names=()
    local scratch_names=()
    local -A session_attached
    ALL_DISPLAY_NAMES=()
    ALL_DISPLAY_TYPES=()
    ALL_DISPLAY_ATTACHED=()
    SESSION_DIRS=()

    if ! tmux has-session 2>/dev/null; then
        TOTAL_SESSIONS=0
        return
    fi

    while IFS=: read -r sname attached; do
        [ -z "$sname" ] && continue

        session_attached["$sname"]="$attached"

        local pdir
        pdir=$(tmux show-environment -t "$sname" PROJECT_DIR 2>/dev/null | grep -v '^-' | cut -d= -f2)

        if [ -n "$pdir" ]; then
            SESSION_DIRS["$sname"]="$pdir"
        fi

        if [[ "$sname" == scratchpad* ]]; then
            scratch_names+=("$sname")
        elif [[ "$pdir" == "$SERVICES_DIR"* ]]; then
            svc_names+=("$sname")
        else
            proj_names+=("$sname")
        fi
    done < <(tmux ls -F '#{session_created}:#{session_name}:#{session_attached}' 2>/dev/null | sort -n -t: -k1,1 | cut -d: -f2-)

    # Build display arrays: projects first, then services, then scratchpads
    for name in "${proj_names[@]}"; do
        ALL_DISPLAY_NAMES+=("$name")
        ALL_DISPLAY_TYPES+=("project")
        ALL_DISPLAY_ATTACHED+=("${session_attached[$name]}")
    done
    for name in "${svc_names[@]}"; do
        ALL_DISPLAY_NAMES+=("$name")
        ALL_DISPLAY_TYPES+=("service")
        ALL_DISPLAY_ATTACHED+=("${session_attached[$name]}")
    done
    for name in "${scratch_names[@]}"; do
        ALL_DISPLAY_NAMES+=("$name")
        ALL_DISPLAY_TYPES+=("scratchpad")
        ALL_DISPLAY_ATTACHED+=("${session_attached[$name]}")
    done

    TOTAL_SESSIONS=${#ALL_DISPLAY_NAMES[@]}
}

load_items() {
    local root_dir="$1"
    AVAILABLE_ITEMS=()

    if [ ! -d "$root_dir" ]; then
        TOTAL_PICKER_ITEMS=0
        return
    fi

    local -A used_dirs
    for sname in "${ALL_DISPLAY_NAMES[@]}"; do
        local pdir="${SESSION_DIRS[$sname]:-}"
        if [ -n "$pdir" ]; then
            used_dirs["$pdir"]=1
        fi
    done

    local find_excludes=()
    for ex in "${EXCLUDE_DIRS[@]}"; do
        find_excludes+=(-not -name "$ex")
    done

    while IFS= read -r folder; do
        [ -z "$folder" ] && continue
        local full_path="$root_dir/$folder"
        if [ -z "${used_dirs[$full_path]+_}" ]; then
            AVAILABLE_ITEMS+=("$folder")
        fi
    done < <(find "$root_dir" -mindepth 1 -maxdepth 1 -type d "${find_excludes[@]}" -printf '%f\n' | sort -f)

    TOTAL_PICKER_ITEMS=${#AVAILABLE_ITEMS[@]}
}

# Strip ANSI escape codes for width calculation
strip_ansi() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Handle escape sequences in confirmation loops
# Sets ESCAPE_RESULT to "cancel" (standalone Esc) or "continue" (consumed sequence)
handle_escape_in_confirm() {
    local cmd_key="$1"  # The command letter to re-display after toggle
    local seq1 seq2
    IFS= read -rsn1 -t 0.2 seq1
    if [[ -z "$seq1" ]]; then
        ESCAPE_RESULT="cancel"
        return
    fi
    if [[ "$seq1" == '[' ]]; then
        IFS= read -rsn1 -t 0.2 seq2
        case "$seq2" in
            C|D)
                if [[ "$CURRENT_MODE" == "projects" ]]; then
                    CURRENT_MODE="services"
                else
                    CURRENT_MODE="projects"
                fi
                if [[ "$CURRENT_MODE" == "projects" ]]; then
                    load_items "$PROJECTS_DIR"
                else
                    load_items "$SERVICES_DIR"
                fi
                draw_screen
                printf "%s" "$cmd_key"
                ESCAPE_RESULT="continue"
                return
                ;;
            *)
                while IFS= read -rsn1 -t 0.05 _discard; do :; done
                ESCAPE_RESULT="continue"
                return
                ;;
        esac
    else
        while IFS= read -rsn1 -t 0.05 _discard; do :; done
        ESCAPE_RESULT="continue"
        return
    fi
}

# Read a line of input with Esc-to-cancel support
# Returns 0 on Enter (input in REPLY), returns 1 on Esc (cancelled)
read_input_with_cancel() {
    local prompt="$1"
    local input=""
    printf "%s" "$prompt"

    while true; do
        IFS= read -rsn1 ch

        if [[ "$ch" == $'\e' ]]; then
            # Check if it's an arrow key or standalone Esc
            IFS= read -rsn1 -t 0.2 seq1
            if [[ -z "$seq1" ]]; then
                # Standalone Esc — cancel
                REPLY=""
                return 1
            else
                # Part of an escape sequence — consume remaining bytes and ignore
                while IFS= read -rsn1 -t 0.05 _discard; do :; done
                continue
            fi
        elif [[ "$ch" == '' ]]; then
            # Enter — confirm
            echo
            REPLY="$input"
            return 0
        elif [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
            # Backspace
            if [[ ${#input} -gt 0 ]]; then
                input="${input%?}"
                printf "\b \b"
            fi
        else
            # Regular character
            input="${input}${ch}"
            printf "%s" "$ch"
        fi
    done
}

# ── Screen Builder ───────────────────────────────────────────────────────────

draw_screen() {
    local output=""
    local inner_width=38
    local border
    border=$(printf '%0.s─' $(seq 1 $inner_width))
    local title="Tmux Connect"
    local title_len=${#title}
    local pad_total=$(( inner_width - title_len ))
    local left_pad=$(( pad_total / 2 ))
    local right_pad=$(( pad_total - left_pad ))

    # Header
    output+="\n"
    output+="  ${BOLD}${CYAN}┌${border}┐${RESET}\n"
    output+="  ${BOLD}${CYAN}│${RESET}"
    output+="$(printf '%*s' "$left_pad" '')${BOLD}${title}${RESET}$(printf '%*s' "$right_pad" '')"
    output+="${BOLD}${CYAN}│${RESET}\n"
    output+="  ${BOLD}${CYAN}└${border}┘${RESET}\n"
    output+="\n"

    # Sessions section
    output+="  ${BOLD}${WHITE}Sessions${RESET}\n"

    if [ "$TOTAL_SESSIONS" -eq 0 ]; then
        output+="    ${DIM}(no active sessions)${RESET}\n"
    else
        # Compute tight column width based on longest session label
        local max_session_len=0
        for (( i = 0; i < TOTAL_SESSIONS; i++ )); do
            local num=$(( i + 1 ))
            local name="${ALL_DISPLAY_NAMES[$i]}"
            # "N. X name" where N is number, X is attached indicator (2 chars)
            local label_len=$(( ${#num} + 2 + 1 + ${#name} ))
            (( label_len > max_session_len )) && max_session_len=$label_len
        done
        local col_width=$(( max_session_len + 4 ))

        # Build labels for all sessions
        local -a session_labels=()
        for (( i = 0; i < TOTAL_SESSIONS; i++ )); do
            local num=$(( i + 1 ))
            local name="${ALL_DISPLAY_NAMES[$i]}"
            local stype="${ALL_DISPLAY_TYPES[$i]}"
            local attached_indicator=""
            local color_code=""

            case "$stype" in
                project)
                    color_code="$GREEN"
                    ;;
                service)
                    color_code="$MAGENTA"
                    ;;
                scratchpad)
                    color_code="$BLUE"
                    ;;
            esac

            if [[ "${ALL_DISPLAY_ATTACHED[$i]}" == "1" ]]; then
                attached_indicator="${BOLD}${color_code}●${RESET}"
            else
                attached_indicator=" "
            fi

            case "$stype" in
                project)
                    session_labels+=("$(printf "${BOLD}%d.${RESET} %b ${GREEN}%s${RESET}" "$num" "$attached_indicator" "$name")")
                    ;;
                service)
                    session_labels+=("$(printf "${BOLD}%d.${RESET} %b ${MAGENTA}%s${RESET}" "$num" "$attached_indicator" "$name")")
                    ;;
                scratchpad)
                    session_labels+=("$(printf "${BOLD}%d.${RESET} %b ${BLUE}%s${RESET}" "$num" "$attached_indicator" "$name")")
                    ;;
            esac
        done

        # Dynamic columns with max 5 rows each, column-major fill
        local rows_per_col=5
        local total_labels=${#session_labels[@]}
        local num_cols=$(( (total_labels + rows_per_col - 1) / rows_per_col ))
        for (( r = 0; r < rows_per_col; r++ )); do
            local row_line=""
            local row_has_content=0
            for (( c = 0; c < num_cols; c++ )); do
                local idx=$(( c * rows_per_col + r ))
                if (( idx < total_labels )); then
                    row_has_content=1
                    local cell="${session_labels[$idx]}"
                    if (( c < num_cols - 1 )); then
                        # Pad to col_width
                        local cell_plain
                        cell_plain=$(strip_ansi "$cell")
                        local cell_len=${#cell_plain}
                        local pad=$(( col_width - cell_len ))
                        [ $pad -lt 1 ] && pad=1
                        row_line+="$(printf "%b%*s " "$cell" "$pad" "")"
                    else
                        row_line+="$(printf "%b" "$cell")"
                    fi
                fi
            done
            if (( row_has_content )); then
                output+="   ${row_line}\n"
            fi
        done
    fi

    output+="\n"

    # Toggle bar
    if [[ "$CURRENT_MODE" == "projects" ]]; then
        output+="  ${BOLD}${GREEN}[► Projects]${RESET}   ${DIM}Services${RESET}\n"
    else
        output+="  ${DIM}Projects${RESET}   ${BOLD}${MAGENTA}[► Services]${RESET}\n"
    fi
    output+="  $(printf '%0.s─' $(seq 1 38))\n"

    # Picker items
    if [ "$TOTAL_PICKER_ITEMS" -eq 0 ]; then
        local label
        if [[ "$CURRENT_MODE" == "projects" ]]; then
            label="projects"
        else
            label="services"
        fi
        output+="   ${DIM}(no available ${label})${RESET}\n"
    else
        local picker_color
        if [[ "$CURRENT_MODE" == "projects" ]]; then
            picker_color="$GREEN"
        else
            picker_color="$MAGENTA"
        fi

        # Compute tight column width based on longest item name
        local max_len=0
        for item in "${AVAILABLE_ITEMS[@]}"; do
            (( ${#item} > max_len )) && max_len=${#item}
        done
        local col_width=$(( max_len + 5 ))  # "a. " = 3 chars + 2 padding

        local -a picker_labels=()
        for (( i = 0; i < TOTAL_PICKER_ITEMS; i++ )); do
            local letter
            letter=$(printf "\\$(printf '%03o' $((97 + i)))")
            local name="${AVAILABLE_ITEMS[$i]}"
            picker_labels+=("$(printf "${BOLD}%s.${RESET} ${picker_color}%s${RESET}" "$letter" "$name")")
        done

        # Dynamic columns with max 5 rows each, column-major fill
        local rows_per_col=5
        local total_picker=${#picker_labels[@]}
        local num_cols=$(( (total_picker + rows_per_col - 1) / rows_per_col ))
        for (( r = 0; r < rows_per_col; r++ )); do
            local row_line=""
            local row_has_content=0
            for (( c = 0; c < num_cols; c++ )); do
                local idx=$(( c * rows_per_col + r ))
                if (( idx < total_picker )); then
                    row_has_content=1
                    local cell="${picker_labels[$idx]}"
                    if (( c < num_cols - 1 )); then
                        # Pad to col_width
                        local cell_plain
                        cell_plain=$(strip_ansi "$cell")
                        local cell_len=${#cell_plain}
                        local pad=$(( col_width - cell_len ))
                        [ $pad -lt 1 ] && pad=1
                        row_line+="$(printf "%b%*s " "$cell" "$pad" "")"
                    else
                        row_line+="$(printf "%b" "$cell")"
                    fi
                fi
            done
            if (( row_has_content )); then
                output+="   ${row_line}\n"
            fi
        done
    fi

    # Footer
    output+="\n"
    output+="  ${DIM}←/→ toggle  |  # + Enter = session  a-z + Enter = open${RESET}\n"
    output+="  ${DIM}[s] Scratchpad  [n] New  [r] Rename  [q] Quit${RESET}\n"

    # Status message
    if [[ -n "$STATUS_MSG" ]]; then
        output+="\n  ${STATUS_COLOR}${STATUS_MSG}${RESET}\n"
    fi

    # Render all at once
    printf "\033[2J\033[H%b" "$output"
    printf "\n  > "
}

# ── Session Actions ──────────────────────────────────────────────────────────

prompt_session_name() {
    local default="$1"
    echo ""
    read_input_with_cancel "  Session name [$default]: "
    if [[ $? -ne 0 ]]; then return 1; fi
    local input="$REPLY"
    if [ -z "$input" ]; then
        REPLY="$default"
    else
        REPLY="$input"
    fi
}

launch_session() {
    local folder="$1"
    local root_dir="$2"
    local full_path="$root_dir/$folder"

    prompt_session_name "$folder"
    if [[ $? -ne 0 ]]; then return 1; fi
    local sname="$REPLY"

    if [[ "$sname" =~ [.:=] ]]; then
        STATUS_MSG="Name cannot contain '.', ':', or '='."
        STATUS_COLOR="$RED"
        return 1
    fi

    if tmux has-session -t "$sname" 2>/dev/null; then
        tmux attach -t "$sname"
    else
        tmux new-session -d -s "$sname" -c "$full_path"
        tmux set-environment -t "$sname" PROJECT_DIR "$full_path"
        tmux send-keys -t "$sname" "claude --dangerously-skip-permissions" Enter
        tmux attach -t "$sname"
    fi
}

create_folder() {
    local root_dir="$1"
    echo ""
    read_input_with_cancel "  Folder name: "
    if [[ $? -ne 0 ]]; then return 1; fi
    local folder
    folder=$(echo "$REPLY" | xargs)

    if [ -z "$folder" ]; then
        STATUS_MSG="No folder name provided."
        STATUS_COLOR="$RED"
        return 1
    fi

    if [[ "$folder" =~ [.:=] ]]; then
        STATUS_MSG="Name cannot contain '.', ':', or '='."
        STATUS_COLOR="$RED"
        return 1
    fi

    mkdir -p "$root_dir/$folder"
    launch_session "$folder" "$root_dir"
}

attach_to_session() {
    local num=$1
    local idx=$(( num - 1 ))
    local sname="${ALL_DISPLAY_NAMES[$idx]}"
    tmux attach -t "$sname"
}

launch_from_picker() {
    local idx=$1
    local folder="${AVAILABLE_ITEMS[$idx]}"
    local root_dir
    if [[ "$CURRENT_MODE" == "projects" ]]; then
        root_dir="$PROJECTS_DIR"
    else
        root_dir="$SERVICES_DIR"
    fi
    launch_session "$folder" "$root_dir"
}

handle_scratchpad() {
    # If scratchpad session exists and it's the only one, attach to it
    if tmux has-session -t scratchpad 2>/dev/null; then
        # Check if there are numbered scratchpads too
        local has_numbered=0
        if tmux ls -F '#{session_name}' 2>/dev/null | grep -qE '^scratchpad-[0-9]+$'; then
            has_numbered=1
        fi
        if [ "$has_numbered" -eq 0 ]; then
            tmux attach -t scratchpad
            return
        fi
    fi

    # If no base scratchpad exists, create it
    if ! tmux has-session -t scratchpad 2>/dev/null; then
        echo ""
        echo -e "  ${DIM}Creating scratchpad...${RESET}"
        tmux new-session -d -s scratchpad -c "$PROJECTS_DIR"
        tmux send-keys -t scratchpad "claude --dangerously-skip-permissions" Enter
        tmux attach -t scratchpad
        return
    fi

    # Base scratchpad exists and there are numbered ones too; auto-number a new one
    local sp_max sp_num sp_name
    echo ""
    read_input_with_cancel "  Name for new scratchpad (Enter for auto): "
    if [[ $? -ne 0 ]]; then return 0; fi
    local sp_input
    sp_input=$(echo "$REPLY" | xargs)

    if [ -z "$sp_input" ]; then
        sp_max=0
        while IFS= read -r sp_line; do
            sp_num="${sp_line#scratchpad-}"
            if [ "$sp_num" -gt "$sp_max" ] 2>/dev/null; then
                sp_max="$sp_num"
            fi
        done < <(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^scratchpad-[0-9]+$')
        sp_name="scratchpad-$(( sp_max + 1 ))"
    else
        sp_name="scratchpad-${sp_input}"
        if tmux has-session -t "$sp_name" 2>/dev/null; then
            STATUS_MSG="Session '$sp_name' already exists."
            STATUS_COLOR="$RED"
            return
        fi
    fi

    if [[ "$sp_name" =~ [.:=] ]]; then
        STATUS_MSG="Name cannot contain '.', ':', or '='."
        STATUS_COLOR="$RED"
        return
    fi

    tmux new-session -d -s "$sp_name" -c "$PROJECTS_DIR"
    tmux send-keys -t "$sp_name" "claude --dangerously-skip-permissions" Enter
    tmux attach -t "$sp_name"
}

handle_rename() {
    if [ "$TOTAL_SESSIONS" -eq 0 ]; then
        STATUS_MSG="No active sessions to rename."
        STATUS_COLOR="$RED"
        return
    fi

    local rnum_int old_name newname
    echo ""
    read_input_with_cancel "  Session number to rename: "
    if [[ $? -ne 0 ]]; then return 0; fi
    local rnum
    rnum=$(echo "$REPLY" | xargs)

    if ! [[ "$rnum" =~ ^[0-9]+$ ]]; then
        STATUS_MSG="Invalid input."
        STATUS_COLOR="$RED"
        return
    fi

    rnum_int=$((10#$rnum))
    if (( rnum_int < 1 || rnum_int > TOTAL_SESSIONS )); then
        STATUS_MSG="Invalid session number."
        STATUS_COLOR="$RED"
        return
    fi

    old_name="${ALL_DISPLAY_NAMES[$((rnum_int - 1))]}"

    read_input_with_cancel "  New name for '$old_name': "
    if [[ $? -ne 0 ]]; then return 0; fi
    newname=$(echo "$REPLY" | xargs)

    if [ -z "$newname" ]; then
        STATUS_MSG="No name provided."
        STATUS_COLOR="$RED"
        return
    fi

    if [[ "$newname" =~ [.:=] ]]; then
        STATUS_MSG="Name cannot contain '.', ':', or '='."
        STATUS_COLOR="$RED"
        return
    fi

    if tmux has-session -t "$newname" 2>/dev/null; then
        STATUS_MSG="Session '$newname' already exists. Choose a different name."
        STATUS_COLOR="$RED"
        return
    fi

    if tmux rename-session -t "$old_name" "$newname"; then
        STATUS_MSG="Renamed '$old_name' to '$newname'."
        STATUS_COLOR="$GREEN"
    else
        STATUS_MSG="Failed to rename '$old_name'."
        STATUS_COLOR="$RED"
    fi
}

handle_new_folder() {
    local root_dir
    if [[ "$CURRENT_MODE" == "projects" ]]; then
        root_dir="$PROJECTS_DIR"
    else
        root_dir="$SERVICES_DIR"
    fi
    create_folder "$root_dir"
}

# ── Main Loop ────────────────────────────────────────────────────────────────

while true; do
    STATUS_MSG=""
    STATUS_COLOR=""
    load_sessions

    if [[ "$CURRENT_MODE" == "projects" ]]; then
        load_items "$PROJECTS_DIR"
    else
        load_items "$SERVICES_DIR"
    fi

    draw_screen

    # Read first character
    IFS= read -rsn1 key

    # Check for escape sequence (arrow keys, mouse clicks, focus events)
    if [[ "$key" == $'\e' ]]; then
        IFS= read -rsn1 -t 0.2 seq1
        if [[ "$seq1" == '[' ]]; then
            IFS= read -rsn1 -t 0.2 seq2
            case "$seq2" in
                C)  # Right arrow
                    CURRENT_MODE=$([[ "$CURRENT_MODE" == "projects" ]] && echo "services" || echo "projects")
                    continue
                    ;;
                D)  # Left arrow
                    CURRENT_MODE=$([[ "$CURRENT_MODE" == "projects" ]] && echo "services" || echo "projects")
                    continue
                    ;;
                *)
                    # Unknown escape sequence -- consume any remaining bytes and discard
                    while IFS= read -rsn1 -t 0.05 _discard; do :; done
                    continue
                    ;;
            esac
        else
            # Not a CSI sequence -- consume remaining and discard
            while IFS= read -rsn1 -t 0.05 _discard; do :; done
            continue
        fi
    fi

    case "$key" in
        [0-9])
            # Show the digit, read more digits until Enter
            input="$key"
            printf "%s" "$key"
            num_cancelled=0
            while true; do
                IFS= read -rsn1 ch
                if [[ "$ch" == '' ]]; then  # Enter
                    break
                elif [[ "$ch" == $'\e' ]]; then
                    handle_escape_in_confirm "$input"
                    if [[ "$ESCAPE_RESULT" == "cancel" ]]; then
                        num_cancelled=1
                        break
                    fi
                    continue
                elif [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then  # Backspace
                    if [[ ${#input} -gt 0 ]]; then
                        input="${input%?}"
                        printf "\b \b"
                    fi
                elif [[ "$ch" =~ [0-9] ]]; then
                    input="${input}${ch}"
                    printf "%s" "$ch"
                fi
            done

            if [[ "$num_cancelled" -eq 1 ]]; then
                continue
            fi

            if [[ -z "$input" ]]; then
                continue
            fi

            num=$((10#$input))

            # Numbers only attach to sessions
            if (( num >= 1 && num <= TOTAL_SESSIONS )); then
                attach_to_session "$num"
            else
                STATUS_MSG="Invalid selection"
                STATUS_COLOR="$RED"
            fi
            continue
            ;;
        [a-z])
            # Letters: s/n/r/q are commands; all others are picker selections
            case "$key" in
                s)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_scratchpad
                    continue
                    ;;
                n)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_new_folder
                    continue
                    ;;
                r)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_rename
                    continue
                    ;;
                q)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    echo ""
                    exit 0
                    ;;
                *)
                    # Picker letter selection
                    printf "%s" "$key"
                    letter="$key"
                    letter_cancelled=0
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then  # Enter
                            break
                        elif [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$letter"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then
                                letter_cancelled=1
                                break
                            fi
                            continue
                        elif [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then  # Backspace
                            if [[ -n "$letter" ]]; then
                                letter=""
                                printf "\b \b"
                            fi
                        fi
                    done

                    if [[ "$letter_cancelled" -eq 1 ]]; then
                        continue 2
                    fi

                    if [[ -z "$letter" ]]; then
                        continue
                    fi

                    # Convert letter to picker index: a=0, b=1, ...
                    idx=$(( $(printf '%d' "'$letter") - 97 ))
                    if (( idx >= 0 && idx < TOTAL_PICKER_ITEMS )); then
                        launch_from_picker "$idx"
                    else
                        STATUS_MSG="Invalid selection"
                        STATUS_COLOR="$RED"
                    fi
                    continue
                    ;;
            esac
            ;;
        [A-Z])
            # Uppercase versions of commands
            case "$key" in
                S)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_scratchpad
                    ;;
                N)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_new_folder
                    ;;
                R)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    handle_rename
                    ;;
                Q)
                    printf "%s" "$key"
                    while true; do
                        IFS= read -rsn1 ch
                        if [[ "$ch" == '' ]]; then break; fi
                        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
                            printf "\b \b"
                            continue 2
                        fi
                        if [[ "$ch" == $'\e' ]]; then
                            handle_escape_in_confirm "$key"
                            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then continue 2; fi
                        fi
                    done
                    echo ""
                    exit 0
                    ;;
            esac
            ;;
        *)
            # Ignore unknown keys
            ;;
    esac
done
