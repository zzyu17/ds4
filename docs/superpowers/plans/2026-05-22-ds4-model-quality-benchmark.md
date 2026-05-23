# DS4 Model Quality Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evaluate and compare the response quality of two DS4 V4 Flash GGUF models (imatrix vs non-imatrix) against each other and against official DeepSeek API results, using ds4's built-in evaluation tools.

**Architecture:** Run two complementary quality assessments on the remote Mac Studio (bobo@100.108.196.57):
1. **`ds4-eval`** — built-in correctness regression harness (GPQA Diamond / SuperGPQA / AIME 2025 / COMPSEC) — measures pass/fail accuracy
2. **`score_official`** — NLL scoring against official DeepSeek API continuations over 100 curated prompts — measures avg negative log likelihood (lower = better), first-token match %, and greedy longest common prefix

**Tech Stack:** ds4-eval (Metal backend), score_official (Metal backend), collect_official.py (Python), compare_scores.py (Python), SSH to remote Mac Studio M3 Ultra 512GB

## Time Estimate

| Task | Description | Est. Time |
|------|-------------|-----------|
| T1 | Build ds4-eval + score_official | ~1 min |
| T2 | ds4-eval on non-imatrix (92 questions, with thinking, plain mode) | ~90 min |
| T3 | ds4-eval on imatrix (same) | ~90 min |
| T4 | Collect official API continuations (100 × 24 tokens, DeepSeek Flash) | ~2 min |
| T5 | score_official NLL on both models (100 prompts × 24 tokens, no generation) | ~30s × 2 = 1 min |
| T6 | Compare with README reference numbers | ~2 min |
| T7 | ds4-bench throughput (6 frontiers × prefill+128gen, per model) | ~5 min × 2 = 10 min |
| | **Total** | **~3 hours** |

**Notes on ds4-eval time:** Each of the 92 embedded questions generates up to `--max-tokens 16000` tokens (default) with thinking mode enabled. Thinking is forced to close with 512 tokens remaining (`--hard-limit-reply-budget 512`), leaving a 512-token answer window. Most MCQs finish in ~200 tokens; harder AIME/COMPSEC cases use more. Estimate assumes ~20 t/s decode on M3 Ultra. For faster results, add `--nothink`. To run fewer questions, add `--questions N`.

---

### Task 1: Build evaluation tools on the remote Mac

**Files:**
- Modify: `$(REMOTE_REPO)/ds4` (recompile `ds4-eval`)
- Modify: `$(REMOTE_REPO)/gguf-tools/quality-testing/score_official` (compile quality-score)

**Prerequisites:** SSH access to bobo@100.108.196.57, repo synced at remote home directory.

- [ ] **Step 1: Build ds4-eval on remote**

```bash
ssh bobo@100.108.196.57 "cd ds4 && make ds4-eval"
```

Expected: Builds `./ds4-eval` binary.

- [ ] **Step 2: Build score_official on remote**

```bash
ssh bobo@100.108.196.57 "cd ds4 && make -C gguf-tools quality-score"
```

Expected: Builds `./gguf-tools/quality-testing/score_official` binary.

---

### Task 2: Run ds4-eval on the non-imatrix model

**Files:**
- Create: `$(REMOTE_REPO)/eval-results/non-imatrix-eval-trace.txt` (trace output)
- Create: `$(REMOTE_REPO)/eval-results/non-imatrix-eval-screen.log` (screen output)

The non-imatrix model: `/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2.gguf`

Short alias for command: `NON_IMATRIX="/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2.gguf"`

- [ ] **Step 1: Create output directory on remote**

```bash
ssh bobo@100.108.196.57 "mkdir -p ds4/eval-results"
```

- [ ] **Step 2: Run ds4-eval on non-imatrix model with trace**

Run from the `ds4/` directory on remote:

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./ds4-eval \
  -m \"$NON_IMATRIX\" \
  --quality \
  --think \
  --trace eval-results/non-imatrix-eval-trace.txt \
  --plain \
  2>&1 | tee eval-results/non-imatrix-eval-screen.log"
```

Use `--plain` to disable TTY UI for non-interactive SSH. Use `--quality` for exact kernels. Enable thinking mode (default).

Expected: Runs all embedded GPQA/SuperGPQA/AIME/COMPSEC cases, prints a score summary (e.g., "score 42/50  failed 3"), writes full trace.

---

### Task 3: Run ds4-eval on the imatrix model

**Files:**
- Create: `$(REMOTE_REPO)/eval-results/imatrix-eval-trace.txt`
- Create: `$(REMOTE_REPO)/eval-results/imatrix-eval-screen.log`

The imatrix model: `/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf`

Short alias: `IMATRIX="/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf"`

- [ ] **Step 1: Run ds4-eval on imatrix model**

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./ds4-eval \
  -m \"$IMATRIX\" \
  --quality \
  --think \
  --trace eval-results/imatrix-eval-trace.txt \
  --plain \
  2>&1 | tee eval-results/imatrix-eval-screen.log"
```

Same configuration as Task 2 for fair comparison.

- [ ] **Step 2: Compare ds4-eval results**

Compare the score summaries from both screen logs:

```bash
ssh bobo@100.108.196.57 "cd ds4 && \
  echo '=== Non-imatrix score ===' && \
  grep 'score' eval-results/non-imatrix-eval-screen.log && \
  echo '=== Imatrix score ===' && \
  grep 'score' eval-results/imatrix-eval-screen.log"
```

Report: total score (correct answers), failed count, and optionally per-case pass/fail breakdown from trace files.

---

### Task 4: Collect official DeepSeek API continuations for NLL scoring

**Cost estimate:**
- 100 prompts × ~20 token average input = ~2,000 input tokens
- 100 × 24 token output each (controlled by `--max-tokens 24`) = 2,400 output tokens
- DeepSeek V4 Flash API pricing: ~$0.01/1M input, ~$0.05/1M output
- Estimated total cost: **~$0.00014 (~0.01 cent)** — effectively free

**Prerequisites:**
- `DEEPSEEK_API_KEY` environment variable set on remote

- [ ] **Step 1: Run collect_official.py on remote**

```bash
ssh bobo@100.108.196.57 "cd ds4 && \
  DEEPSEEK_API_KEY='sk-...' python3 gguf-tools/quality-testing/collect_official.py \
    --prompts gguf-tools/quality-testing/prompts.jsonl \
    --out gguf-tools/quality-testing/data \
    --count 100 \
    --max-tokens 24"
```

Expected: Creates `gguf-tools/quality-testing/data/manifest.tsv`, plus `data/prompts/case_*.txt` and `data/continuations/case_*.txt`.

Note: The official responses are derived from an external API and are not tracked in git (per README). They are ephemeral and must be re-collected if wiped.

---

### Task 5: Run score_official on both models

**Files:**
- Create: `$(REMOTE_REPO)/eval-results/non-imatrix-nll.tsv`
- Create: `$(REMOTE_REPO)/eval-results/imatrix-nll.tsv`

- [ ] **Step 1: Score non-imatrix model against official continuations**

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./gguf-tools/quality-testing/score_official \
  \"$NON_IMATRIX\" \
  gguf-tools/quality-testing/data/manifest.tsv \
  eval-results/non-imatrix-nll.tsv \
  4096"
```

The last argument `4096` is the context window for scoring (matches README example).

- [ ] **Step 2: Score imatrix model against official continuations**

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./gguf-tools/quality-testing/score_official \
  \"$IMATRIX\" \
  gguf-tools/quality-testing/data/manifest.tsv \
  eval-results/imatrix-nll.tsv \
  4096"
```

- [ ] **Step 3: Compare the two NLL scores**

```bash
ssh bobo@100.108.196.57 "cd ds4 && python3 gguf-tools/quality-testing/compare_scores.py \
  eval-results/non-imatrix-nll.tsv \
  eval-results/imatrix-nll.tsv"
```

Expected output fields:
- `old_avg_nll` (non-imatrix) vs `new_avg_nll` (imatrix)
- `delta_new_minus_old` — negative means imatrix is better
- `relative_nll_change` — percentage improvement
- `case_wins_new_old_ties` — per-prompt NLL wins
- `first_token_matches_old_new` — first token match counts
- `avg_greedy_lcp_old_new` — average longest common prefix

---

### Task 6: Compare results with official numbers from README

- [ ] **Step 1: Read imatrix quality impact from gguf-tools/imatrix/README.md**

The imatrix README reports previous measurements:
```
old Q4 avg NLL:         0.177357819
Q4 imatrix avg NLL:     0.173895148
relative NLL change:   -1.95%
case wins:              54 imatrix / 46 old
```

- [ ] **Step 2: Compare our results with these reference numbers**

Check if the imatrix model's NLL improvement is consistent with the reference (-1.95%). Report any discrepancies.

---

### Task 7: Run ds4-bench for throughput comparison (optional)

**What ds4-bench measures:**

At each **context frontier** (e.g., 2048, 4096, 8192, ...):
1. Slice the prompt to exactly that many tokens
2. From the **previous frontier's cached KV state**, prefill only the **new tokens** (not cumulative) — each row measures a fresh prefill interval
3. Run `--gen-tokens` greedy decode (always 128, no sampling variance, skips EOS)
4. Snapshot save/restore time is excluded

**CSV output:**
```
ctx_tokens, prefill_tokens, prefill_tps, gen_tokens, gen_tps, kvcache_bytes
```

**Why run on both models:** The imatrix variant has importance-weighted quantization — certain tensors may compress differently. This confirms throughput is identical (expected) or if there's any degradation.

**Files:**
- Create: `$(REMOTE_REPO)/eval-results/non-imatrix-bench.csv`
- Create: `$(REMOTE_REPO)/eval-results/imatrix-bench.csv`

- [ ] **Step 1: Create a benchmark prompt**

Need ~70K tokens for up to 65536 context. Generate random text:

```bash
ssh bobo@100.108.196.57 "cd ds4 && python3 -c \"
import random, string
random.seed(42)
words = [''.join(random.choices(string.ascii_lowercase, k=random.randint(2,10))) for _ in range(100000)]
with open('/tmp/bench-prompt.txt', 'w') as f:
    f.write(' '.join(words))
\" && wc -c /tmp/bench-prompt.txt"
```

- [ ] **Step 2: Benchmark non-imatrix model**

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./ds4-bench \
  -m \"$NON_IMATRIX\" \
  --quality \
  --prompt-file /tmp/bench-prompt.txt \
  --ctx-start 2048 \
  --ctx-max 65536 \
  --step-mul 2 \
  --gen-tokens 128 \
  --csv eval-results/non-imatrix-bench.csv"
```

- [ ] **Step 3: Benchmark imatrix model**

```bash
ssh bobo@100.108.196.57 "cd ds4 && ./ds4-bench \
  -m \"$IMATRIX\" \
  --quality \
  --prompt-file /tmp/bench-prompt.txt \
  --ctx-start 2048 \
  --ctx-max 65536 \
  --step-mul 2 \
  --gen-tokens 128 \
  --csv eval-results/imatrix-bench.csv"
```

- [ ] **Step 4: Compare throughput**

```bash
ssh bobo@100.108.196.57 "cd ds4 && echo '=== Non-imatrix thruput ===' && cat eval-results/non-imatrix-bench.csv && echo && echo '=== Imatrix thruput ===' && cat eval-results/imatrix-bench.csv"
```

Look for `prefill_tps` and `gen_tps` differences at each frontier. If within ~1%, throughput is unaffected by imatrix.

---

## Summary Report Template

After all tasks, produce a report like:

```
=== ds4-eval Correctness ===
Non-imatrix:      XX/YY correct (ZZ.Z%)
Imatrix:          XX/YY correct (ZZ.Z%)
Delta:            +Z.Z% for imatrix

=== NLL vs Official (score_official) ===
Non-imatrix avg NLL:      X.XXXXX
Imatrix avg NLL:          X.XXXXX
Relative change:          Z.ZZ%
Case wins:                X imatrix / Y non-imatrix / Z ties

=== Throughput (ds4-bench) ===
[attach CSV comparisons]
```

---

## Autopilot Execution

If you select **Autopilot**, I will execute all 7 tasks sequentially in this session, with review checkpoints between groups of tasks:

1. **Checkpoint 1** (after Task 1): Confirm both `ds4-eval` and `score_official` built successfully on the remote Mac
2. **Checkpoint 2** (after Tasks 2-3): Show `ds4-eval` score summaries for both models side by side, ask for your approval before proceeding
3. **Checkpoint 3** (after Tasks 4-6): Show NLL comparison results, ask for your approval
4. **Checkpoint 4** (after Task 7): Show final combined report with all three metrics

Each checkpoint pauses execution and shows intermediate results so you can approve or redirect before the next phase begins.
