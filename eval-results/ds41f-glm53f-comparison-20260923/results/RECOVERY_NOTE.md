# Quality continuation

The initial controller completed all 12 performance runs and finished the 92-case evaluation for DeepSeek V4.1 Flash. It stopped because it treated `ds4-eval` exit status 1 as an execution failure. In ds4, exit status 1 is also the normal score result when a completed evaluation contains failed or incomplete cases. The initial trace records 81 passed, 6 failed, and 5 incomplete out of 92.

The continuation audits all 92 per-case trace records and the matching log summary, then records exit status 1 as a completed score. It reuses that first trace, runs the other three model evaluations, all six official NLL scoring runs, three within-family comparison reports, and a final process audit. The original failure marker and controller logs are retained for provenance.

The preexisting remote `score_official` binary was dated September 6, while the tested DeepSeek V4.1 GGUFs were dated September 18. That binary rejected the new model metadata before scoring. The continuation builds the current repository's scorer source against the already built runtime objects into this result directory, leaving the remote repo unchanged.

## Local transfer finalization

The remote campaign finished, all transferred files passed the remote SHA-256 manifest, and the scoped staging directory was removed. The local transfer initially stopped because tar overlay extraction retained two obsolete local failure markers from earlier attempts. They are preserved with `LOCAL-STALE` names; the remote copies were archived by the successful controller. The report and local checksum manifest were then generated from the verified completed results.
