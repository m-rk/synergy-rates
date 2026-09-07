#!/bin/bash
# Run the scraper and push data/plans.json if it changed. Meant to be
# invoked by cron/launchd/systemd-timer from a machine on an ordinary
# (non-datacenter) IP -- see the note in .github/workflows/update.yml
# for why this can't just run on GitHub-hosted Actions runners.
#
# Optional dead man's switch: set SYNERGY_RATES_HEARTBEAT_URL to a
# healthchecks.io-style ping URL (or any URL a plain GET can hit) and
# this script pings it on success, and "<url>/fail" on failure -- so
# whatever's on the other end can tell you if the scheduled job stops
# running or starts failing, independent of whether Synergy's rates
# actually changed that day (a silent "no change" run must still count
# as a heartbeat). Run deploy/doctor.sh to check this is wired up.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

heartbeat() {
  [ -n "${SYNERGY_RATES_HEARTBEAT_URL:-}" ] || return 0
  curl -fsS -m 10 --retry 2 "$1" -o /dev/null || true
}

main() {
  python3 scripts/scrape.py

  if git diff --quiet -- data/plans.json; then
    echo "$(date -u +%FT%TZ) no change"
    return 0
  fi

  local old
  old=$(mktemp)
  trap 'rm -f "$old"' RETURN
  git show HEAD:data/plans.json > "$old" 2>/dev/null || echo '{"plans":[]}' > "$old"
  local summary
  summary=$(python3 scripts/diff_summary.py "$old" data/plans.json)

  git add data/plans.json
  git commit -m "Update rates: $summary"
  git push
  echo "$(date -u +%FT%TZ) pushed: $summary"
}

if main; then
  heartbeat "${SYNERGY_RATES_HEARTBEAT_URL:-}"
else
  status=$?
  echo "$(date -u +%FT%TZ) FAILED (exit $status)" >&2
  [ -n "${SYNERGY_RATES_HEARTBEAT_URL:-}" ] && heartbeat "${SYNERGY_RATES_HEARTBEAT_URL}/fail"
  exit "$status"
fi
