#!/usr/bin/env python3
"""Validate a completed 92-case ds4-eval trace and report its score."""

import collections
import pathlib
import re
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: audit-eval.py LOG TRACE EXIT_CODE")
    log_path, trace_path = map(pathlib.Path, sys.argv[1:3])
    exit_code = int(sys.argv[3])
    if exit_code not in (0, 1):
        raise SystemExit("ds4-eval returned an execution error code: %d" % exit_code)

    log_text = log_path.read_text(errors="replace")
    trace_text = trace_path.read_text(errors="replace")
    log_summaries = re.findall(
        r"ds4-eval:\s+(\d+)/92 passed,\s+(\d+) failed,\s+(\d+) incomplete,",
        log_text,
    )
    if not log_summaries:
        raise SystemExit("missing complete 92-case summary in " + str(log_path))
    log_counts = tuple(map(int, log_summaries[-1]))

    lines = trace_text.splitlines()
    case_headers = []
    summary_index = None
    for index, line in enumerate(lines):
        match = re.match(r"^===== CASE (\d+)/92 .+ =====$", line)
        if match:
            case_headers.append((index, int(match.group(1))))
        elif line == "===== SUMMARY =====":
            summary_index = index
    if [case_id for _, case_id in case_headers] != list(range(1, 93)):
        raise SystemExit("trace does not contain each of the 92 cases exactly once")
    if summary_index is None:
        raise SystemExit("trace has no terminal summary")

    statuses = []
    for offset, (start, _) in enumerate(case_headers):
        end = case_headers[offset + 1][0] if offset + 1 < len(case_headers) else summary_index
        found = re.findall(r"^status: (PASSED|FAILED|INCOMPLETE)$", "\n".join(lines[start:end]), re.M)
        if len(found) != 1:
            raise SystemExit("case %d has %d terminal statuses" % (offset + 1, len(found)))
        statuses.append(found[0])

    summary_text = "\n".join(lines[summary_index:])
    summary_match = re.search(
        r"^passed: (\d+)\nfailed: (\d+)\nincomplete: (\d+)\ntotal: (\d+)$",
        summary_text,
        re.M,
    )
    if not summary_match:
        raise SystemExit("trace has an invalid terminal summary")
    trace_counts = tuple(map(int, summary_match.groups()[:3]))
    if int(summary_match.group(4)) != 92 or trace_counts != log_counts:
        raise SystemExit("log and trace summaries disagree")
    actual = collections.Counter(statuses)
    actual_counts = (actual["PASSED"], actual["FAILED"], actual["INCOMPLETE"])
    if actual_counts != trace_counts:
        raise SystemExit("case statuses do not match the trace summary")
    if exit_code == 0 and trace_counts != (92, 0, 0):
        raise SystemExit("zero exit status conflicts with scored failures/incomplete cases")
    if exit_code == 1 and trace_counts == (92, 0, 0):
        raise SystemExit("nonzero exit status is unexplained by the complete score")

    print("%d\t%d\t%d\t92" % trace_counts)


if __name__ == "__main__":
    main()
