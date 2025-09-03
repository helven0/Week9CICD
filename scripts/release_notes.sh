#!/usr/bin/env bash
set -euo pipefail

# Release Notes Auto-Sender (PR-level)
# Requires: GITHUB_REPOSITORY, GITHUB_SHA, GITHUB_TOKEN (from Actions), TEAMS_WEBHOOK (optional)

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"
SHA="${GITHUB_SHA:-}"

if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set. Exiting."
  exit 2
fi

# split owner and repo
OWNER=$(echo "$REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$REPO" | cut -d/ -f2)

# find last tag; if none, use 7 days ago
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  TAG_DATE=$(git log -1 --format=%cI "$LAST_TAG")
  SINCE_DATE="$TAG_DATE"
else
  # 7 days ago ISO format
  SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
fi

# Build search query: merged PRs since SINCE_DATE
# Use GitHub Search Issues API: merged:>YYYY-MM-DDTHH:MM:SSZ
SEARCH_URL="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=100"

PR_PAYLOAD=""
if [ -n "$GHTOKEN" ]; then
  PR_PAYLOAD=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$SEARCH_URL" || true)
else
  PR_PAYLOAD=""
fi

# Parse PRs using Python (safe JSON handling)
PR_LIST=$(printf "%s" "$PR_PAYLOAD" | python3 - <<'PY'
import sys, json
data = sys.stdin.read().strip()
if not data:
    sys.exit(0)
try:
    j = json.loads(data)
except Exception:
    sys.exit(0)
items = j.get("items", [])
out = []
for it in items:
    num = it.get("number")
    title = it.get("title", "").strip()
    user = (it.get("user") or {}).get("login", "unknown")
    url = it.get("html_url", "")
    out.append(f"- #{num} {title} ({user}) - {url}")
print("\n".join(out))
PY
)

# If we found PRs, use them. Otherwise, fall back to commits list.
if [ -n "$PR_LIST" ]; then
  BODY="**Release notes for ${REPO}**\nDeployed commit: ${SHA}\n\n_The following PRs were merged since ${SINCE_DATE}:_\n\n${PR_LIST}"
else
  # fallback to last 10 commits or since last tag
  if [ -n "$LAST_TAG" ]; then
    RANGE="${LAST_TAG}..HEAD"
  else
    RANGE="HEAD~10..HEAD"
  fi
  COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" "$RANGE" || echo "No commits")
  BODY="**Release notes for ${REPO}**\nDeployed commit: ${SHA}\n\n_The following commits were detected:_\n\n${COMMITS}"
fi

# Prepare JSON-safe payload using python
PAYLOAD=$(printf "%s" "$BODY" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

# Build final Teams message (simple text block)
FINAL_JSON="{\"text\": $PAYLOAD}"

if [ -n "$WEBHOOK" ]; then
  # post to Teams (best-effort)
  curl -s -X POST -H "Content-Type: application/json" -d "$FINAL_JSON" "$WEBHOOK" || true
  echo "Posted release notes to Teams."
else
  # print to logs
  echo -e "---- Release Notes ----\n$BODY\n-----------------------"
fi

exit 0
