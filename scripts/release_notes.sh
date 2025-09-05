#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh
# Send clean, emoji-enhanced release notes to Microsoft Teams.
# - Hides full SHAs (does not print the long commit SHA)
# - Uses Adaptive Card with structured TextBlocks
# - Falls back to a readable text message when needed

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"   # owner/repo
SHA="${GITHUB_SHA:-}"           # kept for internal use if needed but not shown

if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set; exiting"
  exit 2
fi

OWNER=$(echo "$REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$REPO" | cut -d/ -f2)

echo "Release-notes runner: repo=${REPO}"
echo "Webhook present: ${WEBHOOK:+yes}${WEBHOOK:+ (hidden)}"

# Determine SINCE_DATE (use last tag date or 7 days ago)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG")
else
  if date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  else
    SINCE_DATE=$(date -u -v -7d +%Y-%m-%dT%H:%M:%SZ)
  fi
fi
echo "Collecting merged PRs since: $SINCE_DATE"

# Query merged PRs (limit to 8 items)
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "${GHTOKEN:-}" ]; then
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")
else
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" "$PR_API")
fi

# Build PR_ITEMS JSON with python3 (safe handling)
PR_ITEMS=$(echo "$PR_JSON" | python3 - <<'PY'
import sys, json
s = sys.stdin.read().strip()
if not s:
    print("[]")
    sys.exit(0)
try:
    j = json.loads(s)
except Exception:
    print("[]")
    sys.exit(0)
out = []
for it in j.get("items", [])[:8]:
    out.append({
        "num": it.get("number"),
        "title": (it.get("title") or "").strip(),
        "user": (it.get("user") or {}).get("login","unknown"),
        "url": it.get("html_url","")
    })
print(json.dumps(out))
PY
)

# Build a fallback plain-text body (HEREDOC ensures real newlines)
# We intentionally DO NOT include the full SHA in messages.
PR_TEXT_LINES=$(echo "$PR_ITEMS" | jq -r '.[] | "- " + (.title) + " (#"+(.num|tostring)+") by "+.user + (if .url then " — " + .url else "" end)' || true)

BODY_MD=$(cat <<EOF
🚀 Release: ${REPO}
🔒 Deployed commit: (hidden)

🧩 Merged PRs since ${SINCE_DATE}:
${PR_TEXT_LINES:-No merged PRs found in this window.}
EOF
)

# Preview truncated output
echo "Prepared release notes (preview):"
printf '%s\n' "$BODY_MD" | sed -n '1,40p'

# Build Adaptive Card using Python to avoid quoting issues.
# The card will NOT contain markdown; each PR is its own TextBlock for clean rendering.
export PR_ITEMS
CARD_JSON=$(python3 - "$REPO" "$SINCE_DATE" <<'PY'
import os, sys, json

repo = sys.argv[1]
since = sys.argv[2] or ""
prs_json = os.environ.get("PR_ITEMS", "[]")
try:
    prs = json.loads(prs_json)
except Exception:
    prs = []

def short(s, n=160):
    if not s:
        return ""
    s = s.strip().replace("\n"," ")
    return s if len(s) <= n else s[:n-3].rstrip() + "..."

body = []
# Header
body.append({"type":"TextBlock","size":"Large","weight":"Bolder","text":"🚀 DeployGuard — Release Notes","wrap":True})
body.append({"type":"TextBlock","text":f"📦 Repository: {repo}","wrap":True,"spacing":"Small"})
body.append({"type":"TextBlock","text":"🔒 Deployed commit: (hidden)","wrap":True,"isSubtle":True,"spacing":"Small"})
if since:
    body.append({"type":"TextBlock","text":f"📆 Merged since: {since}","wrap":True,"spacing":"Small","isSubtle":True})

# Changes section
if prs:
    body.append({"type":"TextBlock","text":"🧾 Changes:","weight":"Bolder","wrap":True,"separator":True,"spacing":"Medium"})
    for pr in prs:
        title = short(pr.get("title","(no title)"))
        num = pr.get("num","?")
        user = pr.get("user","unknown")
        url = pr.get("url","")
        # Single readable line, include the URL so it's clickable in Teams.
        if url:
            line = f"• {title} (#{num}) — {user} — {url}"
        else:
            line = f"• {title} (#{num}) — {user}"
        body.append({"type":"TextBlock","text": line,"wrap":True,"spacing":"Small"})
else:
    body.append({"type":"TextBlock","text":"No merged PRs in the selected window.","wrap":True,"spacing":"Small"})

# Action button to view the repo on GitHub
payload = {
    "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
    "type":"AdaptiveCard",
    "version":"1.3",
    "body": body,
    "actions":[
        {"type":"Action.OpenUrl","title":"🔗 View repository on GitHub","url": f"https://github.com/{repo}"}
    ]
}
print(json.dumps(payload))
PY
)

# prepare temp files
TMP_RESP=$(mktemp)
TMP_PLOAD=$(mktemp)
echo "$CARD_JSON" > "$TMP_PLOAD"

if [ -z "$WEBHOOK" ]; then
  echo "TEAMS_WEBHOOK not set — printing release notes to console:"
  echo "-----"
  printf '%s\n' "$BODY_MD"
  echo "-----"
  rm -f "$TMP_RESP" "$TMP_PLOAD"
  exit 0
fi

# Post Adaptive Card
HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
echo "Teams post attempt returned HTTP code: ${HTTP_CODE}"

# read response safely
BODY_TEXT=$(tr -d '\r' < "$TMP_RESP" | tr -s '\n' ' ' | sed 's/"/\\"/g' || true)
echo "Teams response (first 400 chars):"
head -c 400 "$TMP_RESP" || true
echo -e "\n--- full body ---"
cat "$TMP_RESP" || true
echo "------------------"

# If Teams rejects the card or returns non-200, send fallback text (plain text message)
NEED_FALLBACK=0
if [ "$HTTP_CODE" != "200" ]; then
  NEED_FALLBACK=1
fi
if echo "$BODY_TEXT" | grep -i -E 'summary or text|required|invalid|error' >/dev/null 2>&1; then
  NEED_FALLBACK=1
fi

if [ "$NEED_FALLBACK" -eq 1 ]; then
  echo "Adaptive Card rejected or non-200 response; sending fallback text message."

  # Use jq to create JSON "text" payload; $BODY_MD contains real newlines.
  FALLBACK_PAYLOAD=$(jq -n --arg t "🚀 Release: ${REPO} — (commit hidden)" --arg b "$BODY_MD" '{"text": ($t + "\n\n" + $b)}')
  echo "$FALLBACK_PAYLOAD" > "$TMP_PLOAD"
  HTTP_CODE2=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
  echo "Fallback post HTTP code: $HTTP_CODE2"
  echo "Fallback response body:"
  cat "$TMP_RESP" || true
fi

# cleanup
rm -f "$TMP_RESP" "$TMP_PLOAD"
echo "release_notes.sh finished."
