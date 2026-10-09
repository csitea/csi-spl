# 114 Workspace document privacy and sharing: tasks

Skeleton for v0.1. The build tasks are written after the review panel
agrees and the owner answers Q1-Q4 ([spec.md](spec.md) section 8); until
then nothing below is built. Status vocabulary: `../README.md` item 3
(`[x]` Implemented, `[~]` Partial / in progress, `[ ]` Planned).

## 1. Documentation and evidence

- [x] **T000**: `spec.md` v0.1 + this skeleton + `bench/` (the model (a)
  proof, its two controls and the M1-M4 measurements).
  - Owns: `csi-spl-doc/specs/114-workspace-doc-privacy-sharing/**`.
  - Done: `BENCH_N="6 100" BENCH_REPS=5 bash bench/isolation-bench.sh` prints
    29 `PASS` lines, `CONTROL c1-no-force caught`, `CONTROL
    c2-no-revoke-filter caught` and the M1-M4 lines of section 3.2.

## 2. Pending the panel and the owner

- [ ] **T001**: review panel on v0.1 (agy, two claude, grok or mistral),
  seated by the dispatcher; their changes folded into v1.0.
- [ ] **T002**: data model (migration, runtime grants, Go RLS test).
- [ ] **T003**: store and hub API (grant, revoke, "shared with this
  workspace" list).
- [ ] **T004**: WUI (share dialog, shared list, revoke event).
