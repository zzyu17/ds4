#!/bin/bash
set -u

export LC_ALL=C
export LANG=C

repo=/Users/bobo/.ollama/ds4
results="$repo/eval-results/dspark-comparison-20260809"
compat="$results/compatibility"
controller="$compat/controller.log"

preview_q4=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2.gguf
preview_imatrix=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix.gguf
model_0731=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-Q4KExperts-imatrix-0731/DeepSeek-V4-Flash-Q4KExperts-F16HC-F16Compressor-F16Indexer-Q8Attn-Q8Shared-Q8Out-chat-v2-imatrix-0731.gguf
support_preview=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-DSpark/DeepSeek-V4-Flash-DSpark-support.gguf
support_0731=/Users/bobo/.ollama/models/source/DeepSeek-V4-Flash-DSpark/DeepSeek-V4-Flash-DSpark-support-0731.gguf

failures=0

stamp() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

log() {
    printf '%s %s\n' "$(stamp)" "$*" | tee -a "$controller"
}

run_gate() {
    local name=$1
    shift
    local logfile="$compat/$name.log"
    local code
    log "START $name"
    "$@" > "$logfile" 2>&1
    code=$?
    log "END $name exit=$code"
    if [ "$code" -ne 0 ]; then
        failures=$((failures + 1))
        printf '%s\texit=%s\n' "$name" "$code" >> "$compat/failures.tsv"
        tail -n 30 "$logfile" | sed 's/^/  /' | tee -a "$controller"
    fi
}

run_model() {
    local name=$1
    local model=$2
    local support=$3
    local rep

    run_gate "$name-verify-depth" env \
        DS4_TEST_MODEL="$model" \
        DS4_DSPARK_SUPPORT="$support" \
        make dspark-verify-depth

    run_gate "$name-acceptance-32" env \
        DS4_DSPARK_MODEL="$model" \
        DS4_DSPARK_SUPPORT="$support" \
        DS4_DSPARK_FIXTURE_TOKENS=32 \
        make dspark-acceptance

    rep=1
    while [ "$rep" -le 3 ]; do
        run_gate "$name-benchmark-64-r$rep" env \
            DS4_DSPARK_MODEL="$model" \
            DS4_DSPARK_SUPPORT="$support" \
            DS4_DSPARK_FIXTURE_TOKENS=64 \
            make dspark-acceptance
        rep=$((rep + 1))
    done

    run_gate "$name-partial-accept" env \
        DS4_DSPARK_MODEL="$model" \
        DS4_DSPARK_SUPPORT="$support" \
        DS4_DSPARK_FIXTURE_CONFIDENCE=0 \
        DS4_DSPARK_FIXTURE_TOKENS=8 \
        DS4_DSPARK_FIXTURE_REQUIRE_PARTIAL=1 \
        make dspark-acceptance
}

cd "$repo" || exit 90
rm -f "$compat/failures.tsv" "$compat/RUN_COMPLETE" "$compat/RUN_FAILED"
: > "$controller"
log "compatibility controller start pid=$$ commit=$(git rev-parse HEAD)"

run_model preview-q4 "$preview_q4" "$support_preview"
run_model preview-imatrix "$preview_imatrix" "$support_preview"
run_model model-0731 "$model_0731" "$support_0731"

if [ "$failures" -ne 0 ]; then
    printf '%s failures=%s\n' "$(stamp)" "$failures" > "$compat/RUN_FAILED"
    log "compatibility controller failed failures=$failures"
    exit 1
fi

printf '%s\n' "$(stamp)" > "$compat/RUN_COMPLETE"
log "compatibility controller complete"
