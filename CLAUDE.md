# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Running tests

```zsh
zsh scripts/stack_test.sh
```

The test suite is self-contained (no external deps beyond zsh and git). It creates isolated temp repos and temp worktree roots per suite.

## Architecture

This repo contains a single sourced zsh script: `scripts/stack.zsh`.

**Key design constraints:**
- `stack` is a shell *function* (not a script), sourced via `~/.zshrc`. This is required because scripts can't `cd` their parent shell. Internal commands set `_STACK_CD_TARGET`; the `stack()` dispatcher `cd`s there after the command returns.
- Each stacked branch lives in its own git worktree at `${WT_ROOT:-$HOME/wt}/<repo>/<branch>/`. `stack cascade` uses `git -C <wt-path> rebase` so it never needs to check out branches, allowing cascade to run from inside any worktree without disrupting working state.
- `_stack_repo_name()` must use `basename "$(_stack_main_repo_path)"` (first entry from `git worktree list`), NOT `basename "$(git rev-parse --show-toplevel)"` — in a worktree, `show-toplevel` returns the worktree path, not the repo root.
- Stack relationships are stored as `git config branch.<name>.stackparent <parent>`. Git config is shared across all worktrees of the same repo.

**Helper layers:**
- `_stack_main_repo_path()` — returns main (non-worktree) repo root via `git worktree list | head -1`
- `_stack_wt_path <branch>` — computes `$WT_ROOT/<repo>/<branch>`
- `_stack_wt_exists <branch>` — parses `git worktree list --porcelain` to check if branch has an active worktree
- `_stack_cascade_from <parent>` — recursive rebase engine; uses `git -C` for worktrees, falls back to checkout with a warning

**Test fixture pattern:** Each suite calls `_create_test_env` directly (not via `repo=$(...)` subshell) so that `export WT_ROOT` and `cd` propagate to the test shell. `_T_REPO` and `_T_WT_ROOT` are globals set by `_create_test_env`. Call `_teardown_test_env` (no args) at the end of each suite.

## Files

```
scripts/
├── stack.zsh        # Sourced shell function — all commands + dispatcher
├── stack_test.sh    # Self-contained test suite
└── README.md        # Full command reference and workflow examples
```
