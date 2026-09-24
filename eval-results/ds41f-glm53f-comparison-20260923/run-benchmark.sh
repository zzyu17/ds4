#!/usr/bin/env bash
set -Eeuo pipefail

HOST="bobo@100.108.196.57"
REMOTE_REPO="/Users/bobo/.ollama/ds4"
TASK_PREFIX="/tmp/ds41f-glm53f-comparison-20260923-"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=20)
MODEL_KEYS=(deepseek_v41_flash deepseek_v41_flash_uncensored glm53_flash glm53_flash_uncensored)

model_path() {
    case "$1" in
        deepseek_v41_flash) printf '%s\n' "/Users/bobo/.ollama/models/source/DeepSeek-V4.1-Flash/DeepSeek-V4.1-Flash-Q4.gguf" ;;
        deepseek_v41_flash_uncensored) printf '%s\n' "/Users/bobo/.ollama/models/source/DeepSeek-V4.1-Flash-UNCENSORED-FP8/DeepSeek-V4.1-Flash-UNCENSORED-Q4.gguf" ;;
        glm53_flash) printf '%s\n' "/Users/bobo/.ollama/models/source/GLM-5.3-Flash-FP8/GLM-5.3-Flash-Q8_0.gguf" ;;
        glm53_flash_uncensored) printf '%s\n' "/Users/bobo/.ollama/models/source/GLM-5.3-Flash-Uncensored-FP8/GLM-5.3-Flash-Uncensored-Q8_0.gguf" ;;
        *) return 2 ;;
    esac
}

if [ "$#" -gt 0 ] && [ "$1" = "--remote" ]; then
    [ "$#" -eq 2 ] || { echo "usage: run-benchmark.sh --remote STAGING_DIR" >&2; exit 2; }
    STAGE="$2"
    RESULTS="$STAGE/results"
    mkdir -p "$RESULTS/performance" "$RESULTS/quality/eval" \
        "$RESULTS/quality/nll/deepseek_flash" \
        "$RESULTS/quality/nll/deepseek_legacy" \
        "$RESULTS/quality/nll/glm53_flash" \
        "$RESULTS/quality/comparisons"

    log() {
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$RESULTS/remote-controller.log"
    }
    status() {
        printf '%s\n' "$1" > "$RESULTS/status.txt"
        log "STATUS $1"
    }
    write_checksums() {
        python3 - "$STAGE" <<'PY'
import hashlib
import os
import sys
stage = sys.argv[1]
items = [os.path.join(stage, "prompt-100k-seed42.txt")]
root = os.path.join(stage, "results")
for current, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        if name not in ("RUN_COMPLETE", "RUN_FAILED"):
            items.append(os.path.join(current, name))
with open(os.path.join(stage, "SHA256SUMS"), "w") as output:
    for path in sorted(items):
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        output.write(digest.hexdigest() + "  " + os.path.relpath(path, stage) + "\n")
PY
    }
    fail() {
        local reason="$1"
        trap - ERR
        log "FAILED $reason"
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$reason" > "$RESULTS/RUN_FAILED"
        printf '%s\n' failed > "$RESULTS/status.txt"
        write_checksums || true
        exit 1
    }
    trap 'rc=$?; trap - ERR; log "UNEXPECTED_EXIT code=$rc line=$LINENO command=$BASH_COMMAND"; printf "%s unexpected exit code %s at line %s\n" "$(date "+%Y-%m-%dT%H:%M:%S%z")" "$rc" "$LINENO" > "$RESULTS/RUN_FAILED"; printf "%s\n" failed > "$RESULTS/status.txt"; write_checksums || true; exit "$rc"' ERR

    cd "$REMOTE_REPO"
    status "performance-preflight"
    test "$(git rev-parse --short HEAD)" = "3d71849" || fail "remote repo commit changed after preflight"
    test -z "$(git status --porcelain)" || fail "remote worktree is no longer clean"
    for key in "${MODEL_KEYS[@]}"; do
        test -f "$(model_path "$key")" || fail "missing model file for $key"
    done
    command -v python3 > "$RESULTS/remote-python-path.txt"
    python3 --version >> "$RESULTS/remote-python-path.txt" 2>&1
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/remote-started.txt"

    validate_bench_csv() {
        python3 - "$1" <<'PY'
import csv
import math
import sys
expected = [2048, 4096, 8192, 16384, 32768, 65536]
with open(sys.argv[1], newline="") as stream:
    rows = list(csv.DictReader(stream))
if [int(row["ctx_tokens"]) for row in rows] != expected:
    raise SystemExit("wrong frontier set or row count")
for row in rows:
    if int(row["gen_tokens"]) != 128:
        raise SystemExit("wrong generated token count")
    for name in ("prefill_tps", "gen_tps", "gen_first_ms"):
        value = float(row[name])
        if not math.isfinite(value) or value <= 0:
            raise SystemExit("invalid timing field: " + name)
PY
    }
    run_bench() {
        local rep="$1"
        local key="$2"
        local suffix="$3"
        local model="$4"
        local stem
        local csv
        local logfile
        local attempt="primary"
        stem="$(printf 'bench-r%s-%s%s' "$rep" "$key" "$suffix")"
        csv="$RESULTS/performance/$stem.csv"
        logfile="$RESULTS/performance/$stem.log"
        [ -z "$suffix" ] || attempt="retry1"
        status "performance repetition=$rep model=$key attempt=$attempt"
        log "START ds4-bench repetition=$rep model=$key attempt=$attempt"
        if ! ./ds4-bench -m "$model" --quality \
            --prompt-file "$STAGE/prompt-100k-seed42.txt" \
            --ctx-start 2048 --ctx-max 65536 --step-mul 2 --gen-tokens 128 \
            --csv "$csv" > "$logfile" 2>&1; then
            fail "ds4-bench failed repetition=$rep model=$key attempt=$attempt; inspect $logfile"
        fi
        if validate_bench_csv "$csv"; then
            log "VALID ds4-bench repetition=$rep model=$key attempt=$attempt"
        elif [ "$suffix" = "-retry1" ]; then
            fail "grouped retry remained invalid repetition=$rep model=$key"
        else
            printf '%s\t%s\n' "$rep" "$key" >> "$RESULTS/performance/invalid-runs.tsv"
            log "INVALID ds4-bench repetition=$rep model=$key; queued for grouped retry"
        fi
        log "END ds4-bench repetition=$rep model=$key attempt=$attempt"
    }
    for rep in 1 2 3; do
        for pos in 0 1 2 3; do
            idx=$(((rep - 1 + pos) % 4))
            key="${MODEL_KEYS[$idx]}"
            run_bench "$rep" "$key" "" "$(model_path "$key")"
        done
    done
    if [ -s "$RESULTS/performance/invalid-runs.tsv" ]; then
        status "performance-grouped-retries"
        while IFS=$'\t' read -r rep key; do
            run_bench "$rep" "$key" "-retry1" "$(model_path "$key")"
        done < "$RESULTS/performance/invalid-runs.tsv"
    fi
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/RUN_PHASE_SPEED_COMPLETE"

    run_eval() {
        local key="$1"
        local model="$2"
        local logfile="$RESULTS/quality/eval/$key.log"
        local trace="$RESULTS/quality/eval/$key.trace"
        status "quality-eval model=$key"
        log "START ds4-eval model=$key"
        local rc=0
        if ./ds4-eval -m "$model" --quality --think --plain \
            --tokens 16000 --temp 0 --seed 1 --trace "$trace" > "$logfile" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        printf '%s\n' "$rc" > "$RESULTS/quality/eval/$key.exit-code"
        if ! python3 "$STAGE/audit-eval.py" "$logfile" "$trace" "$rc"; then
            fail "ds4-eval did not produce an auditable full score for $key; inspect $logfile"
        fi
        log "END ds4-eval model=$key exit=$rc"
    }
    for key in "${MODEL_KEYS[@]}"; do
        run_eval "$key" "$(model_path "$key")"
    done

    run_score() {
        local key="$1"
        local manifest="$2"
        local outfile="$3"
        local logfile
        logfile="$(printf '%s' "$outfile" | sed 's/\.tsv$/.log/')"
        status "quality-nll model=$key fixture=$(basename "$(dirname "$manifest")")"
        log "START score_official model=$key fixture=$manifest"
        if ! ./gguf-tools/quality-testing/score_official \
            "$(model_path "$key")" "$manifest" "$outfile" 4096 --quality \
            > "$logfile" 2>&1; then
            fail "score_official failed model=$key fixture=$manifest; inspect $logfile"
        fi
        if ! python3 - "$outfile" <<'PY'
import csv
import math
import sys
with open(sys.argv[1], newline="") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))
if len(rows) != 100:
    raise SystemExit("expected 100 scored cases, got " + str(len(rows)))
for row in rows:
    value = float(row["avg_nll"])
    if not math.isfinite(value) or value < 0:
        raise SystemExit("invalid avg_nll for " + row.get("id", "unknown"))
PY
        then
            fail "score_official output failed the 100-case NLL audit: $outfile"
        fi
        log "END score_official model=$key fixture=$manifest"
    }
    for key in deepseek_v41_flash deepseek_v41_flash_uncensored; do
        run_score "$key" gguf-tools/quality-testing/data/flash/manifest.tsv \
            "$RESULTS/quality/nll/deepseek_flash/$key.tsv"
        run_score "$key" gguf-tools/quality-testing/data/manifest.tsv \
            "$RESULTS/quality/nll/deepseek_legacy/$key.tsv"
    done
    for key in glm53_flash glm53_flash_uncensored; do
        run_score "$key" gguf-tools/quality-testing/data/glm53-flash-openrouter-zai-fp8-100/manifest.tsv \
            "$RESULTS/quality/nll/glm53_flash/$key.tsv"
    done

    compare_pair() {
        local fixture="$1"
        local dir="$RESULTS/quality/nll/$fixture"
        local base="$2"
        local uncensored="$3"
        local output="$RESULTS/quality/comparisons/$fixture.txt"
        log "START compare_scores fixture=$fixture"
        if ! python3 gguf-tools/quality-testing/compare_scores.py \
            "$dir/$base.tsv" "$dir/$uncensored.tsv" > "$output" 2>&1; then
            fail "compare_scores failed for $fixture"
        fi
        grep -Eq '^cases[[:space:]]+100$' "$output" || fail "comparison lacks 100 cases for $fixture"
        log "END compare_scores fixture=$fixture"
    }
    compare_pair deepseek_flash deepseek_v41_flash deepseek_v41_flash_uncensored
    compare_pair deepseek_legacy deepseek_v41_flash deepseek_v41_flash_uncensored
    compare_pair glm53_flash glm53_flash glm53_flash_uncensored
    active_ds4="$(ps -axo pid,etime,comm | awk '$3 == "ds4-eval" || $3 == "ds4-bench" || $3 == "ds4-server" || $3 == "ds4-agent" {print $1 ":" $3}')"
    [ -z "$active_ds4" ] || fail "ds4 process remains after benchmark: $active_ds4"
    printf '%s\n' "no ds4-eval, ds4-bench, ds4-server, or ds4-agent process remained" > "$RESULTS/final-process-audit.txt"
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/RUN_PHASE_QUALITY_COMPLETE"
    status "complete"
    log "All performance and quality phases completed"
    write_checksums
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/RUN_COMPLETE"
    exit 0
fi

[ "$#" -eq 0 ] || { echo "usage: run-benchmark.sh" >&2; exit 2; }
if [ -e "$ROOT/RUN_STARTED" ]; then
    echo "A campaign already started in $ROOT; refusing to overwrite artifacts." >&2
    exit 2
fi
for path in "$ROOT"/* "$ROOT"/.[!.]*; do
    [ -e "$path" ] || continue
    case "$path" in
        "$ROOT/protocol.json"|"$ROOT/model-map.tsv"|"$ROOT/run-benchmark.sh") ;;
        *) echo "Unexpected existing artifact in $ROOT: $path" >&2; exit 2 ;;
    esac
done
printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$ROOT/RUN_STARTED"
LOCAL_LOG="$ROOT/controller.log"
local_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOCAL_LOG"
}
local_fail() {
    local reason="$1"
    local_log "FAILED $reason"
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$reason" > "$ROOT/RUN_FAILED"
    exit 1
}

REMOTE_INFO="$(ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s <<'REMOTE_PREFLIGHT'
set -euo pipefail
printf 'host=%s\n' "$(hostname)"
printf 'os=%s\n' "$(uname -srm)"
printf 'remote_time=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
cd /Users/bobo/.ollama/ds4
printf 'repo=%s\n' "$(git rev-parse --show-toplevel)"
printf 'commit=%s\n' "$(git rev-parse --short HEAD)"
printf 'worktree=%s\n' "$(if [ -z "$(git status --porcelain)" ]; then echo clean; else echo dirty; fi)"
printf 'python3=%s\n' "$(command -v python3)"
python3 --version
printf 'disk='
df -h /Users/bobo/.ollama | tail -n 1
printf 'active_ds4_processes='
ps -axo pid,etime,comm | awk '$3 == "ds4-eval" || $3 == "ds4-bench" || $3 == "ds4-server" || $3 == "ds4-agent" {print $1 ":" $3}' | paste -sd, -
REMOTE_PREFLIGHT
)" || local_fail "remote preflight SSH failed"
printf '%s\n' "$REMOTE_INFO" > "$ROOT/preflight.txt"
local_log "Remote preflight recorded"
printf '%s\n' "$REMOTE_INFO" | rg -q '^host=Bos-Mac-Studio\.local$' || local_fail "SSH target identity changed"
printf '%s\n' "$REMOTE_INFO" | rg -q '^commit=3d71849$' || local_fail "remote repo commit changed"
printf '%s\n' "$REMOTE_INFO" | rg -q '^worktree=clean$' || local_fail "remote worktree is not clean"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
REMOTE_STAGE="$TASK_PREFIX$RUN_ID"
ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_CREATE'
set -euo pipefail
case "$1" in /tmp/ds41f-glm53f-comparison-20260923-*) ;; *) exit 2 ;; esac
mkdir -m 700 "$1"
REMOTE_CREATE
local_log "Created scoped remote staging directory"
scp "${SSH_OPTS[@]}" "$ROOT/run-benchmark.sh" "$ROOT/audit-eval.py" "$HOST:$REMOTE_STAGE/" >/dev/null
ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_PROMPT'
set -euo pipefail
python3 - "$1/prompt-100k-seed42.txt" <<'PY'
import random
import string
import sys
random.seed(42)
words = [
    "".join(random.choices(string.ascii_lowercase, k=random.randint(2, 10)))
    for _ in range(100000)
]
with open(sys.argv[1], "w") as output:
    output.write(" ".join(words))
PY
REMOTE_PROMPT
scp "${SSH_OPTS[@]}" "$HOST:$REMOTE_STAGE/prompt-100k-seed42.txt" "$ROOT/prompt-100k-seed42.txt" >/dev/null
local_log "Saved deterministic benchmark prompt locally"

ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_LAUNCH'
set -euo pipefail
stage="$1"
nohup /bin/bash "$stage/run-benchmark.sh" --remote "$stage" \
    > /dev/null 2>&1 < /dev/null &
printf '%s\n' "$!" > "$stage/runner.pid"
REMOTE_LAUNCH
local_log "Remote controller started; it will continue directly from Performance into Quality"

interval=180
while :; do
    state="$(ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" 2>/dev/null <<'REMOTE_STATUS' || true
set -euo pipefail
stage="$1"
if [ -f "$stage/results/RUN_COMPLETE" ]; then
    printf 'COMPLETE\n'
elif [ -f "$stage/results/RUN_FAILED" ]; then
    printf 'FAILED\n'
else
    cat "$stage/results/status.txt" 2>/dev/null || printf 'starting\n'
fi
REMOTE_STATUS
)"
    [ -z "$state" ] || local_log "Remote state: $(printf '%s' "$state" | tr '\n' ' ')"
    case "$state" in COMPLETE|FAILED) break ;; esac
    sleep "$interval"
    interval=$((interval * 2))
    [ "$interval" -le 1800 ] || interval=1800
done

local_log "Remote controller ended; transferring artifacts"
mkdir -p "$ROOT/results"
if ! ssh "${SSH_OPTS[@]}" "$HOST" /usr/bin/tar -C "$REMOTE_STAGE" -cf - results \
    | tar -C "$ROOT" -xf -; then
    local_fail "result transfer failed; remote staging retained for recovery"
fi
scp "${SSH_OPTS[@]}" "$HOST:$REMOTE_STAGE/prompt-100k-seed42.txt" "$ROOT/prompt-100k-seed42.txt" >/dev/null \
    || local_fail "prompt transfer failed; remote staging retained for recovery"
scp "${SSH_OPTS[@]}" "$HOST:$REMOTE_STAGE/SHA256SUMS" "$ROOT/TRANSFER_SHA256SUMS" >/dev/null \
    || local_fail "checksum transfer failed; remote staging retained for recovery"
(
    cd "$ROOT"
    sha256sum -c TRANSFER_SHA256SUMS
) > "$ROOT/transfer-verification.log" 2>&1 || local_fail "transfer checksum verification failed; remote staging retained for recovery"
local_log "Transferred artifacts passed SHA-256 verification"

if [ "$state" = "FAILED" ] || [ -f "$ROOT/results/RUN_FAILED" ]; then
    ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_CLEAN'
set -euo pipefail
case "$1" in /tmp/ds41f-glm53f-comparison-20260923-*) rm -rf -- "$1" ;; *) exit 2 ;; esac
REMOTE_CLEAN
    local_fail "Remote benchmark failed; partial outputs were transferred and audited"
fi
ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_CLEAN'
set -euo pipefail
case "$1" in /tmp/ds41f-glm53f-comparison-20260923-*) rm -rf -- "$1" ;; *) exit 2 ;; esac
REMOTE_CLEAN
local_log "Removed the scoped remote staging directory"

python3 - "$ROOT" <<'PY'
import csv
import math
import pathlib
import re
import statistics
import sys
root = pathlib.Path(sys.argv[1])
results = root / "results"
models = [
    ("deepseek_v41_flash", "DeepSeek V4.1 Flash Q4"),
    ("deepseek_v41_flash_uncensored", "DeepSeek V4.1 Flash Uncensored Q4"),
    ("glm53_flash", "GLM 5.3 Flash Q8_0"),
    ("glm53_flash_uncensored", "GLM 5.3 Flash Uncensored Q8_0"),
]
frontiers = [2048, 4096, 8192, 16384, 32768, 65536]
lines = [
    "# DeepSeek V4.1 Flash and GLM 5.3 Flash Comparison",
    "",
    "Artifact root: eval-results/ds41f-glm53f-comparison-20260923",
    "Remote execution used ds4 tools at commit 3d71849; final artifacts were transferred here and checksum-verified.",
    "",
    "## Performance",
    "",
    "Three repetitions per model, exact-kernel mode, 128 generated tokens per frontier. Values are medians across repetitions.",
    "",
    "| Model | Context | Prefill tok/s | Generation tok/s | First token ms |",
    "|---|---:|---:|---:|---:|",
]
for key, label in models:
    for frontier in frontiers:
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
            if any(not math.isfinite(value) for value in parsed):
                raise SystemExit("non-finite result for %s/%s" % (key, field))
            values[field] = statistics.median(parsed)
        lines.append("| %s | %s | %.2f | %.2f | %.2f |" % (
            label, frontier, values["prefill_tps"], values["gen_tps"], values["gen_first_ms"]
        ))
lines.extend(["", "## 92-case evaluation", "", "| Model | Result |", "|---|---:|"])
for key, label in models:
    logfile = results / "quality" / "eval" / (key + ".log")
    matches = re.findall(r"ds4-eval:\s+\d+/92 passed", logfile.read_text(errors="replace"))
    if not matches:
        raise SystemExit("missing 92-case summary for " + key)
    lines.append("| %s | %s |" % (label, matches[-1]))
lines.extend([
    "",
    "## Official continuation NLL",
    "",
    "Within-family comparisons use the matching tokenizer family. DeepSeek uses the official Flash and legacy fixtures; GLM uses its official 100-case fixture.",
    "",
    "| Fixture | Cases | Base average NLL | Uncensored average NLL | Uncensored minus base |",
    "|---|---:|---:|---:|---:|",
])
for label, path in [
    ("DeepSeek Flash 0731", results / "quality" / "comparisons" / "deepseek_flash.txt"),
    ("DeepSeek legacy", results / "quality" / "comparisons" / "deepseek_legacy.txt"),
    ("GLM 5.3 Flash FP8", results / "quality" / "comparisons" / "glm53_flash.txt"),
]:
    data = {}
    for line in path.read_text(errors="replace").splitlines():
        parts = line.split("\t", 1)
        if len(parts) == 2:
            data[parts[0]] = parts[1]
    required = ("cases", "old_avg_nll", "new_avg_nll", "delta_new_minus_old")
    if any(name not in data for name in required):
        raise SystemExit("comparison summary incomplete: " + str(path))
    lines.append("| %s | %s | %s | %s | %s |" % (
        label, data["cases"], data["old_avg_nll"], data["new_avg_nll"], data["delta_new_minus_old"]
    ))
lines.extend([
    "",
    "## Artifact notes",
    "",
    "- Raw speed CSVs and logs are in results/performance/.",
    "- Full evaluation traces and logs are in results/quality/eval/.",
    "- NLL tables and comparisons are in results/quality/.",
    "- DeepSeek uses Q4 files and GLM uses Q8_0 files; interpret throughput within each family and quantization.",
    "- In each comparison file, old is the base model and new is its uncensored counterpart.",
])
(root / "REPORT.md").write_text("\n".join(lines) + "\n")
PY

python3 "$ROOT/generate-report.py" "$ROOT" || local_fail "final report generation failed"

printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$ROOT/RUN_COMPLETE"
local_log "Full benchmark complete; local report and checksum manifest written"
python3 - "$ROOT" <<'PY'
import hashlib
import os
import sys
root = sys.argv[1]
files = []
for current, dirs, names in os.walk(root):
    dirs.sort()
    for name in sorted(names):
        if name == "LOCAL_SHA256SUMS":
            continue
        path = os.path.join(current, name)
        digest = hashlib.sha256()
        with open(path, "rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        files.append((os.path.relpath(path, root), digest.hexdigest()))
with open(os.path.join(root, "LOCAL_SHA256SUMS"), "w") as output:
    for path, digest in files:
        output.write(digest + "  " + path + "\n")
PY
