#!/bin/bash
# Tests for pr_base_repo (+ its interaction with review_marker_path) in
# _lib-review-markers.sh — the cross-fork approval-marker fix (me2resh/apexyard#765).
#
# pr_base_repo resolves a PR's BASE repo (the canonical marker key) by parsing the
# PR URL, falling back to a hint when base == head or gh fails. The discriminating
# assertions prove: (a) cross-fork keys on BASE, (b) same-repo is UNCHANGED.
#
# gh is mocked via a file-driven stub (no env-export subtleties): the stub prints
# the contents of $MOCKBIN/url, or exits non-zero when that file is empty.

set -u

SRC_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LIB="$SRC_ROOT/.claude/hooks/_lib-review-markers.sh"
# shellcheck source=/dev/null
. "$LIB"

PASS=0; FAIL=0; FAILED=""
assert_eq() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1));
  else echo "FAIL [$1]: want [$2] got [$3]" >&2; FAIL=$((FAIL+1)); FAILED="${FAILED}$1 "; fi
}

MOCKBIN=$(mktemp -d)
cat > "$MOCKBIN/gh" <<EOF
#!/bin/bash
# mock gh: emit the queued URL, or fail when none is queued.
[ -s "$MOCKBIN/url" ] || exit 1
cat "$MOCKBIN/url"
EOF
chmod +x "$MOCKBIN/gh"
export PATH="$MOCKBIN:$PATH"
seturl() { printf '%s' "$1" > "$MOCKBIN/url"; }

# 1. cross-fork gh PR → base parsed from URL (hint = the fork, must be ignored).
seturl 'https://github.com/me2resh/apexyard/pull/762'
assert_eq "cross-fork → base from URL" "me2resh/apexyard" \
  "$(pr_base_repo 762 AbdElrahmaN31/apexyard)"

# 2. same-repo → base == head (UNCHANGED — the provable no-op).
seturl 'https://github.com/me2resh/apexyard/pull/5'
assert_eq "same-repo → unchanged" "me2resh/apexyard" \
  "$(pr_base_repo 5 me2resh/apexyard)"

# 3. GitLab MR URL with a nested group → group/subgroup/project.
seturl 'https://gitlab.com/grp/sub/proj/-/merge_requests/12'
assert_eq "glab nested MR → base" "grp/sub/proj" \
  "$(pr_base_repo 12 grp/fork)"

# 4. gh fails (no URL queued) → fall back to the hint.
seturl ''
assert_eq "gh fail → hint fallback" "me2resh/apexyard" \
  "$(pr_base_repo 999 me2resh/apexyard)"

# 5. unparseable URL → hint fallback (sed leaves it unchanged → base==url → hint).
seturl 'https://github.com/not-a-pr-url'
assert_eq "bad URL → hint fallback" "owner/repo" \
  "$(pr_base_repo 1 owner/repo)"

# 6. no pr number → hint (guard, no gh call).
assert_eq "no pr → hint" "owner/repo" "$(pr_base_repo '' owner/repo)"

# 7. self-hosted GitHub Enterprise host → base still parsed (host-agnostic).
seturl 'https://github.example.com/team/svc/pull/8'
assert_eq "GHE host → base" "team/svc" "$(pr_base_repo 8 team/fork)"

# --- discriminating: the marker PATH keyed via pr_base_repo ---
MH=$(mktemp -d)
# cross-fork → marker keyed on BASE (this is the fix).
seturl 'https://github.com/me2resh/apexyard/pull/762'
CF=$(review_marker_path "$(pr_base_repo 762 AbdElrahmaN31/apexyard)" 762 rex "$MH")
assert_eq "cross-fork marker keyed on BASE" \
  "$MH/.claude/session/reviews/me2resh__apexyard__762-rex.approved" "$CF"
# same-repo → marker path UNCHANGED from the pre-#765 (base==head) behaviour.
seturl 'https://github.com/me2resh/apexyard/pull/5'
SR=$(review_marker_path "$(pr_base_repo 5 me2resh/apexyard)" 5 rex "$MH")
assert_eq "same-repo marker path unchanged" \
  "$MH/.claude/session/reviews/me2resh__apexyard__5-rex.approved" "$SR"

rm -rf "$MOCKBIN" "$MH"
echo "=========================================="
if [ "$FAIL" -eq 0 ]; then
  echo "PASS: $PASS  FAIL: 0"; exit 0
else
  echo "PASS: $PASS  FAIL: $FAIL  (failed: $FAILED)"; exit 1
fi
