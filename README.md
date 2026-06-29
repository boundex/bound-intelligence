# Bound Intelligence

Daily repo-intelligence dashboard for Boundex.

The local scheduler runs `daily-report.sh`, syncs the tracked repos, and updates the static dashboard. The generated board is committed as `index.html` for deployment and kept as `repo-intelligence-report.html` for local use.

Tracked inputs are defined in `sync.sh` and `daily-report.sh`. The hosting repo is intentionally not included in that tracked repo list.

