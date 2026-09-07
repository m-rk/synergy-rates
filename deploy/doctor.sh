#!/bin/bash
# Health check for a self-hosted synergy-rates deployment. Run this any
# time you want to know "is this actually working right now?" -- it
# doesn't change anything except, optionally, posting to Discord.
#
# Exit 0 = all good, 1 = warnings only, 2 = at least one hard failure.
#
# If SYNERGY_RATES_DISCORD_WEBHOOK_URL is set, any WARN/FAIL found gets
# posted there as a compact, notable-only report (a clean run posts
# nothing -- this isn't a "still fine" heartbeat, that's what
# SYNERGY_RATES_HEARTBEAT_URL / deploy/run.sh is for). Same shape as
# this project's other doctors: one Discord incoming-webhook message,
# {"content": "..."}, "@" neutralized since message text can embed
# scraped page content.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

status=0
issues=()
ok()   { echo "OK    $1"; }
warn() { echo "WARN  $1"; issues+=("WARN $1"); [ "$status" -lt 1 ] && status=1; }
fail() { echo "FAIL  $1"; issues+=("FAIL $1"); status=2; }

# --- 1. Python ---
if command -v python3 >/dev/null 2>&1; then
  ok "python3 found ($(python3 --version 2>&1))"
else
  fail "python3 not found on PATH"
fi

# --- 2. Reachability (and the specific WAF-block failure mode) ---
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  "https://www.synergy.net.au/Your-home/Energy-plans" || echo "000")
case "$code" in
  200) ok "synergy.net.au reachable (200)" ;;
  403) fail "synergy.net.au returned 403 -- this host's IP is likely on a blocked datacenter range (expected on GitHub-hosted runners; see README)" ;;
  000) fail "could not reach synergy.net.au (network/DNS/TLS failure)" ;;
  *)   warn "synergy.net.au returned unexpected HTTP $code" ;;
esac

# --- 3. Scrape sanity check ---
if [ "$code" = "200" ]; then
  tmp=$(mktemp)
  log=$(mktemp)
  if python3 scripts/scrape.py --out "$tmp" >"$log" 2>&1; then
    n=$(python3 -c "import json;print(len(json.load(open('$tmp'))['plans']))")
    skipped=$(python3 -c "import json;print(len(json.load(open('$tmp'))['skipped']))")
    if [ "$n" -ge 1 ]; then
      ok "scrape produced $n plan(s), $skipped skipped"
    else
      fail "scrape produced zero plans -- Synergy's page markup may have changed"
    fi
  else
    fail "scrape.py failed: $(tail -3 "$log")"
  fi
  rm -f "$tmp" "$log"
else
  warn "skipping scrape check -- site unreachable (see above)"
fi

# --- 4. Git state ---
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git remote get-url origin >/dev/null 2>&1; then
    if git ls-remote origin >/dev/null 2>&1; then
      ok "git remote 'origin' reachable"
    else
      fail "git remote 'origin' is configured but not reachable -- push will fail"
    fi
  else
    fail "no git remote named 'origin'"
  fi
  if [ -n "$(git status --porcelain -- data/)" ]; then
    warn "data/ has uncommitted changes"
  else
    ok "working tree clean for data/"
  fi
else
  fail "not inside a git work tree"
fi

# --- 5. Dead man's switch configured? ---
if [ -n "${SYNERGY_RATES_HEARTBEAT_URL:-}" ]; then
  ok "heartbeat configured (\$SYNERGY_RATES_HEARTBEAT_URL is set)"
else
  warn "no heartbeat configured -- set \$SYNERGY_RATES_HEARTBEAT_URL so something notices if the scheduled job silently stops running (see README)"
fi

# --- 6. run.sh executable ---
if [ -x deploy/run.sh ]; then
  ok "deploy/run.sh is executable"
else
  warn "deploy/run.sh is not executable -- chmod +x deploy/run.sh"
fi

echo
case "$status" in
  0) echo "All checks passed." ;;
  1) echo "Passed with warnings." ;;
  2) echo "One or more checks failed." ;;
esac

if [ "$status" -ne 0 ] && [ -n "${SYNERGY_RATES_DISCORD_WEBHOOK_URL:-}" ]; then
  emoji="🟡"; [ "$status" -eq 2 ] && emoji="🔴"
  message="$emoji synergy-rates doctor"
  for line in "${issues[@]}"; do
    message="$message"$'\n'"• $line"
  done
  payload=$(python3 -c "
import json, sys
message = sys.argv[1].replace('@', '@​')  # neutralize accidental mentions
print(json.dumps({'content': message[:1900]}))  # stay under Discord's 2000-char limit
" "$message")
  curl -fsS -m 10 -H "Content-Type: application/json" -d "$payload" \
    "$SYNERGY_RATES_DISCORD_WEBHOOK_URL" -o /dev/null || true
fi

exit "$status"
