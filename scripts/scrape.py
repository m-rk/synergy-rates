#!/usr/bin/env python3
"""Scrape Synergy's (WA electricity retailer) published energy plan pages
into a single structured data/plans.json.

Synergy publishes no API for this -- these are the plain server-rendered
HTML pages a browser gets at synergy.net.au. The plan index page lists
each plan's URL; each plan page has a `<table class="data-table">` of
charges (item name + "<cents> cents per <day|unit>") and, for time-of-use
plans, a free-text block naming each period and its hours (e.g.
"Super Off Peak (9am to 3pm)"). Rate-tier pages (K1) have no periods
block at all; informational pages (e.g. Green-energy-options) have
neither and are skipped.

Usage: scripts/scrape.py [--out data/plans.json]
"""
import argparse
import html
import json
import re
import sys
import urllib.request
from urllib.parse import urljoin

BASE = "https://www.synergy.net.au"
INDEX_URL = f"{BASE}/Your-home/Energy-plans"
USER_AGENT = (
    "Mozilla/5.0 (compatible; synergy-rates/1.0; "
    "+https://github.com/m-rk/synergy-rates)"
)


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", errors="replace")


def strip_tags(fragment: str) -> str:
    # Normalize common block/line boundaries to spaces before stripping
    # tags outright, so words either side of a tag don't get glued together.
    text = re.sub(r"<(br|/p|/li|/tr|/td|/div)\s*/?>", " ", fragment, flags=re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    return html.unescape(text)


def find_plan_slugs(index_html: str) -> list[str]:
    hrefs = re.findall(r'href="(/Your-home/Energy-plans/[^"#]+)', index_html)
    seen, slugs = set(), []
    for href in hrefs:
        slug = href.rsplit("/", 1)[-1]
        if slug and slug not in seen:
            seen.add(slug)
            slugs.append(slug)
    return slugs


def extract_name(page_html: str) -> str | None:
    m = re.search(r"<h1[^>]*>(.*?)</h1>", page_html, re.S)
    return strip_tags(m.group(1)).strip() if m else None


def extract_periods(page_html: str) -> list[dict]:
    """Best-effort parse of the "N time periods that apply each day" block
    that precedes the data-table on time-of-use plan pages. Matches
    "<Name> (<hours>)", e.g. "Off Peak (6am to 9am / 9pm to 11pm)"."""
    start = page_html.find("what-you-need-to-know")
    end = page_html.find('<table class="data-table">')
    if start == -1 or end == -1 or end <= start:
        return []
    text = strip_tags(page_html[start:end])
    periods, seen = [], set()
    for m in re.finditer(r"([A-Z][A-Za-z ]{2,30}?)\s*\(([0-9][^()]{2,80})\)", text):
        name, hours = m.group(1).strip(), m.group(2).strip()
        if name not in seen:
            seen.add(name)
            periods.append({"name": name, "hours": hours})
    return periods


def link_period(item: str, periods: list[dict]) -> dict:
    norm = lambda s: re.sub(r"[^a-z]", "", s.lower())
    item_norm = norm(item)
    for period in sorted(periods, key=lambda p: -len(p["name"])):
        if norm(period["name"]) in item_norm:
            return period
    return {"name": None, "hours": None}


def extract_charges(page_html: str, periods: list[dict]) -> list[dict] | None:
    m = re.search(r'<table class="data-table">(.*?)</table>', page_html, re.S)
    if not m:
        return None
    charges = []
    for row in re.finditer(r"<tr>(.*?)</tr>", m.group(1), re.S):
        cells = re.findall(r"<td>(.*?)</td>", row.group(1), re.S)
        if len(cells) != 2:
            continue  # header row uses <th>, not <td>
        item = strip_tags(cells[0]).strip()
        raw = strip_tags(cells[1]).strip()
        price_m = re.match(r"([\d.]+)\s*cents per (day|unit)", raw)
        if not price_m:
            continue
        cents, per = float(price_m.group(1)), price_m.group(2)
        period = link_period(item, periods) if per == "unit" else {"name": None, "hours": None}
        charges.append({
            "item": item,
            "raw": raw,
            "cents": cents,
            "per": "kWh" if per == "unit" else per,
            "period": period["name"],
            "hours": period["hours"],
        })
    return charges


def scrape() -> dict:
    index_html = fetch(INDEX_URL)
    plans, skipped = [], []
    for slug in find_plan_slugs(index_html):
        url = urljoin(BASE, f"/Your-home/Energy-plans/{slug}")
        page_html = fetch(url)
        periods = extract_periods(page_html)
        charges = extract_charges(page_html, periods)
        if not charges:
            skipped.append({"slug": slug.lower(), "url": url, "reason": "no pricing table found"})
            continue
        plans.append({
            "slug": slug.lower(),
            "name": extract_name(page_html) or slug,
            "url": url,
            "periods": periods,
            "charges": charges,
        })
    plans.sort(key=lambda p: p["slug"])
    skipped.sort(key=lambda s: s["slug"])
    return {"source": INDEX_URL, "plans": plans, "skipped": skipped}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="data/plans.json")
    args = parser.parse_args()

    data = scrape()
    if not data["plans"]:
        print("No plans scraped -- refusing to write an empty result.", file=sys.stderr)
        return 1

    with open(args.out, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"Wrote {len(data['plans'])} plan(s), skipped {len(data['skipped'])}, to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
