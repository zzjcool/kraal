#!/usr/bin/env python3
"""Compare bench samples against a recorded baseline.

Read by `Scripts/bench.sh --assert`. Two jobs:

* `--record` writes the baseline (the minimum of the samples, per label).
* otherwise compare and exit 1 if any label regressed beyond `--factor`.

**Minimum, not mean.** Seven runs of the same 1-cell patch on an idle M1 Pro measured
1.00-1.64us (2026-10-26): a 1.64x spread from noise alone. Noise only ever makes a
measurement *slower*, so the minimum is the least contaminated estimate of the true
cost. A mean sits somewhere inside the noise band and would need a threshold so wide it
would miss real regressions.

Exit codes: 0 pass (or recorded), 1 regression, 2 usage or data problem.
"""

import argparse
import json
import sys


def load_samples(path):
    """Read the JSON lines the probe emits, keeping the minimum per label."""
    best = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    # A partial line can happen if a sample crashed; skipping it is
                    # better than aborting the whole comparison.
                    continue
                label = row.get("label")
                micros = row.get("us")
                if label is None or micros is None:
                    continue
                if label not in best or micros < best[label]:
                    best[label] = micros
    except OSError as error:
        print(f"cannot read samples {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error
    if not best:
        print(f"no measurements in {path}", file=sys.stderr)
        raise SystemExit(2)
    return best


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--factor", type=float, default=2.0)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()

    samples = load_samples(args.samples)

    if args.record:
        document = {
            "_note": "Minimum of several runs. Regenerate with "
                     "Scripts/bench.sh --assert --record on an idle machine.",
            "factor": args.factor,
            "labels": samples,
        }
        try:
            with open(args.baseline, "w", encoding="utf-8") as handle:
                json.dump(document, handle, indent=2, sort_keys=True)
                handle.write("\n")
        except OSError as error:
            print(f"cannot write {args.baseline}: {error}", file=sys.stderr)
            return 2
        print(f"recorded {len(samples)} labels to {args.baseline}")
        return 0

    try:
        with open(args.baseline, encoding="utf-8") as handle:
            baseline = json.load(handle)
    except OSError as error:
        print(f"cannot read baseline {args.baseline}: {error}", file=sys.stderr)
        print("run Scripts/bench.sh --assert --record once to create it",
              file=sys.stderr)
        return 2
    except ValueError as error:
        print(f"baseline {args.baseline} is not JSON: {error}", file=sys.stderr)
        return 2

    expected = baseline.get("labels") or {}
    if not expected:
        print(f"baseline {args.baseline} has no labels", file=sys.stderr)
        return 2

    failures = 0
    missing = 0
    for label in sorted(expected):
        base = expected[label]
        actual = samples.get(label)
        if actual is None:
            # A label that disappeared is itself a regression: whatever used to be
            # measured is no longer being measured, and silence would look like success.
            print(f"MISSING  {label}: measured before, not now")
            missing += 1
            continue
        ratio = actual / base if base else 0.0
        if ratio > args.factor:
            print(f"SLOWER   {label}: {actual:.3f}us vs {base:.3f}us "
                  f"({ratio:.2f}x, limit {args.factor:.1f}x)")
            failures += 1
        else:
            print(f"ok       {label}: {actual:.3f}us vs {base:.3f}us ({ratio:.2f}x)")

    extra = sorted(set(samples) - set(expected))
    for label in extra:
        print(f"NEW      {label}: {samples[label]:.3f}us (not in the baseline)")

    print()
    print(f"{len(expected) - failures - missing}/{len(expected)} within "
          f"{args.factor:.1f}x of the baseline")
    return 1 if failures or missing else 0


if __name__ == "__main__":
    sys.exit(main())
