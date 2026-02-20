#!/bin/bash

# Clear screen for clean display
clear

# Change to projects directory
cd /mnt/data/projects/ || { echo "/mnt/data/projects/ not found"; exit 1; }

# If already inside tmux, just show a warning
if [ -n "$TMUX" ]; then
  echo "Already inside a tmux session."
  exit 0
fi

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

show_menu() {
  clear
  echo ""
  echo -e "${BOLD}${CYAN}  ╔══════════════════════════════════╗${RESET}"
  echo -e "${BOLD}${CYAN}  ║       tmux session manager       ║${RESET}"
  echo -e "${BOLD}${CYAN}  ╚══════════════════════════════════╝${RESET}"
  echo ""

  # No sessions exist — create one
  if ! tmux has-session 2>/dev/null; then
    echo -e "  ${DIM}No active sessions found.${RESET}"
    echo ""
    read -p "  Enter new session name: " name
    tmux new -s "$name" \; send-keys "cd /mnt/data/projects/ && clear" Enter \; send-keys "clear && claude --dangerously-skip-permissions" Enter
    exit 0
  fi

  echo -e "  ${BOLD}Active Sessions:${RESET}"
  echo ""

  i=1
  while IFS= read -r line; do
    name=$(echo "$line" | cut -d: -f1)
    windows=$(echo "$line" | grep -oP '\d+ windows?')
    attached=""
    echo "$line" | grep -q "(attached)" && attached="${GREEN}● attached${RESET}"

    echo -e "    ${BOLD}${YELLOW}[$i]${RESET}  $name  ${DIM}($windows)${RESET}  $attached"
    i=$((i + 1))
  done < <(tmux ls)

  echo ""
  echo -e "    ${BOLD}${YELLOW}[n]${RESET}  Create new session"
  echo -e "    ${BOLD}${YELLOW}[r]${RESET}  Rename a session"
  echo -e "    ${BOLD}${YELLOW}[q]${RESET}  Quit"
  echo ""
}

while true; do
  show_menu
  read -p "  Select: " choice

  if [ "$choice" = "q" ]; then
    echo -e "  ${DIM}Goodbye.${RESET}"
    exit 0

  elif [ "$choice" = "n" ]; then
    read -p "  Enter new session name: " name
    tmux new -s "$name" \; send-keys "cd /mnt/data/projects/ && clear" Enter \; send-keys "clear && claude --dangerously-skip-permissions" Enter
    exit 0

  elif [ "$choice" = "r" ]; then
    read -p "  Session number to rename: " num
    session=$(tmux ls -F '#{session_name}' | sed -n "${num}p")
    if [ -n "$session" ]; then
      read -p "  New name for '$session': " newname
      tmux rename-session -t "$session" "$newname"
      echo -e "  ${GREEN}Renamed '$session' to '$newname'.${RESET}"
      sleep 1
    else
      echo -e "  ${RED}Invalid session number.${RESET}"
      sleep 1
    fi

  else
    session=$(tmux ls -F '#{session_name}' | sed -n "${choice}p")
    if [ -n "$session" ]; then
      tmux attach -t "$session"
      exit 0
    else
      echo -e "  ${RED}Invalid selection. Try again.${RESET}"
      sleep 1
    fi
  fi
done
