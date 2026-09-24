# DeepSeek V4.1 Flash and GLM 5.3 Flash Comparison

Artifact root: `eval-results/ds41f-glm53f-comparison-20260923`.
Remote tools ran from ds4 commit `3d71849`; transferred result files passed SHA-256 verification.

## Performance

Three repetitions per model, exact-kernel mode, 128 generated tokens per frontier. Values are medians across repetitions.

### DeepSeek V4.1 Flash Q4

| Context | Prefill tok/s | Generation tok/s | First token ms |
|---:|---:|---:|---:|
| 2048 | 320.85 | 18.34 | 61.02 |
| 4096 | 308.42 | 18.15 | 61.33 |
| 8192 | 278.45 | 18.24 | 60.13 |
| 16384 | 458.47 | 18.18 | 59.48 |
| 32768 | 422.00 | 17.83 | 63.81 |
| 65536 | 338.22 | 17.40 | 63.98 |

### DeepSeek V4.1 Flash Uncensored Q4

| Context | Prefill tok/s | Generation tok/s | First token ms |
|---:|---:|---:|---:|
| 2048 | 319.07 | 18.41 | 62.48 |
| 4096 | 306.52 | 18.35 | 61.24 |
| 8192 | 277.44 | 18.31 | 61.74 |
| 16384 | 457.95 | 18.13 | 60.32 |
| 32768 | 421.06 | 17.91 | 65.10 |
| 65536 | 337.85 | 17.07 | 63.22 |

### GLM 5.3 Flash Q8_0

| Context | Prefill tok/s | Generation tok/s | First token ms |
|---:|---:|---:|---:|
| 2048 | 435.67 | 18.56 | 53.98 |
| 4096 | 357.04 | 18.51 | 54.65 |
| 8192 | 339.11 | 18.44 | 55.56 |
| 16384 | 306.08 | 18.35 | 55.23 |
| 32768 | 255.84 | 18.27 | 56.22 |
| 65536 | 192.42 | 18.05 | 56.19 |

### GLM 5.3 Flash Uncensored Q8_0

| Context | Prefill tok/s | Generation tok/s | First token ms |
|---:|---:|---:|---:|
| 2048 | 436.54 | 18.55 | 55.29 |
| 4096 | 357.28 | 18.52 | 54.82 |
| 8192 | 339.71 | 18.45 | 55.60 |
| 16384 | 306.55 | 18.39 | 55.12 |
| 32768 | 256.29 | 18.25 | 55.89 |
| 65536 | 192.73 | 18.06 | 55.80 |

## 92-case evaluation

Each trace contains all 92 cases. `ds4-eval` returns status 1 when any case fails or is incomplete; those are scored outcomes, while a complete trace and matching summary establish execution completion.

| Model | Passed | Failed | Incomplete | Total |
|---|---:|---:|---:|---:|
| DeepSeek V4.1 Flash Q4 | 81 | 6 | 5 | 92 |
| DeepSeek V4.1 Flash Uncensored Q4 | 77 | 7 | 8 | 92 |
| GLM 5.3 Flash Q8_0 | 68 | 8 | 16 | 92 |
| GLM 5.3 Flash Uncensored Q8_0 | 68 | 9 | 15 | 92 |

## Official continuation NLL

Within-family comparisons use the matching tokenizer family. DeepSeek uses the official Flash and legacy fixtures; GLM uses its official 100-case fixture.

| Fixture | Cases | Base average NLL | Uncensored average NLL | Uncensored minus base |
|---|---:|---:|---:|---:|
| DeepSeek Flash 0731 | 100 | 0.992729713 | 1.002247706 | 0.009517993 |
| DeepSeek legacy | 100 | 1.079000576 | 1.063620740 | -0.015379837 |
| GLM 5.3 Flash FP8 | 100 | 0.360947258 | 0.358533106 | -0.002414152 |

## Artifact notes

- Raw speed CSVs and logs are in `results/performance/`.
- Full evaluation traces, logs, and exit codes are in `results/quality/eval/`.
- NLL tables and comparisons are in `results/quality/`.
- The rebuilt current-source NLL scorer and its build record are in `results/quality/scorer-build/`.
- DeepSeek uses Q4 files and GLM uses Q8_0 files; interpret throughput within each family and quantization.
- In each comparison file, old is the base model and new is its uncensored counterpart.
- `results/RECOVERY_NOTE.md` records the first controller interruption and the score-aware continuation.
