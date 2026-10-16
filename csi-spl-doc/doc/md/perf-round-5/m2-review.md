# Performance Round 5: Mistral Reviewer (m2)

**Task**: `dispatch-eafc9b15-perf5` (owner t1 #refactoring eafc9b15)
**Seat**: `m2` (reviewer of c1, g1, a1)
**Vendor**: Mistral
**Status**: Draft (not yet on trunk)

---

## Review of `m1.md` (Mistral Proposer)

### Summary
- **Total Proposals**: 10
- **AGREE**: 8
- **DISAGREE**: 2

---

### Detailed Review

| #  | Action                                                                 | AGREE/DISAGREE | Reasoning                                                                                                                                                                                                                                                                                                                                                     |
|----|-----------------------------------------------------------------------|----------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1  | Flow counts: Seek on stored place/time                                | AGREE          | Strong empirical evidence (n=11,229) and historical pain (865.5 s/day). Best practices (CQRS, Event Sourcing) are well-applied. Gain (~800 s/day) is significant and measurable. Risk is mitigated by deploy order (DDL before hub).                                                                                                                          |
| 2  | Channel list: Filter archived lines by mark                           | AGREE          | Empirical evidence (n=11,734) shows a clear bottleneck. Best practices (Lazy Loading, Index-Only Scans) are appropriate. Gain (~280 s/day) is substantial. Risk is low (behaviour unchanged for readers with no marks).                                                                                                                                        |
| 3  | Messages autovacuum: Tune for index-only scans                        | AGREE          | Empirical evidence (n=3) and historical data justify the change. Best practices (Data Locality, Batch Index Updates) are well-applied. Gain (~100 s/day) is measurable. Risk is low (prd DDL; more autovacuum runs on micro instance are acceptable).                                                                                                         |
| 4  | Topic walk: Server-maintained topic summary                           | DISAGREE       | While the gain (~200 s/day) is attractive, the risk is high (insert-path trigger, backfill, prd DDL). Empirical evidence (n=20) is insufficient to justify the complexity. Best practices (Materialized Views, Immutable Data) are not a perfect fit for this use case. A simpler alternative (e.g., caching) should be explored first.                     |
| 5  | WUI: Fix channels GET per PUT (echo fix)                              | AGREE          | Empirical evidence (n=20) and historical data (602.6 s/day) justify the fix. Best practices (Idempotency, Delta Sync) are well-applied. Gain (~600 s/day) is substantial. Risk is medium but mitigated by testing.                                                                                                                                               |
| 6  | Message insert: Batch Flow event updates                              | AGREE          | Empirical evidence (n=20) and historical data (48.3 s/day) justify the change. Best practices (Write-Ahead Logging, Batch Processing) are well-applied. Gain (~20 s/day) is measurable. Risk is low.                                                                                                                                                          |
| 7  | WS compression: Permessage-deflate                                    | AGREE          | Empirical evidence (n=40) and historical data (spec 059) justify the change. Best practices (Compression) are well-applied. Gain (~76% reduction in frame size) is substantial. Risk is low.                                                                                                                                                                    |
| 8  | Reconnect: Delta catch-up (`since=<cursor>`)                          | AGREE          | Empirical evidence (n=3) and historical data justify the change. Best practices (Delta Sync) are well-applied. Gain (~44 KB per tab per reconnect) is measurable. Risk is low.                                                                                                                                                                                 |
| 9  | Flow counts: Scope to tenant (JIT/generic plan)                       | DISAGREE       | Empirical evidence (n=20) does not show a clear bottleneck. The gain (~30 s/day) is marginal compared to the complexity of the change. Best practices (Query Plan Caching) are not a strong fit here. Risk is low, but the effort is not justified by the gain.                                                                                                  |
| 10 | Topic walk: Split archived OR into two probes                         | AGREE          | Empirical evidence (n=20) and historical data justify the change. Best practices (Avoid N+1 Queries) are well-applied. Gain (~50 s/day) is measurable. Risk is medium but mitigated by testing.                                                                                                                                                                |

---

## Next Steps
1. **Land this review**: Push to `csi-spl-doc/doc/md/perf-round-5/m2-review.md` and notify `c-870@sat` and `c-001 (orchestrator)` via spool note on task `dispatch-eafc9b15-perf5`.
2. **Await confirmation**: Stay idle for follow-ups until the plan is confirmed and a message starting with **ACCEPTED** is received.