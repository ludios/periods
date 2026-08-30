#!/usr/bin/env python3
# Model-output: Claude Fable 5
"""Summarize a results.csv produced by run.sh.

Usage: summarize.py <results.csv>

For every scenario, prints the median latency of each side, the per-row cost
in microseconds, the latency change of side B relative to side A (positive =
B slower), and a noise figure: the worse of the two sides' (max - min) /
median latency across iterations.  A delta well inside the noise figure is
not a finding.
"""

import csv
import statistics
import sys
from collections import defaultdict

# Rows modified per transaction, used to convert txn latency to per-row cost.
ROWS_PER_TXN_SUFFIX = ("batch1k", 1000)


def rows_per_txn(scenario):
    """How many rows one transaction of this scenario modifies."""
    if scenario.endswith(ROWS_PER_TXN_SUFFIX[0]):
        return ROWS_PER_TXN_SUFFIX[1]
    return 1


def load(path):
    """Read results.csv.

    Returns (scenario order as first seen, {scenario: {side: [latency_ms]}},
    {side: label}).
    """
    order = []
    lat = defaultdict(lambda: defaultdict(list))
    labels = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            scenario = row["scenario"]
            if scenario not in order:
                order.append(scenario)
            lat[scenario][row["side"]].append(float(row["latency_ms"]))
            labels[row["side"]] = row["label"]
    if not order:
        raise SystemExit(f"no data rows in {path}")
    return order, lat, labels


def spread_pct(values):
    """(max - min) / median of a latency series, as a percentage."""
    med = statistics.median(values)
    if med == 0:
        return 0.0
    return (max(values) - min(values)) / med * 100.0


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    order, lat, labels = load(sys.argv[1])
    a_name = labels.get("A", "A")
    b_name = labels.get("B", "B")

    print(f"median latency per transaction, {a_name} (A) vs {b_name} (B); "
          f"positive delta = B slower")
    header = (f"{'scenario':<18} {'rows':>5} {'A ms':>10} {'B ms':>10} "
              f"{'A us/row':>10} {'B us/row':>10} {'delta':>8} {'noise':>7}")
    print(header)
    print("-" * len(header))
    for scenario in order:
        sides = lat[scenario]
        if "A" not in sides or "B" not in sides:
            print(f"{scenario:<18} missing a side, skipped")
            continue
        a = statistics.median(sides["A"])
        b = statistics.median(sides["B"])
        rows = rows_per_txn(scenario)
        delta = (b - a) / a * 100.0
        noise = max(spread_pct(sides["A"]), spread_pct(sides["B"]))
        print(f"{scenario:<18} {rows:>5} {a:>10.3f} {b:>10.3f} "
              f"{a / rows * 1000:>10.1f} {b / rows * 1000:>10.1f} "
              f"{delta:>+7.1f}% {noise:>6.1f}%")


if __name__ == "__main__":
    main()
