# 146: Reliability round - 12 permanent checks that keep the boxes and the hub up

Epic SPL-2364.
Status: Implemented (all 12 checks landed on master: dadff1744, b9d73435a, 377c36205, a3024b410, 27f6c86c7, 81840b7e4, 1da66fe29, e4fb9bc6b, f63906046, 6752317a0, 5947f748a, 9329c596e).

## Scope

The reliability round establishes 12 permanent software and monitoring solutions for system continuity across the fleet layers: Operating System (Debian 13), Networking & Certificates, Agent Fleet & Execution Harness, Docker & CI Runners, Cloud Estate (Cloud Run and Cloud SQL), and Meta-Monitoring. Every check runs in `csi-spl-utl` as a named action and test, executable both manually and via host cron with non-zero measured thresholds, report-first or advisory defaults (`DRY_RUN=1` where applicable), and zero destructive automated interventions.

## Requirements

The requirements, measured baseline facts across fleet layers, inventory of existing detectors, row specifications, and owner approval records are defined in the signed plan document: [reliability-round-plan.md](../../doc/md/reliability-round-plan.md). The plan document is the requirement by pointer; this specification anchors the round and its 12 execution tasks.
