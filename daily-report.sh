#!/bin/bash
# Boundex Daily Repo Intelligence - syncs repos and updates one HTML report.

set -u

WORKSPACE="/Users/2infiniti/Desktop/dev/bound-intelligence"
REPOS_DIR="$WORKSPACE/repos"
GITHUB_ORG="boundex"
STATE_FILE="$WORKSPACE/.daily-state.json"
LOG_FILE="$WORKSPACE/.daily.log"
REPORT="$WORKSPACE/repo-intelligence-report.html"
SYNC_SCRIPT="$WORKSPACE/sync.sh"
CODEX_BIN="/Applications/Codex.app/Contents/Resources/codex"
TODAY=$(date "+%Y-%m-%d")
NOW_HUMAN=$(date "+%Y-%m-%d %H:%M:%S %Z")
NOW_ISO=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

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
<h1>Boundex Repo Intelligence</h1>
<div class="notice">
<p><strong>Setup needed:</strong> this report needs <code>gh</code>, <code>git</code>, and <code>jq</code>.</p>
<p>Install GitHub CLI, run <code>gh auth login</code>, then run <code>/Users/2infiniti/Desktop/dev/bound-intelligence/daily-report.sh</code> again.</p>
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

if [ -f "$STATE_FILE" ]; then
  LAST_RUN=$(jq -r '.last_run' "$STATE_FILE")
else
  LAST_RUN=$(date -u -v-1d "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d '1 day ago' "+%Y-%m-%dT%H:%M:%SZ")
fi
LAST_RUN_DATE=${LAST_RUN%%T*}
REPO_COUNT="${#REPOS[@]}"

ACTIVE_COUNT=0
TOTAL_RELEASES=0
TOTAL_PRS=0
TOTAL_COMMITS=0
TABLE_ROWS=""
DETAIL_BLOCKS=""
BOARD_SHIPPED=""
BOARD_IN_MOTION=""
BOARD_QUIET=""
RAW_DATA=""

for entry in "${REPOS[@]}"; do
  resolve_repo "$entry"
  name="$REPO_NAME"
  repo_full="$REPO_FULL"
  repo_path="$REPOS_DIR/$name"
  echo "Processing $name ($repo_full)..." >> "$LOG_FILE"

  releases=$(gh release list --repo "$repo_full" --limit 30 --json tagName,publishedAt,name 2>/dev/null \
    | jq --arg since "$LAST_RUN" '[.[] | select(.publishedAt >= $since)]' || echo "[]")
  release_count=$(echo "$releases" | jq 'length')

  prs=$(gh pr list --repo "$repo_full" \
    --search "is:pr is:merged merged:>=$LAST_RUN_DATE" \
    --json number,title,author,mergedAt,url --limit 100 2>/dev/null || echo "[]")
  pr_count=$(echo "$prs" | jq 'length')

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
  TABLE_ROWS+="<tr><td><a href=\"$repo_url\">$safe_name</a></td><td>$release_count</td><td>$pr_count</td><td>$commit_count</td><td><a href=\"$pr_url\">Merged PRs</a></td></tr>"$'\n'

  pr_items=$(echo "$prs" | jq -r '.[] | "<li><a href=\"\(.url)\">#\(.number)</a> \(.title | @html) <span>by @\(.author.login)</span></li>"')
  release_items=$(echo "$releases" | jq -r '.[] | "<li><strong>\(.tagName | @html)</strong> \(.name // "" | @html) <span>\(.publishedAt)</span></li>"')
  commit_items=$(printf '%s\n' "$commits" | sed '/^$/d' | while IFS= read -r line; do printf '<li>%s</li>\n' "$(printf '%s' "$line" | html_escape)"; done)

  [ -z "$pr_items" ] && pr_items="<li class=\"muted\">No merged PRs in this window.</li>"
  [ -z "$release_items" ] && release_items="<li class=\"muted\">No releases in this window.</li>"
  [ -z "$commit_items" ] && commit_items="<li class=\"muted\">No commits found in the local mirror for this window.</li>"

  CARD_STATUS="Quiet"
  CARD_CLASS="quiet"
  CARD_BADGE="No activity"
  if [ "$release_count" -gt 0 ]; then
    CARD_STATUS="Shipped"
    CARD_CLASS="shipped"
    CARD_BADGE="Release"
  elif [ "$pr_count" -gt 0 ] || [ "$commit_count" -gt 0 ]; then
    CARD_STATUS="In motion"
    CARD_CLASS="active"
    CARD_BADGE="Changed"
  fi

  CARD_HTML="<article class=\"repo-card $CARD_CLASS\"><div class=\"card-top\"><div><a class=\"repo-name\" href=\"$repo_url\">$safe_name</a><div class=\"repo-subtitle\">$CARD_STATUS in this window</div></div><span class=\"badge\">$CARD_BADGE</span></div><div class=\"count-row\"><span><b>$release_count</b> releases</span><span><b>$pr_count</b> PRs</span><span><b>$commit_count</b> commits</span></div><div class=\"card-actions\"><a href=\"$pr_url\">Merged PRs</a><a href=\"$repo_url\">Repo</a></div><details><summary>Details</summary><div class=\"detail-stack\"><section><h3>Releases</h3><ul>$release_items</ul></section><section><h3>Merged PRs</h3><ul>$pr_items</ul></section><section><h3>Commits</h3><ul>$commit_items</ul></section></div></details></article>"$'\n'
  if [ "$release_count" -gt 0 ]; then
    BOARD_SHIPPED+="$CARD_HTML"
  elif [ "$pr_count" -gt 0 ] || [ "$commit_count" -gt 0 ]; then
    BOARD_IN_MOTION+="$CARD_HTML"
  else
    BOARD_QUIET+="$CARD_HTML"
  fi

  RAW_DATA+=$'\n=== REPO: '"$name"$' ===\n'
  RAW_DATA+="releases=$release_count merged_prs=$pr_count commits=$commit_count"$'\n'
  [ "$pr_count" -gt 0 ] && RAW_DATA+="PRs:"$'\n'"$(echo "$prs" | jq -r '.[] | "  - #\(.number) \(.title) by @\(.author.login)"')"$'\n'
  [ "$commit_count" -gt 0 ] && RAW_DATA+="Commits:"$'\n'"$commits"$'\n'
done

[ -z "$BOARD_SHIPPED" ] && BOARD_SHIPPED="<div class=\"empty-lane\">No releases in this window.</div>"
[ -z "$BOARD_IN_MOTION" ] && BOARD_IN_MOTION="<div class=\"empty-lane\">No merged PRs or commits in this window.</div>"
[ -z "$BOARD_QUIET" ] && BOARD_QUIET="<div class=\"empty-lane\">No quiet repos.</div>"

SUMMARY_HTML="<p class=\"muted\">Install an LLM CLI such as Claude to generate the plain-English narrative. The activity data below is still live from GitHub and the local mirrors.</p>"
if [ ! -x "$CODEX_BIN" ] && command -v codex >/dev/null 2>&1; then
  CODEX_BIN="$(command -v codex)"
fi

if [ -x "$CODEX_BIN" ]; then
  PROMPT="Write a concise daily executive engineering digest for Boundex covering $LAST_RUN to $NOW_ISO across $REPO_COUNT repos. The audience is business planning and external communications. Use plain text only: no Markdown headings, bold markers, bullets, or tables. Do not list every PR. Summarize concrete shipped work, fixes, and notable movement. Mention quiet repos briefly. Do not invent details. Source data:
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
  SUMMARY_HTML="<p class=\"muted\">Codex CLI was not found. The activity data below is still live from GitHub and the local mirrors.</p>"
fi

cat > "$REPORT.tmp" <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Boundex Repo Intelligence</title>
<style>
:root{--ink:#292724;--muted:#6f6960;--line:#ddd6c8;--paper:#f7f4ed;--panel:#fffefa;--lane:#ebe6dc;--accent:#b73f35;--gold:#d5a514;--good:#087b5a;--blue:#2f6f9f}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.5}
a{color:var(--accent);text-decoration:none;border-bottom:1px solid rgba(183,63,53,.3)}a:hover{border-bottom-color:var(--accent)}
main{max-width:1440px;margin:0 auto;padding:32px 24px 56px}
header{display:flex;justify-content:space-between;gap:24px;align-items:flex-end;margin-bottom:18px}
h1{margin:0;font-size:32px;line-height:1.05;letter-spacing:0}.meta{color:var(--muted);font-size:14px}.status{color:var(--good);font-weight:650}
.topbar{margin-bottom:18px}
.summary{background:var(--panel);border:1px solid var(--line);border-left:4px solid var(--gold);border-radius:8px;padding:18px}.summary h2,.board-title{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 10px}.summary p{margin:0;font-size:14px}
.board-wrap{overflow-x:auto;padding-bottom:12px}.board{display:grid;grid-template-columns:repeat(3,minmax(300px,1fr));gap:16px;min-width:980px}
.lane{background:var(--lane);border:1px solid var(--line);border-radius:8px;padding:12px;min-height:360px}.lane header{display:flex;align-items:center;justify-content:space-between;margin:0 0 12px}.lane h2{margin:0;font-size:15px}.lane-count{color:var(--muted);font-size:12px}
.repo-card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px;margin-bottom:12px;box-shadow:0 1px 0 rgba(41,39,36,.06)}.repo-card.shipped{border-top:4px solid var(--good)}.repo-card.active{border-top:4px solid var(--blue)}.repo-card.quiet{border-top:4px solid #aaa093}
.card-top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}.repo-name{font-weight:750;color:var(--ink);border-bottom:0}.repo-subtitle{color:var(--muted);font-size:12px;margin-top:2px}.badge{border-radius:999px;background:#f0ece4;color:var(--muted);font-size:11px;font-weight:700;padding:3px 8px;white-space:nowrap}.shipped .badge{background:#dff2eb;color:var(--good)}.active .badge{background:#e1edf5;color:var(--blue)}
.count-row{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:14px 0}.count-row span{background:#f5f1e8;border:1px solid #e7dfd0;border-radius:7px;padding:8px;font-size:12px;color:var(--muted)}.count-row b{display:block;color:var(--ink);font-size:18px}
.card-actions{display:flex;gap:8px;margin-bottom:10px}.card-actions a{background:#f5f1e8;border:1px solid #e7dfd0;border-radius:7px;padding:6px 9px;font-size:12px;color:var(--ink)}
details{border-top:1px solid var(--line);padding-top:8px}summary{cursor:pointer;color:var(--muted);font-size:13px}h3{font-size:11px;margin:12px 0 6px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}ul{margin:0;padding-left:18px}li{margin:5px 0;font-size:13px;overflow-wrap:anywhere}li span{color:var(--muted)}.muted{color:var(--muted)}.empty-lane{border:1px dashed #cfc5b5;border-radius:8px;color:var(--muted);padding:16px;text-align:center;background:rgba(255,255,255,.35);font-size:13px}
.reference{margin-top:20px}.reference table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:8px;overflow:hidden}.reference th,.reference td{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);font-size:13px}.reference th{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);background:#f3efe6}.reference tr:last-child td{border-bottom:0}
footer{margin-top:24px;color:var(--muted);font-size:12px}
@media(max-width:860px){main{padding:24px 14px 48px}header{display:block}h1{font-size:28px}.board{grid-template-columns:1fr;min-width:0}.board-wrap{overflow-x:visible}}
</style>
</head>
<body>
<main>
<header>
  <div>
    <h1>Boundex Repo Intelligence</h1>
  </div>
  <div class="meta"><span class="status">$SYNC_STATUS</span> · Updated $NOW_HUMAN</div>
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
        <header><h2>Shipped</h2><span class="lane-count">Releases</span></header>
        $BOARD_SHIPPED
      </section>
      <section class="lane">
        <header><h2>In motion</h2><span class="lane-count">PRs & commits</span></header>
        $BOARD_IN_MOTION
      </section>
      <section class="lane">
        <header><h2>Quiet</h2><span class="lane-count">No activity</span></header>
        $BOARD_QUIET
      </section>
    </div>
  </div>
</section>
<section class="reference">
  <h2 class="board-title">Activity Reference</h2>
  <table>
    <thead><tr><th>Repo</th><th>Releases</th><th>Merged PRs</th><th>Commits</th><th>Links</th></tr></thead>
    <tbody>
$TABLE_ROWS
    </tbody>
  </table>
</section>
<footer>Generated by daily-report.sh. The report is read-only and updates this same HTML file each run.</footer>
</main>
</body>
</html>
HTML

mv "$REPORT.tmp" "$REPORT"
cp "$REPORT" "$WORKSPACE/daily-reports/$TODAY.html"
echo "{\"last_run\": \"$NOW_ISO\"}" > "$STATE_FILE"
echo "Daily report completed at $(timestamp): $REPORT" >> "$LOG_FILE"
echo "========================================" >> "$LOG_FILE"
