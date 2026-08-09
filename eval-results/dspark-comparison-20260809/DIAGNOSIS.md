# DSpark performance diagnosis (2026-08-09)

## Outcome

DSpark is functioning correctly in both the CLI and the single-session server,
but the current M3 Ultra runtime cannot reproduce the official serving result.
The limiting factor is target verification cost, not draft acceptance or a
missing DSpark flag in the tested CLI path.

No source/default change was retained because none of the tested changes could
meet the performance and exactness gate. The original non-DSpark 0731 service
was restored after testing.

## What the official result means

The DeepSeek report's stable claim is a 60--85% per-user generation-speed gain
over an MTP-1 serving baseline at matched concurrent throughput. Its larger
strict-SLA throughput deltas occur at latency-frontier cliffs and are explicitly
not representative single-stream multiplicative speedups. The experiment here
is a single-user Apple Metal run against target-only decoding, so a claimed
3--4x single-stream target is not an equivalent comparison.

## Reproduced red case

Preview-imatrix, raw `c_add`, 64 tokens, three paired runs:

| Metric | Measured |
| --- | ---: |
| Target-only generation | 35.60--35.68 t/s |
| DSpark generation | 41.28--41.62 t/s |
| Paired speedup | 15.70--16.68% |
| Draft acceptance | 14/15 (93.33%) |
| DSpark verifier layers | 260.7--262.0 ms per run |
| Ordinary target work | 88.5--89.6 ms per run |
| DSpark proposal | 32.2--32.6 ms per run |
| Exact greedy output | 3/3 byte-identical |

The run contains three five-token verifier blocks. One five-row verification
therefore costs about 87 ms, versus about 30 ms for an ordinary target token.
Even near-perfect draft acceptance cannot yield a large single-stream speedup
with that cost ratio.

## Root causes

1. The verifier still uses the generic layer-major batch kernels. Its own source
   comment calls it the first production-shaped implementation and says the
   final hand-written small-N decode microbatch is not implemented.
2. Five speculative rows route to roughly 18--20 unique experts per layer,
   versus eight experts for one decoded token. The selected-expert profile
   measured 10.5--11.6 GiB of routed expert weights across 43 layers per block.
   This makes the verifier memory-bandwidth bound on Apple unified memory.
3. The newer TensorOps indexed-attention and routed-MoE paths are in this commit's
   ancestry, but this Mac runs macOS 15.3 with SDK 15.5. Those paths are compiled
   only with the macOS 26 SDK, and ds4 intentionally enables them automatically
   only on M5/M6/A19/A20-class devices. A detached force-enable experiment was
   discarded because the feature-probe code was compiled out, making the A/B
   invalid.
4. Native server batching explicitly disables MTP/DSpark. Its public batch API
   advances one token per session; it cannot express a causal speculative block
   plus per-prefix rollback/commit state for each session. The official serving
   regime therefore is not implemented in ds4.

## Server-path confirmation

An instrumented temporary 0731 server was launched with the matched 0731 DSpark
support file.

- Default thinking request: 34.79 t/s, 24/29 accepted, 685 ms saved versus
  714 ms proposal/verification overhead, net -28 ms.
- Matching non-thinking request: 37.29 t/s, 13/14 accepted, net +75 ms.

This proves the server calls DSpark when configured, but the same verifier-cost
limit remains. The normal startup wrapper does not enable DSpark, consistent
with the earlier default-enablement speed gate.

## What a real fix requires

One of the following is required; they are not equivalent small patches:

- Reproduce the official configuration on supported NVIDIA serving hardware
  and the official vLLM DSpark backend with concurrent load.
- Upgrade the Mac OS/SDK and re-evaluate Metal 4 on supported hardware. The M3
  lacks the newer neural-accelerator generation for which ds4 enables TensorOps,
  so an OS/toolchain upgrade alone is not expected to guarantee the result.
- Implement a new ds4 multi-session speculative verifier: coalesce variable
  draft blocks, carry per-session causal masks and KV/compressor frontiers,
  support exact partial commit/rollback, and add concurrency correctness and
  throughput gates. This is a serving architecture project, not a kernel flag.

## Evidence

- `current-red/summary.tsv`: exact repeated high-accept red loop.
- `current-red/layer20-profile/stderr.log`: representative stage timing.
- `current-red/selected-profile/stderr.log`: unique-expert profile.
- `current-red/host-toolchain.txt`: macOS, SDK, and compiler versions.
- `mtp1-baseline/summary.tsv`: DSpark support without `--dspark` stays target-only.
- `server-dspark-*.json`: API response artifacts.
