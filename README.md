# synergy-rates

An unofficial JSON API for [Synergy](https://www.synergy.net.au)'s residential
electricity plan pricing (Western Australia / SWIS) — Synergy publishes no API
of their own, so this scrapes their public plan pages daily and serves the
result as versioned, CORS-enabled JSON.

**[Browse the current rates →](https://m-rk.github.io/synergy-rates/)**

**Unofficial.** Not affiliated with or endorsed by Synergy. No login, no
account access, no usage data involved — just the same numbers a browser sees
at synergy.net.au, scraped from the plain HTML of their public plan pages and
re-published as JSON.

## Why

Synergy's plan pricing (supply charge + per-kWh rates, including time-of-use
periods like Midday Saver's Peak/Off-Peak/Super-Off-Peak) is only published as
formatted web pages. There's no feed to point a cost-estimate dashboard,
Home Assistant automation, or spreadsheet at. This repo turns those pages into
JSON, kept current by a daily scrape, so anyone can query it without scraping
the site themselves.

## Data

Two ways to get it, same underlying data, both plain JSON with CORS enabled:

**GitHub Pages** (nicer URL, correct `Content-Type: application/json`):

```
https://m-rk.github.io/synergy-rates/data/plans.json
https://m-rk.github.io/synergy-rates/data/plans/midday-saver.json   # one plan by slug
```

**Raw file** (works even if Pages is ever down):

```
https://raw.githubusercontent.com/m-rk/synergy-rates/main/data/plans.json
```

[`index.html`](index.html) (served at the Pages root) renders the current
plans and lists per-plan URLs — open it in a browser rather than guessing
slugs.

Git history on [`data/plans.json`](data/plans.json) **is the changelog** —
every commit is either "no change" (skipped, nothing committed) or a real
rate/plan change, with a commit message naming which plan(s) changed.
`git log -p -- data/plans.json` shows the full history of rate changes over
time. The per-plan files under `data/plans/` are a convenience derived from
the same data — mirror the same commits, no separate history of their own.

### Schema

```jsonc
{
  "source": "https://www.synergy.net.au/Your-home/Energy-plans",
  "plans": [
    {
      "slug": "midday-saver",
      "name": "Synergy Midday Saver",
      "url": "https://www.synergy.net.au/Your-home/Energy-plans/Midday-Saver",
      "periods": [
        { "name": "Super Off Peak", "hours": "9am to 3pm" },
        { "name": "Peak", "hours": "3pm to 9pm" },
        { "name": "Off Peak", "hours": "9pm to 9am" }
      ],
      "charges": [
        {
          "item": "Supply charge",
          "raw": "132.7806 cents per day",
          "cents": 132.7806,
          "per": "day",
          "period": null,
          "hours": null
        },
        {
          "item": "Peak electricity charge",
          "raw": "55.3253 cents per unit",
          "cents": 55.3253,
          "per": "kWh",
          "period": "Peak",
          "hours": "3pm to 9pm"
        }
        // ...
      ]
    }
  ],
  "skipped": [
    { "slug": "green-energy-options", "url": "...", "reason": "no pricing table found" }
  ]
}
```

Notes:

- `cents` is cents including GST, matching Synergy's own "Price inc. GST" column.
- `per` is `"day"` (supply charge) or `"kWh"` (Synergy's own site says "per unit" —
  "unit" is standard AU billing terminology for kWh; both `raw` and normalized
  `cents`/`per` are kept so nothing is lost in translation).
- `period`/`hours` link a charge to a named time-of-use period where the item
  name makes that unambiguous (e.g. "Peak electricity charge" → the "Peak"
  period). This is a best-effort text match, not something Synergy's markup
  states explicitly — verify against `url` for anything cost-sensitive.
- Flat-rate and usage-tiered plans (e.g. Home Plan A1, Home Business K1) have
  no time-of-use `periods`, so their charges all have `period: null`.
- `skipped` lists plan-index links that had no `data-table` pricing block
  (currently just the informational "Green energy options" page).

## How it works

`scripts/scrape.py`:

1. Fetches the [plans index page](https://www.synergy.net.au/Your-home/Energy-plans)
   and extracts every `/Your-home/Energy-plans/<slug>` link, so new plans
   appear automatically without a code change.
2. Fetches each plan page and parses its `<table class="data-table">` of
   charges (this table is server-rendered, no JavaScript required).
3. Best-effort parses the free-text "N time periods that apply each day"
   block that precedes the table on time-of-use plans, and links each charge
   to a period by name.

## Running it yourself

```
python3 scripts/scrape.py            # writes data/plans.json
python3 scripts/scrape.py --out out.json
```

No dependencies beyond the Python 3 standard library.

## Why this doesn't run on a `schedule:` trigger

`www.synergy.net.au` sits behind Azure Front Door, and its WAF returns a flat
`403 Forbidden` to requests from GitHub-hosted runner IPs specifically —
confirmed by sending the exact same request (same URL, same User-Agent) from
a non-datacenter IP, where it succeeds every time. This isn't a User-Agent or
TLS-fingerprint thing (plain `urllib.request` works fine off a normal
connection); it's the datacenter/hosting ASN being blocked.

So `.github/workflows/update.yml` only has a `workflow_dispatch` trigger, kept
for convenience if you run it from a self-hosted runner — no `schedule:`.
To keep `data/plans.json` current yourself, run `deploy/run.sh` on a
recurring schedule from any host that isn't on a flagged datacenter IP range:

- **cron** (Linux) or **launchd** (macOS — see
  `deploy/com.m-rk.synergy-rates.plist.example`) invoking `deploy/run.sh`
  daily; it scrapes, and only commits + pushes when something actually
  changed.
- Or a **self-hosted** GitHub Actions runner on a non-datacenter IP, with a
  `schedule:` trigger added back to the workflow.

## Doctor

`deploy/doctor.sh` is a read-only health check for a self-hosted deployment —
run it any time you want to know "is this actually working right now?":

```
deploy/doctor.sh
```

It checks: Python is available, `synergy.net.au` is reachable (and identifies
the specific 403-from-a-blocked-IP failure mode if not), a live scrape
produces at least one plan, the git remote is reachable, the working tree is
clean, `deploy/run.sh` is executable, and whether a dead man's switch (below)
is configured at all. Exits `0` (all good), `1` (warnings only), or `2` (at
least one hard failure) — safe to wire into your own monitoring.

`deploy/run.sh` runs it automatically at the end of every invocation
(regardless of whether the scrape/push itself succeeded), so it doubles as a
daily self-check without a separate schedule. If `SYNERGY_RATES_DISCORD_WEBHOOK_URL`
is set, a non-clean result (warnings or failures — never a clean pass) gets
posted there as a compact report naming exactly which checks failed, as a
standard Discord incoming-webhook message (`{"content": "..."}`, capped under
Discord's 2,000-char limit, `@` neutralized since the message can embed
scraped page content). This is a detail channel, not the dead man's switch
itself — if the job never runs at all, nothing posts here either; that's what
the heartbeat below is for.

## Dead man's switch

A **daily** job that only commits when a rate actually changes has a real
failure mode: rates change rarely, so "nothing has been pushed in 3 weeks"
looks identical whether that's expected (no rate changes) or the scheduled
job silently died. Git history alone can't distinguish those.

`deploy/run.sh` supports an optional heartbeat for exactly this: set
`SYNERGY_RATES_HEARTBEAT_URL` in the environment it runs under, and it pings
that URL on every successful run (whether or not anything changed) and
`<url>/fail` if the run fails — the `<url>` / `<url>/fail` split matches
[healthchecks.io](https://healthchecks.io)'s convention (free tier is enough
for one daily check), but works with any endpoint that treats a bare `GET` as
"I'm alive" — including your own. Configure the check's expected period as
daily with a few hours of grace, and it'll alert you (email/push/whatever you
configure on that end) if a day goes by with no ping in either direction.
`deploy/doctor.sh` reports whether this is set up.

## Caveats

- This tracks the **standard published plan rates**, not any individual
  customer's actual contracted rate, concessions, or GST-exempt status.
- Synergy can restructure their page markup at any time; the scraper will
  then either silently return fewer plans (each missing one lands in
  `skipped`) or fail outright. Check `data/plans.json`'s `skipped` list, or
  run `deploy/doctor.sh`, if something looks stale.
- Not for billing-critical use — verify anything cost-sensitive against the
  `url` on the actual Synergy site.

## License

MIT — see [LICENSE](LICENSE). The scraped data itself belongs to Synergy;
this repo just re-publishes their own public pricing pages in a structured
form.
