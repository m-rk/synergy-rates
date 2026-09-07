#!/usr/bin/env python3
"""Print a short comma-separated list of plan slugs whose data changed
between two plans.json snapshots. Used by the update workflow to write
a commit message that says *what* changed, not just "automated update"."""
import json
import sys


def main() -> int:
    old_path, new_path = sys.argv[1], sys.argv[2]
    with open(old_path) as f:
        old = json.load(f)
    with open(new_path) as f:
        new = json.load(f)

    old_by_slug = {p["slug"]: p for p in old.get("plans", [])}
    new_by_slug = {p["slug"]: p for p in new.get("plans", [])}

    changed = []
    for slug, plan in new_by_slug.items():
        if old_by_slug.get(slug) != plan:
            changed.append(slug)
    for slug in old_by_slug:
        if slug not in new_by_slug:
            changed.append(f"{slug} (removed)")

    print(", ".join(sorted(changed)) if changed else "plan list unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
