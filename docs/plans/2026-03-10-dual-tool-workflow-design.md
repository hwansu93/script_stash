# Dual AI Tool Workflow — tmux-connect + ai-session

**Date**: 2026-03-10
**Status**: Approved
**Scope**: tmux-connect.sh modification + new ai-session wrapper

## Problem

Using both Claude Code and Gemini CLI on the same project risks file conflicts. No isolation between tools, no automated handoff, no commit discipline on session exit.

## Solution

Two changes: add a tool-choice prompt to tmux-connect.sh, and wrap AI tool launches in an `ai-session` script that auto-commits on exit.

## Architecture

### tmux-connect.sh Changes

**One new prompt** in `launch_session`, after session name:

```
Tool (c/g) [c]:
```

Single keypress, defaults to Claude (Enter).

**Claude path** (default): identical to today — opens project directory, runs `ai-session claude`.

**Gemini path**: creates a git worktree at `/mnt/data/projects/.worktrees/<session>-gemini/` on branch `gemini/<session>`, runs `ai-session gemini` in that worktree.

**Worktree directory**: `.worktrees/` inside projects dir. Already excluded from picker by `.*` pattern in `EXCLUDE_DIRS`.

**Non-git projects**: skip tool prompt, launch Claude directly (current behavior).

### ai-session Wrapper

New file: `/mnt/data/projects/script_stash/ai-session`

~25 lines. Two responsibilities:

1. **Launch tool** with correct flags:
   - Claude: `claude --dangerously-skip-permissions`
   - Gemini: `gemini --yolo`

2. **Auto-commit on exit** (if git repo with uncommitted changes):
   - `git add -u` (tracked files only — no secrets risk)
   - Run the same tool headlessly to generate commit message: `<tool> -p "Write a single-line git commit message for this diff..." <flags>`
   - If headless call fails: fallback to `wip: auto-save from <tool> session`
   - If no changes: exit silently

### Session Color Scheme

**Active sessions** — colored by tool (replaces project/service/scratchpad coloring):

| Tool | Color | ANSI |
|------|-------|------|
| Claude | Orange | `\033[38;5;208m` |
| Gemini | Blue | `\033[34m` |

Attached indicator `●` matches tool color. No suffix or symbol for tool — color IS the information.

**Picker** — colored by type (unchanged):

| Type | Color |
|------|-------|
| Projects | Green |
| Services | Magenta |

### tmux Environment Variables

Each session stores:

- `PROJECT_DIR` — path to working directory (existing)
- `TOOL` — `claude` or `gemini` (new)

`load_sessions` reads `TOOL` env var to determine session color.

### Launch Command Change

```bash
# Before:
tmux send-keys -t "$sname" "clear && claude --dangerously-skip-permissions" Enter

# After:
tmux send-keys -t "$sname" "clear && ai-session $tool" Enter
```

### Scratchpads

Scratchpads also get the tool prompt. Same behavior — if Gemini, no worktree (scratchpads have no project dir to branch from), just run `ai-session gemini` directly.

## Handoff Workflow

No special files (no HANDOFF.md). The AI-generated commit messages ARE the handoff. Next tool reads `git log` to pick up context.

**Tool switch**: exit session → reopen from tmux-connect → pick other tool. The auto-commit ensures work is always saved before switching.

**Merging**: done inside an AI session. Tell the tool: "merge gemini/X into main and clean up the worktree."

**Dropping a branch**: tell the tool: "delete branch gemini/X and remove the worktree."

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Non-git project | Skip tool prompt, launch Claude directly |
| Dirty main when creating worktree | Warn user, ask to commit/stash first |
| Headless AI commit fails (API down, no tokens) | Fallback: `wip: auto-save from <tool> session` |
| Chat-only session (no changes) | Wrapper exits silently |
| Chat that became dev (accidental changes) | Wrapper auto-commits, same as any other exit |
| Half-written file from crash | Committed as `wip: auto-save` — next session reviews |
| Worktree folder in picker | Already excluded by `.*` pattern on `.worktrees/` |
| Multiple Gemini sessions on same project | Session name differentiates: `.worktrees/<session>-gemini/` |

## Files Changed

| File | Change |
|------|--------|
| `tmux-connect.sh` | Tool prompt in `launch_session`, worktree creation for Gemini, session colors orange/blue, TOOL env var, ai-session launch command |
| `ai-session` (new) | ~25 line wrapper — tool launch + auto-commit on exit |

## Not Included (YAGNI)

- No mode selection (chat vs develop) — detected at exit
- No worktree management menu — done inside AI sessions
- No tool-switch keybinding — exit and reopen
- No HANDOFF.md — git log is the handoff
- No exit menu — auto-commit is always safe on feature branches
