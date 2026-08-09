# Multi-session DSpark verifier results

Date: 2026-08-09  
Mac: M3 Ultra Mac Studio  
Source baseline: `1021670cf199248f1c4dac509c48bbdc5a09bc8d`

## Outcome

Do not enable DSpark for the normal server. Neither the preview model nor the
0731 model passed the throughput or exact-output gate. The original target-only
0731 service was restored after every test and remains the deployed service.

## Implementation tested

- Added a public multi-session speculative-cycle interface so the server
  coordinator submits target tokens, proposal limits, and accepted-token
  buffers as one batch.
- Enabled Metal target batching with DSpark support loaded and retained
  per-session capture, checkpoint, partial-commit, and rollback state.
- Implemented two experimental multi-session target verifiers:
  layer-major independent suffixes, and a row-coalesced FFN/router/routed/shared
  expert pass with session-local attention and KV updates.
- Both rewritten verifier kernels are opt-in because tuning showed them slower
  than the correctness-first coordinator path.

## Final benchmark method

Both target-only and DSpark used the rewritten binary, eight resident sessions,
`--ctx 1024`, a 2 ms decode coalescing window, one untimed warmup, three timed
trials, greedy decoding, and a 128-token cap. Reported values are median
aggregate completion tokens per second. Every DSpark response was compared
with the corresponding target-only response.

| Model | Concurrency | Target tok/s | DSpark tok/s | Change |
|---|---:|---:|---:|---:|
| preview | 1 | 31.548 | 30.097 | -4.60% |
| preview | 2 | 30.957 | 29.982 | -3.15% |
| preview | 4 | 29.916 | 28.498 | -4.74% |
| preview | 8 | 29.866 | 27.085 | -9.31% |
| 0731 | 1 | 24.615 | 23.440 | -4.77% |
| 0731 | 2 | 24.543 | 23.427 | -4.55% |
| 0731 | 4 | 24.921 | 23.376 | -6.20% |
| 0731 | 8 | 24.663 | 21.721 | -11.93% |

The 0731 prompts often stopped early (34 completion tokens at concurrency 1),
so its latency is more tail-dominated. The preview concurrency-1 case consumed
the full 128-token cap and was still 4.60% slower with DSpark.

## Correctness and activation

- The final short two-request smoke passed byte-exact comparison, executed 42
  DSpark proposals, and reported zero verifier errors.
- Across the longer final matrix, target-only output repeated exactly in every
  trial. DSpark mismatched target-only output in 19 of 45 preview responses and
  9 of 45 0731 responses, and some DSpark trials differed from one another.
- The final server logs reported zero verifier errors, with aggregate draft
  acceptance of 78.28% for preview and 67.69% for 0731. High acceptance did not
  overcome proposal, verifier, synchronization, and batching costs.

## Verifier tuning

On preview at concurrency 4/8 with 96-token trials:

| Variant | Concurrency 4 | Concurrency 8 |
|---|---:|---:|
| sequential verifier | -4.91% | -9.97% |
| layer-major verifier | -3.22% | -11.65% |
| row-coalesced FFN verifier | -3.60% | -11.21% |

Changing dispatch order did not amortize target weights. Coalescing the FFN
added gather/scatter and larger-row kernel overhead without a throughput win.

## Validation

- Local WSL and remote macOS `ds4-server` builds passed with `git diff --check`.
- The final model-backed activation smoke passed.
- Extractor, agent, layer-pack (97/97), placement (101/101), GPU argument,
  CLI argument (44/44), sampling, Q4_K (4/4), and MXFP4 (4/4) tests passed.
- The aggregate local `make test` stopped only because its configured model
  fixture `ds4flash.gguf` is absent.

Raw results and logs are in the sibling `final-preview-sequential/`,
`final-0731-sequential/`, `tuning-preview-*`, and `final-default-smoke/`
directories on the Mac.
