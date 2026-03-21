#!/usr/bin/env bash
# weekly-digest.sh — Generate a weekly summary of repository activity
# Posts to a GitHub Discussion or Issue with metrics

set -euo pipefail

REPO="${REPO:?REPO is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"

export GH_TOKEN

echo "📊 Generating weekly digest for ${REPO}..."

# Count PRs opened this week
WEEK_AGO=$(date -v-7d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)

OPENED=$(gh pr list --repo "$REPO" --state all --search "created:>=${WEEK_AGO}" \
  --json number --jq 'length' 2>/dev/null) || OPENED="?"

MERGED=$(gh pr list --repo "$REPO" --state merged --search "merged:>=${WEEK_AGO}" \
  --json number --jq 'length' 2>/dev/null) || MERGED="?"

CLOSED=$(gh pr list --repo "$REPO" --state closed --search "closed:>=${WEEK_AGO}" \
  --json number,mergedAt --jq '[.[] | select(.mergedAt == null)] | length' 2>/dev/null) || CLOSED="?"

ISSUES_OPENED=$(gh issue list --repo "$REPO" --state all --search "created:>=${WEEK_AGO}" \
  --json number --jq 'length' 2>/dev/null) || ISSUES_OPENED="?"

echo ""
echo "=== Weekly Digest ==="
echo "Period: $(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d) to $(date +%Y-%m-%d)"
echo ""
echo "PRs opened:  ${OPENED}"
echo "PRs merged:  ${MERGED}"
echo "PRs closed:  ${CLOSED}"
echo "Issues opened: ${ISSUES_OPENED}"
echo ""
echo "=== END Weekly Digest ==="
