#!/usr/bin/env bash
set -euo pipefail

# Environment inputs (provided from GitHub Actions)
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

echo "Release-notes runner: repo=${REPO} sha=${SHA}"
echo "Using webhook: ${WEBHOOK:+(present)} ${WEBHOOK:0:8}${WEBHOOK:+...}"

# Prepare SINCE_DATE (last tag date or 7 days ago)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG")
else
  SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
fi
echo "Collecting merged PRs since: $SINCE_DATE"

# Pull merged PRs (use token if present)
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "$GHTOKEN" ]; then
  PR_JSON=$(curl -s -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")
else
  PR_JSON=$(curl -s -H "Accept: application/vnd.github+json" "$PR_API")
fi

# Build a short list of PRs (max 8)
PR_ITEMS=$(echo "$PR_JSON" | python3 - <<'PY'
import sys,json
s=sys.stdin.read().strip()
if not s:
    print("[]"); sys.exit(0)
j=json.loads(s)
out=[]
for it in j.get("items",[])[:8]:
    out.append({"num": it.get("number"), "title": it.get("title","").strip(), "user": (it.get("user") or {}).get("login","unknown"), "url": it.get("html_url","")})
print(json.dumps(out))
PY
)

# Compose a summary markdown (safe)
if [ "$(echo "$PR_ITEMS" | jq 'length')" -gt 0 ]; then
  BODY_MD="**Deployed commit:** ${SHA}\n\n**Merged PRs since ${SINCE_DATE}:**\n"
  BODY_MD="$BODY_MD$(echo "$PR_ITEMS" | jq -r '.[] | "- [" + .title + "](" + .url + ") (#"+(.num|tostring)+" by "+.user+")" + "\n"')"
else
  COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" HEAD~10..HEAD || echo "No commits")
  BODY_MD="**Deployed commit:** ${SHA}\n\n**Recent commits:**\n${COMMITS}"
fi

echo "Prepared body (first 400 chars):"
echo "${BODY_MD}" | sed -n '1,20p'

# Build an Adaptive Card using jq (avoids quoting hell)
CARD=$(jq -n \
  --arg title "DeployGuard — Release Notes" \
  --arg repo "$REPO" \
  --arg sha "$SHA" \
  --arg body "$BODY_MD" \
  '{
    "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
    "type": "AdaptiveCard",
    "version": "1.3",
    "body": [
      {"type":"TextBlock","size":"Medium","weight":"Bolder","text":$title},
      {"type":"TextBlock","text":("Repository: " + $repo), "wrap":true, "spacing":"None"},
      {"type":"TextBlock","text":$sha, "wrap":true, "isSubtle":true, "spacing":"None"},
      {"type":"TextBlock","text":"Changes:","wrap":true, "separator":true},
      {"type":"TextBlock","text":$body, "wrap":true}
    ],
    "actions":[{"type":"Action.OpenUrl","title":"View repository","url":("https://github.com/" + $repo)}]
  }'
)

# Helper to post and show response
post_to_teams() {
  local payload="$1"
  echo "Posting to Teams webhook..."
  http_code=$(curl -s -S -o /tmp/teams_resp.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK" || echo "000")
  echo "Teams response HTTP code: $http_code"
  echo "Response body:"
  sed -n '1,200p' /tmp/teams_resp.txt || true
  return 0
}

if [ -z "$WEBHOOK" ]; then
  echo "TEAMS_WEBHOOK not set. Will print release notes to stdout instead."
  echo -e "$BODY_MD"
  exit 0
fi

# Try Adaptive Card first
post_to_teams "$CARD"

# If Teams returned non-200, attempt fallback simple message
HTTP=$(cat /tmp/teams_resp.txt; true)  # just to ensure file exists
# re-check numeric code
code=$(curl -s -S -o /tmp/teams_resp.txt -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$CARD" "$WEBHOOK" || echo "000")
if [ "$code" != "200" ]; then
  echo "Adaptive Card post returned $code — attempting fallback simple text post."
  FALLBACK=$(jq -n --arg t "Release: ${REPO}" --arg b "$BODY_MD" '{"text': ($t + "\n\n" + $b)}')
  post_to_teams "$FALLBACK"
fi

echo "release_notes.sh completed."
