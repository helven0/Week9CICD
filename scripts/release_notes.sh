#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh — fixed: no printf->head broken-pipe
# - posts an Adaptive Card to Teams (fallback to text)
# - safe preview in CI (no EPIPE failures)
# - minimal external deps: curl, jq, python3, git

export LANG=C
export LC_ALL=C

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"   # owner/repo
SHA="${GITHUB_SHA:-}"           # full SHA (kept internal; we display short)

# Display limits
PR_LIMIT=5
COMMIT_LIMIT=5

if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set; exiting"
  exit 2
fi

# sanitize helper using awk (avoids piping printf -> tr which may in some environments raise EPIPE)
sanitize() {
  awk -v s="$1" 'BEGIN {
    gsub(/\xEF\xBF\xBD/,"",s);          # drop replacement char if present
    gsub(/Ø|ø|𝟘/,"0",s);               # normalize odd zeros
    # remove non-printables except newline
    out = "";
    for (i=1;i<=length(s);i++) {
      c = substr(s,i,1);
      if (c ~ /[[:print:]]/ || c == "\n") out = out c
    }
    # squeeze spaces
    gsub(/  +/," ",out);
    print out;
  }'
}

# sanitize repo
REPO="$(sanitize "$REPO")"
OWNER=$(printf '%s\n' "$REPO" | cut -d/ -f1)
REPO_NAME=$(printf '%s\n' "$REPO" | cut -d/ -f2)

# Determine SINCE_DATE (last tag or 7 days ago)
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$LAST_TAG" ]; then
  SINCE_DATE=$(git log -1 --format=%cI "$LAST_TAG" 2>/dev/null || true)
  COMPARE_URL="https://github.com/${REPO}/compare/${LAST_TAG}...HEAD"
else
  if date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    SINCE_DATE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)
  else
    # macOS/BSD date fallback
    SINCE_DATE=$(date -u -v -7d +%Y-%m-%dT%H:%M:%SZ)
  fi
  COMPARE_URL="https://github.com/${REPO}/commits"
fi

# sanitize SINCE_DATE: keep digits, T, :, -, +, Z
SINCE_DATE=$(printf '%s' "$SINCE_DATE" | awk '{ gsub(/[^0-9T:+\-Z]/,""); print }')

SHORT_SHA="${SHA:-}"
if [ -z "$SHORT_SHA" ]; then
  SHORT_SHA="(hidden)"
else
  SHORT_SHA="${SHORT_SHA:0:7}"
fi

echo "Collecting merged PRs and commits since: $SINCE_DATE"
echo "Repository: $REPO  (owner=${OWNER}, repo=${REPO_NAME})"

# --- Fetch merged PRs from GitHub API ---
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "${GHTOKEN:-}" ]; then
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API")
else
  PR_JSON=$(curl -sS -H "Accept: application/vnd.github+json" "$PR_API")
fi

# Parse PR items with python3 (robust)
PR_ITEMS=$(python3 - <<'PY' "$(printf '%s' "$PR_JSON")"
import sys, json
s = sys.argv[1]
try:
    j = json.loads(s) if s.strip() else {}
except Exception:
    print("[]"); sys.exit(0)
out = []
for it in j.get("items", [])[:50]:
    out.append({
        "num": it.get("number"),
        "title": (it.get("title") or "").strip(),
        "user": (it.get("user") or {}).get("login","unknown"),
        "url": it.get("html_url",""),
        "merged_at": it.get("closed_at","")
    })
print(json.dumps(out))
PY
)

# --- Get commits since SINCE_DATE via git, parse with python3 ---
GIT_RAW=$(git --no-pager log --no-merges --since="$SINCE_DATE" --pretty=format:'%H%x1f%h%x1f%an%x1f%cI%x1f%s%x1e' 2>/dev/null || true)

COMMITS_JSON=$(python3 - <<'PY' "$GIT_RAW"
import sys, json
txt = sys.argv[1] if len(sys.argv) > 1 else ""
if not txt:
    print("[]"); sys.exit(0)
out=[]
for entry in txt.split('\x1e'):
    if not entry.strip():
        continue
    parts = entry.split('\x1f')
    if len(parts) < 5:
        continue
    full, short, author, date, msg = parts[:5]
    out.append({"sha": full, "short": short, "author": author, "date": date, "msg": msg})
print(json.dumps(out))
PY
)

# counts
PR_COUNT=$(printf '%s' "$PR_ITEMS" | jq 'length' 2>/dev/null || echo 0)
COMMIT_COUNT=$(printf '%s' "$COMMITS_JSON" | jq 'length' 2>/dev/null || echo 0)

PR_DISPLAY=$(printf '%s' "$PR_ITEMS" | jq ".[:${PR_LIMIT}]")
COMMITS_DISPLAY=$(printf '%s' "$COMMITS_JSON" | jq ".[:${COMMIT_LIMIT}]")

# Build fallback text blocks
PR_BLOCK=$(printf '%s' "$PR_DISPLAY" | jq -r '.[] | "- 🔀 #' + (.num|tostring) + " — " + (.title) + " — by " + .user + (if .merged_at then " (" + .merged_at + ")" else "" end) + (if .url then " — " + .url else "" end)' 2>/dev/null || echo "No merged PRs")
COM_BLOCK=$(printf '%s' "$COMMITS_DISPLAY" | jq -r '.[] | "- ⎇ " + (.short) + " — " + (.msg) + " — " + .author + " (" + .date + ") — " + ("https://github.com/'"$REPO"'/commit/" + .sha)' 2>/dev/null || echo "No recent commits")

FALLBACK_BODY=$(cat <<EOF
🚀 Release: ${REPO}
🔒 Deployed: ${SHORT_SHA} (full SHA hidden)
📆 Since: ${SINCE_DATE}

🧾 Merged PRs (showing ${PR_LIMIT}/${PR_COUNT}):
${PR_BLOCK}

⎇ Recent commits (showing ${COMMIT_LIMIT}/${COMMIT_COUNT}):
${COM_BLOCK}

🔗 View more: ${COMPARE_URL}
EOF
)

# ---------- SAFE PREVIEW ----------
# Use here-string into head (no separate writer process that can get SIGPIPE)
# Also temporarily disable pipefail to be extra-safe and avoid script failure if head exits early.
set +o pipefail
head -n 80 <<< "$FALLBACK_BODY" || true
set -o pipefail

# Build Adaptive Card payload with python3 (structured TextBlocks)
export PR_DISPLAY
export COMMITS_DISPLAY
export REPO
export SHORT_SHA
export SINCE_DATE
export COMPARE_URL

CARD_JSON=$(python3 - "$REPO" "$SHORT_SHA" "$SINCE_DATE" <<'PY'
import os, sys, json
repo = sys.argv[1]
short_sha = sys.argv[2] or "(hidden)"
since = sys.argv[3] or ""
compare = os.environ.get("COMPARE_URL","")

prs = json.loads(os.environ.get("PR_DISPLAY","[]") or "[]")
commits = json.loads(os.environ.get("COMMITS_DISPLAY","[]") or "[]")

def shorttxt(s, n=180):
    if not s: return ""
    s = s.replace("\n"," ").strip()
    return s if len(s) <= n else s[:n-3].rstrip() + "..."

body = []
body.append({"type":"TextBlock","size":"Large","weight":"Bolder","text":"🚀 Release Notes","wrap":True})
body.append({"type":"TextBlock","text":f"📦 Repository: {repo}","wrap":True,"spacing":"Small"})
body.append({"type":"TextBlock","text":f"🔒 Deployed: {short_sha} (full SHA hidden)","wrap":True,"isSubtle":True,"spacing":"Small"})
if since:
    body.append({"type":"TextBlock","text":f"📆 Since: {since}","wrap":True,"spacing":"Small","isSubtle":True})

summary = f"🧾 PRs: {len(prs)}  •  ⎇ Commits: {len(commits)}"
body.append({"type":"TextBlock","text":summary,"wrap":True,"spacing":"Small","isSubtle":True, "separator":True})

if prs:
    body.append({"type":"TextBlock","text":"🔀 Merged pull requests:","weight":"Bolder","wrap":True,"spacing":"Medium"})
    for pr in prs:
        title = shorttxt(pr.get("title","(no title)"), 220)
        num = pr.get("num","?")
        user = pr.get("user","unknown")
        url = pr.get("url","")
        line = f"• #{num}  {title}  — by {user}"
        if url:
            line += f" — {url}"
        body.append({"type":"TextBlock","text":line,"wrap":True,"spacing":"Small"})

if commits:
    body.append({"type":"TextBlock","text":"⎇ Recent commits:","weight":"Bolder","wrap":True,"spacing":"Medium"})
    for c in commits:
        shortc = c.get("short","")[:7]
        msg = shorttxt(c.get("msg",""), 200)
        author = c.get("author","")
        date = c.get("date","")
        sha_full = c.get("sha","")
        commit_url = f"https://github.com/{repo}/commit/{sha_full}"
        line = f"• {shortc}  {msg} — {author} ({date}) — {commit_url}"
        body.append({"type":"TextBlock","text":line,"wrap":True,"spacing":"Small"})

if not prs and not commits:
    body.append({"type":"TextBlock","text":"No merged pull requests or recent commits found in this window.","wrap":True,"spacing":"Small"})

payload = {
    "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
    "type":"AdaptiveCard",
    "version":"1.3",
    "body": body,
    "actions": [
        {"type":"Action.OpenUrl","title":"🔗 View repository","url": f"https://github.com/{repo}"},
        {"type":"Action.OpenUrl","title":"🔎 View changes on GitHub","url": compare}
    ]
}
print(json.dumps(payload))
PY
)

# Post Adaptive Card
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

BODY_TEXT=$(tr -d '\r' < "$TMP_RESP" | tr -s '\n' ' ' || true)

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
