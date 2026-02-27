#!/bin/bash

# ── tmux-connect.sh ──────────────────────────────────────────────────────────
# Startup launcher for SSH sessions on the NUC.
# Manages tmux sessions scoped to project folders under /mnt/data/projects/.
# ─────────────────────────────────────────────────────────────────────────────

PROJECTS_DIR="/mnt/data/projects"
COLUMN_WIDTH=30
MENU_WIDTH=52

# ── Colors ───────────────────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

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

# ── Helpers ──────────────────────────────────────────────────────────────────

# Collect active tmux sessions into parallel arrays.
# Populates: SESSION_NAMES, SESSION_WINDOWS, SESSION_ATTACHED
load_sessions() {
    SESSION_NAMES=()
    SESSION_WINDOWS=()
    SESSION_ATTACHED=()

    if ! tmux has-session 2>/dev/null; then
        return
    fi

    while IFS= read -r line; do
        local name windows attached
        name=$(echo "$line" | cut -d: -f1)
        windows=$(echo "$line" | grep -oP '\d+ windows?')
        attached=""
        echo "$line" | grep -q "(attached)" && attached="yes"

        SESSION_NAMES+=("$name")
        SESSION_WINDOWS+=("$windows")
        SESSION_ATTACHED+=("$attached")
    done < <(tmux ls 2>/dev/null)
}

# Build list of project folders that do NOT have an active tmux session.
# Populates: AVAILABLE_PROJECTS
load_projects() {
    AVAILABLE_PROJECTS=()

    # Gather PROJECT_DIR values from all active sessions
    local -A used_dirs
    for sname in "${SESSION_NAMES[@]}"; do
        local pdir
        pdir=$(tmux show-environment -t "$sname" PROJECT_DIR 2>/dev/null | grep -v '^-' | cut -d= -f2)
        if [ -n "$pdir" ]; then
            used_dirs["$pdir"]=1
        fi
    done

    # Iterate project folders, skip those already bound to a session
    while IFS= read -r folder; do
        local full_path="$PROJECTS_DIR/$folder"
        if [ -z "${used_dirs[$full_path]+_}" ]; then
            AVAILABLE_PROJECTS+=("$folder")
        fi
    done < <(find "$PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -not -name 'docs' -printf '%f\n' | sort -f)
}

# Print a two-column list of items.
# $1 = "display" (no numbers, dim bullets) or "select" (numbered)
# The items are read from AVAILABLE_PROJECTS.
print_two_columns() {
    local mode="$1"
    local count=${#AVAILABLE_PROJECTS[@]}
    local rows=$(( (count + 1) / 2 ))

    for (( r = 0; r < rows; r++ )); do
        local left_idx=$r
        local right_idx=$(( r + rows ))

        # Left column
        local left_label left_name
        left_name="${AVAILABLE_PROJECTS[$left_idx]}"
        if [ "$mode" = "select" ]; then
            local left_num=$(( left_idx + 1 ))
            left_label=$(printf "${BOLD}${YELLOW}[%2d]${RESET}  %-${COLUMN_WIDTH}s" "$left_num" "$left_name")
        else
            left_label=$(printf "${DIM}      %-${COLUMN_WIDTH}s${RESET}" "$left_name")
        fi

        # Right column (may not exist)
        local right_label=""
        if [ $right_idx -lt $count ]; then
            local right_name="${AVAILABLE_PROJECTS[$right_idx]}"
            if [ "$mode" = "select" ]; then
                local right_num=$(( right_idx + 1 ))
                right_label=$(printf "${BOLD}${YELLOW}[%2d]${RESET}  %s" "$right_num" "$right_name")
            else
                right_label=$(printf "${DIM}%s${RESET}" "$right_name")
            fi
        fi

        echo -e "    ${left_label}${right_label}"
    done
}

# Draw the header box
draw_header() {
    echo ""
    echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}  ║             tmux session manager                 ║${RESET}"
    echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# Draw sessions section.
# $1 = "main" (numbered) or "project" (dim bullets, not selectable)
draw_sessions() {
    local mode="$1"
    local count=${#SESSION_NAMES[@]}

    if [ $count -eq 0 ]; then
        return
    fi

    echo -e "  ${BOLD}Active Sessions:${RESET}"

    for (( i = 0; i < count; i++ )); do
        local prefix attached_label=""
        if [ "$mode" = "main" ]; then
            prefix=$(printf "${BOLD}${YELLOW}[%d]${RESET}" $(( i + 1 )))
        else
            prefix="${DIM} ● ${RESET}"
        fi

        if [ "${SESSION_ATTACHED[$i]}" = "yes" ]; then
            attached_label="  ${GREEN}● attached${RESET}"
        fi

        echo -e "    ${prefix}  ${SESSION_NAMES[$i]}  ${DIM}(${SESSION_WINDOWS[$i]})${RESET}${attached_label}"
    done

    echo ""
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $MENU_WIDTH))${RESET}"
    echo ""
}

# Draw projects section.
# $1 = "display" or "select"
draw_projects() {
    local mode="$1"

    echo -e "  ${BOLD}Projects:${RESET}"

    if [ ${#AVAILABLE_PROJECTS[@]} -eq 0 ]; then
        echo -e "    ${DIM}All projects have active sessions${RESET}"
    else
        print_two_columns "$mode"
    fi

    echo ""
    echo -e "  ${DIM}$(printf '─%.0s' $(seq 1 $MENU_WIDTH))${RESET}"
    echo ""
}

# Prompt for a session name, with a default.
# $1 = default name (folder name)
# Sets REPLY to the chosen name.
prompt_session_name() {
    local default="$1"
    echo ""
    read -p "  Session name [$default]: " input
    if [ -z "$input" ]; then
        REPLY="$default"
    else
        REPLY="$input"
    fi
}

# Create a new tmux session in the given project folder.
# $1 = folder name, $2 = session name
launch_session() {
    local folder="$1"
    local sname="$2"
    local full_path="$PROJECTS_DIR/$folder"

    tmux new-session -d -s "$sname" -c "$full_path"
    tmux set-environment -t "$sname" PROJECT_DIR "$full_path"
    tmux send-keys -t "$sname" "claude --dangerously-skip-permissions" Enter
    tmux attach -t "$sname"
}

# ── Main Menu ────────────────────────────────────────────────────────────────

show_main_menu() {
    clear
    draw_header
    load_sessions
    load_projects
    draw_sessions "main"
    draw_projects "display"

    echo -e "    ${BOLD}${YELLOW}[p]${RESET}  Select a project"
    echo -e "    ${BOLD}${YELLOW}[n]${RESET}  New project"
    echo -e "    ${BOLD}${YELLOW}[r]${RESET}  Rename a session"
    echo -e "    ${BOLD}${YELLOW}[q]${RESET}  Quit"
    echo ""
}

# ── Project Selection Mode ───────────────────────────────────────────────────

show_project_menu() {
    clear
    draw_header
    load_sessions
    load_projects
    draw_sessions "project"
    draw_projects "select"

    echo -e "    ${BOLD}${YELLOW}[b]${RESET}  Back"
    echo -e "    ${BOLD}${YELLOW}[q]${RESET}  Quit"
    echo ""
}

# ── Main Loop ────────────────────────────────────────────────────────────────

while true; do
    show_main_menu
    read -p "  Select: " choice

    case "$choice" in
        q)
            echo -e "  ${DIM}Goodbye.${RESET}"
            exit 0
            ;;

        p)
            # Enter project selection mode
            while true; do
                show_project_menu

                if [ ${#AVAILABLE_PROJECTS[@]} -eq 0 ]; then
                    echo -e "  ${DIM}No projects to select. Press [b] to go back.${RESET}"
                fi

                read -p "  Select: " pchoice

                if [ "$pchoice" = "q" ]; then
                    echo -e "  ${DIM}Goodbye.${RESET}"
                    exit 0
                elif [ "$pchoice" = "b" ]; then
                    break
                elif [[ "$pchoice" =~ ^[0-9]+$ ]]; then
                    local_idx=$(( pchoice - 1 ))
                    if [ $local_idx -ge 0 ] && [ $local_idx -lt ${#AVAILABLE_PROJECTS[@]} ]; then
                        folder="${AVAILABLE_PROJECTS[$local_idx]}"
                        prompt_session_name "$folder"
                        sname="$REPLY"
                        launch_session "$folder" "$sname"
                        exit 0
                    else
                        echo -e "  ${RED}Invalid selection.${RESET}"
                        sleep 1
                    fi
                else
                    echo -e "  ${RED}Invalid selection.${RESET}"
                    sleep 1
                fi
            done
            ;;

        n)
            # New project
            echo ""
            read -p "  Folder name: " folder
            if [ -z "$folder" ]; then
                echo -e "  ${RED}No folder name provided.${RESET}"
                sleep 1
                continue
            fi
            mkdir -p "$PROJECTS_DIR/$folder"
            prompt_session_name "$folder"
            sname="$REPLY"
            launch_session "$folder" "$sname"
            exit 0
            ;;

        r)
            # Rename a session
            if [ ${#SESSION_NAMES[@]} -eq 0 ]; then
                echo -e "  ${RED}No active sessions to rename.${RESET}"
                sleep 1
                continue
            fi
            echo ""
            read -p "  Session number to rename: " num
            if [[ "$num" =~ ^[0-9]+$ ]]; then
                local_idx=$(( num - 1 ))
                if [ $local_idx -ge 0 ] && [ $local_idx -lt ${#SESSION_NAMES[@]} ]; then
                    old_name="${SESSION_NAMES[$local_idx]}"
                    read -p "  New name for '$old_name': " newname
                    if [ -n "$newname" ]; then
                        tmux rename-session -t "$old_name" "$newname"
                        echo -e "  ${GREEN}Renamed '$old_name' to '$newname'.${RESET}"
                        sleep 1
                    else
                        echo -e "  ${RED}No name provided.${RESET}"
                        sleep 1
                    fi
                else
                    echo -e "  ${RED}Invalid session number.${RESET}"
                    sleep 1
                fi
            else
                echo -e "  ${RED}Invalid input.${RESET}"
                sleep 1
            fi
            ;;

        *)
            # Numeric input — attach to a session
            if [[ "$choice" =~ ^[0-9]+$ ]]; then
                local_idx=$(( choice - 1 ))
                if [ $local_idx -ge 0 ] && [ $local_idx -lt ${#SESSION_NAMES[@]} ]; then
                    tmux attach -t "${SESSION_NAMES[$local_idx]}"
                    exit 0
                else
                    echo -e "  ${RED}Invalid session number.${RESET}"
                    sleep 1
                fi
            else
                echo -e "  ${RED}Invalid selection. Try again.${RESET}"
                sleep 1
            fi
            ;;
    esac
done
