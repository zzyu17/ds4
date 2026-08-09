# DSpark comparison on Mac Studio (2026-08-09)

## Decision

DSpark does **not** qualify for default enablement on: preview-q4, preview-imatrix, model-0731. Quality passed, but the required speed improvement did not pass.

## Model summary

| Model | Baseline mean t/s | DSpark mean t/s | Median paired speedup | Faster rows | Exact pairs | Errors | Default gate |
|---|---:|---:|---:|---:|---:|---:|---|
| preview-q4 | 35.66 | 36.63 | -0.14% | 7/15 | 25/25 | 0 | FAIL |
| preview-imatrix | 35.59 | 35.31 | -3.52% | 6/15 | 25/25 | 0 | FAIL |
| model-0731 | 35.68 | 36.33 | +3.57% | 9/15 | 25/25 | 0 | FAIL |

## Per-prompt medians

| Model | Prompt | Baseline t/s | DSpark t/s | Paired speedup |
|---|---|---:|---:|---:|
| preview-q4 | hello | 35.26 | 34.79 | -1.42% |
| preview-q4 | redis | 35.59 | 36.87 | +3.43% |
| preview-q4 | math | 35.60 | 34.09 | -4.16% |
| preview-q4 | python_reverse | 36.13 | 36.06 | -0.14% |
| preview-q4 | c_add | 35.58 | 41.34 | +16.22% |
| preview-imatrix | hello | 35.21 | 28.95 | -17.95% |
| preview-imatrix | redis | 35.55 | 34.25 | -3.52% |
| preview-imatrix | math | 35.33 | 33.23 | -5.94% |
| preview-imatrix | python_reverse | 36.01 | 38.79 | +7.42% |
| preview-imatrix | c_add | 35.50 | 41.51 | +16.90% |
| model-0731 | hello | 35.87 | 35.59 | -0.36% |
| model-0731 | redis | 35.53 | 38.58 | +8.37% |
| model-0731 | math | 35.47 | 33.16 | -6.51% |
| model-0731 | python_reverse | 36.05 | 37.45 | +3.88% |
| model-0731 | c_add | 35.53 | 36.80 | +3.57% |

## Method and quality interpretation

The repository acceptance fixture ran five deterministic prompts at 64 tokens for three repetitions. It byte-compared baseline and DSpark output before emitting each result row. The 32-token acceptance and forced partial-accept fixtures added ten more exact pairs per model. All three verifier-depth tests passed and all recorded verifier error counts were zero.

NLL was not used: DSpark speculative verification leaves the target model authoritative, while ds4 `--quality` disables DSpark. Exact greedy output parity is therefore the direct quality/correctness comparison.

The default-enablement gate required both exact quality parity and at least +5% median paired generation throughput for each target. Prompt-level improvements do occur, but the mixed-workload medians determine the default.

Raw gate logs are under `compatibility/`; machine-readable summaries are under `benchmark/`.
