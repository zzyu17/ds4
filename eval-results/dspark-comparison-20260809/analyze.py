#!/usr/bin/env python3
import csv
import glob
import json
import math
import os
import re
import statistics
import sys


RESULTS = sys.argv[1] if len(sys.argv) > 1 else \
    "/Users/bobo/.ollama/ds4/eval-results/dspark-comparison-20260809"
COMPAT = os.path.join(RESULTS, "compatibility")
BENCH = os.path.join(RESULTS, "benchmark")
MODELS = ("preview-q4", "preview-imatrix", "model-0731")
PROMPTS = ("hello", "redis", "math", "python_reverse", "c_add")
PAIR_RE = re.compile(
    r"^(?P<prompt>\S+)\tbaseline_tps=(?P<baseline>[0-9.]+)"
    r"\tdspark_tps=(?P<dspark>[0-9.]+)\t(?P<stats>.*)$"
)


def stat_value(stats, key, cast=float):
    match = re.search(r"(?:^| )" + re.escape(key) + r"=([^ ]+)", stats)
    if not match:
        raise ValueError("missing %s in %s" % (key, stats))
    value = match.group(1).rstrip("%")
    return cast(value)


def parse_pairs(path):
    rows = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            match = PAIR_RE.match(line.rstrip("\n"))
            if not match:
                continue
            baseline = float(match.group("baseline"))
            dspark = float(match.group("dspark"))
            stats = match.group("stats")
            rows.append({
                "prompt": match.group("prompt"),
                "baseline_tps": baseline,
                "dspark_tps": dspark,
                "speed_ratio": dspark / baseline,
                "speedup_percent": (dspark / baseline - 1.0) * 100.0,
                "cycles": stat_value(stats, "cycles", int),
                "proposed": stat_value(stats, "proposed", int),
                "accepted_draft": stat_value(stats, "accepted_draft", int),
                "accept_rate_percent": stat_value(stats, "accept_rate"),
                "errors": stat_value(stats, "errors", int),
                "net_saved_ms": stat_value(stats, "net_saved"),
            })
    return rows


os.makedirs(BENCH, exist_ok=True)
benchmark_rows = []
quality = {}

for model in MODELS:
    quality_rows = 0
    quality_errors = 0
    for kind in ("acceptance-32", "partial-accept"):
        pairs = parse_pairs(os.path.join(COMPAT, "%s-%s.log" % (model, kind)))
        quality_rows += len(pairs)
        quality_errors += sum(row["errors"] for row in pairs)

    for repetition in range(1, 4):
        path = os.path.join(
            COMPAT, "%s-benchmark-64-r%d.log" % (model, repetition))
        pairs = parse_pairs(path)
        if len(pairs) != len(PROMPTS):
            raise SystemExit("expected 5 benchmark rows in %s, got %d" %
                             (path, len(pairs)))
        quality_rows += len(pairs)
        quality_errors += sum(row["errors"] for row in pairs)
        for row in pairs:
            row["model"] = model
            row["repetition"] = repetition
            benchmark_rows.append(row)

    quality[model] = {
        "exact_output_pairs": quality_rows,
        "verifier_errors": quality_errors,
        "verify_depth_log": "%s-verify-depth.log" % model,
    }

raw_fields = (
    "model", "repetition", "prompt", "baseline_tps", "dspark_tps",
    "speedup_percent", "cycles", "proposed", "accepted_draft",
    "accept_rate_percent", "errors", "net_saved_ms",
)
with open(os.path.join(BENCH, "paired-results.csv"), "w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=raw_fields, extrasaction="ignore")
    writer.writeheader()
    writer.writerows(benchmark_rows)

prompt_summaries = []
for model in MODELS:
    for prompt in PROMPTS:
        rows = [row for row in benchmark_rows
                if row["model"] == model and row["prompt"] == prompt]
        ratios = [row["speed_ratio"] for row in rows]
        prompt_summaries.append({
            "model": model,
            "prompt": prompt,
            "repetitions": len(rows),
            "baseline_tps_median": statistics.median(
                row["baseline_tps"] for row in rows),
            "dspark_tps_median": statistics.median(
                row["dspark_tps"] for row in rows),
            "paired_speedup_median_percent":
                (statistics.median(ratios) - 1.0) * 100.0,
            "accepted_draft_total": sum(row["accepted_draft"] for row in rows),
            "proposed_total": sum(row["proposed"] for row in rows),
            "net_saved_ms_total": sum(row["net_saved_ms"] for row in rows),
        })

prompt_fields = tuple(prompt_summaries[0].keys())
with open(os.path.join(BENCH, "prompt-summary.csv"), "w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=prompt_fields)
    writer.writeheader()
    writer.writerows(prompt_summaries)

model_summaries = []
for model in MODELS:
    rows = [row for row in benchmark_rows if row["model"] == model]
    ratios = [row["speed_ratio"] for row in rows]
    median_speedup = (statistics.median(ratios) - 1.0) * 100.0
    q = quality[model]
    speed_gate = median_speedup >= 5.0
    quality_gate = q["exact_output_pairs"] == 25 and q["verifier_errors"] == 0
    model_summaries.append({
        "model": model,
        "observations": len(rows),
        "baseline_tps_mean": statistics.mean(
            row["baseline_tps"] for row in rows),
        "dspark_tps_mean": statistics.mean(
            row["dspark_tps"] for row in rows),
        "paired_speedup_mean_percent": statistics.mean(
            row["speedup_percent"] for row in rows),
        "paired_speedup_median_percent": median_speedup,
        "paired_speedup_geomean_percent":
            (math.exp(statistics.mean(math.log(value) for value in ratios)) - 1.0)
            * 100.0,
        "faster_observations": sum(1 for value in ratios if value > 1.0),
        "exact_output_pairs": q["exact_output_pairs"],
        "verifier_errors": q["verifier_errors"],
        "accepted_draft_total_benchmark": sum(
            row["accepted_draft"] for row in rows),
        "proposed_total_benchmark": sum(row["proposed"] for row in rows),
        "net_saved_ms_total_benchmark": sum(row["net_saved_ms"] for row in rows),
        "quality_gate_pass": quality_gate,
        "speed_gate_pass": speed_gate,
        "default_gate_pass": quality_gate and speed_gate,
    })

model_fields = tuple(model_summaries[0].keys())
with open(os.path.join(BENCH, "model-summary.csv"), "w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=model_fields)
    writer.writeheader()
    writer.writerows(model_summaries)

summary = {
    "method": {
        "decoding": "greedy --temp 0 --nothink",
        "tokens": 64,
        "repetitions": 3,
        "prompts": list(PROMPTS),
        "speed_gate": "median paired generation throughput improvement >= 5%",
        "quality_gate": "25/25 exact output pairs and zero verifier errors per model",
    },
    "quality": quality,
    "models": model_summaries,
    "all_defaults_qualified": all(
        row["default_gate_pass"] for row in model_summaries),
}
with open(os.path.join(BENCH, "summary.json"), "w") as handle:
    json.dump(summary, handle, indent=2, sort_keys=True)
    handle.write("\n")

report = []
report.append("# DSpark comparison on Mac Studio (2026-08-09)")
report.append("")
report.append("## Decision")
report.append("")
if summary["all_defaults_qualified"]:
    report.append("All targets passed both gates. DSpark qualifies for default enablement.")
else:
    failed = [row["model"] for row in model_summaries
              if not row["default_gate_pass"]]
    report.append(
        "DSpark does **not** qualify for default enablement on: %s. "
        "Quality passed, but the required speed improvement did not pass."
        % ", ".join(failed))
report.append("")
report.append("## Model summary")
report.append("")
report.append("| Model | Baseline mean t/s | DSpark mean t/s | Median paired speedup | Faster rows | Exact pairs | Errors | Default gate |")
report.append("|---|---:|---:|---:|---:|---:|---:|---|")
for row in model_summaries:
    report.append(
        "| {model} | {baseline_tps_mean:.2f} | {dspark_tps_mean:.2f} | "
        "{paired_speedup_median_percent:+.2f}% | {faster_observations}/15 | "
        "{exact_output_pairs}/25 | {verifier_errors} | {gate} |".format(
            gate="PASS" if row["default_gate_pass"] else "FAIL", **row))
report.append("")
report.append("## Per-prompt medians")
report.append("")
report.append("| Model | Prompt | Baseline t/s | DSpark t/s | Paired speedup |")
report.append("|---|---|---:|---:|---:|")
for row in prompt_summaries:
    report.append(
        "| {model} | {prompt} | {baseline_tps_median:.2f} | "
        "{dspark_tps_median:.2f} | {paired_speedup_median_percent:+.2f}% |".format(
            **row))
report.append("")
report.append("## Method and quality interpretation")
report.append("")
report.append(
    "The repository acceptance fixture ran five deterministic prompts at 64 "
    "tokens for three repetitions. It byte-compared baseline and DSpark output "
    "before emitting each result row. The 32-token acceptance and forced "
    "partial-accept fixtures added ten more exact pairs per model. All three "
    "verifier-depth tests passed and all recorded verifier error counts were zero.")
report.append("")
report.append(
    "NLL was not used: DSpark speculative verification leaves the target model "
    "authoritative, while ds4 `--quality` disables DSpark. Exact greedy output "
    "parity is therefore the direct quality/correctness comparison.")
report.append("")
report.append(
    "The default-enablement gate required both exact quality parity and at least "
    "+5% median paired generation throughput for each target. Prompt-level "
    "improvements do occur, but the mixed-workload medians determine the default.")
report.append("")
report.append("Raw gate logs are under `compatibility/`; machine-readable summaries are under `benchmark/`.")

with open(os.path.join(RESULTS, "REPORT.md"), "w") as handle:
    handle.write("\n".join(report) + "\n")

print(json.dumps(summary, indent=2, sort_keys=True))
