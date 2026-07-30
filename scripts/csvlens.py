#!/usr/bin/env python3
"""Query a CSV and print the result to stdout. Read-only: never touches the input.

    csvlens.py FILE [--where EXPR] [--sort COL[:desc],...] [--cols A,B]
                    [--group COL,... [--agg COL:func,...]] [--limit N]

--where is a Python expression over the column names of one row, e.g.
    --where "cores == 64 and exec_ns > 5000"
Values are coerced to int/float where possible, so comparisons are numeric.

Stdlib only, on purpose: the apt pandas in /usr/lib/python3/dist-packages is
built against numpy 1.x and blows up against the pip numpy 2.x in ~/.local,
so anything importing pandas has to go through the venv. This doesn't.
"""

import argparse
import csv
import statistics
import sys

SAFE = {
    "__builtins__": {},
    "abs": abs,
    "min": min,
    "max": max,
    "len": len,
    "round": round,
    "int": int,
    "float": float,
    "str": str,
}


def coerce(v):
    for cast in (int, float):
        try:
            return cast(v)
        except (TypeError, ValueError):
            pass
    return v


def percentile(values, q):
    """Linear-interpolated percentile; statistics.quantiles needs n>=2."""
    xs = sorted(values)
    if not xs:
        return ""
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * q
    lo, hi = int(pos), min(int(pos) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


# Set from --precision right before a group/agg pass; outliers formats each
# value it lists the same way the top-level CSV writer would, since it's
# embedding numbers inside a single cell rather than a cell of its own.
PRECISION = 3


def format_num(v):
    if isinstance(v, float):
        s = f"{v:.{PRECISION}f}".rstrip("0").rstrip(".")
        return s if s else "0"
    return str(v)


def outliers(xs):
    """Tukey's fences: values more than 1.5*IQR outside the quartiles."""
    if len(xs) < 4:
        return ""
    q1, q3 = percentile(xs, 0.25), percentile(xs, 0.75)
    iqr = q3 - q1
    lo, hi = q1 - 1.5 * iqr, q3 + 1.5 * iqr
    return "|".join(format_num(v) for v in sorted(v for v in xs if v < lo or v > hi))


AGGS = {
    "count": len,
    "sum": sum,
    "mean": lambda xs: statistics.fmean(xs) if xs else "",
    "median": lambda xs: statistics.median(xs) if xs else "",
    "min": min,
    "max": max,
    "p50": lambda xs: percentile(xs, 0.50),
    "p95": lambda xs: percentile(xs, 0.95),
    "p99": lambda xs: percentile(xs, 0.99),
    "stdev": lambda xs: statistics.stdev(xs) if len(xs) > 1 else 0.0,
    "outliers": outliers,
}


def load(path):
    with open(path, newline="") as fh:
        reader = csv.DictReader(fh)
        return reader.fieldnames or [], [
            {k: coerce(v) for k, v in row.items()} for row in reader
        ]


def apply_where(rows, expr):
    code = compile(expr, "<--where>", "eval")
    out = []
    for row in rows:
        try:
            if eval(code, SAFE, row):
                out.append(row)
        except NameError as e:
            sys.exit(f"csvlens: unknown column in --where: {e}")
    return out


def apply_sort(rows, spec):
    """Stable sort, applied right-to-left so earlier keys win, which lets each
    key carry its own direction."""
    for key in reversed(spec.split(",")):
        name, _, direction = key.partition(":")
        name = name.strip()
        rows.sort(
            key=lambda r: (r.get(name) is None, r.get(name)),
            reverse=direction.strip() in ("desc", "d", "r"),
        )
    return rows


def numeric_cols(fields, rows, exclude=()):
    return [
        f
        for f in fields
        if f not in exclude and any(isinstance(r.get(f), (int, float)) for r in rows)
    ]


def apply_group(fields, rows, group_spec, agg_spec):
    keys = [k.strip() for k in group_spec.split(",")]
    buckets = {}
    for row in rows:
        buckets.setdefault(tuple(row.get(k) for k in keys), []).append(row)

    if agg_spec:
        pairs = []
        for item in agg_spec.split(","):
            col, _, func = item.partition(":")
            func = func.strip() or "mean"
            if func not in AGGS:
                sys.exit(f"csvlens: unknown agg '{func}'; pick from {', '.join(AGGS)}")
            pairs.append((col.strip(), func))
    else:
        # Sensible default: mean of every numeric column that isn't a group key.
        pairs = [(c, "mean") for c in numeric_cols(fields, rows, exclude=keys)]

    out_fields = keys + ["n"] + [f"{c}_{f}" for c, f in pairs]
    out_rows = []
    for kvals, bucket in buckets.items():
        rec = dict(zip(keys, kvals))
        rec["n"] = len(bucket)
        for col, func in pairs:
            vals = [r[col] for r in bucket if isinstance(r.get(col), (int, float))]
            rec[f"{col}_{func}"] = AGGS[func](vals) if vals else ""
        out_rows.append(rec)
    return out_fields, out_rows


def main():
    p = argparse.ArgumentParser(add_help=True)
    p.add_argument("file")
    p.add_argument("--where")
    p.add_argument("--sort")
    p.add_argument("--cols")
    p.add_argument("--group")
    p.add_argument("--agg")
    p.add_argument("--limit", type=int)
    p.add_argument("--precision", type=int, default=3)
    a = p.parse_args()

    global PRECISION
    PRECISION = a.precision

    fields, rows = load(a.file)

    if a.where:
        rows = apply_where(rows, a.where)
    if a.group:
        fields, rows = apply_group(fields, rows, a.group, a.agg)
        # Bucket order is first-appearance, which reads as random; order by the
        # group keys unless the caller asked for something else.
        a.sort = a.sort or a.group
    if a.sort:
        rows = apply_sort(rows, a.sort)
    if a.cols:
        want = [c.strip() for c in a.cols.split(",")]
        missing = [c for c in want if c not in fields]
        if missing:
            sys.exit(f"csvlens: no such column(s): {', '.join(missing)}")
        fields = want
    if a.limit:
        rows = rows[: a.limit]

    def fmt(v):
        return (
            f"{v:.{a.precision}f}".rstrip("0").rstrip(".")
            if isinstance(v, float)
            else v
        )

    w = csv.DictWriter(
        sys.stdout, fieldnames=fields, extrasaction="ignore", lineterminator="\n"
    )
    w.writeheader()
    for row in rows:
        w.writerow({k: fmt(row.get(k, "")) for k in fields})


if __name__ == "__main__":
    main()
