#!/usr/bin/env python3
"""Run every Grafana panel query against Prometheus and report empty panels.

    python3 scripts/check_dashboards.py [--prom http://127.0.0.1:9090] [--env staging]

Exit 1 if a panel has no data, unless it is listed in EXPECTED_EMPTY with a reason.
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

DASHBOARDS = Path(__file__).resolve().parent.parent / "monitoring" / "grafana" / "dashboards"

# Panels that are legitimately empty on a healthy system with no incident yet.
EXPECTED_EMPTY = {
    "Healer actions per minute by result": "healer not deployed until Phase 8 / no heal actions yet",
    "Alert timeline": "no alert has fired in the selected window",
    "DB errors seen by the API ($env)": "no DB errors since the replicas started",
}


def query(prom: str, expr: str) -> list:
    url = f"{prom}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
    with urllib.request.urlopen(url, timeout=10) as r:
        body = json.load(r)
    if body.get("status") != "success":
        raise RuntimeError(body)
    return body["data"]["result"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prom", default="http://127.0.0.1:9090")
    ap.add_argument("--env", default="staging")
    args = ap.parse_args()

    failures = 0
    for f in sorted(DASHBOARDS.glob("*.json")):
        board = json.loads(f.read_text())
        print(f"== {board['title']}  (env={args.env})")
        for panel in board["panels"]:
            targets = panel.get("targets", [])
            if not targets:
                continue
            series = 0
            for t in targets:
                expr = t["expr"].replace("$env", args.env)
                try:
                    series += len(query(args.prom, expr))
                except Exception as exc:  # noqa: BLE001 - report and continue
                    print(f"   ERROR  {panel['title']}: {exc}")
                    failures += 1
                    break
            title = panel["title"]
            if series:
                print(f"   ok     {title}  ({series} series)")
            elif title in EXPECTED_EMPTY:
                print(f"   empty  {title}  (expected: {EXPECTED_EMPTY[title]})")
            else:
                print(f"   EMPTY  {title}")
                failures += 1
    print(f"\n{'FAIL' if failures else 'PASS'}: {failures} panel(s) without data")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
