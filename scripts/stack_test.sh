#!/usr/bin/env zsh
# stack_test.sh — Test suite for stack.zsh
#
# Run with: zsh scripts/stack_test.sh

SCRIPT_DIR="${0:A:h}"
source "${SCRIPT_DIR}/stack.zsh"

# ── Test runner ───────────────────────────────────────────────────────────────

typeset -i _T_PASS=0 _T_FAIL=0
typeset -a _T_ERRORS=()
typeset _T_SUITE=""
typeset _T_ORIG_DIR="$PWD"
typeset _T_WT_ROOT=""
typeset _T_REPO=""

_t_suite() {
  _T_SUITE="$1"
  printf '\n%s=== %s ===%s\n' "$_STACK_BOLD" "$1" "$_STACK_RESET"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s\n    expected: [%s]\n    actual:   [%s]\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$expected" "$actual"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s\n    needle: [%s]\n' "$_STACK_RED" "$_STACK_RESET" "$desc" "$needle"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_branch_exists() {
  local desc="$1" branch="$2"
  if git rev-parse --verify "refs/heads/$branch" &>/dev/null; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s (branch '"'"'%s'"'"' not found)\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$branch"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_branch_missing() {
  local desc="$1" branch="$2"
  if ! git rev-parse --verify "refs/heads/$branch" &>/dev/null; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s (branch '"'"'%s'"'"' unexpectedly exists)\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$branch"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_config() {
  local desc="$1" key="$2" expected="$3"
  local actual; actual=$(git config --get "$key" 2>/dev/null) || true
  assert_eq "$desc" "$expected" "$actual"
}

assert_no_config() {
  local desc="$1" key="$2"
  local actual; actual=$(git config --get "$key" 2>/dev/null) || true
  if [[ -z "$actual" ]]; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s (expected no config for '"'"'%s'"'"', got '"'"'%s'"'"')\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$key" "$actual"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_current_branch() {
  local desc="$1" expected="$2"
  local actual; actual=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || true
  assert_eq "$desc" "$expected" "$actual"
}

assert_file_on_branch() {
  local desc="$1" branch="$2" file="$3" expected_content="$4"
  local actual; actual=$(git show "${branch}:${file}" 2>/dev/null) || true
  assert_eq "$desc" "$expected_content" "$actual"
}

assert_file_missing_on_branch() {
  local desc="$1" branch="$2" file="$3"
  if ! git show "${branch}:${file}" &>/dev/null; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s ('"'"'%s'"'"' unexpectedly present on '"'"'%s'"'"')\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$file" "$branch"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_worktree_exists() {
  local desc="$1" branch="$2"
  local wt_path; wt_path=$(_stack_wt_path "$branch")
  if [[ -d "$wt_path" ]] && _stack_wt_exists "$branch"; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s (worktree for '"'"'%s'"'"' not found at %s)\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$branch" "$wt_path"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

assert_worktree_missing() {
  local desc="$1" branch="$2"
  local wt_path; wt_path=$(_stack_wt_path "$branch")
  if [[ ! -d "$wt_path" ]] && ! _stack_wt_exists "$branch"; then
    printf '  PASS: %s\n' "$desc"; (( ++_T_PASS ))
  else
    printf '  %sFAIL%s: %s (worktree for '"'"'%s'"'"' unexpectedly exists at %s)\n' \
      "$_STACK_RED" "$_STACK_RESET" "$desc" "$branch" "$wt_path"
    (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: $desc")
  fi
}

# ── Fixture helpers ───────────────────────────────────────────────────────────

# Sets _T_REPO and _T_WT_ROOT globals, exports WT_ROOT, and cd's into repo.
# Call directly (NOT via repo=$(...)) so that cd and export take effect.
_create_test_env() {
  _T_REPO=$(mktemp -d)
  _T_WT_ROOT=$(mktemp -d)
  git init "$_T_REPO" --quiet
  git -C "$_T_REPO" config user.email "test@example.com"
  git -C "$_T_REPO" config user.name "Test User"
  git -C "$_T_REPO" config init.defaultBranch "main"
  printf 'initial\n' > "$_T_REPO/README.md"
  git -C "$_T_REPO" add README.md
  git -C "$_T_REPO" commit --quiet -m "initial commit"
  export WT_ROOT="$_T_WT_ROOT"
  cd "$_T_REPO"
}

_teardown_test_env() {
  cd "$_T_ORIG_DIR"
  rm -rf "$_T_REPO"
  [[ -n "$_T_WT_ROOT" ]] && rm -rf "$_T_WT_ROOT"
  unset WT_ROOT
  _T_WT_ROOT=""
  _T_REPO=""
}

# ── Suite 1: stack new ────────────────────────────────────────────────────────

_t_suite "stack new — creates branch, worktree, sets stackparent"

_create_test_env

stack new "feat-1"
# dispatcher cds us into feat-1's worktree

assert_branch_exists   "creates feat-1 branch"       "feat-1"
assert_config          "feat-1 stackparent is main"   "branch.feat-1.stackparent" "main"
assert_current_branch  "we are now on feat-1"         "feat-1"
assert_worktree_exists "feat-1 worktree created"      "feat-1"

stack new "feat-2"
assert_branch_exists   "creates feat-2 branch"        "feat-2"
assert_config          "feat-2 stackparent is feat-1" "branch.feat-2.stackparent" "feat-1"
assert_worktree_exists "feat-2 worktree created"      "feat-2"

out=$(_stack_cmd_new "feat-2" 2>&1) || true
assert_contains "fails if branch already exists" "already exists" "$out"

out=$(_stack_cmd_new 2>&1) || true
assert_contains "fails without branch name" "Usage" "$out"

_teardown_test_env

# ── Suite 2: stack attach ─────────────────────────────────────────────────────

_t_suite "stack attach — creates worktree for existing branch"

_create_test_env

# Create a branch manually (no worktree)
git checkout -b "feat-1" --quiet
git commit --quiet --allow-empty -m "feat-1 work"
git checkout --quiet main

stack attach "feat-1"

assert_worktree_exists "feat-1 worktree created"       "feat-1"
assert_config          "feat-1 stackparent defaulted"  "branch.feat-1.stackparent" "main"
assert_eq              "_STACK_CD_TARGET set"          "$(_stack_wt_path "feat-1")" "$_STACK_CD_TARGET"

# Test --stacked-on override — create feat-2 in the main repo (we're in feat-1's wt now)
main_repo=$(_stack_main_repo_path)
git -C "$main_repo" checkout -b "feat-2" --quiet
git -C "$main_repo" commit --quiet --allow-empty -m "feat-2 work"
git -C "$main_repo" checkout --quiet main

_STACK_CD_TARGET=""
_stack_cmd_attach "feat-2" --stacked-on "feat-1"

assert_worktree_exists "feat-2 worktree created"            "feat-2"
assert_config          "feat-2 stackparent is feat-1"       "branch.feat-2.stackparent" "feat-1"
assert_eq              "_STACK_CD_TARGET set for feat-2"    "$(_stack_wt_path "feat-2")" "$_STACK_CD_TARGET"

# Fail: already has worktree
out=$(_stack_cmd_attach "feat-1" 2>&1) || true
assert_contains "fails if worktree already exists" "already exists" "$out"

_teardown_test_env

# ── Suite 3: stack switch ─────────────────────────────────────────────────────

_t_suite "stack switch — sets _STACK_CD_TARGET"

_create_test_env

stack new "feat-1"
stack new "feat-2"

main_repo=$(_stack_main_repo_path)

_STACK_CD_TARGET=""
_stack_cmd_switch "feat-1"
assert_eq "switch feat-1 → worktree"  "$(_stack_wt_path "feat-1")" "$_STACK_CD_TARGET"

_STACK_CD_TARGET=""
_stack_cmd_switch "feat-2"
assert_eq "switch feat-2 → worktree"  "$(_stack_wt_path "feat-2")" "$_STACK_CD_TARGET"

_STACK_CD_TARGET=""
_stack_cmd_switch "main"
assert_eq "switch main → main repo"   "$main_repo" "$_STACK_CD_TARGET"

_STACK_CD_TARGET=""
_stack_cmd_switch
assert_eq "switch (no arg) → main repo" "$main_repo" "$_STACK_CD_TARGET"

out=$(_stack_cmd_switch "nonexistent-branch" 2>&1) || true
assert_contains "fails for unknown branch" "does not exist" "$out"

_teardown_test_env

# ── Suite 4: cascade — file addition ─────────────────────────────────────────

_t_suite "stack cascade — file addition propagates (worktree mode)"

_create_test_env

stack new "feat-1"
printf 'feat-1 original\n' > file1.txt
git add file1.txt && git commit --quiet -m "feat-1: add file1"

stack new "feat-2"
printf 'feat-2 content\n' > file2.txt
git add file2.txt && git commit --quiet -m "feat-2: add file2"

stack new "feat-3"
printf 'feat-3 content\n' > file3.txt
git add file3.txt && git commit --quiet -m "feat-3: add file3"

# Go to feat-1's worktree and update a file
cd "$(_stack_wt_path "feat-1")"
printf 'feat-1 updated\n' > file1.txt
git add file1.txt && git commit --quiet -m "feat-1: update file1"

stack cascade  # uses git -C for feat-2 and feat-3, never leaves feat-1 wt

assert_current_branch  "still on feat-1 after cascade"      "feat-1"
assert_file_on_branch  "feat-2 sees updated file1"          "feat-2" "file1.txt" "feat-1 updated"
assert_file_on_branch  "feat-3 sees updated file1"          "feat-3" "file1.txt" "feat-1 updated"
assert_file_on_branch  "feat-2 keeps its own file"          "feat-2" "file2.txt" "feat-2 content"
assert_file_on_branch  "feat-3 keeps its own file"          "feat-3" "file3.txt" "feat-3 content"

_teardown_test_env

# ── Suite 5: cascade — file edited in parent propagates to child ──────────────

_t_suite "stack cascade — file edited in parent propagates to child"

_create_test_env

printf 'original content\n' > shared.txt
git add shared.txt && git commit --quiet -m "main: add shared.txt"

stack new "feat-1"
printf 'feat-1 only\n' > feat1-only.txt
git add feat1-only.txt && git commit --quiet -m "feat-1: own file"

stack new "feat-2"
printf 'feat-2 only\n' > feat2-only.txt
git add feat2-only.txt && git commit --quiet -m "feat-2: own file"

cd "$(_stack_wt_path "feat-1")"
printf 'edited content\n' > shared.txt
git add shared.txt && git commit --quiet -m "feat-1: edit shared.txt"

stack cascade

assert_file_on_branch  "feat-2 sees edited shared.txt" "feat-2" "shared.txt" "edited content"
assert_file_on_branch  "feat-2 keeps its own file"     "feat-2" "feat2-only.txt" "feat-2 only"
assert_current_branch  "still on feat-1"               "feat-1"

_teardown_test_env

# ── Suite 6: cascade — file deletion ─────────────────────────────────────────

_t_suite "stack cascade — deleted files absent in descendants"

_create_test_env

stack new "feat-1"
printf 'temporary\n' > temp.txt
git add temp.txt && git commit --quiet -m "feat-1: add temp.txt"

stack new "feat-2"
printf 'feat-2 own\n' > own.txt
git add own.txt && git commit --quiet -m "feat-2: add own.txt"

cd "$(_stack_wt_path "feat-1")"
git rm --quiet temp.txt
git commit --quiet -m "feat-1: delete temp.txt"

stack cascade

assert_file_missing_on_branch "feat-2 no longer has temp.txt" "feat-2" "temp.txt"
assert_file_on_branch         "feat-2 keeps own.txt"          "feat-2" "own.txt" "feat-2 own"

_teardown_test_env

# ── Suite 7: cascade — conflict handling ──────────────────────────────────────

_t_suite "stack cascade — conflict aborts cleanly"

_create_test_env

printf 'original\n' > conflict.txt
git add conflict.txt && git commit --quiet -m "main: add conflict.txt"

stack new "feat-1"
printf 'feat-1 version\n' > conflict.txt
git add conflict.txt && git commit --quiet -m "feat-1: set conflict.txt"

stack new "feat-2"
printf 'feat-2 diverged\n' > conflict.txt
git add conflict.txt && git commit --quiet -m "feat-2: diverge conflict.txt"

cd "$(_stack_wt_path "feat-1")"
printf 'feat-1 changed differently\n' > conflict.txt
git add conflict.txt && git commit --quiet -m "feat-1: change again"

exit_code=0
out=$(_stack_cmd_cascade 2>&1) || exit_code=$?

assert_eq      "cascade exits nonzero on conflict" "1" "$exit_code"
assert_contains "output mentions conflict"          "onflict" "$out"
assert_contains "output mentions rebase --continue" "rebase --continue" "$out"

feat2_wt=$(_stack_wt_path "feat-2")
if [[ ! -f "$feat2_wt/.git/REBASE_HEAD" ]] && [[ ! -d "$feat2_wt/.git/rebase-merge" ]]; then
  printf '  PASS: rebase was aborted cleanly (no in-progress state)\n'; (( ++_T_PASS ))
else
  printf '  %sFAIL%s: rebase not aborted cleanly\n' "$_STACK_RED" "$_STACK_RESET"
  (( ++_T_FAIL )); _T_ERRORS+=("${_T_SUITE}: rebase aborted cleanly")
  git -C "$feat2_wt" rebase --abort 2>/dev/null || true
fi

_teardown_test_env

# ── Suite 8: cascade — fallback for branch without worktree ──────────────────
# Tests the pure no-worktree fallback path: all branches created manually
# (no worktrees). Cascade should warn and fall back to checkout-based rebase.

_t_suite "stack cascade — fallback for branch without worktree"

_create_test_env

# Create feat-1 without a worktree (manually)
git checkout -b "feat-1" --quiet
git config branch.feat-1.stackparent main
printf 'f1\n' > f1.txt && git add f1.txt && git commit --quiet -m "feat-1"

# Create feat-2 without a worktree (manually)
git checkout -b "feat-2" --quiet
git config branch.feat-2.stackparent feat-1
printf 'f2\n' > f2.txt && git add f2.txt && git commit --quiet -m "feat-2"

# Return to feat-1 to run cascade from there
git checkout --quiet "feat-1"

# Update feat-1
printf 'f1 updated\n' > f1.txt
git add f1.txt && git commit --quiet -m "feat-1 update"

out=$(stack cascade 2>&1)

assert_contains "output warns about missing worktree" "no worktree" "$out"
assert_file_on_branch "feat-2 still gets updated f1" "feat-2" "f1.txt" "f1 updated"
assert_current_branch "back on feat-1 after cascade" "feat-1"

_teardown_test_env

# ── Suite 9: stack land — retargets and cascades ─────────────────────────────

_t_suite "stack land — retargets child to grandparent"

_create_test_env

stack new "feat-1"
printf 'feat-1 work\n' > file1.txt
git add file1.txt && git commit --quiet -m "feat-1: add file1"

stack new "feat-2"
printf 'feat-2 work\n' > file2.txt
git add file2.txt && git commit --quiet -m "feat-2: add file2"

# Simulate MR merge: ff main onto feat-1
main_repo=$(_stack_main_repo_path)
git -C "$main_repo" merge --quiet --ff-only feat-1

cd "$(_stack_wt_path "feat-1")"
_stack_cmd_land "feat-1"

assert_config         "feat-2 stackparent is now main"    "branch.feat-2.stackparent" "main"
assert_file_on_branch "feat-2 has feat-1 content"         "feat-2" "file1.txt" "feat-1 work"
assert_file_on_branch "feat-2 keeps its own file"         "feat-2" "file2.txt" "feat-2 work"

_teardown_test_env

_t_suite "stack land — cascades to grandchildren"

_create_test_env

stack new "feat-1"
printf 'f1\n' > f1.txt && git add f1.txt && git commit --quiet -m "feat-1"
stack new "feat-2"
printf 'f2\n' > f2.txt && git add f2.txt && git commit --quiet -m "feat-2"
stack new "feat-3"
printf 'f3\n' > f3.txt && git add f3.txt && git commit --quiet -m "feat-3"

main_repo=$(_stack_main_repo_path)
git -C "$main_repo" merge --quiet --ff-only feat-1

_stack_cmd_land "feat-1"

assert_config         "feat-2 targets main"          "branch.feat-2.stackparent" "main"
assert_config         "feat-3 still targets feat-2"  "branch.feat-3.stackparent" "feat-2"
assert_file_on_branch "feat-3 has f1"                "feat-3" "f1.txt" "f1"
assert_file_on_branch "feat-3 has f2"                "feat-3" "f2.txt" "f2"
assert_file_on_branch "feat-3 keeps its own f3"      "feat-3" "f3.txt" "f3"

_teardown_test_env

# ── Suite 10: stack land --delete ─────────────────────────────────────────────

_t_suite "stack land --delete removes worktree and branch"

_create_test_env

stack new "feat-1"
printf 'f1\n' > f1.txt && git add f1.txt && git commit --quiet -m "feat-1"
stack new "feat-2"
printf 'f2\n' > f2.txt && git add f2.txt && git commit --quiet -m "feat-2"

main_repo=$(_stack_main_repo_path)
git -C "$main_repo" merge --quiet --ff-only feat-1

# Run from feat-1's worktree
cd "$(_stack_wt_path "feat-1")"
stack land -d

assert_branch_missing   "feat-1 branch deleted"          "feat-1"
assert_worktree_missing "feat-1 worktree removed"        "feat-1"
assert_no_config        "feat-1 config removed"           "branch.feat-1.stackparent"
assert_branch_exists    "feat-2 still exists"             "feat-2"
assert_worktree_exists  "feat-2 worktree still exists"   "feat-2"
assert_config           "feat-2 retargeted to main"       "branch.feat-2.stackparent" "main"

_teardown_test_env

# ── Suite 11: stack rm ────────────────────────────────────────────────────────

_t_suite "stack rm — removes worktree and branch"

_create_test_env

stack new "feat-1"
git commit --quiet --allow-empty -m "feat-1"
stack new "feat-2"
git commit --quiet --allow-empty -m "feat-2"

cd "$(_stack_wt_path "feat-1")"

_stack_cmd_rm "feat-2"

assert_worktree_missing "feat-2 worktree removed"  "feat-2"
assert_branch_missing   "feat-2 branch deleted"    "feat-2"
assert_no_config        "feat-2 config removed"    "branch.feat-2.stackparent"

_teardown_test_env

_t_suite "stack rm --keep-branch keeps branch"

_create_test_env

stack new "feat-1"
git commit --quiet --allow-empty -m "feat-1"

_stack_cmd_rm "feat-1" --keep-branch

assert_worktree_missing "feat-1 worktree removed"    "feat-1"
assert_branch_exists    "feat-1 branch still exists" "feat-1"
assert_no_config        "feat-1 config removed"      "branch.feat-1.stackparent"

_teardown_test_env

# ── Suite 12: stack update-summary ───────────────────────────────────────────

_t_suite "stack update-summary — generates and posts PR description"

_create_test_env

stack new "feat-1"
printf 'hello\n' > hello.txt && git add hello.txt && git commit --quiet -m "add hello.txt"

# No remote → cannot detect backend
out=$(_stack_cmd_update_summary 2>&1) || true
assert_contains "fails without remote"  "Cannot detect backend" "$out"

# Wire up a GitHub remote and inject mock binaries
git remote add origin https://github.com/user/repo.git

mock_dir=$(mktemp -d)
printf '#!/bin/sh\nprintf "Summary: adds hello.txt\\n\\n- Added hello.txt\\n"\n' \
  > "$mock_dir/claude"
# gh records its args so we can assert on them
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh_calls"\n' "$mock_dir" \
  > "$mock_dir/gh"
chmod +x "$mock_dir/claude" "$mock_dir/gh"
old_path="$PATH"; export PATH="$mock_dir:$PATH"

exit_code=0
_stack_cmd_update_summary 2>/dev/null || exit_code=$?

export PATH="$old_path"
gh_calls=$(cat "$mock_dir/gh_calls" 2>/dev/null) || true
rm -rf "$mock_dir"

assert_eq      "update-summary exits 0"  "0"        "$exit_code"
assert_contains "gh pr edit called"      "pr edit"  "$gh_calls"
assert_contains "body flag passed"       "--body"   "$gh_calls"

# --dry-run should print summary and not call gh
mock_dir=$(mktemp -d)
printf '#!/bin/sh\nprintf "Dry run summary\\n"\n' > "$mock_dir/claude"
printf '#!/bin/sh\nprintf "gh called\n" >> "%s/gh_calls"\n' "$mock_dir" > "$mock_dir/gh"
chmod +x "$mock_dir/claude" "$mock_dir/gh"
old_path="$PATH"; export PATH="$mock_dir:$PATH"

dry_out=$(_stack_cmd_update_summary --dry-run 2>/dev/null)
gh_dry=$(cat "$mock_dir/gh_calls" 2>/dev/null) || true
export PATH="$old_path"; rm -rf "$mock_dir"

assert_contains "dry-run prints summary" "Dry run summary" "$dry_out"
assert_eq       "dry-run skips gh call"  ""               "$gh_dry"

_teardown_test_env

# ── Suite 13: stack push ──────────────────────────────────────────────────────

_t_suite "stack push — force-pushes current branch and all descendants"

_create_test_env

# Create a bare repo as the remote
remote_dir=$(mktemp -d)
git init --bare "$remote_dir" --quiet
git remote add origin "$remote_dir"
git push origin main --quiet

stack new "feat-1"
printf 'f1\n' > f1.txt && git add f1.txt && git commit --quiet -m "feat-1"
stack new "feat-2"
printf 'f2\n' > f2.txt && git add f2.txt && git commit --quiet -m "feat-2"

# Push initial branches so remote tracking refs exist
git -C "$(_stack_main_repo_path)" push origin feat-1 --quiet
git -C "$(_stack_wt_path "feat-1")" push origin feat-2 --quiet

# Simulate cascade: amend feat-1 so it diverges from remote
cd "$(_stack_wt_path "feat-1")"
printf 'f1 updated\n' > f1.txt
git add f1.txt && git commit --quiet --amend --no-edit
stack cascade

# Now push the rebased stack
stack push

# Verify both branches were updated on the remote
feat1_remote=$(git -C "$remote_dir" rev-parse refs/heads/feat-1)
feat1_local=$(git rev-parse refs/heads/feat-1)
assert_eq "feat-1 pushed to remote"  "$feat1_local" "$feat1_remote"

feat2_remote=$(git -C "$remote_dir" rev-parse refs/heads/feat-2)
feat2_local=$(git rev-parse refs/heads/feat-2)
assert_eq "feat-2 pushed to remote"  "$feat2_local" "$feat2_remote"

rm -rf "$remote_dir"

_teardown_test_env

# ── Suite 14: backend detection ───────────────────────────────────────────────

_t_suite "stack mr/pr — backend detection"

_create_test_env

git remote add origin https://github.com/user/repo.git 2>/dev/null || true
assert_eq "detects github backend" "github" "$(_stack_detect_backend)"

git remote set-url origin https://gitlab.com/user/repo.git
assert_eq "detects gitlab backend" "gitlab" "$(_stack_detect_backend)"

git remote set-url origin https://gitlab.mycompany.com/user/repo.git
assert_eq "detects self-hosted gitlab" "gitlab" "$(_stack_detect_backend)"

# Both 'mr' and 'pr' map to same function
git remote set-url origin https://github.com/user/repo.git
out_mr=$( (stack mr 2>&1) ) || true
out_pr=$( (stack pr 2>&1) ) || true
assert_contains "stack mr mentions backend"  "github" "$out_mr"
assert_contains "stack pr mentions backend"  "github" "$out_pr"

_teardown_test_env

# ── Suite 15: stack status ────────────────────────────────────────────────────

_t_suite "stack status — shows tree with worktree paths"

_create_test_env

stack new "feat-1"
git commit --quiet --allow-empty -m "feat-1"
stack new "feat-2"
git commit --quiet --allow-empty -m "feat-2"
cd "$(_stack_wt_path "feat-1")"
stack new "feat-2b"
git commit --quiet --allow-empty -m "feat-2b"

cd "$(_stack_wt_path "feat-2")"

out=$(_stack_cmd_status 2>&1)

assert_contains "status shows main"            "main"    "$out"
assert_contains "status shows feat-1"          "feat-1"  "$out"
assert_contains "status shows feat-2"          "feat-2"  "$out"
assert_contains "status shows feat-2b"         "feat-2b" "$out"
assert_contains "current branch marked"        "current" "$out"
assert_contains "worktree path shown"          "$(_stack_wt_root)" "$out"
assert_current_branch "status is read-only"   "feat-2"

_teardown_test_env

_t_suite "stack status — single branch without stack parent"

_create_test_env

exit_code=0
out=$(_stack_cmd_status 2>&1) || exit_code=$?
assert_eq      "status exits 0"                   "0" "$exit_code"
assert_contains "output includes branch name"      "main" "$out"

_teardown_test_env

# ── Summary ───────────────────────────────────────────────────────────────────

printf '\n%s════════════════════════════════════════%s\n' "$_STACK_BOLD" "$_STACK_RESET"
printf 'Results: %s%d passed%s  %s%d failed%s\n' \
  "$_STACK_GREEN" "$_T_PASS" "$_STACK_RESET" \
  "$_STACK_RED"   "$_T_FAIL" "$_STACK_RESET"

if (( _T_FAIL > 0 )); then
  printf '\nFailed tests:\n'
  for e in "${_T_ERRORS[@]}"; do printf '  - %s\n' "$e"; done
  exit 1
fi
exit 0
