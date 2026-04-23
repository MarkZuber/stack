# stack — Stacked Feature Branch Manager (GitHub & GitLab)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

GitLab and GitHub do not natively support stacked feature branches (chained MRs/PRs where each targets the previous branch rather than `main`). When you have a long chain of dependent changes, getting them reviewed separately — and keeping them in sync as code review feedback arrives — requires manual rebasing across every branch in the chain.

This tool automates that: it tracks branch relationships in local git config, manages a worktree per branch so you can work on any branch without losing context, and can rebase an entire chain with one command.

Having the feature branches in separate worktrees also enables easily working in parallel with tools like Claude or GitHub Copilot

---

## How it works

Stack relationships are stored in local git config:

```
branch.feat-2.stackparent = feat-1
branch.feat-3.stackparent = feat-2
```

No data is pushed to the remote. The metadata lives in `.git/config` and is only meaningful in your local clone.

Each stacked branch gets its own git worktree at `${WT_ROOT:-$HOME/wt}/<repo>/<branch>/`. This means `stack cascade` never needs to check out branches — it runs `git -C <wt-path> rebase` for each descendant, leaving you on your current branch throughout.

`stack cascade` walks descendants depth-first and rebases each child onto its parent. `stack land` is run after an MR/PR is merged: it retargets the merged branch's children to point at the grandparent (usually `main`), rebases them, and cascades the rest of the chain.

---

## Setup

**Prerequisites**

- zsh 5+
- git 2.x
- `gh` CLI — only needed for `stack mr`/`stack pr` on GitHub ([install](https://cli.github.com))
- `glab` CLI — only needed for `stack mr`/`stack pr` on GitLab ([install](https://gitlab.com/gitlab-org/cli#installation))

**Install**

Clone the repo and source the script from `~/.zshrc`:

```zsh
git clone https://github.com/markzuber/stack.git ~/stack
```

```zsh
# ~/.zshrc
source ~/stack/scripts/stack.zsh
```

Then open a new shell (or `source ~/.zshrc`).

**Optional: set worktree root**

By default worktrees are created at `$HOME/wt/<repo>/<branch>/`. Override with:

```zsh
export WT_ROOT=~/code/worktrees   # add to ~/.zshrc
```

**Force push policy**

`stack push` uses `--force-with-lease`, which requires force pushes to be allowed on feature branches. This is the default for most repos — branch protection rules typically only restrict `main`/`master`.

If your repo has a blanket org policy that disables force pushes on all branches, stacked diffs cannot work: rebasing rewrites history and force pushing the result is unavoidable.

The recommended setup:
- **GitHub**: Add a branch protection rule (or ruleset) targeting `main` only. Feature branches are unprotected by default.
- **GitLab**: Under Settings → Repository → Protected Branches, protect `main`/`master` only.

`--force-with-lease` is safer than `--force` — it refuses to push if the remote has commits you haven't fetched, so it won't silently overwrite someone else's work.

**Optional short aliases**

```zsh
alias sn='stack new'
alias sc='stack cascade'
alias sl='stack land'
alias ss='stack status'
alias sw='stack switch'
```

---

## Command reference

### `stack new <branch-name>`

Creates a new branch + worktree stacked on the current branch, and cds into it.

```zsh
git checkout main          # or: stack switch main
stack new feat-1           # feat-1 stacked on main, cd into ~/wt/<repo>/feat-1/

# stack new always branches from wherever you are:
stack new feat-2           # called from feat-1's wt → feat-2 stacked on feat-1
```

### `stack attach <branch> [--stacked-on <parent>]`

Creates a worktree for a branch that already exists (manually created, fetched from remote, or created before worktree integration). Cds into the new worktree.

```zsh
stack attach feat-1                         # stackparent defaults to main
stack attach feat-2 --stacked-on feat-1    # explicit parent
```

If the branch doesn't exist locally, `stack attach` attempts to fetch it from `origin` first.

### `stack switch <branch>`

Cds into a branch's worktree. `stack switch main` (or no argument) returns to the main repo root.

```zsh
stack switch feat-2
stack switch main    # return to main repo root
stack switch         # same as above
```

### `stack rm <branch> [-k | --keep-branch]`

Removes a branch's worktree and deletes the branch. Pass `-k` to keep the branch.

```zsh
stack rm feat-1             # remove worktree + delete branch
stack rm feat-1 -k          # remove worktree, keep branch
```

### `stack ls` / `stack list`

Lists all stacked branches with their parent, worktree path, and dirty status.

```zsh
stack ls

# Example output:
# BRANCH               PARENT               STATUS     PATH
# ────────────────────────────────────────────────────────────────────────────────
# feat-1               main                 clean      ~/wt/repo/feat-1
# feat-2               feat-1               *dirty     ~/wt/repo/feat-2
# feat-2b              feat-1               no wt      (no worktree)
```

### `stack mr [flags]` / `stack pr [flags]`

Pushes the current branch and creates a PR/MR targeting its stack parent. Auto-detects the backend from the remote URL (`github.com` → `gh`, anything with `gitlab` → `glab`). Both `stack mr` and `stack pr` work regardless of which backend is detected.

```zsh
stack mr                   # interactive
stack pr --fill --yes      # non-interactive
stack mr --draft           # draft PR/MR
```

Any flags are passed through to `gh pr create` or `glab mr create`.

### `stack push`

Force-pushes the current branch and all its descendants to `origin` using `--force-with-lease`. Run this after `stack cascade` to update the remote.

```zsh
stack push
```

`--force-with-lease` means the push is rejected if someone else has pushed to a branch since you last fetched, preventing accidental overwrites.

### `stack update-summary [--dry-run]`

Uses the `claude` CLI to generate a PR/MR description from the current branch's diff and commits, then posts it directly to GitHub or GitLab. Requires `claude` to be installed and authenticated, and the branch to have an open PR/MR.

```zsh
stack update-summary              # generate and post description
stack update-summary --dry-run   # print the generated description, don't post
```

The generated description includes a short summary paragraph and a bullet list of changes, derived strictly from the diff. Run this after finishing a branch or after incorporating review feedback.

### `stack cascade`

After making commits on the current branch, rebases all descendants in order so they incorporate your changes. Uses `git -C <wt-path> rebase` when worktrees are present — you never leave your current branch.

```zsh
cd ~/wt/repo/feat-1
# ... make changes, commit ...
stack cascade              # rebases feat-2, feat-3, etc. in place; stays on feat-1
```

After cascade completes you remain on the starting branch.

If a rebase conflict occurs, cascade stops and prints step-by-step resolution instructions. You are left in the conflicting branch's worktree.

### `stack land [branch] [-d]`

Run this after a branch's MR/PR has been merged into `main`. It retargets all direct children of the landed branch to point at `main` (or whatever the landed branch's parent was), rebases them, then cascades the rest of the chain.

```zsh
stack land feat-1          # retarget feat-2 → main, rebase, cascade
stack land feat-1 -d       # same, plus delete feat-1 locally + its worktree
stack land                 # uses current branch as the landed branch
```

> **Important**: Before running `stack land`, pull the merged commits from the remote so your local `main` is up to date:
> ```zsh
> stack switch main && git pull
> stack switch feat-1
> stack land -d
> ```

### `stack status`

Shows the full stack tree from the root, with ancestors dimmed, the current branch highlighted, and worktree paths shown inline.

```zsh
stack status

# Example output:
#
# main
# └── feat-1  /Users/you/wt/repo/feat-1
#     ├── feat-2  ◀ current  /Users/you/wt/repo/feat-2
#     └── feat-2b  /Users/you/wt/repo/feat-2b
```

---

## Example workflow

This is the canonical flow for working with a two-branch stack.

```zsh
# 1. Start from main
stack switch main        # cd to repo root

# 2. Create the stack
stack new feat-1         # creates worktree, cds into ~/wt/<repo>/feat-1

# 3. Stack feat-2 on top of feat-1
stack new feat-2         # branches from feat-1, cds into ~/wt/<repo>/feat-2

# 4. Go back to feat-1, make changes, commit
stack switch feat-1
echo "changes" >> api.go
git add api.go && git commit -m "feat-1: implement API"

# 5. Propagate feat-1's changes down to feat-2
stack cascade            # rebases feat-2 in place, stays on feat-1
stack push               # force-pushes feat-1 + feat-2 to origin

# 6. Create MRs for review (each targets its stack parent as the base branch)
stack mr --fill          # MR for feat-1, base branch: main

stack switch feat-2
stack mr --fill          # MR for feat-2, base branch: feat-1 (not main)

# 7. Code review feedback on feat-1 → amend, cascade again
stack switch feat-1
git commit --amend       # or add a fixup commit
stack cascade
stack push

# 8. feat-1 is approved and merged on GitHub/GitLab
#    Pull main so local main includes feat-1's commits
stack switch main && git pull
stack switch feat-1

# 9. Shift the stack left: feat-2 now targets main
stack land -d            # retargets feat-2 → main, rebases, deletes feat-1 + wt

# 10. Update feat-2's PR/MR target to main in the GitHub/GitLab UI
#     (stack land only updates local config, not the remote PR/MR)

# 11. feat-2 is reviewed and merged — done
stack switch main && git pull
stack land feat-2 -d
```

---

## Troubleshooting

### Conflict during cascade

When `stack cascade` hits a conflict it prints:

```
ERROR: Conflict rebasing 'feat-2' onto 'feat-1'.

To resolve manually:
  1. cd ~/wt/repo/feat-2
  2. git rebase feat-1
  3. Resolve conflicts: git add <files> && git rebase --continue
  4. Re-run: stack cascade
```

After resolving and completing the rebase, run `stack cascade` again from feat-1's worktree — it will pick up where it left off.

### Uncommitted changes blocking cascade

If a descendant branch has uncommitted changes, cascade stops before attempting the rebase:

```
ERROR: 'feat-2' has uncommitted changes — stash or commit before cascading.

  cd ~/wt/repo/feat-2
```

Stash or commit the changes in that worktree, then re-run `stack cascade`.

### Conflict during `stack land`

`stack land` rebases children onto the grandparent branch and will stop on a conflict with the same instructions:

```
ERROR: Conflict rebasing 'feat-2' onto 'main'.

To resolve manually:
  1. cd ~/wt/repo/feat-2
  2. git rebase main
  3. Resolve conflicts: git add <files> && git rebase --continue
  4. Re-run: stack land feat-1
```

After resolving, re-run `stack land <landed-branch>` to complete the operation.

### Branch without a worktree

If a branch was created without `stack new` or `stack attach`, cascade falls back to a checkout-based rebase and warns you:

```
WARN: 'feat-2' has no worktree — falling back to checkout (run 'stack attach feat-2')
```

Run `stack attach feat-2` to give it a worktree and silence the warning.

### Wrong parent set

If you created a branch without `stack new`, set the parent manually:

```zsh
git config branch.feat-2.stackparent feat-1
```

### Inspect all stack relationships

```zsh
git config --get-regexp 'branch\..*\.stackparent'
```

### Squash-merged MRs/PRs

If GitLab/GitHub squash-merges an MR, git sees the commits as new and may warn "skipped previously applied commits" during `stack land`. This is expected — the rebase is still correct. If it drops commits you need, use `git rebase --reapply-cherry-picks`.

### After `stack land`, update the PR/MR target

`stack land` rebases locally and updates git config, but the remote PR/MR still shows the old target branch. Update it in the UI, or via CLI:

```zsh
# GitHub:
gh pr edit <number> --base main

# GitLab:
glab mr update <mr-id> --target-branch main
```

---

## Contributing

```zsh
zsh scripts/stack_test.sh
```

The test suite requires only zsh and git. `gh`/`glab` are only needed if you're manually testing the `stack mr`/`stack pr` commands outside the suite.

---

## License

[MIT](LICENSE) © Mark Zuber
