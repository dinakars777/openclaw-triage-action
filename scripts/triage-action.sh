#!/usr/bin/env bash
# triage-action.sh — Main engine for the PR Triage GitHub Action
# Runs automatically on PR open/reopen/synchronize events
# Posts a structured triage comment on the PR
set -euo pipefail

###############################################################################
# Environment (set by action.yml)
###############################################################################
PR_NUMBER="${PR_NUMBER:?PR_NUMBER is required}"
REPO="${REPO:?REPO is required}"
GH_TOKEN="${GH_TOKEN:?GH_TOKEN is required}"
DUPLICATE_THRESHOLD="${DUPLICATE_THRESHOLD:-50}"
ENABLE_LABELS="${ENABLE_LABELS:-true}"
ENABLE_DUPLICATE_CHECK="${ENABLE_DUPLICATE_CHECK:-true}"
ENABLE_CONTRIBUTOR_PROFILE="${ENABLE_CONTRIBUTOR_PROFILE:-true}"

export GH_TOKEN

echo "🔍 Triaging PR #${PR_NUMBER} in ${REPO}..."

###############################################################################
# 1. Fetch PR metadata
###############################################################################
echo "📥 Fetching PR metadata..."

PR_DATA=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json \
  number,title,state,author,createdAt,updatedAt,baseRefName,headRefName, \
  isDraft,mergeable,mergeStateStatus,labels,reviewDecision,reviewRequests, \
  additions,deletions,changedFiles,body,url,milestone,assignees,files \
  2>/dev/null) || {
  echo "::error::Failed to fetch PR #${PR_NUMBER}"
  exit 1
}

TITLE=$(echo "$PR_DATA" | jq -r '.title')
AUTHOR=$(echo "$PR_DATA" | jq -r '.author.login')
ADDITIONS=$(echo "$PR_DATA" | jq -r '.additions')
DELETIONS=$(echo "$PR_DATA" | jq -r '.deletions')
CHANGED_FILES=$(echo "$PR_DATA" | jq -r '.changedFiles')
IS_DRAFT=$(echo "$PR_DATA" | jq -r '.isDraft')
MERGEABLE=$(echo "$PR_DATA" | jq -r '.mergeable')
MERGE_STATUS=$(echo "$PR_DATA" | jq -r '.mergeStateStatus')
REVIEW_DECISION=$(echo "$PR_DATA" | jq -r '.reviewDecision')
BASE_BRANCH=$(echo "$PR_DATA" | jq -r '.baseRefName')
HEAD_BRANCH=$(echo "$PR_DATA" | jq -r '.headRefName')
BODY=$(echo "$PR_DATA" | jq -r '.body // ""')
URL=$(echo "$PR_DATA" | jq -r '.url')
CREATED=$(echo "$PR_DATA" | jq -r '.createdAt')
LABELS=$(echo "$PR_DATA" | jq -r '[.labels[].name] | join(", ")')
FILE_PATHS=$(echo "$PR_DATA" | jq -r '[.files[].path] | join("\n")')

TOTAL_CHANGES=$((ADDITIONS + DELETIONS))

###############################################################################
# 2. Classify PR type
###############################################################################
echo "🏷️  Classifying PR type..."

LOWER_TITLE=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]')
LOWER_BODY=$(echo "$BODY" | tr '[:upper:]' '[:lower:]' | head -c 2000)
LOWER_BRANCH=$(echo "$HEAD_BRANCH" | tr '[:upper:]' '[:lower:]')
TEXT="$LOWER_TITLE $LOWER_BODY $LOWER_BRANCH"

# Check file patterns
HAS_DOCS_ONLY=false
HAS_DEPS_ONLY=false
HAS_CI_ONLY=false
HAS_TEST_ONLY=false
HAS_SECURITY_FILES=false

DOCS_PATTERN='\.md$|\.txt$|\.rst$|^docs/|^doc/'
DEPS_PATTERN='package\.json$|package-lock\.json$|yarn\.lock$|Cargo\.toml$|Cargo\.lock$|go\.mod$|go\.sum$|requirements\.txt$|Gemfile|pnpm-lock'
CI_PATTERN='\.github/workflows/|Makefile$|Dockerfile$|\.ci/|\.circleci/|\.travis\.yml$|Jenkinsfile$'
TEST_PATTERN='test|spec|__tests__|_test\.'
SECURITY_PATTERN='auth|security|crypto|password|token|secret|session|permission|access|login|oauth|jwt|encrypt|certificate|ssl|tls'

if echo "$FILE_PATHS" | grep -qE "$SECURITY_PATTERN"; then
  HAS_SECURITY_FILES=true
fi

if echo "$FILE_PATHS" | grep -qvE "$DOCS_PATTERN" > /dev/null 2>&1; then
  HAS_DOCS_ONLY=false
else
  HAS_DOCS_ONLY=true
fi

# Determine PR type
PR_TYPE="chore"
TYPE_EMOJI="🔧"

if [[ "$HAS_DOCS_ONLY" == "true" ]]; then
  PR_TYPE="docs"; TYPE_EMOJI="📝"
elif echo "$FILE_PATHS" | grep -qE "$CI_PATTERN" && ! echo "$FILE_PATHS" | grep -qvE "$CI_PATTERN" 2>/dev/null; then
  PR_TYPE="ci"; TYPE_EMOJI="⚙️"
elif echo "$FILE_PATHS" | grep -qE "$DEPS_PATTERN" && ! echo "$FILE_PATHS" | grep -qvE "$DEPS_PATTERN" 2>/dev/null; then
  PR_TYPE="deps"; TYPE_EMOJI="📦"
elif echo "$TEXT" | grep -qE "(fix|bug|crash|error|regression|resolve|patch)"; then
  PR_TYPE="bug-fix"; TYPE_EMOJI="🐛"
elif echo "$TEXT" | grep -qE "(feat|add|implement|new|support|introduce)"; then
  PR_TYPE="feature"; TYPE_EMOJI="✨"
elif echo "$TEXT" | grep -qE "(refactor|cleanup|reorganize|rename|restructure)"; then
  PR_TYPE="refactor"; TYPE_EMOJI="♻️"
elif echo "$FILE_PATHS" | grep -qE "$TEST_PATTERN" && ! echo "$FILE_PATHS" | grep -qvE "$TEST_PATTERN" 2>/dev/null; then
  PR_TYPE="test"; TYPE_EMOJI="🧪"
fi

###############################################################################
# 3. Assess risk level
###############################################################################
echo "⚠️  Assessing risk..."

RISK="low"
RISK_EMOJI="🟢"
RISK_REASONS=()

if [[ "$HAS_SECURITY_FILES" == "true" ]]; then
  RISK="critical"; RISK_EMOJI="🔴"
  RISK_REASONS+=("Touches security-sensitive files")
fi

if echo "$FILE_PATHS" | grep -qE "$CI_PATTERN" && [[ "$PR_TYPE" != "ci" ]]; then
  RISK="high"; RISK_EMOJI="🟠"
  RISK_REASONS+=("Modifies CI pipelines alongside code")
fi

if [[ "$TOTAL_CHANGES" -gt 500 ]] && [[ "$CHANGED_FILES" -gt 10 ]]; then
  if [[ "$RISK" != "critical" ]]; then
    RISK="high"; RISK_EMOJI="🟠"
  fi
  RISK_REASONS+=("Large change: ${TOTAL_CHANGES} lines across ${CHANGED_FILES} files")
elif [[ "$TOTAL_CHANGES" -gt 200 ]] || [[ "$CHANGED_FILES" -gt 5 ]]; then
  if [[ "$RISK" == "low" ]]; then
    RISK="medium"; RISK_EMOJI="🟡"
  fi
  RISK_REASONS+=("Medium-sized change: ${TOTAL_CHANGES} lines across ${CHANGED_FILES} files")
fi

if [[ ${#RISK_REASONS[@]} -eq 0 ]]; then
  RISK_REASONS+=("Small, focused change")
fi

###############################################################################
# 4. Determine suggested labels
###############################################################################
echo "🏷️  Suggesting labels..."

SUGGESTED_LABELS=("triage:$PR_TYPE")

if [[ "$RISK" == "critical" ]] || [[ "$RISK" == "high" ]]; then
  SUGGESTED_LABELS+=("risk:$RISK")
fi

if [[ "$HAS_SECURITY_FILES" == "true" ]]; then
  SUGGESTED_LABELS+=("security")
fi

if [[ "$IS_DRAFT" == "true" ]]; then
  SUGGESTED_LABELS+=("draft")
fi

if [[ "$TOTAL_CHANGES" -lt 50 ]] && [[ "$CHANGED_FILES" -le 2 ]]; then
  SUGGESTED_LABELS+=("size:small")
elif [[ "$TOTAL_CHANGES" -gt 500 ]]; then
  SUGGESTED_LABELS+=("size:large")
fi

###############################################################################
# 5. Check for duplicates (optional)
###############################################################################
DUPLICATE_SECTION=""

if [[ "$ENABLE_DUPLICATE_CHECK" == "true" ]]; then
  echo "🔍 Checking for duplicates..."

  TARGET_FILES=$(echo "$PR_DATA" | jq -r '[.files[].path] | .[]')
  TARGET_FILE_COUNT=$(echo "$TARGET_FILES" | wc -l | xargs)

  if [[ "$TARGET_FILE_COUNT" -gt 0 ]]; then
    # Get recent open PRs
    OPEN_PRS=$(gh pr list --repo "$REPO" --state open --limit 30 \
      --json number,title,author,headRefName,files \
      --jq ".[] | select(.number != ${PR_NUMBER})" 2>/dev/null) || OPEN_PRS=""

    DUPLICATES_FOUND=""

    if [[ -n "$OPEN_PRS" ]]; then
      echo "$OPEN_PRS" | jq -c '.' 2>/dev/null | while IFS= read -r other_pr; do
        OTHER_NUM=$(echo "$other_pr" | jq -r '.number')
        OTHER_TITLE=$(echo "$other_pr" | jq -r '.title')
        OTHER_AUTHOR=$(echo "$other_pr" | jq -r '.author.login')
        OTHER_FILES=$(echo "$other_pr" | jq -r '[.files[].path] | .[]' 2>/dev/null) || continue

        # Count file overlap
        OVERLAP=0
        while IFS= read -r f; do
          if echo "$OTHER_FILES" | grep -qF "$f"; then
            OVERLAP=$((OVERLAP + 1))
          fi
        done <<< "$TARGET_FILES"

        if [[ "$TARGET_FILE_COUNT" -gt 0 ]]; then
          OVERLAP_PCT=$(( (OVERLAP * 100) / TARGET_FILE_COUNT ))
        else
          OVERLAP_PCT=0
        fi

        if [[ "$OVERLAP_PCT" -ge "$DUPLICATE_THRESHOLD" ]]; then
          RISK_LEVEL="medium"
          RISK_NOTE="Overlapping files"
          if [[ "$OTHER_AUTHOR" != "$AUTHOR" ]] && [[ "$OVERLAP_PCT" -ge 80 ]]; then
            RISK_LEVEL="high"
            RISK_NOTE="⚠️ Different author with ${OVERLAP_PCT}% file overlap"
          fi
          DUPLICATES_FOUND="${DUPLICATES_FOUND}\n| #${OTHER_NUM} | ${OTHER_TITLE} | @${OTHER_AUTHOR} | ${OVERLAP_PCT}% | ${RISK_LEVEL} |"
        fi
      done
    fi

    if [[ -n "$DUPLICATES_FOUND" ]]; then
      DUPLICATE_SECTION="
### 🔍 Potential Duplicates

| PR | Title | Author | File Overlap | Risk |
|----|-------|--------|-------------|------|${DUPLICATES_FOUND}
"
    fi
  fi
fi

###############################################################################
# 6. Contributor profile (optional)
###############################################################################
CONTRIBUTOR_SECTION=""

if [[ "$ENABLE_CONTRIBUTOR_PROFILE" == "true" ]]; then
  echo "👤 Profiling contributor @${AUTHOR}..."

  MERGED=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state merged --limit 100 \
    --json number --jq 'length' 2>/dev/null) || MERGED="0"
  CLOSED=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state closed --limit 100 \
    --json number,mergedAt --jq '[.[] | select(.mergedAt == null)] | length' 2>/dev/null) || CLOSED="0"
  OPEN=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state open --limit 100 \
    --json number --jq 'length' 2>/dev/null) || OPEN="0"

  TOTAL_PRS=$((MERGED + CLOSED + OPEN))

  if [[ "$TOTAL_PRS" -gt 0 ]]; then
    MERGE_RATE=$(( (MERGED * 100) / TOTAL_PRS ))
  else
    MERGE_RATE=0
  fi

  # Determine tier
  if [[ "$TOTAL_PRS" -eq 1 ]] && [[ "$MERGED" -eq 0 ]]; then
    TIER="🆕 First-time contributor"
    TIER_ACTION="Welcome! Consider leaving encouraging, constructive feedback."
  elif [[ "$TOTAL_PRS" -le 3 ]]; then
    TIER="🌱 New contributor"
    TIER_ACTION="May need guidance on project conventions."
  elif [[ "$MERGE_RATE" -ge 80 ]] && [[ "$MERGED" -ge 10 ]]; then
    TIER="⭐ Trusted contributor"
    TIER_ACTION="Fast-track review recommended — high merge rate."
  elif [[ "$MERGE_RATE" -ge 60 ]]; then
    TIER="✅ Regular contributor"
    TIER_ACTION="Standard review process."
  elif [[ "$MERGE_RATE" -lt 30 ]] && [[ "$TOTAL_PRS" -ge 5 ]]; then
    TIER="⚠️ Low merge rate"
    TIER_ACTION="Review with extra attention to quality."
  else
    TIER="👤 Occasional contributor"
    TIER_ACTION="Standard review process."
  fi

  # Bot detection
  LOWER_AUTHOR=$(echo "$AUTHOR" | tr '[:upper:]' '[:lower:]')
  IS_BOT=""
  if echo "$LOWER_AUTHOR" | grep -qE "(bot|dependabot|renovate|snyk|github-actions|codecov)"; then
    IS_BOT=" 🤖 *Automated account*"
  fi

  CONTRIBUTOR_SECTION="
### 👤 Contributor: @${AUTHOR}${IS_BOT}

| Metric | Value |
|--------|-------|
| **Tier** | ${TIER} |
| **Total PRs** | ${TOTAL_PRS} |
| **Merged** | ${MERGED} ✅ |
| **Merge Rate** | ${MERGE_RATE}% |
| **Open PRs** | ${OPEN} |

> ${TIER_ACTION}
"
fi

###############################################################################
# 7. Determine recommended action
###############################################################################
echo "💡 Generating recommendation..."

if [[ "$IS_DRAFT" == "true" ]]; then
  ACTION="⏳ **Draft PR** — No review needed yet. Check back when marked ready."
  ACTION_EMOJI="⏳"
elif [[ "$RISK" == "critical" ]]; then
  ACTION="🚨 **Security Review Required** — This PR touches security-sensitive code. Request a security-focused reviewer."
  ACTION_EMOJI="🚨"
elif [[ "$REVIEW_DECISION" == "APPROVED" ]] && [[ "$MERGE_STATUS" == "CLEAN" ]]; then
  ACTION="✅ **Ready to Merge** — Approved and CI passing."
  ACTION_EMOJI="✅"
elif [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
  ACTION="🔄 **Changes Requested** — Author needs to address review feedback."
  ACTION_EMOJI="🔄"
elif [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  ACTION="⚠️ **Merge Conflicts** — Base branch has diverged. Author needs to rebase."
  ACTION_EMOJI="⚠️"
elif [[ "$PR_TYPE" == "docs" ]] || [[ "$PR_TYPE" == "deps" ]]; then
  ACTION="👀 **Quick Review** — Low-risk ${PR_TYPE} change. Can be reviewed quickly."
  ACTION_EMOJI="👀"
else
  ACTION="👁️ **Needs Review** — Assign a reviewer for this ${PR_TYPE} PR."
  ACTION_EMOJI="👁️"
fi

###############################################################################
# 8. Build the comment
###############################################################################
echo "📝 Building triage report..."

RISK_REASONS_STR=""
for reason in "${RISK_REASONS[@]}"; do
  RISK_REASONS_STR="${RISK_REASONS_STR}\n- ${reason}"
done

LABELS_STR=""
for label in "${SUGGESTED_LABELS[@]}"; do
  LABELS_STR="${LABELS_STR} \`${label}\`"
done

COMMENT="## ${ACTION_EMOJI} PR Triage — #${PR_NUMBER}

${ACTION}

---

### 📊 Classification

| Field | Value |
|-------|-------|
| **Type** | ${TYPE_EMOJI} \`${PR_TYPE}\` |
| **Risk** | ${RISK_EMOJI} \`${RISK}\` |
| **Size** | \`+${ADDITIONS} / -${DELETIONS}\` across ${CHANGED_FILES} files |
| **Branch** | \`${HEAD_BRANCH}\` → \`${BASE_BRANCH}\` |
| **Draft** | ${IS_DRAFT} |
| **Mergeable** | ${MERGEABLE} (${MERGE_STATUS}) |
| **Review** | ${REVIEW_DECISION:-none} |

**Risk factors:**
$(echo -e "$RISK_REASONS_STR")

**Suggested labels:**${LABELS_STR}
${DUPLICATE_SECTION}${CONTRIBUTOR_SECTION}
---
<sub>🤖 Auto-triaged by <a href=\"https://github.com/dinakars777/openclaw-triage-action\">openclaw-triage-action</a></sub>"

###############################################################################
# 9. Post comment on the PR
###############################################################################
echo "💬 Posting triage comment..."

# Check for existing triage comment to update instead of duplicate
EXISTING_COMMENT_ID=$(gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" \
  --jq '.[] | select(.body | contains("PR Triage —")) | .id' \
  2>/dev/null | head -1) || EXISTING_COMMENT_ID=""

if [[ -n "$EXISTING_COMMENT_ID" ]]; then
  echo "📝 Updating existing triage comment..."
  gh api "repos/${REPO}/issues/comments/${EXISTING_COMMENT_ID}" \
    -X PATCH \
    -f body="$COMMENT" \
    --silent 2>/dev/null || echo "::warning::Failed to update comment"
else
  echo "💬 Creating new triage comment..."
  gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$COMMENT" 2>/dev/null || \
    echo "::warning::Failed to post comment"
fi

###############################################################################
# 10. Apply labels (optional)
###############################################################################
if [[ "$ENABLE_LABELS" == "true" ]]; then
  echo "🏷️  Applying labels..."
  for label in "${SUGGESTED_LABELS[@]}"; do
    # Create label if it doesn't exist, ignore errors
    gh label create "$label" --repo "$REPO" --color "0E8A16" --force 2>/dev/null || true
  done
  # Apply all labels at once
  LABEL_ARGS=""
  for label in "${SUGGESTED_LABELS[@]}"; do
    LABEL_ARGS="${LABEL_ARGS} --add-label ${label}"
  done
  # shellcheck disable=SC2086
  gh pr edit "$PR_NUMBER" --repo "$REPO" $LABEL_ARGS 2>/dev/null || \
    echo "::warning::Failed to apply labels"
fi

echo ""
echo "✅ Triage complete for PR #${PR_NUMBER}"
echo "   Type: ${PR_TYPE} | Risk: ${RISK} | Action: ${ACTION_EMOJI}"
