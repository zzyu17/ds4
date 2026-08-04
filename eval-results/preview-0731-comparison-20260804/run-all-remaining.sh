#!/bin/zsh

set -u

repo=/Users/bobo/.ollama/ds4
results="$repo/eval-results/three-model-0731-20260804"
controller_log="$results/controller.log"
non_model=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2.gguf
imatrix_model=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf
model_0731=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix-0731/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf
prompt=/tmp/ds4-three-model-bench-prompt-20260804.txt

cd "$repo" || exit 90

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$controller_log"
}

fail() {
    log "FAILED $*"
    printf '%s\n' "$*" > "$results/RUN_FAILED"
    rm -f "$prompt"
    exit 1
}

run_eval() {
    name=$1
    model=$2
    log "START eval $name"
    ./ds4-eval \
        -m "$model" \
        --quality \
        --think \
        --plain \
        --tokens 16000 \
        --temp 0 \
        --seed 1 \
        --trace "$results/$name-full.trace" \
        > "$results/$name-full.log" 2>&1
    code=$?
    log "END eval $name exit=$code"
    grep -Eq 'ds4-eval: [0-9]+/92 passed' "$results/$name-full.log" || fail "eval $name lacks a complete 92-case summary"
}

run_score() {
    fixture=$1
    manifest=$2
    name=$3
    model=$4
    log "START score fixture=$fixture model=$name"
    ./gguf-tools/quality-testing/score_official \
        "$model" \
        "$manifest" \
        "$results/$fixture-$name-nll.tsv" \
        4096 \
        --quality \
        > "$results/$fixture-$name-nll.log" 2>&1 || fail "score fixture=$fixture model=$name"
    log "END score fixture=$fixture model=$name"
}

run_bench() {
    repetition=$1
    name=$2
    model=$3
    log "START bench repetition=$repetition model=$name"
    ./ds4-bench \
        -m "$model" \
        --quality \
        --prompt-file "$prompt" \
        --ctx-start 2048 \
        --ctx-max 65536 \
        --step-mul 2 \
        --gen-tokens 128 \
        --csv "$results/bench-r$repetition-$name.csv" \
        > "$results/bench-r$repetition-$name.log" 2>&1 || fail "bench repetition=$repetition model=$name"
    log "END bench repetition=$repetition model=$name"
}

rm -f "$results/RUN_COMPLETE" "$results/RUN_FAILED"
log "controller started pid=$$"

non_pid=$(cat "$results/preview-non-imatrix-full.pid") || fail "missing non-imatrix pid"
log "waiting for existing non-imatrix eval pid=$non_pid"
while kill -0 "$non_pid" 2>/dev/null; do
    sleep 30
done
grep -Eq 'ds4-eval: [0-9]+/92 passed' "$results/preview-non-imatrix-full.log" || fail "existing non-imatrix eval lacks a complete 92-case summary"
log "existing non-imatrix eval complete"

run_eval preview-imatrix "$imatrix_model"
run_eval 0731-imatrix "$model_0731"

for fixture in flash-0731 legacy; do
    if test "$fixture" = flash-0731; then
        manifest=gguf-tools/quality-testing/data/flash/manifest.tsv
    else
        manifest=gguf-tools/quality-testing/data/manifest.tsv
    fi
    run_score "$fixture" "$manifest" preview-non-imatrix "$non_model"
    run_score "$fixture" "$manifest" preview-imatrix "$imatrix_model"
    run_score "$fixture" "$manifest" 0731-imatrix "$model_0731"
    python3 gguf-tools/quality-testing/compare_scores.py \
        "$results/$fixture-preview-non-imatrix-nll.tsv" \
        "$results/$fixture-preview-imatrix-nll.tsv" \
        > "$results/$fixture-compare-preview-non-vs-imatrix.txt" 2>&1 || fail "compare $fixture preview non vs imatrix"
    python3 gguf-tools/quality-testing/compare_scores.py \
        "$results/$fixture-preview-non-imatrix-nll.tsv" \
        "$results/$fixture-0731-imatrix-nll.tsv" \
        > "$results/$fixture-compare-preview-non-vs-0731.txt" 2>&1 || fail "compare $fixture preview non vs 0731"
    python3 gguf-tools/quality-testing/compare_scores.py \
        "$results/$fixture-preview-imatrix-nll.tsv" \
        "$results/$fixture-0731-imatrix-nll.tsv" \
        > "$results/$fixture-compare-preview-imatrix-vs-0731.txt" 2>&1 || fail "compare $fixture preview imatrix vs 0731"
done

python3 -c "import random,string; random.seed(42); words=[''.join(random.choices(string.ascii_lowercase,k=random.randint(2,10))) for _ in range(100000)]; open('$prompt','w').write(' '.join(words))" || fail "create throughput prompt"

run_bench 1 preview-non-imatrix "$non_model"
run_bench 1 preview-imatrix "$imatrix_model"
run_bench 1 0731-imatrix "$model_0731"

run_bench 2 preview-imatrix "$imatrix_model"
run_bench 2 0731-imatrix "$model_0731"
run_bench 2 preview-non-imatrix "$non_model"

run_bench 3 0731-imatrix "$model_0731"
run_bench 3 preview-non-imatrix "$non_model"
run_bench 3 preview-imatrix "$imatrix_model"

rm -f "$prompt"
log "temporary throughput prompt removed"

log "START restore default server"
bin/ds4-server-start > "$results/server-restore.log" 2>&1 || fail "restore default server"
log "END restore default server"

date '+%Y-%m-%dT%H:%M:%S%z' > "$results/RUN_COMPLETE"
log "controller complete"

