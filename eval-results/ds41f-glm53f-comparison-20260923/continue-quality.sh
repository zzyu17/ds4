#!/usr/bin/env bash
set -Eeuo pipefail

HOST="bobo@100.108.196.57"
REMOTE_REPO="/Users/bobo/.ollama/ds4"
REMOTE_PREFIX="/tmp/ds41f-glm53f-comparison-20260923-quality-"
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

write_checksums() {
    python3 - "$1" <<'PY'
import hashlib
import os
import sys
stage = sys.argv[1]
items = [os.path.join(stage, "prompt-100k-seed42.txt")]
root = os.path.join(stage, "results")
for current, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        if name not in ("RUN_COMPLETE", "QUALITY_RESUME_FAILED"):
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

if [ "${1:-}" = "--remote" ]; then
    [ "$#" -eq 2 ] || { echo "usage: continue-quality.sh --remote STAGING_DIR" >&2; exit 2; }
    STAGE="$2"
    case "$STAGE" in /tmp/ds41f-glm53f-comparison-20260923-quality-*) ;; *) exit 2 ;; esac
    RESULTS="$STAGE/results"
    mkdir -p "$RESULTS/quality/eval" \
        "$RESULTS/quality/nll/deepseek_flash" \
        "$RESULTS/quality/nll/deepseek_legacy" \
        "$RESULTS/quality/nll/glm53_flash" \
        "$RESULTS/quality/comparisons" "$RESULTS/quality/scorer-build" "$RESULTS/recovery"
    REMOTE_LOG="$RESULTS/quality/resume-controller.log"
    log() {
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$REMOTE_LOG"
    }
    status() {
        printf '%s\n' "$1" > "$RESULTS/status.txt"
        log "STATUS $1"
    }
    fail() {
        local reason="$1"
        trap - ERR
        log "FAILED $reason"
        printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$reason" > "$RESULTS/QUALITY_RESUME_FAILED"
        printf '%s\n' failed > "$RESULTS/status.txt"
        write_checksums "$STAGE" || true
        exit 1
    }
    trap 'rc=$?; trap - ERR; log "UNEXPECTED_EXIT code=$rc line=$LINENO command=$BASH_COMMAND"; printf "%s unexpected exit code %s at line %s\n" "$(date "+%Y-%m-%dT%H:%M:%S%z")" "$rc" "$LINENO" > "$RESULTS/QUALITY_RESUME_FAILED"; printf "%s\n" failed > "$RESULTS/status.txt"; write_checksums "$STAGE" || true; exit "$rc"' ERR

    cd "$REMOTE_REPO"
    status "quality-resume-preflight"
    [ "$(git rev-parse --short HEAD)" = "3d71849" ] || fail "remote repo commit changed"
    [ -z "$(git status --porcelain)" ] || fail "remote worktree is dirty"
    for key in "${MODEL_KEYS[@]}"; do
        [ -f "$(model_path "$key")" ] || fail "missing model file for $key"
    done
    [ -f "$STAGE/prompt-100k-seed42.txt" ] || fail "missing frozen performance prompt in staging"
    for path in ds4-eval gguf-tools/quality-testing/score_official gguf-tools/quality-testing/compare_scores.py; do
        [ -e "$path" ] || fail "missing benchmark tool $path"
    done
    [ -s "$RESULTS/quality/eval/deepseek_v41_flash.log" ] || fail "missing completed initial evaluation log"
    [ -s "$RESULTS/quality/eval/deepseek_v41_flash.trace" ] || fail "missing completed initial evaluation trace"
    if [ -e "$RESULTS/RUN_FAILED" ]; then
        mv "$RESULTS/RUN_FAILED" "$RESULTS/RUN_FAILED_FIRST_ATTEMPT"
    fi
    rm -f "$RESULTS/RUN_COMPLETE"
    if [ -e "$RESULTS/QUALITY_RESUME_FAILED" ]; then
        mv "$RESULTS/QUALITY_RESUME_FAILED" "$RESULTS/QUALITY_RESUME_FAILED-$(date -u '+%Y%m%dT%H%M%SZ')"
    fi
    cat > "$RESULTS/RECOVERY_NOTE.md" <<'NOTE'
# Quality continuation

The initial controller completed all 12 performance runs and finished the 92-case evaluation for DeepSeek V4.1 Flash. It stopped because it treated `ds4-eval` exit status 1 as an execution failure. In ds4, exit status 1 is also the normal score result when a completed evaluation contains failed or incomplete cases. The initial trace records 81 passed, 6 failed, and 5 incomplete out of 92.

The continuation audits all 92 per-case trace records and the matching log summary, then records exit status 1 as a completed score. It reuses that first trace, runs the other three model evaluations, all six official NLL scoring runs, three within-family comparison reports, and a final process audit. The original failure marker and controller logs are retained for provenance.

The preexisting remote `score_official` binary was dated September 6, while the tested DeepSeek V4.1 GGUFs were dated September 18. That binary rejected the new model metadata before scoring. The continuation builds the current repository's scorer source against the already built runtime objects into this result directory, leaving the remote repo unchanged.
NOTE

    audit_eval() {
        python3 "$STAGE/audit-eval.py" "$1" "$2" "$3"
    }
    printf '1\n' > "$RESULTS/quality/eval/deepseek_v41_flash.exit-code"
    if ! audit_eval "$RESULTS/quality/eval/deepseek_v41_flash.log" \
        "$RESULTS/quality/eval/deepseek_v41_flash.trace" 1; then
        fail "initial DeepSeek evaluation is not a complete, internally consistent 92-case score"
    fi
    log "VALID reused evaluation model=deepseek_v41_flash score=81/92"

    run_eval() {
        local key="$1"
        local model="$2"
        local logfile="$RESULTS/quality/eval/$key.log"
        local trace="$RESULTS/quality/eval/$key.trace"
        local codefile="$RESULTS/quality/eval/$key.exit-code"
        if [ -s "$logfile" ] && [ -s "$trace" ] && [ -s "$codefile" ]; then
            if audit_eval "$logfile" "$trace" "$(cat "$codefile")" >/dev/null; then
                log "VALID reused evaluation model=$key"
                return
            fi
            mv "$logfile" "$logfile.previous-invalid"
            mv "$trace" "$trace.previous-invalid"
        fi
        status "quality-eval model=$key"
        log "START ds4-eval model=$key"
        local rc=0
        if ./ds4-eval -m "$model" --quality --think --plain \
            --tokens 16000 --temp 0 --seed 1 --trace "$trace" > "$logfile" 2>&1; then
            rc=0
        else
            rc=$?
        fi
        printf '%s\n' "$rc" > "$codefile"
        if ! audit_eval "$logfile" "$trace" "$rc"; then
            fail "ds4-eval failed to produce an auditable full score for $key (exit=$rc); inspect $logfile"
        fi
        score="$(grep -Eo 'ds4-eval: [0-9]+/92 passed, [0-9]+ failed, [0-9]+ incomplete' "$logfile" | tail -n 1)"
        log "END ds4-eval model=$key exit=$rc score=$score"
    }
    run_eval deepseek_v41_flash_uncensored "$(model_path deepseek_v41_flash_uncensored)"
    run_eval glm53_flash "$(model_path glm53_flash)"
    run_eval glm53_flash_uncensored "$(model_path glm53_flash_uncensored)"

    SCORE_BIN="$RESULTS/quality/scorer-build/score_official"
    BUILD_INFO="$RESULTS/quality/scorer-build/build-info.txt"
    if [ ! -x "$SCORE_BIN" ] || ! grep -Eq '^binary_sha256=[0-9a-f]{64}$' "$BUILD_INFO" 2>/dev/null; then
        status "quality-scorer-build"
        log "START building current score_official source into the result directory"
        if ! cc -O3 -g -mcpu=native -Wall -Wextra -std=c11 -I. \
            -o "$SCORE_BIN" gguf-tools/quality-testing/score_official.c \
            ds4.o ds4_image.o ds4_distributed.o ds4_tp.o ds4_ssd.o ds4_metal.o \
            ds4_layer_pack.o ds4_engram.o rax.o ds4_gpu_args.o \
            -lm -pthread -framework Foundation -framework Metal \
            > "$RESULTS/quality/scorer-build/build.log" 2>&1; then
            fail "could not build current score_official source; inspect scorer-build/build.log"
        fi
        python3 - "$SCORE_BIN" gguf-tools/quality-testing/score_official.c "$BUILD_INFO" \
            "$(git rev-parse --short HEAD)" "$(command -v cc)" <<'PY'
import hashlib
import pathlib
import sys
from datetime import datetime

binary = pathlib.Path(sys.argv[1])
source = pathlib.Path(sys.argv[2])
output = pathlib.Path(sys.argv[3])
commit = sys.argv[4]
compiler = sys.argv[5]

def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()

source_stat = source.stat()
temporary = output.with_suffix(".tmp")
temporary.write_text(
    "repo_commit=%s\ncompiler=%s\nsource=%s\nsource_bytes=%d\nsource_sha256=%s\n"
    "built_local=%s\nbinary_bytes=%d\nbinary_sha256=%s\n"
    % (
        commit,
        compiler,
        source,
        source_stat.st_size,
        digest(source),
        datetime.now().astimezone().isoformat(timespec="seconds"),
        binary.stat().st_size,
        digest(binary),
    )
)
temporary.replace(output)
PY
        log "END building current score_official source"
    else
        log "VALID reusing audited score_official artifact from a prior continuation attempt"
    fi

    validate_nll() {
        python3 - "$1" <<'PY'
import csv
import math
import sys
with open(sys.argv[1], newline="") as stream:
    rows = list(csv.DictReader(stream, delimiter="\t"))
if len(rows) != 100:
    raise SystemExit("expected 100 scored cases, got " + str(len(rows)))
if len({row.get("id") for row in rows}) != 100:
    raise SystemExit("duplicate or missing case ids")
for row in rows:
    value = float(row["avg_nll"])
    if not math.isfinite(value) or value < 0:
        raise SystemExit("invalid avg_nll for " + row.get("id", "unknown"))
PY
    }
    run_score() {
        local key="$1"
        local manifest="$2"
        local outfile="$3"
        local logfile="${outfile%.tsv}.log"
        if [ -s "$outfile" ] && validate_nll "$outfile"; then
            log "VALID reused score model=$key fixture=$(basename "$(dirname "$manifest")")"
            return
        fi
        if [ -e "$outfile" ]; then
            mv "$outfile" "$outfile.previous-invalid"
        fi
        if [ -s "$logfile" ]; then
            mv "$logfile" "$logfile.previous-attempt-$(date -u '+%Y%m%dT%H%M%SZ')"
        fi
        status "quality-nll model=$key fixture=$(basename "$(dirname "$manifest")")"
        log "START score_official model=$key fixture=$manifest"
        if ! "$SCORE_BIN" \
            "$(model_path "$key")" "$manifest" "$outfile" 4096 --quality \
            > "$logfile" 2>&1; then
            fail "score_official failed model=$key fixture=$manifest; inspect $logfile"
        fi
        if ! validate_nll "$outfile"; then
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
        if [ -s "$output" ] && grep -Eq '^cases[[:space:]]+100$' "$output"; then
            log "VALID reused comparison fixture=$fixture"
            return
        fi
        status "quality-compare fixture=$fixture"
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
    [ -z "$active_ds4" ] || fail "ds4 process remains after quality campaign: $active_ds4"
    printf '%s\n' "no ds4-eval, ds4-bench, ds4-server, or ds4-agent process remained" > "$RESULTS/final-process-audit.txt"
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/RUN_PHASE_QUALITY_COMPLETE"
    status complete
    log "Performance and quality phases completed after score-aware continuation"
    write_checksums "$STAGE"
    printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$RESULTS/RUN_COMPLETE"
    exit 0
fi

[ "${1:-}" = "" ] || { echo "usage: continue-quality.sh" >&2; exit 2; }
[ ! -e "$ROOT/RUN_COMPLETE" ] || { echo "campaign is already complete" >&2; exit 2; }
[ -s "$ROOT/results/quality/eval/deepseek_v41_flash.trace" ] || { echo "missing first completed eval" >&2; exit 2; }
[ -s "$ROOT/prompt-100k-seed42.txt" ] || { echo "missing frozen performance prompt" >&2; exit 2; }

LOCAL_LOG="$ROOT/quality-resume-controller.log"
local_log() {
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOCAL_LOG"
}
local_fail() {
    local reason="$1"
    local_log "FAILED $reason"
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$reason" > "$ROOT/QUALITY_RESUME_FAILED"
    exit 1
}

ATTEMPT_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
if [ -e "$ROOT/QUALITY_RESUME_FAILED" ]; then
    mv "$ROOT/QUALITY_RESUME_FAILED" "$ROOT/QUALITY_RESUME_FAILED-$ATTEMPT_ID"
fi
printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" >> "$ROOT/QUALITY_RESUME_STARTED"

python3 "$ROOT/audit-eval.py" \
    "$ROOT/results/quality/eval/deepseek_v41_flash.log" \
    "$ROOT/results/quality/eval/deepseek_v41_flash.trace" 1 \
    > "$ROOT/results/quality/eval/deepseek_v41_flash.audit.tsv" \
    || local_fail "first evaluation trace failed its 92-case audit"
printf '1\n' > "$ROOT/results/quality/eval/deepseek_v41_flash.exit-code"
python3 - "$ROOT" <<'PY' || local_fail "performance artifact matrix failed local preflight"
import csv
import pathlib
import sys
root = pathlib.Path(sys.argv[1]) / "results" / "performance"
models = ["deepseek_v41_flash", "deepseek_v41_flash_uncensored", "glm53_flash", "glm53_flash_uncensored"]
expected = [2048, 4096, 8192, 16384, 32768, 65536]
for model in models:
    for repetition in (1, 2, 3):
        path = root / ("bench-r%d-%s.csv" % (repetition, model))
        with path.open(newline="") as stream:
            rows = list(csv.DictReader(stream))
        if [int(row["ctx_tokens"]) for row in rows] != expected or any(int(row["gen_tokens"]) != 128 for row in rows):
            raise SystemExit("invalid performance file " + str(path))
PY
local_log "Verified 12 performance runs and the completed first-model evaluation"

REMOTE_INFO="$(ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s <<'REMOTE_PREFLIGHT'
set -euo pipefail
cd /Users/bobo/.ollama/ds4
printf 'host=%s\n' "$(hostname)"
printf 'commit=%s\n' "$(git rev-parse --short HEAD)"
printf 'worktree=%s\n' "$(if [ -z "$(git status --porcelain)" ]; then echo clean; else echo dirty; fi)"
printf 'remote_time=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
printf 'active_ds4_processes='
ps -axo pid,etime,comm | awk '$3 == "ds4-eval" || $3 == "ds4-bench" || $3 == "ds4-server" || $3 == "ds4-agent" {print $1 ":" $3}' | paste -sd, -
REMOTE_PREFLIGHT
)" || local_fail "remote preflight SSH failed"
printf '%s\n' "$REMOTE_INFO" > "$ROOT/quality-resume-preflight.txt"
printf '%s\n' "$REMOTE_INFO" | rg -q '^host=Bos-Mac-Studio\.local$' || local_fail "SSH target identity changed"
printf '%s\n' "$REMOTE_INFO" | rg -q '^commit=3d71849$' || local_fail "remote repo commit changed"
printf '%s\n' "$REMOTE_INFO" | rg -q '^worktree=clean$' || local_fail "remote worktree is not clean"
printf '%s\n' "$REMOTE_INFO" | rg -q '^active_ds4_processes=$' || local_fail "a ds4 process is still active on the remote host"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
REMOTE_STAGE="${REMOTE_PREFIX}${RUN_ID}"
ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_CREATE'
set -euo pipefail
case "$1" in /tmp/ds41f-glm53f-comparison-20260923-quality-*) ;; *) exit 2 ;; esac
mkdir -m 700 "$1"
REMOTE_CREATE
local_log "Created new scoped remote quality staging directory"
scp "${SSH_OPTS[@]}" -r \
    "$ROOT/results" "$ROOT/prompt-100k-seed42.txt" "$ROOT/audit-eval.py" \
    "$ROOT/continue-quality.sh" "$HOST:$REMOTE_STAGE/" >/dev/null \
    || local_fail "upload of recovery artifacts failed"

ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_LAUNCH'
set -euo pipefail
stage="$1"
nohup /bin/bash "$stage/continue-quality.sh" --remote "$stage" \
    > /dev/null 2>&1 < /dev/null &
printf '%s\n' "$!" > "$stage/runner.pid"
REMOTE_LAUNCH
local_log "Remote quality continuation started; the completed performance phase will not be repeated"

interval=300
last_state=""
while :; do
    state="$(ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" 2>/dev/null <<'REMOTE_STATUS' || true
set -euo pipefail
stage="$1"
if [ -f "$stage/results/RUN_COMPLETE" ]; then
    printf 'COMPLETE\n'
elif [ -f "$stage/results/QUALITY_RESUME_FAILED" ]; then
    printf 'FAILED\n'
else
    cat "$stage/results/status.txt" 2>/dev/null || printf 'starting\n'
fi
REMOTE_STATUS
)"
    if [ "$state" != "$last_state" ]; then
        [ -z "$state" ] || local_log "Remote state: $(printf '%s' "$state" | tr '\n' ' ')"
        last_state="$state"
    fi
    case "$state" in COMPLETE|FAILED) break ;; esac
    sleep "$interval"
    interval=$((interval * 2))
    [ "$interval" -le 3600 ] || interval=3600
done

local_log "Remote quality controller ended; transferring and verifying results"
if ! ssh "${SSH_OPTS[@]}" "$HOST" /usr/bin/tar -C "$REMOTE_STAGE" -cf - results \
    | tar -C "$ROOT" -xf -; then
    local_fail "quality result transfer failed; remote staging retained for recovery"
fi
scp "${SSH_OPTS[@]}" "$HOST:$REMOTE_STAGE/prompt-100k-seed42.txt" "$ROOT/prompt-100k-seed42.txt" >/dev/null \
    || local_fail "prompt transfer failed; remote staging retained for recovery"
scp "${SSH_OPTS[@]}" "$HOST:$REMOTE_STAGE/SHA256SUMS" "$ROOT/TRANSFER_SHA256SUMS" >/dev/null \
    || local_fail "checksum transfer failed; remote staging retained for recovery"
(
    cd "$ROOT"
    sha256sum -c TRANSFER_SHA256SUMS
) > "$ROOT/quality-transfer-verification.log" 2>&1 \
    || local_fail "quality result checksum verification failed; remote staging retained for recovery"
local_log "Quality results passed SHA-256 verification"

ssh "${SSH_OPTS[@]}" "$HOST" /bin/bash -s -- "$REMOTE_STAGE" <<'REMOTE_CLEAN'
set -euo pipefail
case "$1" in /tmp/ds41f-glm53f-comparison-20260923-quality-*) rm -rf -- "$1" ;; *) exit 2 ;; esac
REMOTE_CLEAN
local_log "Removed the scoped remote staging directory"

if [ "$state" = "FAILED" ]; then
    local_fail "quality continuation failed; partial quality outputs and first-attempt records are retained"
fi
if [ "$state" != "COMPLETE" ]; then
    local_fail "unexpected remote terminal state: $state"
fi

# tar extraction overlays transferred files but does not remove local files
# that disappeared when the remote worker archived old failed-attempt markers.
if [ -e "$ROOT/results/QUALITY_RESUME_FAILED" ]; then
    mv "$ROOT/results/QUALITY_RESUME_FAILED" \
        "$ROOT/results/QUALITY_RESUME_FAILED-LOCAL-STALE-$ATTEMPT_ID"
fi
if [ -e "$ROOT/results/RUN_FAILED" ]; then
    mv "$ROOT/results/RUN_FAILED" \
        "$ROOT/results/RUN_FAILED-LOCAL-STALE-$ATTEMPT_ID"
fi
if [ -e "$ROOT/QUALITY_RESUME_FAILED" ]; then
    mv "$ROOT/QUALITY_RESUME_FAILED" "$ROOT/QUALITY_RESUME_FAILED-FINALIZER-$ATTEMPT_ID"
fi
if [ -e "$ROOT/RUN_FAILED" ]; then
    mv "$ROOT/RUN_FAILED" "$ROOT/RUN_FAILED_FIRST_ATTEMPT"
fi
cat >> "$ROOT/results/RECOVERY_NOTE.md" <<'NOTE'

## Local transfer finalization

The remote campaign finished, all transferred files passed the remote SHA-256 manifest, and the scoped staging directory was removed. The local transfer initially stopped because tar overlay extraction retained two obsolete local failure markers from earlier attempts. They are preserved with `LOCAL-STALE` names; the remote copies were archived by the successful controller. The report and local checksum manifest were then generated from the verified completed results.
NOTE
python3 "$ROOT/generate-report.py" "$ROOT" || local_fail "report generation failed"
printf '%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" > "$ROOT/RUN_COMPLETE"
local_log "Full benchmark outputs and report are ready; writing local checksum manifest"
python3 - "$ROOT" <<'PY'
import hashlib
import os
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
manifest = root / "LOCAL_SHA256SUMS"
excluded = {manifest, root / "local-checksum-verification.log"}
paths = []
for current, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(files):
        path = pathlib.Path(current) / name
        if path not in excluded:
            paths.append(path)
with manifest.open("w") as output:
    for path in sorted(paths):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        output.write("%s  %s\n" % (digest, path.relative_to(root)))
PY
(cd "$ROOT" && sha256sum -c LOCAL_SHA256SUMS) > "$ROOT/local-checksum-verification.log" 2>&1 \
    || local_fail "local final checksum verification failed"
