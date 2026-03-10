# Dual AI Tool Workflow — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Gemini CLI support to tmux-connect.sh with git worktree isolation and auto-commit on exit.

**Architecture:** One new tool-choice prompt in the tmux launcher, a wrapper script (`ai-session`) that launches either tool and auto-commits on exit, and git worktrees for Gemini session isolation. Session colors change from type-based to tool-based.

**Tech Stack:** Bash, tmux, git worktrees

---

### Task 1: Create ai-session wrapper script

**Files:**
- Create: `ai-session`

**Step 1: Write the ai-session script**

```bash
#!/bin/bash

# ── ai-session ──────────────────────────────────────────────────────────────
# Wrapper for AI CLI tools. Launches the tool interactively, then auto-commits
# any uncommitted changes on exit using a headless AI-generated commit message.
# Usage: ai-session <claude|gemini>
# ────────────────────────────────────────────────────────────────────────────

TOOL="$1"

if [ -z "$TOOL" ]; then
    echo "Usage: ai-session <claude|gemini>"
    exit 1
fi

# ── Launch tool interactively ─────────────────────────────────────────────

case "$TOOL" in
    claude)
        claude --dangerously-skip-permissions
        ;;
    gemini)
        gemini --yolo
        ;;
    *)
        echo "Unknown tool: $TOOL"
        exit 1
        ;;
esac

# ── Auto-commit on exit ──────────────────────────────────────────────────

# Only proceed if we're in a git repo
if ! git rev-parse --git-dir &>/dev/null; then
    exit 0
fi

# Only proceed if there are uncommitted changes
if [ -z "$(git status --porcelain)" ]; then
    exit 0
fi

echo ""
echo "  Changes detected — running AI commit review..."

# Stage tracked files only (no secrets risk)
git add -u

# Check if staging produced anything (changes might be untracked-only)
if [ -z "$(git diff --cached --name-only)" ]; then
    echo "  No tracked files changed. Skipping commit."
    exit 0
fi

# Generate commit message via headless AI call
DIFF_STAT=$(git diff --cached --stat)

case "$TOOL" in
    claude)
        MSG=$(claude -p "Write a single-line git commit message (no quotes, no prefix like 'feat:') for these changes. Output ONLY the message, nothing else: $DIFF_STAT" --dangerously-skip-permissions 2>/dev/null)
        ;;
    gemini)
        MSG=$(gemini -p "Write a single-line git commit message (no quotes, no prefix like 'feat:') for these changes. Output ONLY the message, nothing else: $DIFF_STAT" --yolo 2>/dev/null)
        ;;
esac

# Fallback if AI call failed
if [ -z "$MSG" ]; then
    MSG="wip: auto-save from $TOOL session"
fi

# Clean up message — remove quotes, trim whitespace
MSG=$(echo "$MSG" | sed 's/^["'\'']*//;s/["'\'']*$//' | xargs)

git commit -m "$MSG"
echo "  ✓ Committed: $MSG"
```

**Step 2: Make it executable**

Run: `chmod +x ai-session`

**Step 3: Verify it runs without errors**

Run: `./ai-session`
Expected: `Usage: ai-session <claude|gemini>` and exit code 1

**Step 4: Commit**

```bash
git add ai-session
git commit -m "feat: add ai-session wrapper for tool launch + auto-commit on exit"
```

---

### Task 2: Add tool color constants to tmux-connect.sh

**Files:**
- Modify: `tmux-connect.sh:14-22` (color constants)

**Step 1: Add ORANGE and rename BLUE for clarity**

After the existing color constants (line 22), add:

```bash
ORANGE="\033[38;5;208m"
```

The existing `BLUE="\033[34m"` stays as-is — it's already the right color for Gemini.

**Step 2: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: add orange color constant for Claude sessions"
```

---

### Task 3: Add TOOL env var to load_sessions

**Files:**
- Modify: `tmux-connect.sh:71-125` (load_sessions function)

**Step 1: Add ALL_DISPLAY_TOOLS array**

Add to the state variables section (around line 43, after `ALL_DISPLAY_ATTACHED=()`):

```bash
ALL_DISPLAY_TOOLS=()
```

**Step 2: Read TOOL env var in load_sessions**

Inside the `while` loop in `load_sessions` (after line 96, where `SESSION_DIRS` is set), add:

```bash
            local tool_val
            tool_val=$(tmux show-environment -t "$sname" TOOL 2>/dev/null | grep -v '^-' | cut -d= -f2)
            if [ -z "$tool_val" ]; then
                tool_val="claude"
            fi
```

Then in each of the three `for` loops that build display arrays (lines 108-122), add after each `ALL_DISPLAY_ATTACHED` line:

```bash
        ALL_DISPLAY_TOOLS+=("$tool_val_for_session")
```

Actually, a cleaner approach: store tool values in an associative array (like `session_attached`), then reference it in the display loops.

Add to the top of `load_sessions` (after line 75):

```bash
    local -A session_tools
```

Inside the while loop, after storing `SESSION_DIRS`, add:

```bash
            local tool_val
            tool_val=$(tmux show-environment -t "$sname" TOOL 2>/dev/null | grep -v '^-' | cut -d= -f2)
            session_tools["$sname"]="${tool_val:-claude}"
```

In the three for-loops that build display arrays, add after each `ALL_DISPLAY_ATTACHED+=` line:

For projects loop (after line 111):
```bash
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
```

For services loop (after line 116):
```bash
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
```

For scratchpads loop (after line 121):
```bash
        ALL_DISPLAY_TOOLS+=("${session_tools[$name]}")
```

Also add `ALL_DISPLAY_TOOLS=()` to the reset block at line 78 (after `ALL_DISPLAY_ATTACHED=()`).

**Step 3: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: read TOOL env var from tmux sessions in load_sessions"
```

---

### Task 4: Change session colors from type-based to tool-based

**Files:**
- Modify: `tmux-connect.sh:296-324` (draw_screen session rendering)

**Step 1: Replace the color assignment case statement**

Replace lines 296-306 (the `case "$stype"` block for `color_code`) with:

```bash
            local tool="${ALL_DISPLAY_TOOLS[$i]}"
            if [[ "$tool" == "gemini" ]]; then
                color_code="$BLUE"
            else
                color_code="$ORANGE"
            fi
```

**Step 2: Replace the session label rendering case statement**

Replace lines 314-324 (the `case "$stype"` block for `session_labels`) with:

```bash
            session_labels+=("$(printf "${BOLD}%d.${RESET} %b ${color_code}%s${RESET}" "$num" "$attached_indicator" "$name")")
```

This is now a single line — no case statement needed since `color_code` is already set correctly above.

**Step 3: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: color sessions by tool (orange=Claude, blue=Gemini)"
```

---

### Task 5: Add tool prompt and worktree logic to launch_session

**Files:**
- Modify: `tmux-connect.sh:473-498` (launch_session function)

**Step 1: Add a prompt_tool helper function**

Add this new function before `launch_session` (around line 471):

```bash
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
```

**Step 2: Add a setup_worktree helper function**

Add after `prompt_tool`:

```bash
setup_worktree() {
    local project_dir="$1"
    local sname="$2"
    local worktree_base="/mnt/data/projects/.worktrees"
    local worktree_dir="$worktree_base/${sname}-gemini"
    local branch_name="gemini/$sname"

    # Create worktrees directory
    mkdir -p "$worktree_base"

    # Reuse existing worktree
    if [ -d "$worktree_dir" ]; then
        REPLY="$worktree_dir"
        return 0
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
    git -C "$project_dir" worktree add "$worktree_dir" -b "$branch_name" 2>/dev/null

    # If branch already exists, check it out instead
    if [ $? -ne 0 ]; then
        git -C "$project_dir" worktree add "$worktree_dir" "$branch_name" 2>/dev/null
    fi

    if [ ! -d "$worktree_dir" ]; then
        echo "  ✗ Failed to create worktree."
        return 1
    fi

    REPLY="$worktree_dir"
    return 0
}
```

**Step 3: Rewrite launch_session to integrate tool choice**

Replace the entire `launch_session` function (lines 473-498) with:

```bash
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
        tmux send-keys -t "$sname" "clear && ai-session $tool" Enter
        tmux set-environment -t "=$sname" PROJECT_DIR "$session_dir"
        tmux set-environment -t "=$sname" TOOL "$tool"
        tmux attach -t "=$sname"
        check_exit_after_attach "$sname"
    fi
}
```

**Step 4: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: add tool prompt and worktree logic to launch_session"
```

---

### Task 6: Add tool prompt to handle_scratchpad

**Files:**
- Modify: `tmux-connect.sh:555-600` (handle_scratchpad function)

**Step 1: Add tool prompt to scratchpad creation**

In `handle_scratchpad`, there are two places where sessions are created:

1. Lines 563-569 — first scratchpad (no existing ones)
2. Lines 596-599 — subsequent scratchpads

For each, add tool prompt before session creation. The first block (lines 563-569) becomes:

```bash
    if [ "$has_any_scratchpad" -eq 0 ]; then
        prompt_tool "$PROJECTS_DIR"
        local tool="$REPLY"
        tmux new-session -d -s scratchpad -c "$PROJECTS_DIR"
        tmux send-keys -t "scratchpad" "clear && ai-session $tool" Enter
        tmux set-environment -t "=scratchpad" TOOL "$tool"
        tmux attach -t "=scratchpad"
        check_exit_after_attach "scratchpad"
        return
    fi
```

The second block (lines 596-599) becomes:

```bash
    prompt_tool "$PROJECTS_DIR"
    local tool="$REPLY"
    tmux new-session -d -s "$sp_name" -c "$PROJECTS_DIR"
    tmux send-keys -t "$sp_name" "clear && ai-session $tool" Enter
    tmux set-environment -t "=$sp_name" TOOL "$tool"
    tmux attach -t "=$sp_name"
    check_exit_after_attach "$sp_name"
```

**Step 2: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: add tool prompt to scratchpad creation"
```

---

### Task 7: Ensure ai-session is on PATH

**Files:**
- Modify: `tmux-connect.sh` (top of file, after guards)

**Step 1: Add script directory to PATH**

After line 67 (the `mkdir -p "$SERVICES_DIR"` line), add:

```bash
# Ensure ai-session wrapper is available on PATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"
```

This ensures that `ai-session` (which lives alongside `tmux-connect.sh` in `script_stash/`) is callable without a full path.

**Step 2: Commit**

```bash
git add tmux-connect.sh
git commit -m "feat: add script directory to PATH for ai-session access"
```

---

### Task 8: Manual integration test

**Step 1: Run tmux-connect.sh and verify display**

Run: `./tmux-connect.sh`
Expected: Script launches normally, existing sessions (if any) show in orange (Claude default).

**Step 2: Select a project and verify tool prompt**

Pick a git-initialized project from the picker.
Expected: Session name prompt appears, then `Tool (c/g) [c]:` prompt. Pressing Enter defaults to Claude.

**Step 3: Verify Claude session launches**

Expected: tmux session opens, `ai-session claude` runs, Claude starts with `--dangerously-skip-permissions`.

**Step 4: Exit Claude and verify auto-commit**

Make a small change to a tracked file, then exit Claude (`/exit`).
Expected: `Changes detected — running AI commit review...` followed by `✓ Committed: <message>`.

**Step 5: Test Gemini worktree creation**

Open tmux-connect, pick same project, press `g` at tool prompt.
Expected: Worktree created at `.worktrees/<session>-gemini/`, Gemini launches with `--yolo`.

**Step 6: Verify session colors**

After having both a Claude and Gemini session, check the session list.
Expected: Claude session in orange, Gemini session in blue.

**Step 7: Commit final state**

```bash
git add -A
git commit -m "feat: complete dual AI tool workflow implementation"
```
