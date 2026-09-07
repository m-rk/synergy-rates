#!/bin/bash
# Run the scraper and push data/plans.json if it changed. Meant to be
# invoked by cron/launchd/systemd-timer from a machine on an ordinary
# (non-datacenter) IP -- see the note in .github/workflows/update.yml
# for why this can't just run on GitHub-hosted Actions runners.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

python3 scripts/scrape.py

if git diff --quiet -- data/plans.json; then
  echo "$(date -u +%FT%TZ) no change"
  exit 0
fi

old=$(mktemp)
trap 'rm -f "$old"' EXIT
git show HEAD:data/plans.json > "$old" 2>/dev/null || echo '{"plans":[]}' > "$old"
summary=$(python3 scripts/diff_summary.py "$old" data/plans.json)

git add data/plans.json
git commit -m "Update rates: $summary"
git push
echo "$(date -u +%FT%TZ) pushed: $summary"
