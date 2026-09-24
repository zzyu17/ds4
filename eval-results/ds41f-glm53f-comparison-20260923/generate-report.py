#!/usr/bin/env python3
"""Generate the campaign report from the frozen artifacts."""

import csv
import math
import pathlib
import statistics
import subprocess
import sys


MODELS = [
    ("deepseek_v41_flash", "DeepSeek V4.1 Flash Q4"),
    ("deepseek_v41_flash_uncensored", "DeepSeek V4.1 Flash Uncensored Q4"),
    ("glm53_flash", "GLM 5.3 Flash Q8_0"),
    ("glm53_flash_uncensored", "GLM 5.3 Flash Uncensored Q8_0"),
]
FRONTIERS = [2048, 4096, 8192, 16384, 32768, 65536]


def eval_counts(root, key):
    base = root / "results" / "quality" / "eval" / key
    code = int(base.with_suffix(".exit-code").read_text().strip())
    output = subprocess.run(
        [sys.executable, str(root / "audit-eval.py"), str(base.with_suffix(".log")), str(base.with_suffix(".trace")), str(code)],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()
    return tuple(map(int, output.split("\t")))


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate-report.py ARTIFACT_ROOT")
    root = pathlib.Path(sys.argv[1]).resolve()
    results = root / "results"
    lines = [
        "# DeepSeek V4.1 Flash and GLM 5.3 Flash Comparison",
        "",
        "Artifact root: `eval-results/ds41f-glm53f-comparison-20260923`.",
        "Remote tools ran from ds4 commit `3d71849`; transferred result files passed SHA-256 verification.",
        "",
        "## Performance",
        "",
        "Three repetitions per model, exact-kernel mode, 128 generated tokens per frontier. Values are medians across repetitions.",
    ]
    for key, label in MODELS:
        lines.extend([
            "",
            "### " + label,
            "",
            "| Context | Prefill tok/s | Generation tok/s | First token ms |",
            "|---:|---:|---:|---:|",
        ])
        for frontier in FRONTIERS:
            rows = []
            for rep in (1, 2, 3):
                retry = results / "performance" / ("bench-r%d-%s-retry1.csv" % (rep, key))
                source = retry if retry.exists() else results / "performance" / ("bench-r%d-%s.csv" % (rep, key))
                with source.open(newline="") as stream:
                    rows.extend(row for row in csv.DictReader(stream) if int(row["ctx_tokens"]) == frontier)
            if len(rows) != 3:
                raise SystemExit("expected 3 valid rows for %s at %d, found %d" % (key, frontier, len(rows)))
            values = {}
            for field in ("prefill_tps", "gen_tps", "gen_first_ms"):
                parsed = [float(row[field]) for row in rows]
                if any(not math.isfinite(value) or value <= 0 for value in parsed):
                    raise SystemExit("invalid result for %s/%s" % (key, field))
                values[field] = statistics.median(parsed)
            lines.append("| %s | %.2f | %.2f | %.2f |" % (
                frontier, values["prefill_tps"], values["gen_tps"], values["gen_first_ms"]
            ))

    lines.extend([
        "",
        "## 92-case evaluation",
        "",
        "Each trace contains all 92 cases. `ds4-eval` returns status 1 when any case fails or is incomplete; those are scored outcomes, while a complete trace and matching summary establish execution completion.",
        "",
        "| Model | Passed | Failed | Incomplete | Total |",
        "|---|---:|---:|---:|---:|",
    ])
    for key, label in MODELS:
        passed, failed, incomplete, total = eval_counts(root, key)
        lines.append("| %s | %d | %d | %d | %d |" % (label, passed, failed, incomplete, total))

    lines.extend([
        "",
        "## Official continuation NLL",
        "",
        "Within-family comparisons use the matching tokenizer family. DeepSeek uses the official Flash and legacy fixtures; GLM uses its official 100-case fixture.",
        "",
        "| Fixture | Cases | Base average NLL | Uncensored average NLL | Uncensored minus base |",
        "|---|---:|---:|---:|---:|",
    ])
    comparisons = [
        ("DeepSeek Flash 0731", results / "quality" / "comparisons" / "deepseek_flash.txt"),
        ("DeepSeek legacy", results / "quality" / "comparisons" / "deepseek_legacy.txt"),
        ("GLM 5.3 Flash FP8", results / "quality" / "comparisons" / "glm53_flash.txt"),
    ]
    for label, path in comparisons:
        data = {}
        for line in path.read_text(errors="replace").splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                data[parts[0]] = parts[1]
        required = ("cases", "old_avg_nll", "new_avg_nll", "delta_new_minus_old")
        if any(name not in data for name in required) or data["cases"] != "100":
            raise SystemExit("comparison summary incomplete: " + str(path))
        lines.append("| %s | %s | %s | %s | %s |" % (
            label, data["cases"], data["old_avg_nll"], data["new_avg_nll"], data["delta_new_minus_old"]
        ))

    lines.extend([
        "",
        "## Artifact notes",
        "",
        "- Raw speed CSVs and logs are in `results/performance/`.",
        "- Full evaluation traces, logs, and exit codes are in `results/quality/eval/`.",
        "- NLL tables and comparisons are in `results/quality/`.",
        "- The rebuilt current-source NLL scorer and its build record are in `results/quality/scorer-build/`.",
        "- DeepSeek uses Q4 files and GLM uses Q8_0 files; interpret throughput within each family and quantization.",
        "- In each comparison file, old is the base model and new is its uncensored counterpart.",
        "- `results/RECOVERY_NOTE.md` records the first controller interruption and the score-aware continuation.",
    ])
    (root / "REPORT.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
