#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh
# Detailed, visually-appealing release notes for Teams, with short SHAs only.

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"   # owner/repo
SHA="${GITHUB_SHA:-}"           # full SHA (kept internal); will only display short form

# Config
PR_LIMIT=12
COMMIT_LIMIT=20

if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set; exiting"
  exit 2
fi

OWNER=$(echo "$REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$REPO" | cut -d/ -f2)

echo "Release-notes runner: repo=${REPO}"
echo "Webhook present: ${WEBHOOK:+yes}${WEBHOOK:+ (hidden)}"

# Determine since date (last tag date or 7 days)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG")
  COMPARE_URL="https://github.com/${REPO}/compare/${LAST_TAG}...HEAD"
else
  if date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  else
    SINCE_DATE=$(date -u -v -7d +%Y-%m-%dT%H:%M:%SZ)
  fi
  COMPARE_URL="https://github.com/${REPO}/commits"
fi

echo "Collecting merged PRs and commits since: $SINCE_DATE"

# Fetch merged PRs
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "${GHTOKEN:-}" ]; then
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")
else
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" "$PR_API")
fi

# Build PR_ITEMS JSON safely via python
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
for it in j.get("items", [])[:50]:
    out.append({
        "num": it.get("number"),
        "title": (it.get("title") or "").strip(),
        "user": (it.get("user") or {}).get("login","unknown"),
        "url": it.get("html_url",""),
        "merged_at": it.get("closed_at") or it.get("updated_at") or ""
    })
print(json.dumps(out))
PY
)

# Build commits JSON from local git since SINCE_DATE
# Use a delimiter-safe format then parse with python
GIT_RAW=$(git --no-pager log --no-merges --since="$SINCE_DATE" --pretty=format:'%H%x1f%h%x1f%an%x1f%cI%x1f%s%x1e' || true)
COMMITS_JSON=$(python3 - <<'PY'
import sys, json
data = sys.stdin.buffer.read()
if not data:
    print("[]"); sys.exit(0)
text = data.decode('utf-8', errors='replace')
items = []
for entry in text.split('\x1e'):
    if not entry.strip(): continue
    parts = entry.split('\x1f')
    if len(parts) < 5:
        continue
    full, short, author, date, msg = parts[:5]
    items.append({"sha": full, "short": short, "author": author, "date": date, "msg": msg})
print(json.dumps(items))
PY
<<<"$GIT_RAW"
)

# Trim to configured limits for display
PR_COUNT=$(echo "$PR_ITEMS" | jq 'length' || echo 0)
COMMIT_COUNT=$(echo "$COMMITS_JSON" | jq 'length' || echo 0)

PR_DISPLAY=$(echo "$PR_ITEMS" | jq ".[:${PR_LIMIT}]" )
COMMITS_DISPLAY=$(echo "$COMMITS_JSON" | jq ".[:${COMMIT_LIMIT}]" )

# Build fallback plain-text body (HEREDOC ensures real newlines)
FALLBACK_BODY=$(cat <<'EOF'
Release notes for: __REPO__
Deployed: __DEPLOY__
Since: __SINCE__

Merged PRs (showing __PR_SHOW__/__PR_COUNT__):
__PR_BLOCK__

Recent commits (showing __COM_SHOW__/__COM_COUNT__):
__COM_BLOCK__

View more: __COMPARE_URL__
EOF
)

# Build PR and commit text blocks for the fallback
PR_BLOCK=$(echo "$PR_DISPLAY" | jq -r '.[] | ("- 🔀 #" + (.num|tostring) + " — " + (.title) + " — by " + .user + (if .merged_at then " (" + .merged_at + ")" else "" end) + (if .url then " — " + .url else "" end))' || echo "No merged PRs")
COM_BLOCK=$(echo "$COMMITS_DISPLAY" | jq -r '.[] | ("- ⎇ " + (.short) + " — " + (.msg) + " — " + .author + " (" + .date + ") — " + ("https://github.com/'"$REPO"'/commit/" + .sha))' || echo "No recent commits")

# Fill the template
FALLBACK_BODY="${FALLBACK_BODY//__REPO__/$REPO}"
SHORT_SHA="$(printf '%.7s' "$SHA" 2>/dev/null || echo "(hidden)")"
FALLBACK_BODY="${FALLBACK_BODY//__DEPLOY__/$SHORT_SHA}"
FALLBACK_BODY="${FALLBACK_BODY//__SINCE__/$SINCE_DATE}"
FALLBACK_BODY="${FALLBACK_BODY//__PR_BLOCK__/$PR_BLOCK}"
FALLBACK_BODY="${FALLBACK_BODY//__PR_SHOW__/$PR_LIMIT}"
FALLBACK_BODY="${FALLBACK_BODY//__PR_COUNT__/$PR_COUNT}"
FALLBACK_BODY="${FALLBACK_BODY//__COM_BLOCK__/$COM_BLOCK}"
FALLBACK_BODY="${FALLBACK_BODY//__COM_SHOW__/$COMMIT_LIMIT}"
FALLBACK_BODY="${FALLBACK_BODY//__COM_COUNT__/$COMMIT_COUNT}"
FALLBACK_BODY="${FALLBACK_BODY//__COMPARE_URL__/$COMPARE_URL}"

# Preview fallback (first 300 chars)
echo "Fallback preview:"
printf '%s\n' "$FALLBACK_BODY" | sed -n '1,60p'

# Build Adaptive Card using Python to avoid quoting issues.
# Export the JSON blobs so python can read them from env.
export PR_DISPLAY
export COMMITS_DISPLAY
export REPO
export SINCE_DATE
export COMPARE_URL
export SHORT_SHA

CARD_JSON=$(python3 - "$REPO" "$SINCE_DATE" <<'PY'
import os, json, sys

repo = sys.argv[1]
since = sys.argv[2] or ""
compare = os.environ.get("COMPARE_URL","")
short_sha = os.environ.get("SHORT_SHA","(hidden)")

prs = json.loads(os.environ.get("PR_DISPLAY","[]") or "[]")
commits = json.loads(os.environ.get("COMMITS_DISPLAY","[]") or "[]")

def short(s, n=160):
    if not s:
        return ""
    s = s.replace("\n"," ").strip()
    return s if len(s) <= n else s[:n-3].rstrip() + "..."

body = []
body.append({"type":"TextBlock","size":"Large","weight":"Bolder","text":"🚀 Release Notes","wrap":True})
body.append({"type":"TextBlock","text":f"📦 Repository: {repo}","wrap":True,"spacing":"Small"})
body.append({"type":"TextBlock","text":f"🔒 Deployed commit: {short_sha} (full SHA hidden)","wrap":True,"isSubtle":True,"spacing":"Small"})
if since:
    body.append({"type":"TextBlock","text":f"📆 Since: {since}","wrap":True,"spacing":"Small","isSubtle":True})

# Summary row with counts
summary = f"🧾 Merged PRs: {len(prs)}"
summary += f" • ⎇ Commits: {len(commits)}"
body.append({"type":"TextBlock","text":summary,"wrap":True,"spacing":"Small","isSubtle":True, "separator": True})

# PR list (showing up to PR_LIMIT items)
if prs:
    body.append({"type":"TextBlock","text":"🔀 Merged pull requests:","weight":"Bolder","wrap":True,"spacing":"Medium"})
    for pr in prs:
        title = short(pr.get("title","(no title)"), 220)
        num = pr.get("num","?")
        user = pr.get("user","unknown")
        url = pr.get("url","")
        line = f"• #{num}  {title}  — by {user}"
        if url:
            line += f" — {url}"
        body.append({"type":"TextBlock","text":line,"wrap":True,"spacing":"Small"})

# Commits list
if commits:
    body.append({"type":"TextBlock","text":"⎇ Recent commits:","weight":"Bolder","wrap":True,"spacing":"Medium"})
    for c in commits:
        shortc = c.get("short", "")[:7]
        msg = short(c.get("msg",""), 200)
        author = c.get("author","")
        date = c.get("date","")
        sha_full = c.get("sha","")
        commit_url = f"https://github.com/{repo}/commit/{sha_full}"
        line = f"• {shortc}  {msg} — {author} ({date}) — {commit_url}"
        body.append({"type":"TextBlock","text":line,"wrap":True,"spacing":"Small"})

# If no content
if not prs and not commits:
    body.append({"type":"TextBlock","text":"No merged pull requests or recent commits found in this window.","wrap":True,"spacing":"Small"})

payload = {
    "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
    "type":"AdaptiveCard",
    "version":"1.3",
    "body": body,
    "actions":[
        {"type":"Action.OpenUrl","title":"🔗 View repository","url": f"https://github.com/{repo}"},
        {"type":"Action.OpenUrl","title":"🔎 View changes on GitHub","url": compare}
    ]
}
print(json.dumps(payload))
PY
)

# Post to Teams (Adaptive Card)
TMP_RESP=$(mktemp)
TMP_PLOAD=$(mktemp)
echo "$CARD_JSON" > "$TMP_PLOAD"

if [ -z "$WEBHOOK" ]; then
  echo "TEAMS_WEBHOOK not set — printing fallback body to console:"
  echo "-----"
  printf '%s\n' "$FALLBACK_BODY"
  echo "-----"
  rm -f "$TMP_RESP" "$TMP_PLOAD"
  exit 0
fi

HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
echo "Adaptive card POST HTTP code: $HTTP_CODE"
echo "Teams response preview:"
head -c 400 "$TMP_RESP" || true
echo

BODY_TEXT=$(tr -d '\r' < "$TMP_RESP" | tr -s '\n' ' ' | sed 's/"/\\"/g' || true)

NEED_FALLBACK=0
if [ "$HTTP_CODE" != "200" ]; then NEED_FALLBACK=1; fi
if echo "$BODY_TEXT" | grep -i -E 'summary or text|required|invalid|error' >/dev/null 2>&1; then NEED_FALLBACK=1; fi

if [ "$NEED_FALLBACK" -eq 1 ]; then
  echo "Adaptive Card rejected or non-200 response; sending fallback text message."
  FALLBACK_PAYLOAD=$(jq -n --arg t "🚀 Release: ${REPO} — deployed (short SHA: ${SHORT_SHA})" --arg b "$FALLBACK_BODY" '{"text": ($t + "\n\n" + $b)}')
  echo "$FALLBACK_PAYLOAD" > "$TMP_PLOAD"
  HTTP_CODE2=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
  echo "Fallback POST HTTP code: $HTTP_CODE2"
  echo "Fallback response preview:"
  head -c 400 "$TMP_RESP" || true
  echo
fi

rm -f "$TMP_RESP" "$TMP_PLOAD"
echo "release_notes.sh finished."
