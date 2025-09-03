#!/usr/bin/env bash
set -euo pipefail

# Release Notes Auto-Sender
# Uses TEAMS_WEBHOOK secret if present; otherwise prints notes in Action logs.

WEBHOOK="${TEAMS_WEBHOOK:-}"

# Try to get last tag, otherwise fall back to last 10 commits
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$LAST_TAG" ]; then
  RANGE="HEAD~10..HEAD"
else
  RANGE="$LAST_TAG..HEAD"
fi

# Produce a short commit list, no merges
COMMITS=$(git --no-pager log --no-merges --pretty=format:"- %h %s (%an)" "$RANGE" || echo "No commits")

# Compose the message
BODY="Release notes for ${GITHUB_REPOSITORY}\nDeployed commit: ${GITHUB_SHA}\n\n${COMMITS}"

# If Teams webhook is available post to Teams; else echo to logs
if [ -n "$WEBHOOK" ]; then
  # Escape quotes and newlines for JSON payload
  PAYLOAD=$(printf '%s' "$BODY" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')
  # PAYLOAD contains a JSON string literal; build final object
  # Use simple message layout: {"text":"..."}
  curl -s -X POST -H "Content-Type: application/json" -d "{\"text\": $PAYLOAD}" "$WEBHOOK" || true
else
  echo -e "---- Release Notes ----\n$BODY\n-----------------------"
fi
