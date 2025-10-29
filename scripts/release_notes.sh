#!/usr/bin/env bash
set -euo pipefail

# release_notes.sh — robust version that avoids broken-pipe by using temp files
# Requirements: bash, git, curl, jq, python3

export LANG=C
export LC_ALL=C

WEBHOOK="${TEAMS_WEBHOOK:-}"
GHTOKEN="${GITHUB_TOKEN:-}"
REPO="${GITHUB_REPOSITORY:-}"   # owner/repo
SHA="${GITHUB_SHA:-}"           # full SHA (optional)

# Display limits
PR_LIMIT=5
COMMIT_LIMIT=5

if [ -z "$REPO" ]; then
  echo "GITHUB_REPOSITORY not set; exiting"
  exit 2
fi

# sanitize helper
sanitize() {
  # normalize odd zero-like characters and remove non-printables
  local inp="$1"
  printf '%s' "$inp" \
    | tr 'Øø𝟘' '000' \
    | tr -cd '[:print:]\n' \
    | tr -s ' '
}

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
    # macOS/BSD fallback
    SINCE_DATE=$(date -u -v -7d +%Y-%m-%dT%H:%M:%SZ)
  fi
  COMPARE_URL="https://github.com/${REPO}/commits"
fi

# sanitize SINCE_DATE
SINCE_DATE=$(printf '%s' "$SINCE_DATE" | tr 'Øø𝟘' '000' | awk '{ gsub(/[^0-9T:+\-Z]/,""); print }')

SHORT_SHA="${SHA:-}"
if [ -z "$SHORT_SHA" ]; then
  SHORT_SHA="(hidden)"
else
  SHORT_SHA="${SHORT_SHA:0:7}"
fi

echo "Collecting merged PRs and commits since: $SINCE_DATE"
echo "Repository: $REPO  (owner=${OWNER}, repo=${REPO_NAME})"

# Create temp files
TMP_PR_JSON="$(mktemp)"
TMP_PR_ITEMS="$(mktemp)"
TMP_GIT_RAW="$(mktemp)"
TMP_COMMITS_JSON="$(mktemp)"
TMP_PR_DISPLAY="$(mktemp)"
TMP_COMMITS_DISPLAY="$(mktemp)"
TMP_PREVIEW="$(mktemp)"
TMP_CARD="$(mktemp)"
TMP_RESP="$(mktemp)"
TMP_PLOAD="$(mktemp)"

trap 'rm -f "$TMP_PR_JSON" "$TMP_PR_ITEMS" "$TMP_GIT_RAW" "$TMP_COMMITS_JSON" "$TMP_PR_DISPLAY" "$TMP_COMMITS_DISPLAY" "$TMP_PREVIEW" "$TMP_CARD" "$TMP_RESP" "$TMP_PLOAD"' EXIT

# --- Fetch merged PRs from GitHub API into a file (no pipe) ---
PR_API="https://api.github.com/search/issues?q=repo:${OWNER}/${REPO_NAME}+is:pr+is:merged+merged:>${SINCE_DATE}&per_page=50"
if [ -n "${GHTOKEN:-}" ]; then
  curl -sS -H "Accept: application/vnd.github+json" -H "Authorization: token ${GHTOKEN}" "$PR_API" -o "$TMP_PR_JSON"
else
  curl -sS -H "Accept: application/vnd.github+json" "$PR_API" -o "$TMP_PR_JSON"
fi

# Parse PR JSON to compact PR_ITEMS using python3 (file input)
python3 - "$TMP_PR_JSON" > "$TMP_PR_ITEMS" <<'PY'
import sys, json
p = sys.argv[1]
try:
    s = open(p, 'r', encoding='utf-8').read()
    j = json.loads(s) if s.strip() else {}
except Exception:
    print("[]"); sys.exit(0)
out=[]
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

# --- Get commits via git into a temp file (no pipe) ---
git --no-pager log --no-merges --since="$SINCE_DATE" --pretty=format:'%H%x1f%h%x1f%an%x1f%cI%x1f%s%x1e' > "$TMP_GIT_RAW" 2>/dev/null || true

# Parse commits with python, reading file
python3 - "$TMP_GIT_RAW" > "$TMP_COMMITS_JSON" <<'PY'
import sys, json
p = sys.argv[1]
try:
    txt = open(p,'r',encoding='utf-8',errors='replace').read()
except Exception:
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

# counts and trimmed displays (use jq reading from files)
PR_COUNT=$(jq 'length' "$TMP_PR_ITEMS" 2>/dev/null || echo 0)
COMMIT_COUNT=$(jq 'length' "$TMP_COMMITS_JSON" 2>/dev/null || echo 0)

# Build displays limited by PR_LIMIT and COMMIT_LIMIT into files
jq ".[0:${PR_LIMIT}]" "$TMP_PR_ITEMS" > "$TMP_PR_DISPLAY" 2>/dev/null || printf '[]' > "$TMP_PR_DISPLAY"
jq ".[0:${COMMIT_LIMIT}]" "$TMP_COMMITS_JSON" > "$TMP_COMMITS_DISPLAY" 2>/dev/null || printf '[]' > "$TMP_COMMITS_DISPLAY"

# Build fallback text blocks safely using jq reading the temp display files
jq -r '.[] | "- 🔀 #"+(.num|tostring)+" — "+(.title)+" — by "+.user + (if .merged_at then " (" + .merged_at + ")" else "" end) + (if .url then " — " + .url else "" end)' "$TMP_PR_DISPLAY" > "${TMP_PREVIEW}.prblock" 2>/dev/null || printf 'No merged PRs\n' > "${TMP_PREVIEW}.prblock"
jq -r '.[] | "- ⎇ "+(.short)+" — "+(.msg)+" — "+.author+" ("+.date+") — https://github.com/'"$REPO"'/commit/"+.sha' "$TMP_COMMITS_DISPLAY" > "${TMP_PREVIEW}.comblock" 2>/dev/null || printf 'No recent commits\n' > "${TMP_PREVIEW}.comblock"

PR_BLOCK=$(cat "${TMP_PREVIEW}.prblock")
COM_BLOCK=$(cat "${TMP_PREVIEW}.comblock")

# Compose FALLBACK_BODY into a file (no pipes)
cat > "$TMP_PREVIEW" <<EOF
🚀 Release: ${REPO}
🔒 Deployed: ${SHORT_SHA} (full SHA hidden)
📆 Since: ${SINCE_DATE}

🧾 Merged PRs (showing ${PR_LIMIT}/${PR_COUNT}):
${PR_BLOCK}

⎇ Recent commits (showing ${COMMIT_LIMIT}/${COMMIT_COUNT}):
${COM_BLOCK}

🔗 View more: ${COMPARE_URL}
EOF

# SAFE PREVIEW: use sed to print first 80 lines (reads file; no writer->reader pipe)
sed -n '1,80p' "$TMP_PREVIEW" || true

# Build Adaptive Card JSON using python reading display files
python3 - "$REPO" "$SHORT_SHA" "$TMP_PR_DISPLAY" "$TMP_COMMITS_DISPLAY" > "$TMP_CARD" <<'PY'
import sys
import json
import os


def generate_adaptive_card(repo, short_sha, prs, commits):
    """Generates an Adaptive Card for a release."""

    def short_txt(s, n=180):
        if not s:
            return ""
        s = s.replace("\n", " ").strip()
        return s if len(s) <= n else s[:n - 3].rstrip() + "..."

    pr_section = []
    if prs:
        pr_section.append({
            "type": "TextBlock",
            "text": "🔀 Merged Pull Requests",
            "weight": "Bolder",
            "wrap": True,
            "spacing": "Medium"
        })
        for pr in prs:
            pr_section.append({
                "type": "TextBlock",
                "text": f"• **#{pr.get('num', '?')}**: [{short_txt(pr.get('title', '(no title)'), 220)}]({pr.get('url', '')}) by {pr.get('user', 'unknown')}",
                "wrap": True,
                "spacing": "Small"
            })

    commit_section = []
    if commits:
        commit_section.append({
            "type": "TextBlock",
            "text": "⎇ Recent Commits",
            "weight": "Bolder",
            "wrap": True,
            "spacing": "Medium"
        })
        for c in commits:
            commit_url = f"https://github.com/{repo}/commit/{c.get('sha', '')}"
            commit_section.append({
                "type": "TextBlock",
                "text": f"• **[{c.get('short', '')[:7]}]({commit_url})**: {short_txt(c.get('msg', ''), 200)} by {c.get('author', '')}",
                "wrap": True,
                "spacing": "Small"
            })

    no_changes_section = []
    if not prs and not commits:
        no_changes_section.append({
            "type": "TextBlock",
            "text": "No merged pull requests or recent commits found in this window.",
            "wrap": True,
            "spacing": "Small"
        })

    payload = {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.3",
        "body": [
            {
                "type": "TextBlock",
                "size": "Large",
                "weight": "Bolder",
                "text": "🚀 Release Notes",
                "wrap": True
            },
            {
                "type": "ColumnSet",
                "columns": [
                    {
                        "type": "Column",
                        "width": "stretch",
                        "items": [
                            {
                                "type": "FactSet",
                                "facts": [
                                    {"title": "📦 Repository", "value": f"[{repo}](https://github.com/{repo})"},
                                    {"title": "🔒 Deployed", "value": short_sha},
                                    {"title": "📆 Since", "value": os.environ.get('SINCE_DATE', '')},
                                    {"title": "🧾 PRs", "value": str(len(prs))},
                                    {"title": "⎇ Commits", "value": str(len(commits))}
                                ]
                            }
                        ]
                    }
                ]
            },
            *pr_section,
            *commit_section,
            *no_changes_section
        ],
        "actions": [
            {"type": "Action.OpenUrl", "title": "🔗 View Repository", "url": f"https://github.com/{repo}"},
            {"type": "Action.OpenUrl", "title": "🔎 View Changes on GitHub", "url": os.environ.get('COMPARE_URL', '')}
        ]
    }
    return json.dumps(payload)


if __name__ == "__main__":
    repo = sys.argv[1]
    short_sha = sys.argv[2] or "(hidden)"
    pr_file = sys.argv[3]
    commits_file = sys.argv[4]

    try:
        with open(pr_file, 'r', encoding='utf-8') as f:
            prs = json.load(f)
    except Exception:
        prs = []

    try:
        with open(commits_file, 'r', encoding='utf-8') as f:
            commits = json.load(f)
    except Exception:
        commits = []

    adaptive_card = generate_adaptive_card(repo, short_sha, prs, commits)
    print(adaptive_card)
PY

# Post Adaptive Card
cat "$TMP_CARD" > "$TMP_PLOAD"

if [ -z "$WEBHOOK" ]; then
  echo "TEAMS_WEBHOOK not set — printing fallback body to console:"
  echo "-----"
  sed -n '1,999p' "$TMP_PREVIEW"
  echo "-----"
  exit 0
fi

HTTP_CODE=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
echo "Adaptive card POST HTTP code: $HTTP_CODE"
echo "Teams response preview:"
sed -n '1,400p' "$TMP_RESP" || true
echo

BODY_TEXT=$(tr -d '\r' < "$TMP_RESP" | tr -s '\n' ' ' || true)

NEED_FALLBACK=0
if [ "$HTTP_CODE" != "200" ]; then NEED_FALLBACK=1; fi
if echo "$BODY_TEXT" | grep -i -E 'summary or text|required|invalid|error' >/dev/null 2>&1; then NEED_FALLBACK=1; fi

if [ "$NEED_FALLBACK" -eq 1 ]; then
  echo "Adaptive Card rejected or non-200 response; sending fallback text message."
  FALLBACK_PAYLOAD=$(jq -n --arg t "🚀 Release: ${REPO} — deployed (short SHA: ${SHORT_SHA})" --arg b "$(cat "$TMP_PREVIEW")" '{"text": ($t + "\n\n" + $b)}')
  printf '%s\n' "$FALLBACK_PAYLOAD" > "$TMP_PLOAD"
  HTTP_CODE2=$(curl -sS -o "$TMP_RESP" -w "%{http_code}" -X POST -H "Content-Type: application/json" -d @"$TMP_PLOAD" "$WEBHOOK" || echo "000")
  echo "Fallback POST HTTP code: $HTTP_CODE2"
  echo "Fallback response preview:"
  sed -n '1,400p' "$TMP_RESP" || true
  echo
fi

echo "release_notes.sh finished."
