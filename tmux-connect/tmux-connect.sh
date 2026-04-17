#!/bin/bash

# ── tmux-connect.sh ──────────────────────────────────────────────────────────
# Startup launcher for SSH sessions on the NUC.
# Manages tmux sessions scoped to project and service folders.
# Single-screen UX: sessions always visible, toggle picker for projects/services.
# ─────────────────────────────────────────────────────────────────────────────

PROJECTS_DIR="/mnt/data/projects"
SERVICES_DIR="/mnt/data/services"
SCRATCH_DIR="/mnt/data/scratch"

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
ORANGE="\033[38;5;208m"

# ── Exclude patterns for directory listing ───────────────────────────────────

EXCLUDE_DIRS=(
    '.*'
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
ALL_DISPLAY_TOOLS=()
TOTAL_SESSIONS=0

# Picker arrays
AVAILABLE_ITEMS=()
TOTAL_PICKER_ITEMS=0
FILTER_BUFFER=""
FILTERED_INDICES=()
FILTERED_MATCH_COUNT=0
SELECTED_PICKER_POS=0
PICKER_SCROLL_OFFSET=0
LAST_PICKER_ROWS=0

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
mkdir -p "$SCRATCH_DIR"

# Ensure ai-session wrapper is available on PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"

# ── Helpers ──────────────────────────────────────────────────────────────────

load_sessions() {
    local proj_names=()
    local svc_names=()
    local scratch_names=()
    local -A session_attached
    local -A session_tools
    ALL_DISPLAY_NAMES=()
    ALL_DISPLAY_TYPES=()
    ALL_DISPLAY_ATTACHED=()
    ALL_DISPLAY_TOOLS=()
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

        local tool_val
        tool_val=$(tmux show-environment -t "$sname" TOOL 2>/dev/null | grep -v '^-' | cut -d= -f2)
        session_tools["$sname"]="${tool_val:-claude}"

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
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
    done
    for name in "${svc_names[@]}"; do
        ALL_DISPLAY_NAMES+=("$name")
        ALL_DISPLAY_TYPES+=("service")
        ALL_DISPLAY_ATTACHED+=("${session_attached[$name]}")
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
    done
    for name in "${scratch_names[@]}"; do
        ALL_DISPLAY_NAMES+=("$name")
        ALL_DISPLAY_TYPES+=("scratchpad")
        ALL_DISPLAY_ATTACHED+=("${session_attached[$name]}")
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
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

get_term_cols() {
    local cols
    cols=$(tput cols 2>/dev/null)
    if [[ ! "$cols" =~ ^[0-9]+$ ]] || (( cols < 40 )); then
        cols=80
    fi
    echo "$cols"
}

get_term_lines() {
    local lines
    lines=$(tput lines 2>/dev/null)
    if [[ ! "$lines" =~ ^[0-9]+$ ]] || (( lines < 18 )); then
        lines=24
    fi
    echo "$lines"
}

repeat_char() {
    local char="$1"
    local count="$2"
    if (( count <= 0 )); then
        return
    fi
    printf "%${count}s" "" | tr ' ' "$char"
}

truncate_text() {
    local text="$1"
    local max_width="$2"
    local text_len=${#text}

    if (( max_width <= 0 )); then
        echo ""
    elif (( text_len <= max_width )); then
        echo "$text"
    elif (( max_width <= 3 )); then
        echo "${text:0:max_width}"
    else
        echo "${text:0:$((max_width - 3))}..."
    fi
}

fuzzy_match_score() {
    local query="${1,,}"
    local candidate="${2,,}"
    local qlen=${#query}
    local clen=${#candidate}
    local qi=0
    local last_match=-2
    local score=0
    local idx
    local char
    local prev

    if (( qlen == 0 )); then
        echo 0
        return
    fi

    for (( idx = 0; idx < clen && qi < qlen; idx++ )); do
        char="${candidate:idx:1}"
        if [[ "$char" == "${query:qi:1}" ]]; then
            score=$(( score + 10 ))
            if (( idx == last_match + 1 )); then
                score=$(( score + 5 ))
            fi
            if (( idx == 0 )); then
                score=$(( score + 4 ))
            else
                prev="${candidate:idx-1:1}"
                if [[ "$prev" == "-" || "$prev" == "_" || "$prev" == "." || "$prev" == "/" || "$prev" == " " ]]; then
                    score=$(( score + 4 ))
                fi
            fi
            last_match=$idx
            qi=$(( qi + 1 ))
        fi
    done

    if (( qi != qlen )); then
        echo -1
        return
    fi

    score=$(( score - clen ))
    echo "$score"
}

is_filterable_key() {
    local key="$1"
    [[ "$key" =~ ^[[:graph:]]$ ]]
}

current_root_dir() {
    if [[ "$CURRENT_MODE" == "projects" ]]; then
        echo "$PROJECTS_DIR"
    else
        echo "$SERVICES_DIR"
    fi
}

reset_picker_selection() {
    SELECTED_PICKER_POS=0
    PICKER_SCROLL_OFFSET=0
}

sync_picker_selection() {
    if (( FILTERED_MATCH_COUNT <= 0 )); then
        SELECTED_PICKER_POS=0
        PICKER_SCROLL_OFFSET=0
        return
    fi

    if (( SELECTED_PICKER_POS < 0 )); then
        SELECTED_PICKER_POS=0
    elif (( SELECTED_PICKER_POS >= FILTERED_MATCH_COUNT )); then
        SELECTED_PICKER_POS=$(( FILTERED_MATCH_COUNT - 1 ))
    fi

    if (( LAST_PICKER_ROWS > 0 )); then
        if (( SELECTED_PICKER_POS < PICKER_SCROLL_OFFSET )); then
            PICKER_SCROLL_OFFSET=$SELECTED_PICKER_POS
        elif (( SELECTED_PICKER_POS >= PICKER_SCROLL_OFFSET + LAST_PICKER_ROWS )); then
            PICKER_SCROLL_OFFSET=$(( SELECTED_PICKER_POS - LAST_PICKER_ROWS + 1 ))
        fi
    fi

    if (( PICKER_SCROLL_OFFSET < 0 )); then
        PICKER_SCROLL_OFFSET=0
    fi

    if (( PICKER_SCROLL_OFFSET > SELECTED_PICKER_POS )); then
        PICKER_SCROLL_OFFSET=$SELECTED_PICKER_POS
    fi
}

move_picker_selection() {
    local delta="$1"
    if (( FILTERED_MATCH_COUNT <= 0 )); then
        return
    fi

    SELECTED_PICKER_POS=$(( SELECTED_PICKER_POS + delta ))
    if (( SELECTED_PICKER_POS < 0 )); then
        SELECTED_PICKER_POS=0
    elif (( SELECTED_PICKER_POS >= FILTERED_MATCH_COUNT )); then
        SELECTED_PICKER_POS=$(( FILTERED_MATCH_COUNT - 1 ))
    fi
    sync_picker_selection
}

set_picker_filter() {
    FILTER_BUFFER="$1"
    filter_picker_items "$FILTER_BUFFER"
    sync_picker_selection
}

append_picker_filter() {
    set_picker_filter "${FILTER_BUFFER}$1"
}

backspace_picker_filter() {
    if [[ -n "$FILTER_BUFFER" ]]; then
        set_picker_filter "${FILTER_BUFFER%?}"
    fi
}

clear_picker_filter() {
    if [[ -n "$FILTER_BUFFER" ]]; then
        set_picker_filter ""
    fi
}

set_mode() {
    local new_mode="$1"
    CURRENT_MODE="$new_mode"
    reset_picker_selection
    set_picker_filter ""
}

toggle_mode() {
    if [[ "$CURRENT_MODE" == "projects" ]]; then
        set_mode "services"
    else
        set_mode "projects"
    fi
}

refresh_screen_data() {
    load_sessions
    load_items "$(current_root_dir)"
    filter_picker_items "$FILTER_BUFFER"
    sync_picker_selection
}

launch_selected_picker_item() {
    if (( FILTERED_MATCH_COUNT <= 0 )); then
        return
    fi
    launch_from_picker "${FILTERED_INDICES[$SELECTED_PICKER_POS]}"
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
                toggle_mode
                refresh_screen_data
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

filter_picker_items() {
    local filter_str="$1"
    local i
    local item_name
    local score
    local scored_matches=()

    FILTERED_INDICES=()
    FILTERED_MATCH_COUNT=0
    for (( i = 0; i < TOTAL_PICKER_ITEMS; i++ )); do
        item_name="${AVAILABLE_ITEMS[$i]}"
        if [[ -z "$filter_str" ]]; then
            FILTERED_INDICES+=("$i")
        else
            score=$(fuzzy_match_score "$filter_str" "$item_name")
            if (( score >= 0 )); then
                scored_matches+=("${score}:${i}")
            fi
        fi
    done

    if [[ -n "$filter_str" && ${#scored_matches[@]} -gt 0 ]]; then
        while IFS=: read -r _score match_idx; do
            [[ -n "$match_idx" ]] && FILTERED_INDICES+=("$match_idx")
        done < <(printf '%s\n' "${scored_matches[@]}" | sort -t: -k1,1nr -k2,2n)
    fi

    FILTERED_MATCH_COUNT=${#FILTERED_INDICES[@]}
}

# ── Screen Builder ───────────────────────────────────────────────────────────

RENDER_OUTPUT=""
RENDER_CONTENT_WIDTH=0
RENDER_RULE_WIDTH=0
RENDER_SESSION_ROWS=0
RENDER_PICKER_ROWS=0
RENDER_LEFT_WIDTH=0
RENDER_RIGHT_WIDTH=0
LEFT_PANE_OUTPUT=""
RIGHT_PANE_OUTPUT=""

append_render() {
    RENDER_OUTPUT+="$1"
}

append_left_render() {
    LEFT_PANE_OUTPUT+="$1"
}

append_right_render() {
    RIGHT_PANE_OUTPUT+="$1"
}

pad_visible_line() {
    local line="$1"
    local target_width="$2"
    local visible
    local pad

    visible=$(strip_ansi "$line")
    pad=$(( target_width - ${#visible} ))
    if (( pad < 0 )); then
        pad=0
    fi

    printf "%b%*s" "$line" "$pad" ""
}

render_header() {
    local mode_badge
    local subtitle

    if [[ "$CURRENT_MODE" == "projects" ]]; then
        mode_badge="${BOLD}${GREEN}[ Projects ]${RESET}"
        subtitle="Browse launchable projects and active sessions"
    else
        mode_badge="${BOLD}${MAGENTA}[ Services ]${RESET}"
        subtitle="Browse launchable services and active sessions"
    fi

    append_render "\n"
    append_render "  ${BOLD}${CYAN}Tmux Connect${RESET}\n"
    append_render "  ${mode_badge} ${DIM}${subtitle}${RESET}\n"
    append_render "  ${DIM}$(repeat_char "-" "$RENDER_RULE_WIDTH")${RESET}\n"
    append_render "  ${DIM}Enter launch selected${RESET}   ${DIM}Up/Down move${RESET}   ${DIM}Left/Right switch mode${RESET}\n\n"
}

render_left_pane() {
    local displayed_sessions=0
    local remaining_sessions=0
    local i
    local num
    local name
    local color_code
    local attached_indicator
    local prefix_plain
    local max_name_width
    local shown_name
    local tool

    LEFT_PANE_OUTPUT=""

    append_left_render "  ${BOLD}${WHITE}Sessions${RESET}"
    if (( TOTAL_SESSIONS > 0 )); then
        append_left_render " ${DIM}(${TOTAL_SESSIONS})${RESET}"
    fi
    append_left_render "\n"

    if (( TOTAL_SESSIONS == 0 )); then
        append_left_render "    ${DIM}(no active sessions)${RESET}\n"
    else
        for (( i = 0; i < TOTAL_SESSIONS && displayed_sessions < RENDER_SESSION_ROWS; i++ )); do
            num=$(( i + 1 ))
            name="${ALL_DISPLAY_NAMES[$i]}"
            tool="${ALL_DISPLAY_TOOLS[$i]}"
            if [[ "$tool" == "gemini" ]]; then
                color_code="$BLUE"
            else
                color_code="$ORANGE"
            fi

            if [[ "${ALL_DISPLAY_ATTACHED[$i]}" == "1" ]]; then
                attached_indicator="${BOLD}${color_code}*${RESET}"
            else
                attached_indicator=" "
            fi

            prefix_plain="${num}. * "
            max_name_width=$(( RENDER_LEFT_WIDTH - 6 - ${#prefix_plain} ))
            (( max_name_width < 8 )) && max_name_width=8
            shown_name=$(truncate_text "$name" "$max_name_width")
            append_left_render "    ${BOLD}${num}.${RESET} ${attached_indicator} ${color_code}${shown_name}${RESET}\n"
            displayed_sessions=$(( displayed_sessions + 1 ))
        done

        remaining_sessions=$(( TOTAL_SESSIONS - displayed_sessions ))
        if (( remaining_sessions > 0 )); then
            append_left_render "    ${DIM}(+${remaining_sessions} more)${RESET}\n"
        fi
    fi

    append_left_render "\n"
    append_left_render "  ${BOLD}${WHITE}Actions${RESET}\n"
    append_left_render "    ${DIM}[S] Scratchpad${RESET}\n"
    append_left_render "    ${DIM}[N] New folder${RESET}\n"
    append_left_render "    ${DIM}[R] Rename${RESET}\n"
    append_left_render "    ${DIM}[Q] Quit${RESET}\n"
    append_left_render "\n"
    append_left_render "  ${BOLD}${WHITE}Hints${RESET}\n"
    append_left_render "    ${DIM}[1-9] Attach${RESET}\n"
    append_left_render "    ${DIM}Type to search${RESET}\n"
    append_left_render "    ${DIM}Esc clears filter${RESET}\n"
}

render_right_pane() {
    local active_filter_display="${FILTER_BUFFER:-}"
    local picker_color
    local display_limit
    local start_index
    local end_index
    local display_pos
    local match_idx
    local name
    local shown_name
    local max_name_width
    local remaining_picker
    local label

    RIGHT_PANE_OUTPUT=""

    if [[ -z "$active_filter_display" ]]; then
        active_filter_display="(none)"
    fi
    active_filter_display=$(truncate_text "$active_filter_display" $(( RENDER_RIGHT_WIDTH - 22 )))

    if [[ "$CURRENT_MODE" == "projects" ]]; then
        append_right_render "  ${BOLD}${GREEN}[Projects]${RESET}   ${DIM}Services${RESET}\n"
        picker_color="$GREEN"
        label="projects"
    else
        append_right_render "  ${DIM}Projects${RESET}   ${BOLD}${MAGENTA}[Services]${RESET}\n"
        picker_color="$MAGENTA"
        label="services"
    fi
    append_right_render "  ${DIM}$(repeat_char "-" "$RENDER_RIGHT_WIDTH")${RESET}\n"

    append_right_render "  ${BOLD}${WHITE}Available To Launch${RESET}\n"
    append_right_render "  ${DIM}Filter:${RESET} ${BOLD}${WHITE}${active_filter_display}${RESET}"
    append_right_render " ${DIM}(${FILTERED_MATCH_COUNT}/${TOTAL_PICKER_ITEMS})${RESET}\n"

    if (( TOTAL_PICKER_ITEMS == 0 )); then
        append_right_render "   ${DIM}No available ${label}.${RESET}\n"
        append_right_render "   ${DIM}Press N to create one.${RESET}\n"
        return
    fi

    if (( FILTERED_MATCH_COUNT == 0 )); then
        append_right_render "   ${DIM}No matches for \"${FILTER_BUFFER}\".${RESET}\n"
        append_right_render "   ${DIM}Backspace edits. Esc clears.${RESET}\n"
        return
    fi

    LAST_PICKER_ROWS=$RENDER_PICKER_ROWS
    sync_picker_selection

    display_limit=$RENDER_PICKER_ROWS
    start_index=$PICKER_SCROLL_OFFSET
    end_index=$(( start_index + display_limit ))
    if (( end_index > FILTERED_MATCH_COUNT )); then
        end_index=$FILTERED_MATCH_COUNT
    fi

    name="${AVAILABLE_ITEMS[${FILTERED_INDICES[$SELECTED_PICKER_POS]}]}"
    shown_name=$(truncate_text "$name" $(( RENDER_RIGHT_WIDTH - 14 )))
    append_right_render "  ${DIM}Selected:${RESET} ${BOLD}${picker_color}${shown_name}${RESET}\n"

    for (( display_pos = start_index; display_pos < end_index; display_pos++ )); do
        match_idx="${FILTERED_INDICES[$display_pos]}"
        name="${AVAILABLE_ITEMS[$match_idx]}"
        if (( display_pos == SELECTED_PICKER_POS )); then
            max_name_width=$(( RENDER_RIGHT_WIDTH - 11 ))
            shown_name=$(truncate_text "$name" "$max_name_width")
            append_right_render "   ${BOLD}${WHITE}>${RESET} ${BOLD}${picker_color}${shown_name}${RESET} ${DIM}[enter]${RESET}\n"
        else
            max_name_width=$(( RENDER_RIGHT_WIDTH - 7 ))
            shown_name=$(truncate_text "$name" "$max_name_width")
            append_right_render "     ${picker_color}${shown_name}${RESET}\n"
        fi
    done

    if (( start_index > 0 )); then
        append_right_render "   ${DIM}(↑ ${start_index} above)${RESET}\n"
    fi

    remaining_picker=$(( FILTERED_MATCH_COUNT - end_index ))
    if (( remaining_picker > 0 )); then
        append_right_render "   ${DIM}(↓ ${remaining_picker} more matches)${RESET}\n"
    fi
}

draw_screen() {
    local term_cols
    local term_lines
    local available_rows
    local divider="  ${DIM}|${RESET} "
    local divider_visible_width=3
    local -a left_lines=()
    local -a right_lines=()
    local max_lines=0
    local i
    local left_line
    local right_line

    RENDER_OUTPUT=""
    term_cols=$(get_term_cols)
    term_lines=$(get_term_lines)
    RENDER_CONTENT_WIDTH=$(( term_cols - 6 ))
    (( RENDER_CONTENT_WIDTH < 22 )) && RENDER_CONTENT_WIDTH=22
    RENDER_RULE_WIDTH=$RENDER_CONTENT_WIDTH
    RENDER_LEFT_WIDTH=$(( RENDER_CONTENT_WIDTH * 32 / 100 ))
    (( RENDER_LEFT_WIDTH < 24 )) && RENDER_LEFT_WIDTH=24
    (( RENDER_LEFT_WIDTH > 34 )) && RENDER_LEFT_WIDTH=34
    RENDER_RIGHT_WIDTH=$(( RENDER_CONTENT_WIDTH - RENDER_LEFT_WIDTH - divider_visible_width ))
    if (( RENDER_RIGHT_WIDTH < 28 )); then
        RENDER_RIGHT_WIDTH=28
        RENDER_LEFT_WIDTH=$(( RENDER_CONTENT_WIDTH - RENDER_RIGHT_WIDTH - divider_visible_width ))
    fi

    available_rows=$(( term_lines - 16 ))
    (( available_rows < 8 )) && available_rows=8

    RENDER_SESSION_ROWS=$(( available_rows - 9 ))
    (( RENDER_SESSION_ROWS < 3 )) && RENDER_SESSION_ROWS=3
    if (( TOTAL_SESSIONS > 0 && RENDER_SESSION_ROWS > TOTAL_SESSIONS )); then
        RENDER_SESSION_ROWS=$TOTAL_SESSIONS
    fi

    RENDER_PICKER_ROWS=$(( available_rows - 4 ))
    (( RENDER_PICKER_ROWS < 5 )) && RENDER_PICKER_ROWS=5

    render_header
    render_left_pane
    render_right_pane

    mapfile -t left_lines < <(printf "%b" "$LEFT_PANE_OUTPUT")
    mapfile -t right_lines < <(printf "%b" "$RIGHT_PANE_OUTPUT")

    if (( ${#left_lines[@]} > max_lines )); then
        max_lines=${#left_lines[@]}
    fi
    if (( ${#right_lines[@]} > max_lines )); then
        max_lines=${#right_lines[@]}
    fi

    for (( i = 0; i < max_lines; i++ )); do
        left_line="${left_lines[$i]}"
        right_line="${right_lines[$i]}"
        [[ -z "${left_line+x}" ]] && left_line=""
        [[ -z "${right_line+x}" ]] && right_line=""
        append_render "$(pad_visible_line "$left_line" "$RENDER_LEFT_WIDTH")${divider}${right_line}\n"
    done

    if [[ -n "$STATUS_MSG" ]]; then
        append_render "\n  ${STATUS_COLOR}${STATUS_MSG}${RESET}\n"
    fi

    printf "\033[2J\033[H%b" "$RENDER_OUTPUT"
    printf "\n  > "
}

# Exit script with goodbye if the attached session was destroyed
check_exit_after_attach() {
    local sname="$1"
    if ! tmux has-session -t "=$sname" 2>/dev/null; then
        printf '\033[2J\033[H'
        printf '\n'
        printf '  \033[1;36m Thanks for using tmux-connect. See you next time! \033[0m\n'
        printf '\n'
        exit 0
    fi
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

prompt_tool() {
    local full_path="$1"

    # Skip tool choice for non-git projects — default to claude
    if ! git -C "$full_path" rev-parse --git-dir &>/dev/null 2>&1; then
        REPLY="claude"
        return 0
    fi

    echo ""
    printf "  Tool (c/g) [c]: "
    IFS= read -rsn1 tool_key
    echo ""

    case "$tool_key" in
        g|G)
            REPLY="gemini"
            ;;
        *)
            REPLY="claude"
            ;;
    esac
}

setup_worktree() {
    local project_dir="$1"
    local sname="$2"
    local worktree_base="/mnt/data/projects/.worktrees"
    local worktree_dir="$worktree_base/${sname}-gemini"
    local branch_name="gemini/$sname"

    # Create worktrees directory
    mkdir -p "$worktree_base"

    # Reuse existing registered worktree
    if [ -d "$worktree_dir" ] && git -C "$project_dir" worktree list --porcelain 2>/dev/null | grep -qF "worktree $worktree_dir"; then
        REPLY="$worktree_dir"
        return 0
    fi

    # Clean up orphaned worktree directory
    if [ -d "$worktree_dir" ]; then
        rm -rf "$worktree_dir"
    fi

    # Check for dirty working tree
    if [ -n "$(git -C "$project_dir" status --porcelain)" ]; then
        echo ""
        echo "  ⚠ Uncommitted changes on current branch."
        printf "  Stash them before creating worktree? (y/n) [y]: "
        IFS= read -rsn1 stash_key
        echo ""
        if [[ "$stash_key" != "n" && "$stash_key" != "N" ]]; then
            git -C "$project_dir" stash push -m "auto-stash before gemini worktree"
        fi
    fi

    # Create worktree on new branch
    if ! git -C "$project_dir" worktree add "$worktree_dir" -b "$branch_name" 2>/dev/null; then
        # Branch already exists — check it out instead
        if ! git -C "$project_dir" worktree add "$worktree_dir" "$branch_name" 2>/dev/null; then
            echo "  ✗ Failed to create worktree."
            return 1
        fi
    fi

    REPLY="$worktree_dir"
    return 0
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

    if tmux has-session -t "=$sname" 2>/dev/null; then
        tmux attach -t "=$sname"
        check_exit_after_attach "$sname"
    else
        prompt_tool "$full_path"
        local tool="$REPLY"
        local session_dir="$full_path"

        if [[ "$tool" == "gemini" ]]; then
            setup_worktree "$full_path" "$sname"
            if [[ $? -ne 0 ]]; then return 1; fi
            session_dir="$REPLY"
        fi

        tmux new-session -d -s "$sname" -c "$session_dir"
        tmux send-keys -t "$sname" "clear && /mnt/data/projects/script_stash/tmux-connect/ai-session $tool" Enter
        tmux set-environment -t "=$sname" PROJECT_DIR "$session_dir"
        tmux set-environment -t "=$sname" TOOL "$tool"
        tmux attach -t "=$sname"
        check_exit_after_attach "$sname"
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
    tmux attach -t "=$sname"
    check_exit_after_attach "$sname"
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

next_scratchpad_number() {
    local sp_max=0 sp_line sp_num
    while IFS= read -r sp_line; do
        sp_num="${sp_line#scratchpad-}"
        if [ "$sp_num" -gt "$sp_max" ] 2>/dev/null; then
            sp_max="$sp_num"
        fi
    done < <(tmux ls -F '#{session_name}' 2>/dev/null | grep -E '^scratchpad-[0-9]+$')
    echo $(( sp_max + 1 ))
}

handle_scratchpad() {
    # Check if ANY scratchpad session exists (base or numbered)
    local has_any_scratchpad=0
    if tmux ls -F '#{session_name}' 2>/dev/null | grep -qE '^scratchpad(-|$)'; then
        has_any_scratchpad=1
    fi

    # No scratchpads exist — create the base scratchpad and attach
    if [ "$has_any_scratchpad" -eq 0 ]; then
        prompt_tool "$SCRATCH_DIR"
        local tool="$REPLY"
        tmux new-session -d -s scratchpad -c "$SCRATCH_DIR"
        tmux send-keys -t "scratchpad" "clear && /mnt/data/projects/script_stash/tmux-connect/ai-session $tool" Enter
        tmux set-environment -t "=scratchpad" TOOL "$tool"
        tmux attach -t "=scratchpad"
        check_exit_after_attach "scratchpad"
        return
    fi

    # At least one scratchpad exists — prompt for auto-number or custom name
    local sp_name
    echo ""
    read_input_with_cancel "  Name for new scratchpad (Enter for auto): "
    if [[ $? -ne 0 ]]; then return 0; fi
    local sp_input
    sp_input=$(echo "$REPLY" | xargs)

    if [ -z "$sp_input" ]; then
        sp_name="scratchpad-$(next_scratchpad_number)"
    else
        sp_name="scratchpad-${sp_input}"
        if tmux has-session -t "=$sp_name" 2>/dev/null; then
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

    prompt_tool "$SCRATCH_DIR"
    local tool="$REPLY"
    tmux new-session -d -s "$sp_name" -c "$SCRATCH_DIR"
    tmux send-keys -t "$sp_name" "clear && /mnt/data/projects/script_stash/tmux-connect/ai-session $tool" Enter
    tmux set-environment -t "=$sp_name" TOOL "$tool"
    tmux attach -t "=$sp_name"
    check_exit_after_attach "$sp_name"
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

    # Scratchpad sessions: prompt for suffix, preserve prefix
    if [[ "$old_name" == scratchpad || "$old_name" == scratchpad-* ]]; then
        read_input_with_cancel "  New suffix for '$old_name' (blank = auto-number): "
        if [[ $? -ne 0 ]]; then return 0; fi
        local suffix
        suffix=$(echo "$REPLY" | xargs)

        if [ -z "$suffix" ]; then
            newname="scratchpad-$(next_scratchpad_number)"
        else
            if [[ "$suffix" =~ [.:=] ]]; then
                STATUS_MSG="Suffix cannot contain '.', ':', or '='."
                STATUS_COLOR="$RED"
                return
            fi
            newname="scratchpad-${suffix}"
        fi

        if tmux has-session -t "=$newname" 2>/dev/null; then
            STATUS_MSG="Session '$newname' already exists. Choose a different name."
            STATUS_COLOR="$RED"
            return
        fi

        if tmux rename-session -t "=$old_name" "$newname"; then
            STATUS_MSG="Renamed '$old_name' to '$newname'."
            STATUS_COLOR="$GREEN"
        else
            STATUS_MSG="Failed to rename '$old_name'."
            STATUS_COLOR="$RED"
        fi
        return
    fi

    # Non-scratchpad sessions: original rename behavior
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

    if tmux has-session -t "=$newname" 2>/dev/null; then
        STATUS_MSG="Session '$newname' already exists. Choose a different name."
        STATUS_COLOR="$RED"
        return
    fi

    if tmux rename-session -t "=$old_name" "$newname"; then
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

confirm_command_key() {
    local cmd_key="$1"
    printf "%s" "$cmd_key"
    while true; do
        IFS= read -rsn1 ch
        if [[ "$ch" == '' ]]; then
            return 0
        fi
        if [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then
            printf "\b \b"
            skip_reload=1
            return 1
        fi
        if [[ "$ch" == $'\e' ]]; then
            handle_escape_in_confirm "$cmd_key"
            if [[ "$ESCAPE_RESULT" == "cancel" ]]; then
                return 1
            fi
        fi
    done
}

dispatch_command_key() {
    local key="$1"
    case "$key" in
        S) handle_scratchpad ;;
        N) handle_new_folder ;;
        R) handle_rename ;;
        Q)
            echo ""
            exit 0
            ;;
    esac
}

handle_main_escape() {
    local seq1
    local seq2

    IFS= read -rsn1 -t 0.2 seq1
    if [[ "$seq1" == '[' ]]; then
        IFS= read -rsn1 -t 0.2 seq2
        case "$seq2" in
            A)
                move_picker_selection -1
                return 0
                ;;
            B)
                move_picker_selection 1
                return 0
                ;;
            C|D)
                toggle_mode
                return 0
                ;;
            *)
                while IFS= read -rsn1 -t 0.05 _discard; do :; done
                return 0
                ;;
        esac
    fi

    while IFS= read -rsn1 -t 0.05 _discard; do :; done
    clear_picker_filter
    return 0
}

# ── Main Loop ────────────────────────────────────────────────────────────────

skip_reload=0
pushback_key=""
while true; do
    STATUS_MSG=""
    STATUS_COLOR=""
    if [[ "$skip_reload" -eq 1 ]]; then
        skip_reload=0
    else
        refresh_screen_data
    fi

    draw_screen

    # Read first character (or consume a pushed-back key)
    if [[ -n "$pushback_key" ]]; then
        key="$pushback_key"
        pushback_key=""
    else
        IFS= read -rsn1 key
    fi

    if [[ "$key" == $'\e' ]]; then
        handle_main_escape
        continue
    fi

    case "$key" in
        [0-9])
            if [[ -n "$FILTER_BUFFER" ]]; then
                append_picker_filter "$key"
                continue
            fi
            # Show the digit, read more digits until Enter
            input="$key"
            printf "%s" "$key"
            num_cancelled=0
            while true; do
                IFS= read -rsn1 ch
                if [[ "$ch" == '' ]]; then  # Enter
                    if [[ -n "$input" ]]; then break; fi
                    # Empty input on Enter — stay in inner loop, no redraw needed
                elif [[ "$ch" == $'\e' ]]; then
                    handle_escape_in_confirm "$input"
                    if [[ "$ESCAPE_RESULT" == "cancel" ]]; then
                        num_cancelled=1
                        break
                    fi
                elif [[ "$ch" == $'\x7f' || "$ch" == $'\b' ]]; then  # Backspace
                    if [[ ${#input} -gt 0 ]]; then
                        input="${input%?}"
                        printf "\b \b"
                    fi
                    # If input is already empty, stay in inner loop (no redraw needed)
                elif [[ "$ch" =~ [0-9] ]]; then
                    input="${input}${ch}"
                    printf "%s" "$ch"
                elif [[ -z "$input" && "$ch" =~ [a-zA-Z] ]]; then
                    pushback_key="$ch"
                    num_cancelled=1
                    break
                fi
            done

            if [[ "$num_cancelled" -eq 1 ]]; then
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
            append_picker_filter "$key"
            continue
            ;;
        $'\x7f'|$'\b')
            backspace_picker_filter
            continue
            ;;
        '')
            launch_selected_picker_item
            ;;
        [A-Z])
            if [[ -n "$FILTER_BUFFER" && ! "$key" =~ ^[SNRQ]$ ]]; then
                append_picker_filter "$key"
                continue
            fi
            if [[ "$key" =~ ^[SNRQ]$ ]]; then
                if confirm_command_key "$key"; then
                    dispatch_command_key "$key"
                fi
            else
                append_picker_filter "$key"
            fi
            ;;
        *)
            if is_filterable_key "$key"; then
                append_picker_filter "$key"
            fi
            ;;
    esac
done
