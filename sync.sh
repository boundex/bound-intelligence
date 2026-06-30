#!/bin/bash
# Boundex Repo Sync - clones repos if missing, pulls latest if present.

set -u

WORKSPACE="${WORKSPACE:-/Users/2infiniti/Desktop/dev/bound-intelligence}"
REPOS_DIR="$WORKSPACE/repos"
LOG_FILE="$WORKSPACE/.sync.log"
GITHUB_ORG="boundex"

REPOS=(
  "radfi-web"
  "ordinal-provider"
  "ord-indexer"
  "bound_lending"
  "bound_lending_solver"
  "bound_marketing_mcp"
  "bound-dashboard"
  "docs_bound_exchange"
)

mkdir -p "$REPOS_DIR"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

resolve_repo() {
  local entry="$1"
  if [[ "$entry" == */* ]]; then
    REPO_FULL="$entry"
    REPO_NAME="${entry##*/}"
  else
    REPO_FULL="$GITHUB_ORG/$entry"
    REPO_NAME="$entry"
  fi
}

{
  echo "========================================"
  echo "Sync started at $(timestamp)"
} >> "$LOG_FILE"

for cmd in git gh; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required. Install it and rerun this script." >> "$LOG_FILE"
    echo "Sync failed at $(timestamp)" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    exit 1
  fi
done

MAX_WAIT=300
INTERVAL=30
WAITED=0
while ! curl -sSf --max-time 5 -o /dev/null https://github.com 2>/dev/null; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "Network unreachable after ${MAX_WAIT}s - aborting at $(timestamp)" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"
    exit 1
  fi
  echo "Network not ready (waited ${WAITED}s), retrying in ${INTERVAL}s..." >> "$LOG_FILE"
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
done

SUCCESS_COUNT=0
FAIL_COUNT=0

for entry in "${REPOS[@]}"; do
  resolve_repo "$entry"
  name="$REPO_NAME"
  repo_full="$REPO_FULL"
  repo_path="$REPOS_DIR/$name"

  if [ -d "$repo_path/.git" ]; then
    echo "[$name] Pulling latest..." >> "$LOG_FILE"
    if pull_output=$(git -C "$repo_path" pull --ff-only 2>&1); then
      echo "$pull_output" >> "$LOG_FILE"
      echo "[$name] Pull successful at $(timestamp)" >> "$LOG_FILE"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "$pull_output" >> "$LOG_FILE"
      if echo "$pull_output" | grep -qE "Could not resolve host|Failed to connect|Connection (timed out|refused)|unable to access"; then
        reason="network unreachable"
      elif echo "$pull_output" | grep -qE "non-fast-forward|diverged|local changes|would be overwritten|untracked working tree"; then
        reason="local changes or diverged branch"
      elif echo "$pull_output" | grep -qE "Authentication failed|could not read Username|denied|Permission denied"; then
        reason="auth failure (run: gh auth status)"
      else
        reason="unknown - see error above"
      fi
      echo "[$name] Pull FAILED at $(timestamp) - $reason" >> "$LOG_FILE"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    echo "[$name] Cloning $repo_full..." >> "$LOG_FILE"
    if gh repo clone "$repo_full" "$repo_path" >> "$LOG_FILE" 2>&1; then
      echo "[$name] Clone successful at $(timestamp)" >> "$LOG_FILE"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "[$name] Clone FAILED at $(timestamp) - check repo access ($repo_full)" >> "$LOG_FILE"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi
done

echo "Sync completed at $(timestamp): $SUCCESS_COUNT succeeded, $FAIL_COUNT failed" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"

[ "$FAIL_COUNT" -eq 0 ]
