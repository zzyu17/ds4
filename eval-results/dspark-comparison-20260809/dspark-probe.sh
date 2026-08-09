#!/bin/sh
set -eu

: "${DS4_BIN:?set DS4_BIN}"
: "${DS4_DSPARK_MODEL:?set DS4_DSPARK_MODEL}"
: "${DS4_DSPARK_SUPPORT:?set DS4_DSPARK_SUPPORT}"
: "${DS4_DSPARK_PROBE_OUT:?set DS4_DSPARK_PROBE_OUT}"

variant=${DS4_DSPARK_PROBE_VARIANT:-unknown}
tokens=${DS4_DSPARK_PROBE_TOKENS:-64}
reps=${DS4_DSPARK_PROBE_REPS:-3}
prompt=${DS4_DSPARK_PROBE_PROMPT:-Complete this C function: int add(int a, int b) {}

mkdir -p "$DS4_DSPARK_PROBE_OUT"
summary="$DS4_DSPARK_PROBE_OUT/summary.tsv"
printf 'variant\trep\tbaseline_tps\tdspark_tps\tspeedup_pct\texact\tdspark_stats\n' >"$summary"

rep=1
while [ "$rep" -le "$reps" ]; do
    base_out="$DS4_DSPARK_PROBE_OUT/baseline-r${rep}.out"
    base_err="$DS4_DSPARK_PROBE_OUT/baseline-r${rep}.err"
    spark_out="$DS4_DSPARK_PROBE_OUT/dspark-r${rep}.out"
    spark_err="$DS4_DSPARK_PROBE_OUT/dspark-r${rep}.err"

    "$DS4_BIN" -m "$DS4_DSPARK_MODEL" --tokens "$tokens" \
        --temp 0 --nothink -p "$prompt" >"$base_out" 2>"$base_err"
    DS4_DSPARK_STATS=1 "$DS4_BIN" --dspark \
        -m "$DS4_DSPARK_MODEL" --mtp "$DS4_DSPARK_SUPPORT" \
        --tokens "$tokens" --temp 0 --nothink -p "$prompt" \
        >"$spark_out" 2>"$spark_err"

    exact=0
    cmp -s "$base_out" "$spark_out" && exact=1
    base_tps=$(sed -n 's/.*generation: \([0-9.][0-9.]*\) t\/s.*/\1/p' "$base_err" | tail -n 1)
    spark_tps=$(sed -n 's/.*generation: \([0-9.][0-9.]*\) t\/s.*/\1/p' "$spark_err" | tail -n 1)
    stats=$(sed -n 's/^ds4: DSpark stats //p' "$spark_err" | tail -n 1)
    [ -n "$base_tps" ] && [ -n "$spark_tps" ] && [ -n "$stats" ]
    speedup=$(/usr/bin/awk -v b="$base_tps" -v s="$spark_tps" 'BEGIN { printf "%.2f", (s / b - 1) * 100 }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$variant" "$rep" "$base_tps" "$spark_tps" "$speedup" "$exact" "$stats" \
        | tee -a "$summary"
    [ "$exact" -eq 1 ]
    rep=$((rep + 1))
done
