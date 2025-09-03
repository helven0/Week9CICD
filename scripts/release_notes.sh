#!/usr/bin/env bash
set -euo pipefail

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"
SHA="${GITHUB_SHA:-}"
if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set; exiting"
  exit 2
fi

OWNER=$(echo "$REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$REPO" | cut -d/ -f2)

# Find a since date: last tag date or 7 days ago
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG")
else
  SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
fi

# Query merged PRs since SINCE_DATE
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
PR_JSON=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")

# Build PR lines: up to 8 PRs
PR_LINES=$(echo "$PR_JSON" | python3 - <<PY
import sys,json
data=sys.stdin.read()
if not data:
    print('')
    sys.exit(0)
j=json.loads(data)
items=j.get('items',[])[:8]
out=[]
for it in items:
    num=it.get('number')
    title=it.get('title','').strip()
    user=(it.get('user') or {}).get('login','unknown')
    url=it.get('html_url','')
    out.append(f"- [{title}]({url}) (#{num} by {user})")
print("\\n".join(out))
PY
)

if [ -z "$PR_LINES" ]; then
  # fallback: recent commits
  COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" HEAD~10..HEAD || echo "No commits")
  BODY_MD="**Deployed commit:** ${SHA}\n\n**Recent commits:**\n${COMMITS}"
else
  BODY_MD="**Deployed commit:** ${SHA}\n\n**Merged PRs since ${SINCE_DATE}:**\n${PR_LINES}"
fi

# Build a simple Adaptive Card (Microsoft Teams)
CARD=$(cat <<JSON
{
  "\$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
  "type": "AdaptiveCard",
  "version": "1.3",
  "body": [
    {
      "type": "TextBlock",
      "size": "Medium",
      "weight": "Bolder",
      "text": "DeployGuard — Release Notes",
      "wrap": true
    },
    {
      "type": "TextBlock",
      "text": "Repository: ${REPO}",
      "wrap": true,
      "spacing": "None"
    },
    {
      "type": "TextBlock",
      "text": "${SHA}",
      "wrap": true,
      "isSubtle": true,
      "spacing": "None"
    },
    {
      "type": "TextBlock",
      "text": "Changes:",
      "wrap": true,
      "separator": true
    },
    {
      "type": "TextBlock",
      "text": "$(echo "$BODY_MD" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')",
      "wrap": true,
      "spacing": "None"
    }
  ],
  "actions": [
    {
      "type": "Action.OpenUrl",
      "title": "View repository",
      "url": "https://github.com/${REPO}"
    }
  ]
}
JSON
)

if [ -n "$WEBHOOK" ]; then
  # Teams incoming webhooks expect content-type application/json
  curl -s -S -X POST -H "Content-Type: application/json" -d "$CARD" "$WEBHOOK" || true
  echo "Posted Adaptive Card to Teams."
else
  echo -e "---- Release Notes (preview) ----\n$BODY_MD\n-----------------------"
fi
