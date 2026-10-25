# CI failures panel: seat mistral review

Status: **SIGN** (mistral, 2026-10-26).

## Verdict
**SIGN** the document `csi-spl-doc/doc/md/ci-failures-100-2026-10-25.md` (sha `bc0ee0801e7d0101ab6ed364119de1093826d804`).

The themes, fairness, proposed issues, and refactor rows are **correct and actionable**. The document is ready for v0.2 and issue filing.

## Spot-checks

| Fact | Verdict | Notes |
|---|---|---|
| SPL-3190: Cause commit and fix | CONFIRMED | Padding change broke the test. |
| Smell S1: WUI e2e geometry asserts and font | CONFIRMED | No `FONTCONFIG` in gate; font split documented. |
| Smell S4: Tests reading live config | CONFIRMED | Test copies live `dev.env.yaml`; cause commit edited it. |
| Family C: ubuntu-26.04 runner image | CONFIRMED | `SPOOL_CI_RUNNER` updated at 16:37Z. |
| Family D: Flake claim | CONFIRMED | Fix commit cites the flaky runs. |
| Family F: Advisory claim | CONFIRMED | Fix commit cites GO-2026-6809. |
| Family G: Deploy/ops claim | CONFIRMED | Run `39480361834` exists and failed. |
| Per-vendor and per-kind: WUI defect rate | CONFIRMED | 7 defect commits (~7% of WUI commits). |

## Numbered Points

1. **W1 (S4, lane-only issue)**: The `test-tmux-close-window.sh` case 16 red (stale build WARN) is not in the 100 runs but costs lane time. Recommend adding it to the **lane hygiene checklist** (e.g., `do_check_pre_push`).

2. **W2 (S2, orc fixtures)**: The two remaining `sleep` symlinks (`test-spool-send.sh:69`, `test-tmux-close-window.sh:352`) may still fail on 26.04. Recommend a **containerized test** for orc features (e.g., `ubuntu:26.04`).

3. **W3 (Family G)**: The three smoke reds are unchecked. Recommend tracing them to **deploy ordering** (hub vs WUI) or real regressions.

## Fact Table Counts

| Family | Jobs | Runs | Verdict |
|---|---|---|---|
| B (defects) | 45 | 41 | CONFIRMED |
| C (ubuntu-26.04) | 16 | 7 | CONFIRMED |
| D (flakes) | 12 | 12 | CONFIRMED |
| F (advisories) | 24 | 24 | CONFIRMED |
| G (deploy/ops) | 7 | 7 | CONFIRMED (run exists) |

