#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh
# Outputs structured release notes to Teams via Adaptive Card, with fallback to text message.
# Env vars used:
#   TEAMS_WEBHOOK  - Teams incoming webhook URL (required to post)
#   GITHUB_TOKEN   - optional GitHub token to increase API rate limits
#   GITHUB_REPOSITORY - owner/repo (if running outside GH actions)
#   GITHUB_SHA     - deployed commit SHA (optional)

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
echo "Webhook present: ${WEBHOOK:+yes}${WEBHOOK:+ (hidden)}"

# Choose SINCE_DATE (last tag or 7d)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG")
else
  # fallback to 7 days ago in UTC
  if date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  else
    # portable BSD date fallback (macOS)
    SINCE_DATE=$(date -u -v -7d +%Y-%m-%dT%H:%M:%SZ)
  fi
fi
echo "Collecting merged PRs since: $SINCE_DATE"

# Query merged PRs (limit to 12 items)
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "${GHTOKEN:-}" ]; then
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")
else
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" "$PR_API")
fi

# Build JSON array of PR items (num, title, user, url) using python3 for robust parsing
PR_ITEMS=$(echo "$PR_JSON" | python3 - <<'PY'
import sys, json
s=sys.stdin.read().strip()
if not s:
    print("[]")
    sys.exit(0)
try:
    j=json.loads(s)
except Exception:
    print("[]")
    sys.exit(0)
out=[]
for it in j.get("items",[])[:12]:
    out.append({
        "num": it.get("number"),
        "title": (it.get("title") or "").strip(),
        "user": (it.get("user") or {}).get("login","unknown"),
        "url": it.get("html_url","")
    })
print(json.dumps(out))
PY
)

# If PR_ITEMS present -> build structured body; else fallback to recent commits text
if [ "$(echo "$PR_ITEMS" | jq 'length')" -gt 0 ]; then
  # Build a Markdown-ish body for fallback and log (keeps old behavior)
  MD_LINES=$(echo "$PR_ITEMS" | jq -r '.[] | "- [" + (.title) + "](" + .url + ") (#"+(.num|tostring)+" by "+.user+")"')
  BODY_MD="**Deployed commit:** ${SHA:-N/A}\n\n**Merged PRs since ${SINCE_DATE}:**\n${MD_LINES}"
else
  COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" HEAD~10..HEAD || echo "No commits")
  BODY_MD="**Deployed commit:** ${SHA:-N/A}\n\n**Recent commits:**\n${COMMITS}"
fi

echo "Prepared release notes (truncated):"
printf '%s\n' "$BODY_MD" | sed -n '1,20p'

# Build an Adaptive Card that places each PR as its own TextBlock (renders clearer in Teams)
# We pass the PR items into jq as JSON and map them to TextBlock items.
CARD_JSON=$(jq -n \
  --arg title "🚀 DeployGuard — Release Notes" \
  --arg repo "$REPO" \
  --arg sha "${SHA:-N/A}" \
  --arg commiturl "https://github.com/$REPO/commit/${SHA:-}" \
  --argjson prs "$PR_ITEMS" \
  '{
    "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
    "type":"AdaptiveCard",
    "version":"1.3",
    "body": (
      [
        {"type":"TextBlock","size":"Large","weight":"Bolder","text":$title,"wrap":true},
        {"type":"TextBlock","text":("📂 Repository: " + $repo),"wrap":true,"spacing":"Small"},
        {"type":"TextBlock","text":("🔖 Commit: [" + ($sha|if .=="" then "N/A" else . end) + "](" + $commiturl + ")"),"wrap":true,"isSubtle":true,"spacing":"Small"},
        {"type":"TextBlock","text":"📌 Changes:","weight":"Bolder","wrap":true,"separator":true,"spacing":"Medium"}
      ]
    ) + ($prs | if (length>0) then map({type:"TextBlock", text:( ("• " + (.title) + " (" + (.num|tostring) + ") by " + .user + " — " + .url) ), wrap:true, spacing:"Small"}) else [] end)
  ,
    "actions":[
      {"type":"Action.OpenUrl","title":"🔗 View repository","url":("https://github.com/" + $repo)}
    ]
  }'
)

# prepare temp files
TMP_RESP="$(mktemp)"
TMP_PLOAD="$(mktemp)"

echo "$CARD_JSON" > "$TMP_PLOAD"

if [ -z "$WEBHOOK" ]; then
  echo "TEAMS_WEBHOOK not set — printing release notes to console:"
  echo "-----"
  printf '%s\n' "$BODY_MD"
  echo "-----"
  rm -f "$TMP_RESP" "$TMP_PLOAD"
  exit 0
fi

# post the Adaptive Card and capture response code and body
HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
echo "Teams post attempt returned HTTP code: ${HTTP_CODE}"
echo "Teams response body (first 400 chars):"
head -c 400 "$TMP_RESP" || true
echo -e "\n--- full body ---"
cat "$TMP_RESP" || true
echo "------------------"

# Determine if fallback is needed (non-200 or Teams complains about card)
BODY_TEXT=$(tr -d '\r' < "$TMP_RESP" | tr -s '\n' ' ' | sed 's/"/\\"/g')
NEED_FALLBACK=0
if [ "$HTTP_CODE" != "200" ]; then
  NEED_FALLBACK=1
fi
if echo "$BODY_TEXT" | grep -i -E 'summary or text|required|invalid|error|card' >/dev/null 2>&1; then
  NEED_FALLBACK=1
fi

if [ "$NEED_FALLBACK" -eq 1 ]; then
  echo "Adaptive Card rejected or non-200 response; sending simple fallback text message."
  # Keep the fallback compact: title + list (Body MD)
  FALLBACK_PAYLOAD=$(jq -n --arg t "Release: ${REPO} - ${SHA:-N/A}" --arg b "$BODY_MD" '{"text": ($t + "\n\n" + $b)}')
  echo "$FALLBACK_PAYLOAD" > "$TMP_PLOAD"
  HTTP_CODE2=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
  echo "Fallback post HTTP code: $HTTP_CODE2"
  echo "Fallback response body:"
  cat "$TMP_RESP" || true
fi

# cleanup
rm -f "$TMP_RESP" "$TMP_PLOAD"
echo "release_notes.sh finished."
