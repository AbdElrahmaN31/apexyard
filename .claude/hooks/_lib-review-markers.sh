#!/bin/bash
# _lib-review-markers.sh — single source of truth for review-marker path
# construction.
#
# WHY THIS EXISTS
# ---------------
# Review markers (.claude/session/reviews/<qualifier>-<role>.approved) were
# previously keyed by bare PR number, e.g. `429-rex.approved`. Because PR
# numbers are per-repository and routinely overlap across managed repos, two
# repos could each have a PR #429 whose markers shared the same filename —
# a (repo, pr) collision hazard.
#
# This library encodes the repo in every marker path using the scheme:
#
#   <owner>__<repo>__<pr>-<role>.approved
#
# Double-underscore is the separator because GitHub owner/repo slugs use only
# [a-zA-Z0-9._-] — they never contain `__`. Splitting on `__` reliably
# recovers the three components. See docs/agdr/AgDR-0060-review-marker-repo-qualifier.md.
#
# FUNCTIONS
# ---------
#   review_marker_path <owner/repo> <pr> <role>
#       Returns the absolute path to the marker file, anchored at the
#       resolved MARKER_HOME/.claude/session/reviews/ directory. Exits with
#       a non-zero status and an error message if required args are missing.
#       Does NOT create the directory — callers must `mkdir -p` as needed.
#
#   review_markers_dir <marker_home>
#       Returns the absolute path to the reviews directory:
#       <marker_home>/.claude/session/reviews
#
# USAGE (in a hook or skill)
# --------------------------
#   . "$(dirname "$0")/_lib-review-markers.sh"
#   # ... resolve MARKER_HOME as usual via _lib-ops-root.sh ...
#   MARKER_HOME="${OPS_ROOT:-${REPO_ROOT:-.}}"
#   REX_MARKER=$(review_marker_path "owner/repo" "$PR_NUMBER" rex)
#
# SOURCE GUARD
# ------------
# Idempotent: sourcing more than once is a no-op (standard _lib pattern).

[ -n "${_LIB_REVIEW_MARKERS_SOURCED:-}" ] && return 0
_LIB_REVIEW_MARKERS_SOURCED=1

# review_markers_dir <marker_home>
# Returns the path: <marker_home>/.claude/session/reviews
review_markers_dir() {
  local marker_home="${1:-.}"
  printf '%s/.claude/session/reviews' "$marker_home"
}

# review_marker_path <owner/repo> <pr> <role> [marker_home]
#
# Args:
#   owner/repo  — the fully-qualified GitHub repo (e.g. "me2resh/apexyard").
#                 Slashes are sanitised to double-underscores in the filename.
#   pr          — the PR number (integer)
#   role        — the marker role: rex | ceo | design | architecture
#   marker_home — optional; defaults to $MARKER_HOME if set, then "." as last
#                 resort. Callers that have already resolved the ops fork root
#                 via _lib-ops-root.sh should pass it explicitly.
#
# Output (stdout): the absolute marker file path.
# Exit code: 0 on success; 1 if required args are missing (with stderr msg).
review_marker_path() {
  local repo="${1:-}"
  local pr="${2:-}"
  local role="${3:-}"
  local marker_home="${4:-${MARKER_HOME:-.}}"

  if [ -z "$repo" ] || [ -z "$pr" ] || [ -z "$role" ]; then
    echo "_lib-review-markers.sh: review_marker_path requires <owner/repo> <pr> <role>" >&2
    return 1
  fi

  # Sanitise: replace every '/' with '__' so the repo slug is flat-file safe.
  local safe_repo
  safe_repo=$(printf '%s' "$repo" | tr '/' '_' | sed 's/_/__/g; s/____/__/g')
  # The tr+sed above can double the underscores incorrectly for repos that
  # already use underscores. Use a single, cleaner transformation instead:
  # replace ALL '/' with the two-char string '__'.
  safe_repo=$(printf '%s' "$repo" | sed 's|/|__|g')

  local reviews_dir
  reviews_dir=$(review_markers_dir "$marker_home")

  printf '%s/%s__%s-%s.approved' "$reviews_dir" "$safe_repo" "$pr" "$role"
}

# pr_base_repo <pr> [hint_repo]
#
# Echoes the PR/MR's BASE (host) repo as "owner/repo" — the repo the PR *lives
# on* and is numbered against. This is the canonical key for approval markers
# (me2resh/apexyard#765).
#
# WHY THE BASE REPO IS CANONICAL
# ------------------------------
# The merge gates (block-unreviewed-merge.sh, require-architecture-review.sh,
# require-design-review-for-ui.sh) derive their marker-lookup repo (`CMD_REPO`)
# from the merge command's `--repo` value or `gh api repos/<o>/<r>/pulls/.../merge`
# path. For a CROSS-FORK PR that is ALWAYS the base repo — you cannot merge a
# fork's copy (`gh pr merge <n> --repo <fork>` errors; the PR doesn't live
# there). So `merge --repo == CMD_REPO == base`. Historically the marker WRITERS
# keyed on `headRepository` (the fork) instead, so on a cross-fork PR the marker
# was written under the fork qualifier while the gate searched under the base →
# a valid approval never satisfied the gate. Keying every writer on the base via
# this helper makes writer/reader agreement STRUCTURAL, not coincidental.
#
# `gh pr view` exposes no baseRepository field, but the PR URL is ALWAYS rooted
# on the base repo — parse owner/repo from it (handles GitHub /pull/ and GitLab
# /-/merge_requests/, including nested GitLab groups). Falls back to <hint_repo>
# (typically the headRepository value) when the URL can't be parsed or gh is
# unavailable — so SAME-REPO PRs (base == head) resolve exactly as before and
# this change is a provable no-op for them.
#
# Args:
#   pr        — the PR/MR number.
#   hint_repo — optional "owner/repo": scopes the gh query with --repo AND is the
#               fallback when URL parsing yields nothing.
#
# Output (stdout): "owner/repo", or the hint (or empty) when unresolved.
pr_base_repo() {
  local pr="${1:-}" hint="${2:-}" url base
  if [ -z "$pr" ]; then
    [ -n "$hint" ] && printf '%s' "$hint"
    return 0
  fi
  if [ -n "$hint" ]; then
    url=$(gh pr view "$pr" --repo "$hint" --json url --jq '.url' 2>/dev/null)
  else
    url=$(gh pr view "$pr" --json url --jq '.url' 2>/dev/null)
  fi
  base=$(printf '%s' "$url" | sed -E 's#^https?://[^/]+/(.+)/(pull|-/merge_requests)/[0-9].*#\1#')
  if [ -n "$base" ] && [ "$base" != "$url" ]; then
    printf '%s' "$base"
  else
    [ -n "$hint" ] && printf '%s' "$hint"
  fi
}
