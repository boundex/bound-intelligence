# Repo Intelligence Playbook — set up a code-aware workspace in an afternoon

> **You are reading this as the team's AI coding assistant (Claude Code, or similar).**
> Your job is to stand up a "repo intelligence" system for the team that owns this file.
> Work through **V1 — The Core** in order. For each step: **discover** the team's specifics
> (ask if you don't already know them), **adapt** the template to their values, **install** it,
> **run it once**, and **verify** it worked before moving to the next step.
> **Do not start V2 (the knowledge base) until V1 is confirmed working.**

This is a generalized version of a system we run in-house. The other team keeps their own
repos, their own GitHub org, their own machine — they're inheriting the **method**, not our data.

---

## 0. Discover first (do this before writing anything)

Ask the team (or detect) these five things. Everything below is parameterized on them:

| What | Why you need it | Example |
|------|-----------------|---------|
| **GitHub org(s)** | Default owner for repos; lets bare names resolve | `acme-labs` |
| **The repo list** | The single manifest the whole system reads | `api`, `web`, `contracts`, … |
| **Local workspace path** | One folder that holds all the clones + scripts | `~/work/acme` |
| **Operating system** | Picks the scheduler (launchd / cron / Task Scheduler) | macOS |
| **LLM CLI available?** | Optional for the digest narrative; required for the query step | `claude` on PATH |

Confirm: the team has the **GitHub CLI (`gh`) installed and authenticated** (`gh auth status`),
plus `git`, `bash` 4+, and `jq`. These are the only hard dependencies for V1.

---

## 1. The idea (the "why" — share this with the humans)

**You can't manage what you can't see.** Engineering reality lives in the repos, but a PM,
BD lead, or founder can't read every PR across a dozen codebases every day. This system gives
you a **read-only window into what's actually being built**, in three moves:

1. **Mirror every repo locally** so you always have the real, current source on disk.
2. **One weekly digest** that reads the merged PRs and releases and tells you, in plain English,
   what shipped — so you never have to ping an engineer to find out "what changed this week."
3. **Ask the code questions** and get answers read straight from the source, with file
   citations — instead of trusting docs that go stale.

Three principles run through the whole thing — keep them in mind as you build:

- **Read the live products, never write into them.** The clones are a mirror. The system
  only ever reads. It never pushes, edits, or opens PRs against the team's repos.
- **Liveness comes from code, not docs.** "Is X live?" is answered from executed source
  (deployment artifacts, registries, enums) — never from `.env.example`, commented-out
  config, or a doc that says "planned."
- **Automate the repeatable parts; keep a human at the verify points.** Sync and digest
  generation run themselves. A human reads the digest and asks the questions.

> **The progression:** V1 (below) is the whole core — mirror, digest, query. It works on its
> own and delivers value day one. V2 (a compounding knowledge base) is a *later* layer that
> makes answers faster and reusable. **Ship V1 first. Don't touch V2 until V1 is humming.**

---

# V1 — The Core

Four steps. This is the headline of the whole system.

## Step 1 — Identify the repos and pull them into one local folder

The entire system is driven by **one list of repos**. There's no database and no manifest
file — the list is a bash array at the top of the sync script (Step 2). That array is the
single source of truth for "which repos do we track."

**The convention** (use it in both scripts so they always agree):

- A bare entry `name` resolves to `$GITHUB_ORG/name` (the team's default org).
- An entry with a slash `owner/name` keeps its explicit owner (for a repo in a different org).
- The local clone directory is always the **basename** (the part after the slash).

**Discover** the team's repo list and default org, then you'll drop them into the array.
**Verify** at the end of Step 2 that every repo cloned into `<workspace>/repos/`.

## Step 2 — Sync the repos daily, automatically

Two artifacts: a **sync script** (clone-or-pull, with logging and network resilience) and a
**scheduler entry** (runs it daily). Adapt the placeholders in `«guillemets»`.

### 2a. The sync script

Save as `<workspace>/sync.sh`, then `chmod +x <workspace>/sync.sh`.

```bash
#!/bin/bash
# Multi-Repo Sync — clones repos if missing, pulls latest if they exist.
# Run daily via a scheduler or manually.

set -euo pipefail

WORKSPACE="«/absolute/path/to/workspace»/repos"   # where the clones live
LOG_FILE="«/absolute/path/to/workspace»/.sync.log"
GITHUB_ORG="«your-default-org»"

# Each entry is either:
#   "name"        — defaults to $GITHUB_ORG/name
#   "owner/name"  — explicit org (for any repo outside the default org)
# The local directory always uses the basename (the part after the slash).
REPOS=(
  "«repo-one»"
  "«repo-two»"
  "«repo-three»"
  "«some-other-org/repo-four»"
)

# Split a REPOS entry into "owner/name" and bare "name".
resolve_repo() {
  local entry="$1"
  if [[ "$entry" == */* ]]; then
    REPO_FULL="$entry"; REPO_NAME="${entry##*/}"
  else
    REPO_FULL="$GITHUB_ORG/$entry"; REPO_NAME="$entry"
  fi
}

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }

echo "========================================" >> "$LOG_FILE"
echo "Sync started at $(timestamp)" >> "$LOG_FILE"

# --- Network readiness check ---
# A scheduler fires at the scheduled minute regardless of network state. If the
# machine just woke from sleep, Wi-Fi may still be negotiating. Wait up to 5
# minutes for github.com to become reachable before giving up.
MAX_WAIT=300; INTERVAL=30; WAITED=0
while ! curl -sSf --max-time 5 -o /dev/null https://github.com 2>/dev/null; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "Network unreachable after ${MAX_WAIT}s — aborting at $(timestamp)" >> "$LOG_FILE"
    echo "========================================" >> "$LOG_FILE"; exit 1
  fi
  echo "Network not ready (waited ${WAITED}s), retrying in ${INTERVAL}s..." >> "$LOG_FILE"
  sleep "$INTERVAL"; WAITED=$((WAITED + INTERVAL))
done

SUCCESS_COUNT=0; FAIL_COUNT=0

for entry in "${REPOS[@]}"; do
  resolve_repo "$entry"
  name="$REPO_NAME"; repo_full="$REPO_FULL"; repo_path="$WORKSPACE/$name"

  if [ -d "$repo_path/.git" ]; then
    echo "[$name] Pulling latest..." >> "$LOG_FILE"
    if pull_output=$(git -C "$repo_path" pull --ff-only 2>&1); then
      echo "$pull_output" >> "$LOG_FILE"
      echo "[$name] Pull successful at $(timestamp)" >> "$LOG_FILE"
      ((SUCCESS_COUNT++))
    else
      echo "$pull_output" >> "$LOG_FILE"
      # Categorize the failure for a clearer log message
      if echo "$pull_output" | grep -qE "Could not resolve host|Failed to connect|Connection (timed out|refused)|unable to access"; then
        reason="network unreachable"
      elif echo "$pull_output" | grep -qE "non-fast-forward|diverged|local changes|would be overwritten|untracked working tree"; then
        reason="local changes or diverged branch"
      elif echo "$pull_output" | grep -qE "Authentication failed|could not read Username|denied|Permission denied"; then
        reason="auth failure (run: gh auth status)"
      else
        reason="unknown — see error above"
      fi
      echo "[$name] Pull FAILED at $(timestamp) — $reason" >> "$LOG_FILE"
      ((FAIL_COUNT++))
    fi
  else
    echo "[$name] Cloning $repo_full..." >> "$LOG_FILE"
    if gh repo clone "$repo_full" "$repo_path" >> "$LOG_FILE" 2>&1; then
      echo "[$name] Clone successful at $(timestamp)" >> "$LOG_FILE"
      ((SUCCESS_COUNT++))
    else
      echo "[$name] Clone FAILED at $(timestamp) — check repo access ($repo_full)" >> "$LOG_FILE"
      ((FAIL_COUNT++))
    fi
  fi
done

echo "Sync completed at $(timestamp): $SUCCESS_COUNT succeeded, $FAIL_COUNT failed" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
```

**Why these design choices** (they matter — don't strip them out):
- `git pull --ff-only` — fast-forward only. The mirror never merges or creates conflicts;
  if a repo can't fast-forward, it logs the reason instead of corrupting the clone.
- **Clone-or-pull** — first run clones everything; every run after just pulls. Idempotent;
  safe to run any number of times.
- **Network-readiness wait** — a scheduled run right after wake-from-sleep would otherwise
  fail on a half-up network. This waits up to 5 minutes for `github.com`.
- **Error categorization** — the log tells you *why* a repo failed (network / diverged / auth),
  so a glance at the tail is enough to triage.

> **Important — don't gitignore-trap yourself:** the `repos/` folder is a mirror of *other*
> people's repos. If this workspace is itself a git repo, add `repos/` and `.sync.log` (and
> `.weekly-state.json` from Step 3) to `.gitignore` so you never commit the clones.

### 2b. Schedule it (pick the team's OS)

**macOS — launchd.** Save as `~/Library/LaunchAgents/com.«team».repo-sync.plist`, then
`launchctl load ~/Library/LaunchAgents/com.«team».repo-sync.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.«team».repo-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>«/absolute/path/to/workspace»/sync.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>8</integer><key>Minute</key><integer>30</integer></dict>
    </array>
    <key>StandardOutPath</key>
    <string>«/absolute/path/to/workspace»/.sync-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>«/absolute/path/to/workspace»/.sync-stderr.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
```

> Two intervals (08:00 **and** 08:30) is a cheap reliability trick: if the machine was asleep
> at 08:00, the 08:30 run catches it. The script is idempotent, so a double-run is harmless.
> The explicit `PATH` matters — launchd runs with a minimal environment and won't find
> `gh`/`git` otherwise.

**Linux — cron.** `crontab -e` and add:

```cron
0 8 * * *  /bin/bash «/absolute/path/to/workspace»/sync.sh
```
(Ensure `gh`, `git`, `jq` are on the cron PATH — set `PATH=` at the top of the crontab if needed.)

**Windows — Task Scheduler.** Create a Basic Task → Daily 8:00 AM → Action: *Start a program*
→ run the script via Git Bash / WSL bash (`bash.exe «path»/sync.sh`).

### 2c. Install & verify (gate before Step 3)

```bash
bash «/absolute/path/to/workspace»/sync.sh          # run once by hand
ls «/absolute/path/to/workspace»/repos              # every repo should be a folder
tail -n 20 «/absolute/path/to/workspace»/.sync.log  # last line: "... N succeeded, 0 failed"
# macOS: confirm the timer is registered
launchctl list | grep «team».repo-sync
```

**Pass = every repo present in `repos/` and the log ends in `0 failed`.** Only then continue.

## Step 3 — Weekly PR digest → a report of what shipped

This reads the merged PRs, releases, and commits across all repos *since the last run* and
produces a plain-English report. It uses the same `REPOS` array and `resolve_repo` convention
as Step 2 — keep them identical.

Save as `<workspace>/weekly.sh`, `chmod +x`. It expects the clones from Step 2 to exist.

```bash
#!/bin/bash
# Weekly Digest — reports what changed across the repos since the last run.
# Run sync.sh first (or rely on the daily scheduled run) so clones are current.
# State file (.weekly-state.json) tracks the last run; first run falls back to 7 days.

set -euo pipefail

WORKSPACE="«/absolute/path/to/workspace»"
REPOS_DIR="$WORKSPACE/repos"
GITHUB_ORG="«your-default-org»"
STATE_FILE="$WORKSPACE/.weekly-state.json"
TODAY=$(date "+%Y-%m-%d")
NOW_ISO=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
REPORTS_DIR="$WORKSPACE/weekly-reports"
mkdir -p "$REPORTS_DIR"
REPORT="$REPORTS_DIR/${TODAY}-weekly-digest.md"

# Same convention + list as sync.sh — keep them in sync.
REPOS=( "«repo-one»" "«repo-two»" "«repo-three»" "«some-other-org/repo-four»" )

resolve_repo() {
  local entry="$1"
  if [[ "$entry" == */* ]]; then REPO_FULL="$entry"; REPO_NAME="${entry##*/}"
  else REPO_FULL="$GITHUB_ORG/$entry"; REPO_NAME="$entry"; fi
}
REPO_COUNT="${#REPOS[@]}"

# --- Dependency checks ---
for cmd in git gh jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required" >&2; exit 1; }
done
HAS_CLAUDE=0; command -v claude >/dev/null 2>&1 && HAS_CLAUDE=1   # optional LLM narrative

# --- Determine the window (last run → now) ---
if [ -f "$STATE_FILE" ]; then
  LAST_RUN=$(jq -r '.last_run' "$STATE_FILE")
else
  LAST_RUN=$(date -u -v-7d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
             || date -u -d '7 days ago' "+%Y-%m-%dT%H:%M:%SZ")   # macOS / Linux
  echo "No state file — falling back to last 7 days ($LAST_RUN)"
fi
LAST_RUN_DATE=${LAST_RUN%%T*}

RAW_DATA=""; TABLE_ROWS=""

for entry in "${REPOS[@]}"; do
  resolve_repo "$entry"
  name="$REPO_NAME"; repo_full="$REPO_FULL"; repo_path="$REPOS_DIR/$name"
  echo "  Processing $name ($repo_full)..."

  # Releases since the window (from GitHub)
  releases=$(gh release list --repo "$repo_full" --limit 30 --json tagName,publishedAt,name 2>/dev/null \
    | jq --arg since "$LAST_RUN" '[.[] | select(.publishedAt >= $since)]' || echo "[]")
  release_count=$(echo "$releases" | jq 'length')

  # Merged PRs since the window (from GitHub)
  prs=$(gh pr list --repo "$repo_full" \
    --search "is:pr is:merged merged:>=$LAST_RUN_DATE" \
    --json number,title,author,mergedAt,url --limit 100 2>/dev/null || echo "[]")
  pr_count=$(echo "$prs" | jq 'length')

  # Commits since the window (from the local clone) — subjects + bodies are the
  # substance the narrative reads; PR titles are often vague after squash merges.
  commits=""
  if [ -d "$repo_path/.git" ]; then
    ref=$(git -C "$repo_path" rev-parse --verify --quiet origin/HEAD >/dev/null \
          && echo origin/HEAD || echo "origin/$(git -C "$repo_path" rev-parse --abbrev-ref HEAD)")
    commits=$(git -C "$repo_path" log "$ref" --since="$LAST_RUN" --no-merges \
      --pretty=format:'__COMMIT__%n%h | %an%n%s%n%b%n' 2>/dev/null | head -800 || true)
  fi
  commit_count=$(printf '%s\n' "$commits" | grep -c '^__COMMIT__$' || true)

  # --- One table row per repo ---
  rel_label=$([ "$release_count" -gt 0 ] && echo "$release_count" || echo "—")
  pr_label=$([ "$pr_count" -gt 0 ] && echo "$pr_count" || echo "—")
  links="—"
  [ "$pr_count" -gt 0 ] && links="[PRs](https://github.com/$repo_full/pulls?q=is%3Apr+is%3Amerged+merged%3A%3E%3D$LAST_RUN_DATE)"
  TABLE_ROWS+="| \`$name\` | $rel_label | $pr_label | $links |"$'\n'

  # --- Raw data fed to the narrative ---
  RAW_DATA+=$'\n=== REPO: '"$name"' ===\n'
  RAW_DATA+="releases=$release_count merged_prs=$pr_count commits=$commit_count"$'\n'
  [ "$pr_count" -gt 0 ] && RAW_DATA+="PRs:"$'\n'"$(echo "$prs" | jq -r '.[] | "  - #\(.number) \(.title) — @\(.author.login)"')"$'\n'
  [ "$commit_count" -gt 0 ] && RAW_DATA+="Commits:"$'\n'"$commits"$'\n'
done

# --- Optional: narrative summary via an LLM CLI ---
SUMMARY=""
if [ "$HAS_CLAUDE" -eq 1 ]; then
  echo "  Generating narrative via claude -p..."
  PROMPT="You are writing a weekly engineering change digest covering $LAST_RUN → $NOW_ISO across $REPO_COUNT repos. The reader does NOT want PR lists — they want a plain-English narrative of what was built, fixed, and shipped. Commit subjects + bodies are your primary source (PR titles are often vague). Structure: a 2-3 sentence '**Workspace this week.**' paragraph; then one '**<repo>.**' paragraph per active repo (group commits into themes, name concrete features/files, skip chore/lint noise); end with '**Quiet this week:** repo, repo'. Prose only, no invented detail.

DATA:
$RAW_DATA"
  SUMMARY=$(printf '%s' "$PROMPT" | claude -p 2>/dev/null || echo "")
fi

# --- Write the report ---
{
  echo "# Weekly Digest"
  echo ""; echo "_${LAST_RUN_DATE} → ${TODAY} · ${REPO_COUNT} repos_"; echo ""
  if [ -n "$SUMMARY" ]; then echo "## What's new"; echo ""; echo "$SUMMARY"; echo ""; fi
  echo "## Activity reference"; echo ""
  echo "| Repo | Releases | Merged PRs | Links |"
  echo "|------|----------|------------|-------|"
  printf '%s' "$TABLE_ROWS"
} > "$REPORT"

# --- Advance the window ---
echo "{\"last_run\": \"$NOW_ISO\"}" > "$STATE_FILE"
echo "Done: $REPORT"
```

**What the report looks like:** a dated header (the window), a **"What's new"** narrative
written from the actual commits (only if an LLM CLI is present — otherwise you still get the
table), and an **"Activity reference"** table: one row per repo with release count, merged-PR
count, and a clickable link to that repo's merged PRs for the window.

**The state file is the clever bit.** `.weekly-state.json` stores the last-run timestamp;
each run reports only what changed *since then* and advances the marker. Run it weekly for a
weekly digest, or mid-week for a delta — it always covers exactly "since you last looked."

**Schedule it weekly** the same way as Step 2 (e.g. launchd `Weekday 1` / cron `0 9 * * 1`),
or run it by hand. **Verify:** `bash «workspace»/weekly.sh` produces a file in
`weekly-reports/` that reads correctly.

## Step 4 — Ask the code questions (V1's payoff)

This is what makes the whole thing worth it, and it's the **first thing we built** — before
any knowledge base existed. The capability is simple: **a question comes in → the assistant
reads the synced source → it answers with file citations.** No guessing, no stale docs.

You (the assistant) already have everything you need: the repos are mirrored on disk and kept
current by Step 2. Two things make the answers reliable:

**(a) A routing table** so you don't scan everything for every question. Maintain a short map
of "topic → which repo/folder to read first." Discover the team's repos' shape and write a few
lines like:

```
| Question about…            | Read first                          |
|----------------------------|-------------------------------------|
| HTTP API / endpoints       | repos/«api»/src/routes/             |
| Smart contracts            | repos/«contracts»/src/              |
| Frontend pages/components  | repos/«web»/app/                    |
| Background jobs / indexing | repos/«worker»/                     |
```
Route to the 1–2 relevant repos, read those files, answer. Don't grep all repos every time.

**(b) Liveness rules** so "is X actually live?" is answered from executed code, not scaffolding:

- **Trust** (positive evidence): deployment artifacts with real addresses, chain/feature
  **registries and enums** in source, config that production actually loads.
- **Never trust** (zero signal): `.env.example` / `.env.sample` (always blank in git),
  Docker Compose `${FOO:-}` placeholders, CI env defaults, commented-out config, README
  "supported" prose, or any doc that says "planned." Verify against executed-code signals.

> We learned this the hard way: we once told a stakeholder a chain's integration was "planned"
> based on a blank `.env.example`. It was fully live — the registries and deployment artifacts
> proved it; the template file was simply the wrong place to look. **Read what runs.**

**Example interaction:**

> **Q:** "Do we support webhook retries, and where's that handled?"
>
> **A:** "Yes. Retries are handled in `repos/api/src/queue/webhook.ts:42` — failed
> deliveries are re-enqueued with exponential backoff (max 5 attempts, see `RETRY_POLICY`
> at line 18). The dead-letter path is `repos/api/src/queue/dlq.ts`."

That's V1 complete: **mirror → digest → query.** It delivers value immediately and needs
nothing else to be useful.

---

## Dependencies & prerequisites (one glance)

| Tool | Needed for | Notes |
|------|-----------|-------|
| **`gh`** (GitHub CLI) | sync + digest | Must be authenticated: `gh auth status` |
| **`git`** | sync + digest | — |
| **`jq`** | digest | JSON parsing of `gh` output |
| **`bash` 4+** | both scripts | `set -euo pipefail`, arrays |
| **A scheduler** | automation | launchd (macOS) / cron (Linux) / Task Scheduler (Windows) |
| **An LLM CLI** (e.g. `claude`) | digest narrative *(optional)*, query step *(required)* | Without it: digest still produces the table; query is done by the assistant reading this workspace |

---

# V2 — Next iteration: the Knowledge Base layer

> ⚠️ **Only after V1 is running and trusted.** V2 is a layer built *on top of* the core — it
> doesn't replace anything in V1. If V1 isn't humming yet, stop here and come back later.

V1 reads the code fresh on every question. That's correct and reliable, but it re-derives the
same understanding over and over. **V2 captures that understanding into a compounding, sourced
knowledge base** so answers get faster and the team accumulates a living map of the codebase.
The shape we use:

1. **Auto-feed from the digest.** The weekly script *also* writes one small markdown file per
   merged PR (and per release) into an `inbox/` folder — pure shell, no LLM, idempotent. Every
   merged PR becomes a "raw source" waiting to be processed.
2. **Ingest.** A command reads each inbox item, **re-verifies it against the actual source
   code**, updates the relevant knowledge-base pages (per-feature, per-repo, reference tables),
   bumps a `last_reviewed` date, then moves the inbox item to `processed/` and logs the change.
   This is the single point where the wiki is *written* — and a human stays in the loop.
3. **Query, wiki-first.** Now the query step checks the knowledge base first (fast, compounding),
   then **cross-checks against the code** and emits a parity verdict:
   **✓ Match / △ Partial / ✗ Silent / ⚠ Contradicts.** When there's a gap, it files an inbox
   item for the next ingest to reconcile — so the wiki improves a little with every question.
4. **Lint.** A periodic health check flags stale pages, orphans, broken links, and
   contradictions, and reports an inbox backlog. It proposes fixes; a human approves them.
5. **A local UI (optional).** We surface all of it — repos, digests, the knowledge base,
   pending inbox, the query box — in a small local web app so the whole team can use it
   without touching the terminal.

**The arc:** V1 answers from code every time; V2 turns those answers into a sourced wiki that
keeps itself current from the same PR stream the digest already reads. Same inputs, compounding
output. **Build it only once the core is part of the team's daily rhythm.**

---

## Quickstart checklist

- [ ] **Discover:** org(s), repo list, workspace path, OS, LLM-CLI availability
- [ ] **Prereqs:** `gh auth status` green; `git`, `jq`, `bash` 4+ present
- [ ] **Step 1:** decide the repo list (the `REPOS` array)
- [ ] **Step 2:** write `sync.sh` (fill `WORKSPACE`, `GITHUB_ORG`, `REPOS`) → schedule it →
      run once → verify all repos in `repos/` and log ends `0 failed`
- [ ] **Step 3:** write `weekly.sh` (same `REPOS`) → run once → verify the report → schedule weekly
- [ ] **Step 4:** write the routing table + liveness rules → answer a test question with citations
- [ ] **V1 done.** Use it for a week.
- [ ] **Later — V2:** add inbox feed to `weekly.sh`, then ingest / wiki-first query / lint / UI
```
