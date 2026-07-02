#!/bin/bash
# test_forge_aware_extract_pr.sh — the #764 forge-awareness of the merge-gate
# PR/MR extraction lib (`_lib-extract-pr.sh`).
#
# The merge gates originally spoke only GitHub. A GitLab-forge project merges via
# `glab mr merge <iid>` — a shape the matcher + extractor didn't recognise, so
# the gates silently didn't fire (the forge analog of the #47 `gh api` bypass).
# This suite proves the lib now recognises the glab merge shape and resolves MR
# state via a mocked `glab`, WITHOUT disturbing the gh path (regression cases).
#
# Uses MOCK CLIs (fake gh/glab on PATH) — no real PR/MR is touched. Forge kind is
# driven by the sandbox's project-config `.tracker.kind` (resolved via tracker_kind).
#
# Cases:
#   is_merge_command:        glab mr merge recognised; non-merge glab rejected; gh unchanged
#   extract_pr_number:       glab positional iid; glab fallback via `glab mr view`
#   extract_repo_from_command: glab -R flag; glab fallback via `glab repo view`
#   resolve_pr_head:         glab MR HEAD via `glab mr view .sha`; gh path unchanged (regression)
#   resolve_pr_head_branch:  glab source_branch; gh headRefName (regression)
#   merge_command_uses_variable: glab `$VAR` positional + `-R $VAR` detected
#
# Exit 0 = all pass. Exit 1 on first failure.

set -u
unset APEXYARD_OPS_PIN_DIR CLAUDE_CODE_SESSION_ID 2>/dev/null || true

HOOK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXTRACT_LIB="$HOOK_DIR/_lib-extract-pr.sh"
TRACKER_LIB="$HOOK_DIR/_lib-tracker.sh"
CONFIG_LIB="$HOOK_DIR/_lib-read-config.sh"
PORTFOLIO_LIB="$HOOK_DIR/_lib-portfolio-paths.sh"
OPSROOT_LIB="$HOOK_DIR/_lib-ops-root.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$2" "$3"; fi; }
assert_true()  { if "$@" >/dev/null 2>&1; then pass "${*}"; else fail "${*} (expected true)" "0" "1"; fi; }
assert_false() { if "$@" >/dev/null 2>&1; then fail "${*} (expected false)" "1" "0"; else pass "${*} → false"; fi; }

# Build a sandbox with a chosen tracker kind so tracker_kind (→ _forge_kind_for)
# resolves gh or glab. Copies the extraction lib + tracker lib + config libs.
make_sandbox() {
  local kind="${1:-gh}" sb
  sb=$(mktemp -d); sb=$(cd "$sb" && pwd -P)
  mkdir -p "$sb/.claude/hooks" "$sb/bin"
  touch "$sb/onboarding.yaml"
  cp "$EXTRACT_LIB"   "$sb/.claude/hooks/_lib-extract-pr.sh"
  cp "$TRACKER_LIB"   "$sb/.claude/hooks/_lib-tracker.sh"
  cp "$CONFIG_LIB"    "$sb/.claude/hooks/_lib-read-config.sh"
  cp "$PORTFOLIO_LIB" "$sb/.claude/hooks/_lib-portfolio-paths.sh"
  [ -f "$OPSROOT_LIB" ] && cp "$OPSROOT_LIB" "$sb/.claude/hooks/_lib-ops-root.sh"
  printf '{ "tracker": { "kind": "%s" } }\n' "$kind" > "$sb/.claude/project-config.defaults.json"
  printf 'version: 1\nprojects: []\n' > "$sb/apexyard.projects.yaml"
  echo "$sb"
}

# Mock glab: capture argv, print MR/repo JSON for the view subcommands.
install_glab_mock() {
  local sb="$1"
  cat > "$sb/bin/glab" <<'EOF'
#!/bin/bash
[ -n "${GLAB_CAPTURE:-}" ] && printf '%s\n' "$@" > "$GLAB_CAPTURE"
if [ "$1" = "mr" ] && [ "$2" = "view" ]; then
  echo '{"iid":42,"sha":"glabsha0000000000000000000000000000000042","source_branch":"feature/gl-x","diff_refs":{"head_sha":"glabsha0000000000000000000000000000000042"}}'
elif [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  echo '{"full_name":"o/r"}'
fi
EOF
  chmod +x "$sb/bin/glab"
}

# Mock gh: print the field the merge hooks ask for (headRefOid / headRefName / …).
install_gh_mock() {
  local sb="$1"
  cat > "$sb/bin/gh" <<'EOF'
#!/bin/bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  case "$*" in
    *headRefOid*)     echo "ghsha00000000000000000000000000000000000007" ;;
    *headRefName*)    echo "main" ;;
    *headRepository*) echo "o/r" ;;
    *number*)         echo "7" ;;
  esac
fi
EOF
  chmod +x "$sb/bin/gh"
}

# ---------------------------------------------------------------------------
# Primary sandbox: kind=glab (drives _forge_kind_for → glab for the resolvers).
SB=$(make_sandbox glab)
install_glab_mock "$SB"
install_gh_mock "$SB"
cd "$SB" || { echo "FAIL: cd sandbox"; exit 1; }
# shellcheck source=/dev/null
. "$SB/.claude/hooks/_lib-extract-pr.sh"

# --- is_merge_command: forge shapes ---
assert_true  is_merge_command "glab mr merge 42 -R o/r --squash"
assert_true  is_merge_command "gh pr merge 42 --squash"
assert_true  is_merge_command "gh api repos/o/r/pulls/42/merge -X PUT"
assert_false is_merge_command "glab mr view 42 -R o/r"
assert_false is_merge_command "glab mr note 42"
assert_false is_merge_command "echo not a merge"

# --- extract_pr_number: glab positional iid (no CLI needed) ---
assert_eq "extract_pr_number glab positional" "42" "$(extract_pr_number 'glab mr merge 42 -R o/r --squash')"
# redirection must not leak digits (the #568 discipline, glab span)
assert_eq "extract_pr_number glab positional w/ redirection" "42" "$(extract_pr_number 'glab mr merge 42 -R o/r 2>&1 | tail -5')"
# glab fallback: no positional → `glab mr view` (mock returns iid 42)
tracker_clear_cache 2>/dev/null || true
assert_eq "extract_pr_number glab fallback via glab mr view" "42" "$(PATH="$SB/bin:$PATH" extract_pr_number 'glab mr merge --squash')"

# --- extract_repo_from_command: glab -R flag; glab fallback ---
assert_eq "extract_repo glab -R flag" "o/r" "$(extract_repo_from_command 'glab mr merge 42 -R o/r --squash')"
assert_eq "extract_repo glab --repo flag" "o/r" "$(extract_repo_from_command 'glab mr merge 42 --repo o/r')"
assert_eq "extract_repo glab fallback via glab repo view" "o/r" "$(PATH="$SB/bin:$PATH" extract_repo_from_command 'glab mr merge 42')"

# --- repo-flag search is span-fenced: a trailing unrelated -R in a compound
#     command must NOT be captured (Rex finding on PR #767). ---
assert_eq "extract_repo gh compound: trailing 'grep -R' ignored" "o/r" \
  "$(extract_repo_from_command 'gh pr merge 42 --repo o/r && grep -R foo .')"
assert_eq "extract_repo glab compound: trailing 'grep -R' ignored" "o/r" \
  "$(extract_repo_from_command 'glab mr merge 42 -R o/r && grep -R foo .')"
assert_false merge_command_uses_variable 'gh pr merge 42 --repo o/r && grep -R $HOME .'

# --- resolve_pr_head / resolve_pr_head_branch: glab path (kind=glab) ---
tracker_clear_cache 2>/dev/null || true
assert_eq "resolve_pr_head glab → .sha" "glabsha0000000000000000000000000000000042" \
  "$(PATH="$SB/bin:$PATH" resolve_pr_head 42 o/r)"
tracker_clear_cache 2>/dev/null || true
assert_eq "resolve_pr_head_branch glab → .source_branch" "feature/gl-x" \
  "$(PATH="$SB/bin:$PATH" resolve_pr_head_branch 42 o/r)"

# --- merge_command_uses_variable: glab $VAR forms (#643 parity) ---
assert_true  merge_command_uses_variable 'glab mr merge $MR -R o/r'
assert_true  merge_command_uses_variable 'glab mr merge 42 -R $REPO'
assert_false merge_command_uses_variable 'glab mr merge 42 -R o/r --squash'

# ---------------------------------------------------------------------------
# Regression sandbox: kind=gh — the resolvers must take the UNCHANGED gh path.
SB_GH=$(make_sandbox gh)
install_glab_mock "$SB_GH"   # present but must NOT be used on the gh path
install_gh_mock "$SB_GH"
cd "$SB_GH" || { echo "FAIL: cd gh sandbox"; exit 1; }
tracker_clear_cache 2>/dev/null || true
assert_eq "resolve_pr_head gh path unchanged (regression)" "ghsha00000000000000000000000000000000000007" \
  "$(PATH="$SB_GH/bin:$PATH" resolve_pr_head 7 o/r)"
tracker_clear_cache 2>/dev/null || true
assert_eq "resolve_pr_head_branch gh path unchanged (regression)" "main" \
  "$(PATH="$SB_GH/bin:$PATH" resolve_pr_head_branch 7 o/r)"
# gh merge shapes still recognised; gh $VAR still detected
assert_true  is_merge_command "gh pr merge 7 --repo o/r --squash"
assert_eq "extract_pr_number gh positional (regression)" "7" "$(extract_pr_number 'gh pr merge 7 --repo o/r --squash')"
assert_true  merge_command_uses_variable 'gh pr merge $PR --repo o/r'

# ---------------------------------------------------------------------------
echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
