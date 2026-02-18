#!/usr/bin/env python3
"""
Fetch perfcompare artifacts from GitHub Actions and analyze cross-run variance,
mirroring the logic in analyzeVariance.ts.

Usage:
    python3 analyze-variance.py <owner/repo> <branch>
    python3 analyze-variance.py <owner/repo> <branch> --workflow-run-ids id1 id2 ...

Requirements: gh CLI authenticated, Python 3.11+
"""

import argparse
import json
import math
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


# ── helpers ──────────────────────────────────────────────────────────────────

def gh(*args: str) -> dict | list:
    """Run `gh api` and return parsed JSON."""
    result = subprocess.run(
        ["gh", "api", "--paginate", *args],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def format_duration(seconds: float) -> str:
    """Mirror formatDuration from @codspeed/shared-utils (ms with 2 dp)."""
    ms = seconds * 1000
    if ms < 1:
        return f"{ms * 1000:.2f} µs"
    if ms < 1000:
        return f"{ms:.2f} ms"
    return f"{ms / 1000:.3f} s"


def stats(values: list[float]) -> dict:
    n = len(values)
    average = sum(values) / n
    variance = sum((v - average) ** 2 for v in values) / n
    std = math.sqrt(variance)
    cv = std / average if average != 0 else math.nan
    rng = max(values) - min(values)
    rc = rng / average if average != 0 else math.nan
    return {
        "average": format_duration(average),
        "std": format_duration(std),
        "cv": f"{cv * 100:.1f}%" if not math.isnan(cv) else "N/A",
        "range": format_duration(rng),
        "range_coeff": f"{rc * 100:.1f}%" if not math.isnan(rc) else "N/A",
        "_cv_raw": cv if not math.isnan(cv) else -1,
    }


# ── artifact fetching ─────────────────────────────────────────────────────────

def get_run_ids(repo: str, branch: str) -> list[int]:
    data = gh(f"/repos/{repo}/actions/workflows/perfcompare.yml/runs?per_page=100")
    runs = [r for r in data["workflow_runs"] if r["head_branch"] == branch and r["conclusion"] == "success"]
    if not runs:
        print(f"No successful perfcompare runs found on branch '{branch}'", file=sys.stderr)
        sys.exit(1)
    print(f"Found {len(runs)} successful run(s) on '{branch}'")
    return [r["id"] for r in runs]


def download_artifact(repo: str, artifact: dict, dest: Path) -> Path:
    """Download a zip artifact and return the extracted directory."""
    aid = artifact["id"]
    name = artifact["name"]
    zip_path = dest / f"{name}.zip"

    result = subprocess.run(
        ["gh", "api", f"/repos/{repo}/actions/artifacts/{aid}/zip",
         "--header", "Accept: application/vnd.github+json"],
        capture_output=True, check=True,
    )
    zip_path.write_bytes(result.stdout)

    out_dir = dest / name
    out_dir.mkdir(exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        zf.extractall(out_dir)
    return out_dir


def collect_jsons(repo: str, run_ids: list[int]) -> dict[str, list[dict]]:
    """
    Returns {bench_name: [hyperfine_result, ...]} where each entry is one
    workflow run's result dict (has "mean", "min", "times", etc.).
    """
    by_bench: dict[str, list[dict]] = {}

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for run_id in run_ids:
            artifacts = gh(f"/repos/{repo}/actions/runs/{run_id}/artifacts")["artifacts"]
            perf_artifacts = [a for a in artifacts if a["name"].startswith("perfcompare-")]
            if not perf_artifacts:
                print(f"  run {run_id}: no perfcompare artifact, skipping")
                continue

            for artifact in perf_artifacts:
                out_dir = download_artifact(repo, artifact, tmp_path)
                for json_file in out_dir.glob("*.json"):
                    bench_name = json_file.stem
                    data = json.loads(json_file.read_text())
                    result = data["results"][0]
                    by_bench.setdefault(bench_name, []).append(result)
                    print(f"  run {run_id}: loaded {bench_name} ({len(result['times'])} samples, mean={result['mean']*1000:.1f}ms)")

    return by_bench


# ── analysis ──────────────────────────────────────────────────────────────────

def analyze(by_bench: dict[str, list[dict]]) -> None:
    """
    Mirrors analyzeVariance.ts:
    - "MIN" pass: one value per run = hyperfine result["min"]   (≡ resultToValue / walltime.min)
    - "MEAN" pass: one value per run = hyperfine result["mean"] (≡ resultToMeanValue / walltime.mean)
    """
    for label, key in [("MIN", "min"), ("MEAN", "mean")]:
        rows = {}
        for bench, results in by_bench.items():
            values = [r[key] for r in results]
            if len(values) < 2:
                print(f"  {bench}: only {len(values)} run(s), skipping", file=sys.stderr)
                continue
            s = stats(values)
            rows[bench] = s

        if not rows:
            continue

        sorted_rows = sorted(rows.items(), key=lambda x: -x[1]["_cv_raw"])

        print(f"\n=== Variance using walltime {label} ({len(next(iter(by_bench.values()),'') or [])} runs) ===")
        col_w = max(len(b) for b in rows) + 2
        header = f"{'benchmark':<{col_w}}  {'average':>12}  {'std':>10}  {'cv':>7}  {'range':>12}  {'range%':>7}"
        print(header)
        print("-" * len(header))
        for bench, s in sorted_rows:
            print(
                f"{bench:<{col_w}}  {s['average']:>12}  {s['std']:>10}  {s['cv']:>7}"
                f"  {s['range']:>12}  {s['range_coeff']:>7}"
            )


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    p = argparse.ArgumentParser(description="Analyze cross-run variance from perfcompare artifacts")
    p.add_argument("repo", help="owner/repo")
    p.add_argument("branch", help="branch name")
    p.add_argument("--workflow-run-ids", nargs="+", type=int,
                   help="explicit run IDs to use instead of fetching from branch")
    args = p.parse_args()

    run_ids = args.workflow_run_ids or get_run_ids(args.repo, args.branch)
    print(f"Using {len(run_ids)} run(s): {run_ids}")

    by_bench = collect_jsons(args.repo, run_ids)
    if not by_bench:
        print("No results collected.", file=sys.stderr)
        sys.exit(1)

    n_runs = len(next(iter(by_bench.values())))
    print(f"\nCollected {n_runs} run(s) across {len(by_bench)} benchmark(s)")
    analyze(by_bench)


if __name__ == "__main__":
    main()
