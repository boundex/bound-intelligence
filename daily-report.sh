#!/bin/bash
# Boundex Daily Repo Intelligence - syncs repos and updates one HTML report.

set -u

WORKSPACE="${WORKSPACE:-/Users/2infiniti/Desktop/dev/bound-intelligence}"
REPOS_DIR="$WORKSPACE/repos"
GITHUB_ORG="boundex"
STATE_FILE="$WORKSPACE/.daily-state.json"
LOG_FILE="$WORKSPACE/.daily.log"
REPORT="$WORKSPACE/repo-intelligence-report.html"
SYNC_SCRIPT="$WORKSPACE/sync.sh"
CODEX_BIN="/Applications/Codex.app/Contents/Resources/codex"
DISPLAY_TZ="America/New_York"
TODAY=$(TZ="$DISPLAY_TZ" date "+%Y-%m-%d")
NOW_HUMAN=$(TZ="$DISPLAY_TZ" date "+%Y-%m-%d %H:%M:%S %Z")
NOW_ISO=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
DAY_START_ISO=$(python3 - <<PY
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
tz = ZoneInfo("$DISPLAY_TZ")
start = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
print(start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)

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

mkdir -p "$WORKSPACE/daily-reports"

timestamp() { date "+%Y-%m-%d %H:%M:%S"; }
html_escape() { jq -Rr @html; }

iso_to_display_time() {
  local iso="$1"
  local epoch
  epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" "+%s" 2>/dev/null \
    || date -u -d "$iso" "+%s" 2>/dev/null \
    || printf '')
  if [ -n "$epoch" ]; then
    TZ="$DISPLAY_TZ" date -r "$epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null \
      || TZ="$DISPLAY_TZ" date -d "@$epoch" "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null \
      || printf '%s' "$iso"
  else
    printf '%s' "$iso"
  fi
}

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

echo "========================================" >> "$LOG_FILE"
echo "Daily report started at $(timestamp)" >> "$LOG_FILE"

MISSING_DEPS=0
for cmd in git gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is required. Install it and rerun this script." >> "$LOG_FILE"
    MISSING_DEPS=1
  fi
done

if [ "$MISSING_DEPS" -eq 1 ]; then
  cat > "$REPORT" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Boundex Repo Intelligence</title>
<style>
body{font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;margin:0;background:#f8f7f3;color:#292724}
main{max-width:860px;margin:0 auto;padding:56px 24px}
.notice{background:#fff;border:1px solid #e2ddd2;border-radius:8px;padding:24px}
code{background:#f0ece4;padding:2px 6px;border-radius:5px}
</style>
</head>
<body><main>
<h1>BoundEx Intelligence</h1>
<div class="notice">
<p><strong>Setup needed:</strong> this report needs <code>gh</code>, <code>git</code>, and <code>jq</code>.</p>
<p>Install GitHub CLI, run <code>gh auth login</code>, then run <code>$WORKSPACE/daily-report.sh</code> again.</p>
</div>
</main></body></html>
HTML
  echo "Daily report stopped: missing dependencies" >> "$LOG_FILE"
  echo "========================================" >> "$LOG_FILE"
  exit 1
fi

if [ -x "$SYNC_SCRIPT" ]; then
  if "$SYNC_SCRIPT" >> "$LOG_FILE" 2>&1; then
    SYNC_STATUS="Sync completed successfully."
  else
    SYNC_STATUS="Sync finished with errors. See .sync.log."
  fi
else
  SYNC_STATUS="Sync script is not executable."
fi

LAST_RUN="$DAY_START_ISO"
LAST_RUN_DATE=${LAST_RUN%%T*}
LAST_RUN_HUMAN=$(iso_to_display_time "$LAST_RUN")
REPO_COUNT="${#REPOS[@]}"

ACTIVE_COUNT=0
TOTAL_RELEASES=0
TOTAL_PRS=0
TOTAL_COMMITS=0
BOARD_COMPLETED=""
BOARD_IN_PROGRESS=""
BOARD_QUIET=""
RAW_DATA=""

for entry in "${REPOS[@]}"; do
  resolve_repo "$entry"
  name="$REPO_NAME"
  repo_full="$REPO_FULL"
  repo_path="$REPOS_DIR/$name"
  echo "Processing $name ($repo_full)..." >> "$LOG_FILE"

  if ! gh repo view "$repo_full" --json name >/dev/null 2>> "$LOG_FILE"; then
    echo "ERROR: cannot access $repo_full. Check BOUND_REPO_TOKEN/GH_TOKEN permissions." >> "$LOG_FILE"
    exit 1
  fi

  releases=$(gh release list --repo "$repo_full" --limit 30 --json tagName,publishedAt,name 2>/dev/null \
    | jq --arg since "$LAST_RUN" '[.[] | select(.publishedAt >= $since)]' 2>/dev/null || echo "[]")
  release_count=$(echo "$releases" | jq 'length' 2>/dev/null || echo "0")

  prs=$(gh pr list --repo "$repo_full" \
    --search "is:pr is:merged merged:>=$LAST_RUN_DATE" \
    --json number,title,author,mergedAt,url --limit 100 2>/dev/null || echo "[]")
  pr_count=$(echo "$prs" | jq 'length' 2>/dev/null || echo "0")

  commits=""
  if [ -d "$repo_path/.git" ]; then
    ref=$(git -C "$repo_path" rev-parse --verify --quiet origin/HEAD >/dev/null \
      && echo origin/HEAD || echo "origin/$(git -C "$repo_path" rev-parse --abbrev-ref HEAD)")
    commits=$(git -C "$repo_path" log "$ref" --since="$LAST_RUN" --no-merges \
      --pretty=format:'%h | %an | %s' 2>/dev/null | head -80 || true)
  fi
  commit_count=$(printf '%s\n' "$commits" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$release_count" -gt 0 ] || [ "$pr_count" -gt 0 ] || [ "$commit_count" -gt 0 ]; then
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
  fi
  TOTAL_RELEASES=$((TOTAL_RELEASES + release_count))
  TOTAL_PRS=$((TOTAL_PRS + pr_count))
  TOTAL_COMMITS=$((TOTAL_COMMITS + commit_count))

  safe_name=$(printf '%s' "$name" | html_escape)
  pr_url="https://github.com/$repo_full/pulls?q=is%3Apr+is%3Amerged+merged%3A%3E%3D$LAST_RUN_DATE"
  repo_url="https://github.com/$repo_full"

  pr_items=$(echo "$prs" | jq -r '.[] | "<li><a href=\"\(.url)\">#\(.number)</a> \(.title | @html) <span>by @\(.author.login)</span></li>"')
  release_items=$(echo "$releases" | jq -r '.[] | "<li><strong>\(.tagName | @html)</strong> \(.name // "" | @html) <span>\(.publishedAt)</span></li>"')
  commit_items=$(printf '%s\n' "$commits" | sed '/^$/d' | while IFS= read -r line; do printf '<li>%s</li>\n' "$(printf '%s' "$line" | html_escape)"; done)

  [ -z "$pr_items" ] && pr_items="<li class=\"muted\">No merged PRs in this window.</li>"
  [ -z "$release_items" ] && release_items="<li class=\"muted\">No releases in this window.</li>"
  [ -z "$commit_items" ] && commit_items="<li class=\"muted\">No commits found in the local mirror for this window.</li>"

  CARD_STATUS="Quiet"
  CARD_SUBTITLE="No activity in this window"
  CARD_CLASS="quiet"
  CARD_BADGE="No activity"
  if [ "$pr_count" -gt 0 ]; then
    CARD_STATUS="Completed"
    CARD_SUBTITLE="Merged PRs in this window"
    CARD_CLASS="completed"
    CARD_BADGE="Merged"
  elif [ "$commit_count" -gt 0 ]; then
    CARD_STATUS="In Progress"
    CARD_SUBTITLE="Commits without merged PRs"
    CARD_CLASS="active"
    CARD_BADGE="Commits"
  fi

  CARD_HTML="<article class=\"repo-card $CARD_CLASS\"><div class=\"card-top\"><div><a class=\"repo-name\" href=\"$repo_url\">$safe_name</a><div class=\"repo-subtitle\">$CARD_SUBTITLE</div></div><span class=\"badge\">$CARD_BADGE</span></div><div class=\"count-row\"><span><b>$release_count</b> releases</span><span><b>$pr_count</b> merged PRs</span><span><b>$commit_count</b> commits</span></div><div class=\"card-actions\"><a href=\"$pr_url\">PR search</a><a href=\"$repo_url\">Repo</a></div><details><summary>Details</summary><div class=\"detail-stack\"><section><h3>Releases</h3><ul>$release_items</ul></section><section><h3>Merged PRs</h3><ul>$pr_items</ul></section><section><h3>Commits</h3><ul>$commit_items</ul></section></div></details></article>"$'\n'
  if [ "$pr_count" -gt 0 ]; then
    BOARD_COMPLETED+="$CARD_HTML"
  elif [ "$commit_count" -gt 0 ]; then
    BOARD_IN_PROGRESS+="$CARD_HTML"
  else
    BOARD_QUIET+="$CARD_HTML"
  fi

  RAW_DATA+=$'\n=== REPO: '"$name"$' ===\n'
  RAW_DATA+="releases=$release_count merged_prs=$pr_count commits=$commit_count"$'\n'
  [ "$pr_count" -gt 0 ] && RAW_DATA+="PRs:"$'\n'"$(echo "$prs" | jq -r '.[] | "  - #\(.number) \(.title) by @\(.author.login)"')"$'\n'
  [ "$commit_count" -gt 0 ] && RAW_DATA+="Commits:"$'\n'"$commits"$'\n'
done

[ -z "$BOARD_COMPLETED" ] && BOARD_COMPLETED="<div class=\"empty-lane\">No merged PRs in this window.</div>"
[ -z "$BOARD_IN_PROGRESS" ] && BOARD_IN_PROGRESS="<div class=\"empty-lane\">No commits without merged PRs in this window.</div>"
[ -z "$BOARD_QUIET" ] && BOARD_QUIET="<div class=\"empty-lane\">No quiet repos.</div>"

SUMMARY_HTML="<p class=\"muted\">Install an LLM CLI such as Claude to generate the plain-English narrative. The activity data below is still live from GitHub and the local mirrors.</p>"
if [ ! -x "$CODEX_BIN" ] && command -v codex >/dev/null 2>&1; then
  CODEX_BIN="$(command -v codex)"
fi

if [ -x "$CODEX_BIN" ]; then
  PROMPT="Write a concise daily executive engineering digest for Boundex covering $LAST_RUN_HUMAN to $NOW_HUMAN across $REPO_COUNT repos. The audience is business planning and external communications. Use Eastern Time when referring to the reporting window. Use plain text only: no Markdown headings, bold markers, bullets, or tables. Do not list every PR. Summarize concrete shipped work, fixes, and notable movement. Mention quiet repos briefly. Do not invent details. Source data:
$RAW_DATA"
  SUMMARY_FILE=$(mktemp "$WORKSPACE/.codex-summary.XXXXXX")
  SUMMARY=""
  if printf '%s' "$PROMPT" | "$CODEX_BIN" exec --cd "$WORKSPACE" --skip-git-repo-check --ephemeral --sandbox read-only --output-last-message "$SUMMARY_FILE" - >> "$LOG_FILE" 2>&1; then
    SUMMARY=$(cat "$SUMMARY_FILE")
  else
    echo "Codex summary generation failed; report will keep the activity table." >> "$LOG_FILE"
  fi
  rm -f "$SUMMARY_FILE"
  if [ -n "$SUMMARY" ]; then
    SUMMARY_ESCAPED=$(printf '%s' "$SUMMARY" | html_escape | awk 'BEGIN{first=1} {if (!first) printf "<br>"; printf "%s", $0; first=0}')
    SUMMARY_HTML="<p>$SUMMARY_ESCAPED</p>"
  fi
else
  PROMPT="Write a concise daily executive engineering digest for Boundex covering $LAST_RUN_HUMAN to $NOW_HUMAN across $REPO_COUNT repos. The audience is business planning and external communications. Use Eastern Time when referring to the reporting window. Use plain text only: no Markdown headings, bold markers, bullets, or tables. Do not list every PR. Summarize concrete shipped work, fixes, and notable movement. Mention quiet repos briefly. Do not invent details. Source data:
$RAW_DATA"
  SUMMARY_FILE=$(mktemp "$WORKSPACE/.openai-summary.XXXXXX")
  PROMPT_FILE=$(mktemp "$WORKSPACE/.openai-prompt.XXXXXX")
  printf '%s' "$PROMPT" > "$PROMPT_FILE"
  SUMMARY=""
  if [ -n "${OPENAI_API_KEY:-}" ] && python3 -c "import openai" >/dev/null 2>&1; then
    if PROMPT_FILE="$PROMPT_FILE" SUMMARY_FILE="$SUMMARY_FILE" python3 - <<'PY' >> "$LOG_FILE" 2>&1
import os
from pathlib import Path
from openai import OpenAI

prompt = Path(os.environ["PROMPT_FILE"]).read_text()
client = OpenAI()
response = client.responses.create(
    model=os.environ.get("OPENAI_MODEL", "gpt-5.5"),
    input=prompt,
)
Path(os.environ["SUMMARY_FILE"]).write_text(response.output_text.strip())
PY
    then
      SUMMARY=$(cat "$SUMMARY_FILE")
    else
      echo "OpenAI summary generation failed; report will keep the activity cards." >> "$LOG_FILE"
    fi
  else
    echo "No Codex CLI or OPENAI_API_KEY/openai package available; report will keep the activity cards." >> "$LOG_FILE"
  fi
  rm -f "$SUMMARY_FILE" "$PROMPT_FILE"
  if [ -n "$SUMMARY" ]; then
    SUMMARY_ESCAPED=$(printf '%s' "$SUMMARY" | html_escape | awk 'BEGIN{first=1} {if (!first) printf "<br>"; printf "%s", $0; first=0}')
    SUMMARY_HTML="<p>$SUMMARY_ESCAPED</p>"
  else
    SUMMARY_HTML="<p class=\"muted\">AI summary was not available for this run. The repo board below is still live from GitHub and the local mirrors.</p>"
  fi
fi

cat > "$REPORT.tmp" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Boundex Repo Intelligence</title>
<style>
:root{--primary:#f7931a;--primary-dark:#c56f00;--on-primary:#fff;--surface:#fff;--surface-variant:#f3f1ee;--background:#faf8f5;--outline:#dadce0;--outline-soft:#e8eaed;--text:#202124;--muted:#5f6368;--success:#188038;--progress:#f7931a;--quiet:#9aa0a6;--warning:#f9ab00;--shadow-1:0 1px 2px rgba(60,64,67,.3),0 1px 3px 1px rgba(60,64,67,.15);--shadow-2:0 2px 6px rgba(60,64,67,.22),0 1px 2px rgba(60,64,67,.14)}
*{box-sizing:border-box}body{margin:0;background:var(--background);color:var(--text);font-family:Roboto,Inter,system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.5}
a{color:var(--primary);text-decoration:none}a:hover{text-decoration:underline}
main{max-width:1440px;margin:0 auto;padding:28px 24px 56px}
.page-header{display:flex;justify-content:space-between;gap:24px;align-items:center;margin-bottom:22px;padding:4px 2px 2px}.brand{display:flex;align-items:center;gap:10px}.brand-logo{width:30px;height:30px;object-fit:contain;display:block}
h1{margin:0;font-size:24px;line-height:1.15;letter-spacing:0;font-weight:500}.meta{color:var(--muted);font-size:13px;white-space:nowrap}
.topbar{margin-bottom:22px}
.summary{background:var(--surface);border:1px solid var(--outline-soft);border-radius:8px;padding:22px 24px;box-shadow:var(--shadow-1);position:relative}.summary:before{content:"";position:absolute;inset:0 auto 0 0;width:4px;background:var(--primary);border-radius:8px 0 0 8px}.summary h2,.board-title{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 10px;font-weight:700}.summary p{margin:0;font-size:15px;max-width:112ch}
.board-wrap{overflow-x:auto;padding:2px 2px 14px}.board{display:grid;grid-template-columns:repeat(3,minmax(300px,1fr));gap:18px;min-width:980px}
.lane{background:var(--surface-variant);border:1px solid var(--outline-soft);border-radius:8px;padding:14px;min-height:380px}.lane header{display:flex;align-items:center;justify-content:space-between;margin:0 0 14px;padding:0 2px 10px;border-bottom:1px solid var(--outline)}.lane h2{margin:0;font-size:16px;font-weight:500}.lane-count{color:var(--muted);font-size:12px;font-weight:500}
.repo-card{background:var(--surface);border:1px solid var(--outline-soft);border-radius:8px;padding:15px;margin-bottom:12px;box-shadow:var(--shadow-1);transition:box-shadow .15s ease,transform .15s ease}.repo-card:hover{transform:translateY(-1px);box-shadow:var(--shadow-2)}.repo-card.completed{border-left:4px solid var(--success)}.repo-card.active{border-left:4px solid var(--progress)}.repo-card.quiet{border-left:4px solid var(--quiet)}
.card-top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.repo-name{font-weight:500;color:var(--text);font-size:15px}.repo-subtitle{color:var(--muted);font-size:12px;margin-top:2px}.badge{border-radius:999px;background:#eef0f2;color:var(--muted);font-size:11px;font-weight:500;padding:4px 10px;white-space:nowrap}.completed .badge{background:#e6f4ea;color:var(--success)}.active .badge{background:#fff3e0;color:var(--progress)}
.count-row{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:15px 0}.count-row span{background:#fafafa;border:1px solid var(--outline-soft);border-radius:8px;padding:8px;font-size:12px;color:var(--muted)}.count-row b{display:block;color:var(--text);font-size:20px;font-weight:500;line-height:1.05}
.card-actions{display:flex;gap:8px;margin-bottom:10px}.card-actions a{background:#fff3e0;border:1px solid #ffd7a3;border-radius:999px;padding:6px 12px;font-size:12px;font-weight:500;color:var(--primary-dark)}
details{border-top:1px solid var(--outline-soft);padding-top:9px}summary{cursor:pointer;color:var(--muted);font-size:13px;font-weight:500}h3{font-size:11px;margin:12px 0 6px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;font-weight:700}ul{margin:0;padding-left:18px}li{margin:5px 0;font-size:13px;overflow-wrap:anywhere}li span{color:var(--muted)}.muted{color:var(--muted)}.empty-lane{border:1px dashed var(--outline);border-radius:8px;color:var(--muted);padding:18px;text-align:center;background:rgba(255,255,255,.68);font-size:13px;font-weight:500}
@media(max-width:860px){main{padding:18px 12px 44px}.page-header{display:block;padding:2px 0}.brand-logo{width:28px;height:28px}h1{font-size:22px}.meta{display:inline-block;margin-top:8px;white-space:normal}.summary{padding:18px}.board{grid-template-columns:1fr;min-width:0}.board-wrap{overflow-x:visible}}
</style>
</head>
<body>
<main>
<header class="page-header">
  <div class="brand">
    <img class="brand-logo" src="assets/logo-bunny-mark.png" alt="" aria-hidden="true">
    <h1>BoundEx Intelligence</h1>
  </div>
  <div class="meta">Updated $NOW_HUMAN</div>
</header>
<section class="topbar">
  <div class="summary">
    <h2>$TODAY Daily Summary</h2>
    $SUMMARY_HTML
  </div>
</section>
<section>
  <h2 class="board-title">Repo Board</h2>
  <div class="board-wrap">
    <div class="board">
      <section class="lane">
        <header><h2>Completed</h2><span class="lane-count">Merged PRs</span></header>
        $BOARD_COMPLETED
      </section>
      <section class="lane">
        <header><h2>In Progress</h2><span class="lane-count">Commits</span></header>
        $BOARD_IN_PROGRESS
      </section>
      <section class="lane">
        <header><h2>Quiet</h2><span class="lane-count">No activity</span></header>
        $BOARD_QUIET
      </section>
    </div>
  </div>
</section>
</main>
</body>
</html>
HTML

mv "$REPORT.tmp" "$REPORT"
cp "$REPORT" "$WORKSPACE/daily-reports/$TODAY.html"
echo "{\"last_run\": \"$NOW_ISO\", \"window_start\": \"$LAST_RUN\", \"mode\": \"daily-window\"}" > "$STATE_FILE"
echo "Daily report completed at $(timestamp): $REPORT" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
