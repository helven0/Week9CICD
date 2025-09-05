#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh
# Structured release notes to Teams via Adaptive Card (no literal \n or markdown inside card),
# with fallback to text message.

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
  # fallback to 7 days ago in UTC (supports GNU and BSD/macOS)
  if date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  else
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

# Build JSON array of PR items (num, title, user, url) using python3
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
  # Compose a plain-text fallback body (kept for the text fallback)
  MD_LINES=$(echo "$PR_ITEMS" | jq -r '.[] | "- " + (.title) + " (#"+(.num|tostring)+" by "+.user+")"')
  BODY_MD="**Deployed commit:** ${SHA:-N/A}\n\n**Merged PRs since ${SINCE_DATE}:**\n${MD_LINES}"
else
  COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" HEAD~10..HEAD || echo "No commits")
  BODY_MD="**Deployed commit:** ${SHA:-N/A}\n\n**Recent commits:**\n${COMMITS}"
fi

echo "Prepared release notes (truncated):"
printf '%s\n' "$BODY_MD" | sed -n '1,20p'

# ---------------------------
# Build Adaptive Card with Python (structured TextBlocks; no markdown)
# ---------------------------
# Export PR_ITEMS so the python subprocess can read it safely
export PR_ITEMS

CARD_JSON=$(python3 - "$REPO" "$SHA" "$SINCE_DATE" <<'PY'
import os, sys, json

repo = sys.argv[1]
sha = sys.argv[2] or "N/A"
since = sys.argv[3] or ""
prs_json = os.environ.get("PR_ITEMS", "[]")
try:
    prs = json.loads(prs_json)
except Exception:
    prs = []

def short(s, n=180):
    if not s:
        return ""
    s = s.strip()
    if len(s) <= n:
        return s
    return s[: n-3].rstrip() + "..."

body = []
# Header
body.append({"type":"TextBlock","size":"Large","weight":"Bolder","text":"DeployGuard — Release Notes","wrap":True})
body.append({"type":"TextBlock","text":f"Repository: {repo}","wrap":True,"spacing":"Small"})
body.append({"type":"TextBlock","text":f"Deployed commit: {sha}","wrap":True,"isSubtle":True,"spacing":"Small"})
if since:
    body.append({"type":"TextBlock","text":f"Merged PRs since: {since}","wrap":True,"spacing":"Small","isSubtle":True})

# If we have PRs, add each as its own TextBlock for clean rendering.
if prs:
    # small separator
    body.append({"type":"TextBlock","text":"Changes:","weight":"Bolder","wrap":True,"separator":True,"spacing":"Medium"})
    for pr in prs:
        title = short(pr.get("title","(no title)"))
        num = pr.get("num","?")
        user = pr.get("user","unknown")
        url = pr.get("url","")
        # Construct a single-line human-friendly text. Avoid markdown. Include URL so it is clickable in Teams.
        if url:
            line = f"• {title} (#{num}) by {user} — {url}"
        else:
            line = f"• {title} (#{num}) by {user}"
        body.append({"type":"TextBlock","text": line,"wrap":True,"spacing":"Small"})
else:
    # No PRs: include recent commits as separate blocks (trimmed)
    body.append({"type":"TextBlock","text":"Recent commits:","weight":"Bolder","wrap":True,"separator":True,"spacing":"Medium"})
    # read fallback commits from environment variable if you want; for now display a hint
    body.append({"type":"TextBlock","text":"No merged PRs in the selected window. See fallback text message for recent commits.","wrap":True,"spacing":"Small"})

payload = {
    "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
    "type":"AdaptiveCard",
    "version":"1.3",
    "body": body,
    "actions":[
        {"type":"Action.OpenUrl","title":"View repository","url": f"https://github.com/{repo}"}
    ]
}

print(json.dumps(payload))
PY
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
