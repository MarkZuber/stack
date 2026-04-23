#!/usr/bin/env zsh
# Stacked diff manager for GitHub & GitLab with worktree support
#
# Setup: add to ~/.zshrc
#   source /path/to/scripts/stack.zsh
#
# Worktrees are stored at: ${WT_ROOT:-$HOME/wt}/<repo-name>/<branch-name>/

# ── Colors ────────────────────────────────────────────────────────────────────
_STACK_RED=$'\033[0;31m'
_STACK_GREEN=$'\033[0;32m'
_STACK_YELLOW=$'\033[1;33m'
_STACK_BLUE=$'\033[0;34m'
_STACK_DIM=$'\033[2m'
_STACK_BOLD=$'\033[1m'
_STACK_RESET=$'\033[0m'

_stack_err()  { printf '%sERROR%s: %s\n' "$_STACK_RED"    "$_STACK_RESET" "$*" >&2; }
_stack_ok()   { printf '%s✔%s %s\n'      "$_STACK_GREEN"  "$_STACK_RESET" "$*"; }
_stack_warn() { printf '%sWARN%s: %s\n'  "$_STACK_YELLOW" "$_STACK_RESET" "$*" >&2; }
_stack_info() { printf '%s==>%s %s\n'    "$_STACK_BLUE"   "$_STACK_RESET" "$*"; }

# ── Git helpers ───────────────────────────────────────────────────────────────

_stack_require_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    _stack_err "Not inside a git repository."
    return 1
  fi
}

_stack_current_branch() {
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
    _stack_err "Detached HEAD state. Checkout a branch first."
    return 1
  fi
  printf '%s' "$branch"
}

_stack_get_parent() {
  local branch="${1:-}"
  [[ -z "$branch" ]] && { branch=$(_stack_current_branch) || return 1; }
  git config --get "branch.${branch}.stackparent" 2>/dev/null
  return 0
}

_stack_get_children() {
  local parent="$1" line key value b
  while IFS= read -r line; do
    key="${line%% *}"; value="${line#* }"
    if [[ "$value" == "$parent" ]]; then
      b="${key#branch.}"; b="${b%.stackparent}"
      printf '%s\n' "$b"
    fi
  done < <(git config --get-regexp 'branch\..*\.stackparent' 2>/dev/null)
}

_stack_branch_exists() {
  git rev-parse --verify "refs/heads/$1" &>/dev/null
}

_stack_detect_main_branch() {
  local default
  default=$(git config --get init.defaultBranch 2>/dev/null) || true
  if [[ -n "$default" ]] && _stack_branch_exists "$default"; then
    printf '%s' "$default"; return
  fi
  _stack_branch_exists "main" && printf 'main' && return
  _stack_branch_exists "master" && printf 'master' && return
  printf 'main'
}

# Returns the main (non-worktree) repo root path.
_stack_main_repo_path() {
  git worktree list 2>/dev/null | head -1 | awk '{print $1}'
}

# ── Worktree helpers ──────────────────────────────────────────────────────────

_stack_repo_name() { basename "$(_stack_main_repo_path)"; }
_stack_wt_root()   { printf '%s' "${WT_ROOT:-$HOME/wt}"; }
_stack_wt_path()   { printf '%s/%s/%s' "$(_stack_wt_root)" "$(_stack_repo_name)" "$1"; }

_stack_wt_exists() {
  local branch="$1" line wt_path="" wt_branch=""
  while IFS= read -r line; do
    if [[ "$line" == worktree\ * ]]; then
      wt_path="${line#worktree }"; wt_branch=""
    elif [[ "$line" == branch\ * ]]; then
      wt_branch="${line#branch refs/heads/}"
    elif [[ -z "$line" ]]; then
      [[ "$wt_branch" == "$branch" && -d "$wt_path" ]] && return 0
      wt_path=""; wt_branch=""
    fi
  done < <(git worktree list --porcelain 2>/dev/null)
  [[ "$wt_branch" == "$branch" && -d "$wt_path" ]] && return 0
  return 1
}

# ── PR/MR backend helpers ─────────────────────────────────────────────────────

_stack_detect_backend() {
  local url
  url=$(git remote get-url origin 2>/dev/null) || true
  [[ "$url" == *"github.com"* ]] && printf 'github' && return
  [[ "$url" == *"gitlab"*     ]] && printf 'gitlab' && return
}

_stack_require_cli() {
  case "$1" in
    github)
      command -v gh   &>/dev/null && return 0
      _stack_err "gh not found. Install from: https://cli.github.com"; return 1 ;;
    gitlab)
      command -v glab &>/dev/null && return 0
      _stack_err "glab not found. Install from: https://gitlab.com/gitlab-org/cli"; return 1 ;;
    "")
      local url; url=$(git remote get-url origin 2>/dev/null) || true
      _stack_err "Cannot detect backend from remote: '${url:-<no origin>}'"
      return 1 ;;
  esac
}

# ── Core rebase engine ────────────────────────────────────────────────────────

# Recursively rebases all descendants of <parent> onto their stack parent.
# Prefers git -C <wt-path> rebase (non-destructive) when worktree exists.
# Falls back to checkout-based rebase for branches without worktrees.
_stack_cascade_from() {
  local parent="$1" child wt_path

  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    wt_path=$(_stack_wt_path "$child")
    _stack_info "Rebasing '$child' onto '$parent'..."

    if _stack_wt_exists "$child"; then
      if [[ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
        _stack_err "'$child' has uncommitted changes — stash or commit before cascading."
        printf '\n  cd %s\n' "$wt_path"
        return 1
      fi
      if ! git -C "$wt_path" rebase "$parent" --quiet 2>/dev/null; then
        git -C "$wt_path" rebase --abort 2>/dev/null
        _stack_err "Conflict rebasing '$child' onto '$parent'."
        printf '\nTo resolve manually:\n'
        printf '  1. cd %s\n'   "$wt_path"
        printf '  2. git rebase %s\n' "$parent"
        printf '  3. Resolve conflicts: git add <files> && git rebase --continue\n'
        printf '  4. Re-run: stack cascade\n'
        return 1
      fi
    else
      _stack_warn "'$child' has no worktree — falling back to checkout (run 'stack attach $child')"
      git checkout "$child" --quiet
      if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        _stack_err "'$child' has uncommitted changes — stash or commit before cascading."
        return 1
      fi
      if ! git rebase "$parent" --quiet 2>/dev/null; then
        git rebase --abort 2>/dev/null
        _stack_err "Conflict rebasing '$child' onto '$parent'."
        printf '\nTo resolve manually:\n'
        printf '  1. git checkout %s\n' "$child"
        printf '  2. git rebase %s\n'   "$parent"
        printf '  3. Resolve conflicts: git add <files> && git rebase --continue\n'
        printf '  4. Re-run: stack cascade\n'
        printf '\nYou are now on: %s\n' "$child"
        return 1
      fi
    fi

    _stack_ok "Rebased '$child' onto '$parent'"
    _stack_cascade_from "$child" || return 1
  done < <(_stack_get_children "$parent")
}

# ── Commands ──────────────────────────────────────────────────────────────────

_stack_cmd_new() {
  _stack_require_git_repo || return 1
  local new_branch="$1"
  [[ -z "$new_branch" ]] && { _stack_err "Usage: stack new <branch-name>"; return 1; }
  _stack_branch_exists "$new_branch" && { _stack_err "Branch '$new_branch' already exists."; return 1; }

  local parent wt_path
  parent=$(_stack_current_branch) || return 1
  wt_path=$(_stack_wt_path "$new_branch")

  [[ -e "$wt_path" ]] && { _stack_err "Path already exists: $wt_path"; return 1; }
  mkdir -p "$(dirname "$wt_path")"

  git worktree add -b "$new_branch" "$wt_path" --quiet 2>/dev/null || {
    _stack_err "Failed to create worktree at $wt_path"; return 1
  }
  git config "branch.${new_branch}.stackparent" "$parent"
  _STACK_CD_TARGET="$wt_path"
  _stack_ok "Created '$new_branch' stacked on '$parent'"
  _stack_info "Worktree: $wt_path"
}

_stack_cmd_attach() {
  _stack_require_git_repo || return 1
  local branch="" parent=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stacked-on|-p)
        [[ -z "${2:-}" ]] && { _stack_err "--stacked-on requires a branch name"; return 1; }
        parent="$2"; shift 2 ;;
      -*)
        _stack_err "Unknown flag: $1. Usage: stack attach <branch> [--stacked-on <parent>]"
        return 1 ;;
      *)
        [[ -n "$branch" ]] && { _stack_err "Too many arguments."; return 1; }
        branch="$1"; shift ;;
    esac
  done

  [[ -z "$branch" ]] && { _stack_err "Usage: stack attach <branch> [--stacked-on <parent>]"; return 1; }

  if ! _stack_branch_exists "$branch"; then
    _stack_info "Fetching '$branch' from origin..."
    git fetch origin "$branch:$branch" --quiet 2>/dev/null || {
      _stack_err "Branch '$branch' not found locally or on origin."; return 1
    }
  fi

  local wt_path
  wt_path=$(_stack_wt_path "$branch")
  _stack_wt_exists "$branch" && { _stack_err "Worktree for '$branch' already exists at $wt_path"; return 1; }
  [[ -e "$wt_path" ]] && { _stack_err "Path already exists: $wt_path"; return 1; }

  mkdir -p "$(dirname "$wt_path")"
  git worktree add "$wt_path" "$branch" --quiet 2>/dev/null || {
    _stack_err "Failed to create worktree at $wt_path"; return 1
  }

  [[ -z "$parent" ]] && parent=$(_stack_get_parent "$branch")
  if [[ -z "$parent" ]]; then
    parent=$(_stack_detect_main_branch)
    _stack_warn "No stackparent for '$branch'. Defaulting to '$parent'. Use --stacked-on to override."
  fi

  git config "branch.${branch}.stackparent" "$parent"
  _STACK_CD_TARGET="$wt_path"
  _stack_ok "Attached worktree for '$branch' at $wt_path (stacked on '$parent')"
}

_stack_cmd_switch() {
  _stack_require_git_repo || return 1
  local branch="${1:-}"

  if [[ -z "$branch" ]]; then
    _STACK_CD_TARGET=$(_stack_main_repo_path)
    _stack_ok "Switching to main repo"
    return 0
  fi

  local main_branch
  main_branch=$(_stack_detect_main_branch)
  if [[ "$branch" == "main" || "$branch" == "master" || "$branch" == "$main_branch" ]]; then
    _STACK_CD_TARGET=$(_stack_main_repo_path)
    _stack_ok "Switching to repo root"
    return 0
  fi

  _stack_branch_exists "$branch" || { _stack_err "Branch '$branch' does not exist."; return 1; }
  _stack_wt_exists "$branch"     || { _stack_err "No worktree for '$branch'. Run: stack attach $branch"; return 1; }

  _STACK_CD_TARGET=$(_stack_wt_path "$branch")
  _stack_ok "Switching to '$branch'"
}

_stack_cmd_rm() {
  _stack_require_git_repo || return 1
  local branch="" keep_branch=0

  for arg in "$@"; do
    case "$arg" in
      --keep-branch|-k) keep_branch=1 ;;
      -*) _stack_err "Unknown flag: $arg"; return 1 ;;
      *)
        [[ -n "$branch" ]] && { _stack_err "Too many arguments. Usage: stack rm <branch> [--keep-branch]"; return 1; }
        branch="$arg" ;;
    esac
  done
  [[ -z "$branch" ]] && { _stack_err "Usage: stack rm <branch> [--keep-branch]"; return 1; }

  local wt_path
  wt_path=$(_stack_wt_path "$branch")

  if _stack_wt_exists "$branch"; then
    # If we're currently inside the worktree being removed, move to main repo first
    local current_wt_branch
    current_wt_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    if [[ "$current_wt_branch" == "$branch" ]]; then
      local safe_dest; safe_dest=$(_stack_main_repo_path)
      cd "${safe_dest:-/tmp}"
      _STACK_CD_TARGET="$safe_dest"
    fi
    _stack_info "Removing worktree at $wt_path..."
    git worktree remove "$wt_path" --force 2>/dev/null || rm -rf "$wt_path"
    git worktree prune --quiet 2>/dev/null || true
    _stack_ok "Removed worktree"
  elif [[ -d "$wt_path" ]]; then
    rm -rf "$wt_path"
    _stack_ok "Removed directory $wt_path"
  else
    _stack_warn "No worktree found for '$branch'."
  fi

  if (( !keep_branch )) && _stack_branch_exists "$branch"; then
    git branch -d "$branch" 2>/dev/null || git branch -D "$branch"
    _stack_ok "Deleted branch '$branch'"
  fi

  git config --unset "branch.${branch}.stackparent" 2>/dev/null || true
}

_stack_cmd_list() {
  _stack_require_git_repo || return 1

  local -a branches=()
  local line key b current branch max_len
  local parent wt_path color reset status_label path_label dirty

  while IFS= read -r line; do
    key="${line%% *}"; b="${key#branch.}"; b="${b%.stackparent}"
    branches+=("$b")
  done < <(git config --get-regexp 'branch\..*\.stackparent' 2>/dev/null)

  if (( ${#branches[@]} == 0 )); then
    _stack_info "No stacked branches. Use 'stack new <name>' to create one."
    return 0
  fi

  current=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true

  max_len=20
  for branch in "${branches[@]}"; do
    (( ${#branch} > max_len )) && max_len=${#branch}
  done
  (( max_len += 2 ))

  printf '%s%-*s %-20s %-10s %s%s\n' \
    "$_STACK_BOLD" "$max_len" "BRANCH" "PARENT" "STATUS" "PATH" "$_STACK_RESET"
  printf '%s\n' "$(printf '─%.0s' {1..80})"

  for branch in "${branches[@]}"; do
    parent=$(_stack_get_parent "$branch")
    wt_path=$(_stack_wt_path "$branch")
    color=""; reset=""
    [[ "$branch" == "$current" ]] && color="${_STACK_GREEN}${_STACK_BOLD}" && reset="$_STACK_RESET"

    if _stack_wt_exists "$branch"; then
      dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null)
      if [[ -n "$dirty" ]]; then
        status_label="${_STACK_YELLOW}*dirty${_STACK_RESET}"
      else
        status_label="clean"
      fi
      path_label="$wt_path"
    else
      status_label="${_STACK_DIM}no wt${_STACK_RESET}"
      path_label="${_STACK_DIM}(no worktree)${_STACK_RESET}"
    fi

    printf '%s%-*s%s %-20s %-10s %s\n' \
      "$color" "$max_len" "$branch" "$reset" \
      "$parent" "$status_label" "$path_label"
  done
}

_stack_cmd_open_pr() {
  _stack_require_git_repo || return 1

  local current parent backend
  current=$(_stack_current_branch) || return 1
  parent=$(_stack_get_parent "$current")
  [[ -z "$parent" ]] && {
    parent=$(_stack_detect_main_branch)
    _stack_warn "No stackparent set for '$current'. Targeting '$parent'."
  }

  backend=$(_stack_detect_backend)
  _stack_require_cli "$backend" || return 1
  _stack_info "Creating ${backend} PR/MR: $current → $parent"

  case "$backend" in
    github) gh   pr create     --base "$parent" --head "$current" "$@" ;;
    gitlab) glab mr create     --source-branch "$current" --target-branch "$parent" "$@" ;;
  esac
}

_stack_cmd_update_summary() {
  _stack_require_git_repo || return 1
  local dry_run=0
  [[ "${1:-}" == "--dry-run" ]] && { dry_run=1; shift; }

  local current parent backend
  current=$(_stack_current_branch) || return 1
  parent=$(_stack_get_parent "$current")
  [[ -z "$parent" ]] && {
    parent=$(_stack_detect_main_branch)
    _stack_warn "No stackparent for '$current'. Diffing against '$parent'."
  }

  command -v claude &>/dev/null || {
    _stack_err "claude CLI not found. Install from: https://claude.ai/code"
    return 1
  }

  backend=$(_stack_detect_backend)
  _stack_require_cli "$backend" || return 1

  _stack_info "Collecting changes for '$current' vs '$parent'..."
  local commits diff
  commits=$(git log --oneline "${parent}..${current}" 2>/dev/null)
  [[ -z "$commits" ]] && {
    _stack_err "No commits on '$current' beyond '$parent'."
    return 1
  }
  diff=$(git diff "${parent}..${current}" 2>/dev/null | head -c 102400)

  local prompt summary
  prompt="Generate a concise pull request description in markdown.

## Commits
${commits}

## Diff
${diff}

Write a PR/MR description with:
- A 1-2 sentence summary paragraph (what changed and why)
- A bullet list of the specific changes made
- Base it strictly on the diff and commit messages above
- No testing checklist, reviewer notes, or boilerplate sections
- Output only the markdown body, nothing else"

  _stack_info "Running claude..."
  summary=$(printf '%s' "$prompt" | claude -p 2>/dev/null) || {
    _stack_err "claude failed. Is it authenticated? Try running: claude"
    return 1
  }
  [[ -z "$summary" ]] && { _stack_err "claude returned empty output."; return 1; }

  if (( dry_run )); then
    printf '%s\n' "$summary"
    _stack_ok "Dry run complete — PR/MR not updated."
    return 0
  fi

  _stack_info "Updating ${backend} PR/MR description for '$current'..."
  case "$backend" in
    github)
      gh pr edit --body "$summary" ;;
    gitlab)
      local mr_id
      mr_id=$(glab mr view -F json 2>/dev/null \
        | grep -oE '"iid":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
      [[ -z "$mr_id" ]] && {
        _stack_err "Could not find open MR for '$current'. Create it first with 'stack mr'."
        return 1
      }
      glab mr update "$mr_id" --description "$summary" ;;
  esac || { _stack_err "Failed to update PR/MR description."; return 1; }

  _stack_ok "PR/MR description updated for '$current'."
}

_stack_push_branch() {
  local branch="$1" wt_path
  wt_path=$(_stack_wt_path "$branch")
  _stack_info "Pushing '$branch'..."
  if _stack_wt_exists "$branch"; then
    git -C "$wt_path" push --force-with-lease origin "$branch" || return 1
  else
    git -C "$(_stack_main_repo_path)" push --force-with-lease origin "$branch" || return 1
  fi
  _stack_ok "Pushed '$branch'"
  local child
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    _stack_push_branch "$child" || return 1
  done < <(_stack_get_children "$branch")
}

_stack_cmd_push() {
  _stack_require_git_repo || return 1
  local start
  start=$(_stack_current_branch) || return 1
  _stack_info "Force-pushing '$start' and all descendants (--force-with-lease)..."
  _stack_push_branch "$start" || return 1
  _stack_ok "Push complete."
}

_stack_cmd_cascade() {
  _stack_require_git_repo || return 1
  local start
  start=$(_stack_current_branch) || return 1

  local has_children=0 _child
  while IFS= read -r _child; do
    [[ -n "$_child" ]] && { has_children=1; break; }
  done < <(_stack_get_children "$start")

  if (( !has_children )); then
    _stack_info "No stacked branches below '$start'."
    return 0
  fi

  _stack_info "Cascading changes from '$start'..."

  if _stack_cascade_from "$start"; then
    # Return to start if fallback checkout-mode moved us away
    local current_now
    current_now=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
    if [[ "$current_now" != "$start" ]]; then
      if _stack_wt_exists "$start"; then
        _STACK_CD_TARGET=$(_stack_wt_path "$start")
      else
        git checkout "$start" --quiet 2>/dev/null || true
      fi
    fi
    _stack_ok "Cascade complete."
  else
    _stack_warn "Cascade stopped. Fix the conflict above, then re-run 'stack cascade' from '$start'."
    return 1
  fi
}

_stack_cmd_land() {
  _stack_require_git_repo || return 1
  local landed_branch="" do_delete=0

  for arg in "$@"; do
    case "$arg" in
      --delete|-d) do_delete=1 ;;
      -*)
        _stack_err "Unknown flag: $arg"; return 1 ;;
      *)
        [[ -n "$landed_branch" ]] && { _stack_err "Too many arguments. Usage: stack land [branch] [-d]"; return 1; }
        landed_branch="$arg" ;;
    esac
  done

  [[ -z "$landed_branch" ]] && { landed_branch=$(_stack_current_branch) || return 1; }
  _stack_branch_exists "$landed_branch" || { _stack_err "Branch '$landed_branch' does not exist."; return 1; }

  local grandparent
  grandparent=$(_stack_get_parent "$landed_branch")
  if [[ -z "$grandparent" ]]; then
    grandparent=$(_stack_detect_main_branch)
    _stack_warn "No stackparent for '$landed_branch'. Assuming '$grandparent'."
  fi

  local start_branch
  start_branch=$(_stack_current_branch) || return 1

  local -a children=()
  local child
  while IFS= read -r child; do
    [[ -n "$child" ]] && children+=("$child")
  done < <(_stack_get_children "$landed_branch")

  (( ${#children[@]} == 0 )) && _stack_info "No stacked branches below '$landed_branch'."

  for child in "${children[@]}"; do
    _stack_info "Retargeting '$child': $landed_branch → $grandparent"
    git config "branch.${child}.stackparent" "$grandparent"

    local child_wt_path
    child_wt_path=$(_stack_wt_path "$child")
    _stack_info "Rebasing '$child' onto '$grandparent'..."

    if _stack_wt_exists "$child"; then
      if ! git -C "$child_wt_path" rebase "$grandparent" --quiet 2>/dev/null; then
        git -C "$child_wt_path" rebase --abort 2>/dev/null
        _stack_err "Conflict rebasing '$child' onto '$grandparent'."
        printf '\nTo resolve manually:\n'
        printf '  1. cd %s\n' "$child_wt_path"
        printf '  2. git rebase %s\n' "$grandparent"
        printf '  3. Resolve conflicts: git add <files> && git rebase --continue\n'
        printf '  4. Re-run: stack land %s\n' "$landed_branch"
        return 1
      fi
    else
      _stack_warn "'$child' has no worktree — falling back to checkout"
      git checkout "$child" --quiet
      if ! git rebase "$grandparent" --quiet 2>/dev/null; then
        git rebase --abort 2>/dev/null
        _stack_err "Conflict rebasing '$child' onto '$grandparent'."
        printf '\nTo resolve manually:\n'
        printf '  1. git checkout %s\n' "$child"
        printf '  2. git rebase %s\n'   "$grandparent"
        printf '  3. Resolve conflicts: git add <files> && git rebase --continue\n'
        printf '  4. Re-run: stack land %s\n' "$landed_branch"
        return 1
      fi
    fi

    _stack_ok "Rebased '$child' onto '$grandparent'"
    _stack_cascade_from "$child" || return 1
  done

  if (( do_delete )); then
    local landed_wt_path
    landed_wt_path=$(_stack_wt_path "$landed_branch")
    if _stack_wt_exists "$landed_branch"; then
      # If we're currently IN the landed worktree, move away first
      local current_now
      current_now=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
      if [[ "$current_now" == "$landed_branch" ]]; then
        local safe_dest
        safe_dest=$(_stack_main_repo_path)
        cd "${safe_dest:-/tmp}"
        _STACK_CD_TARGET="$safe_dest"
        start_branch="$grandparent"
      fi
      _stack_info "Removing worktree for '$landed_branch'..."
      git worktree remove "$landed_wt_path" --force 2>/dev/null || rm -rf "$landed_wt_path"
      git worktree prune --quiet 2>/dev/null || true
    fi
    git branch -d "$landed_branch" 2>/dev/null || git branch -D "$landed_branch"
    git config --unset "branch.${landed_branch}.stackparent" 2>/dev/null || true
    _stack_ok "Deleted branch '$landed_branch'"
  fi

  # Return to start if fallback checkout moved us
  local current_now
  current_now=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
  if [[ "$current_now" != "$start_branch" ]]; then
    if _stack_wt_exists "$start_branch"; then
      _STACK_CD_TARGET=$(_stack_wt_path "$start_branch")
    elif _stack_branch_exists "$start_branch"; then
      git checkout "$start_branch" --quiet 2>/dev/null || true
    fi
  fi

  _stack_ok "Land complete. Children of '$landed_branch' now target '$grandparent'."
}

_stack_cmd_status() {
  _stack_require_git_repo || return 1
  local current
  current=$(_stack_current_branch) || return 1

  local -a ancestors=()
  local b="$current"
  while true; do
    local p; p=$(_stack_get_parent "$b")
    [[ -z "$p" ]] && break
    ancestors=("$p" "${ancestors[@]}")
    b="$p"
  done
  local root="${ancestors[1]:-$current}"

  _stack_print_tree() {
    local branch="$1" prefix="$2" connector="$3"
    local color="$_STACK_RESET" suffix="" a

    if [[ "$branch" == "$current" ]]; then
      color="${_STACK_GREEN}${_STACK_BOLD}"
      suffix="  ${_STACK_BOLD}◀ current${_STACK_RESET}"
    else
      for a in "${ancestors[@]}"; do
        [[ "$a" == "$branch" ]] && { color="$_STACK_DIM"; break; }
      done
    fi

    local path_suffix="" wt_path
    wt_path=$(_stack_wt_path "$branch")
    [[ -d "$wt_path" ]] && path_suffix="  ${_STACK_DIM}${wt_path}${_STACK_RESET}"

    printf '%s%s%s%s%s%s%s\n' "$prefix" "$connector" "$color" "$branch" "$_STACK_RESET" "$suffix" "$path_suffix"

    local child_prefix
    if   [[ "$connector" == "└── " ]]; then child_prefix="${prefix}    "
    elif [[ -z "$connector"         ]]; then child_prefix=""
    else                                     child_prefix="${prefix}│   "
    fi

    local -a kids=() kid
    while IFS= read -r kid; do [[ -n "$kid" ]] && kids+=("$kid"); done < <(_stack_get_children "$branch")

    local n=${#kids[@]} i
    for (( i=1; i<=n; i++ )); do
      (( i == n )) \
        && _stack_print_tree "${kids[$i]}" "$child_prefix" "└── " \
        || _stack_print_tree "${kids[$i]}" "$child_prefix" "├── "
    done
  }

  printf '\n'
  _stack_print_tree "$root" "" ""
  printf '\n'
  unfunction _stack_print_tree 2>/dev/null || true
}

# ── Dispatcher ────────────────────────────────────────────────────────────────

_STACK_CD_TARGET=""

stack() {
  _STACK_CD_TARGET=""
  local cmd="${1:-help}"
  (( $# > 0 )) && shift

  local _ret=0
  case "$cmd" in
    new)          _stack_cmd_new      "$@" || _ret=$? ;;
    attach)       _stack_cmd_attach   "$@" || _ret=$? ;;
    switch)       _stack_cmd_switch   "$@" || _ret=$? ;;
    mr|pr)        _stack_cmd_open_pr  "$@" || _ret=$? ;;
    push)            _stack_cmd_push           "$@" || _ret=$? ;;
    update-summary)  _stack_cmd_update_summary "$@" || _ret=$? ;;
    cascade)         _stack_cmd_cascade        "$@" || _ret=$? ;;
    land)         _stack_cmd_land     "$@" || _ret=$? ;;
    rm)           _stack_cmd_rm       "$@" || _ret=$? ;;
    ls|list)      _stack_cmd_list     "$@" || _ret=$? ;;
    status)       _stack_cmd_status   "$@" || _ret=$? ;;
    help|--help|-h)
      printf '%s\n' \
        "stack — Stacked diff manager for GitHub & GitLab" \
        "" \
        "Usage: stack <command> [args]" \
        "" \
        "Branch / worktree commands:" \
        "  stack new <branch>              Create stacked branch + worktree, cd in" \
        "  stack attach <branch>           Create worktree for existing branch, cd in" \
        "                                  [--stacked-on <parent>]" \
        "  stack switch [<branch>]          cd into a branch's worktree (no arg: main repo)" \
        "  stack rm <branch> [-k]          Remove worktree + branch (-k to keep branch)" \
        "" \
        "Stack management:" \
        "  stack cascade                   Rebase all descendants onto updated ancestors" \
        "  stack land [branch] [-d]        Retarget children after MR/PR is merged" \
        "                                  -d / --delete  also remove the landed branch" \
        "" \
        "PR / MR  (auto-detects GitHub or GitLab from remote URL):" \
        "  stack mr [flags]                Create MR/PR targeting the stack parent" \
        "  stack pr [flags]                Alias for 'stack mr'" \
        "  stack push                      Force-push current branch + all descendants" \
        "  stack update-summary            Generate PR/MR description via claude and post it" \
        "                                  --dry-run  print without posting" \
        "" \
        "Information:" \
        "  stack status                    Show stack tree with worktree paths" \
        "  stack ls                        List stacked branches with paths + dirty status" \
        "" \
        "Worktrees: \${WT_ROOT:-\$HOME/wt}/<repo>/<branch>/" \
        "Setup:  source /path/to/scripts/stack.zsh  (add to ~/.zshrc)"
      ;;
    *)
      _stack_err "Unknown command: '$cmd'. Run 'stack help' for usage."
      _ret=1 ;;
  esac

  if (( _ret == 0 )) && [[ -n "$_STACK_CD_TARGET" && -d "$_STACK_CD_TARGET" ]]; then
    cd "$_STACK_CD_TARGET"
  fi
  return $_ret
}

# Allow direct execution: ./stack.zsh new feat-1
[[ "${ZSH_EVAL_CONTEXT}" == "toplevel" ]] && stack "$@"
