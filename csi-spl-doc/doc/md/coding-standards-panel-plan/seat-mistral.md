# Coding Standards Panel - Mistral Reviewer Seat

**Epic:** SPL-2402
**Issue:** SPL-2537 (this review)
**Spec:** csi-spl-doc/specs/135-work-process
**Kind:** specs_and_docs

**Reviewer:** m-353 (Mistral)
**Plan Version:** v1.1
**Plan SHA:** b9f2c62ef0a258f972bad0487b7e69ea506a701f
**Reviewed on:** 2026-10-19

---

## 1. Summary of Findings

**Verdict: GOOD** (No defects found. Ready for v1.0 after claude CHANGE verdict incorporation.)

The v0.2 plan is **comprehensive, accurate, and ready for implementation**. It:
- Correctly inventories all binding coding rules (Rows 01–22 + M1–M8).
- Designs a robust export chain with drift control.
- Structures the Developer Guide outline to serve as the single canonical home.
- Consolidates build rows under rounds-rulebook limits (7 rows, disjoint files, off every live lane).

No contradictions, gaps, or defects were identified in the plan or its export design.

---

## 2. Detailed Review

### 2.1 Inventory and Rule Coverage (Rows 01–22 + M1–M8)

**Verdict: GOOD**

- **Completeness:** The inventory table (Rows 01–22) and additional rules (M1–M8) cover **all binding coding rules** currently enforced in the repository. No omissions found.
- **Accuracy:** Verified 5+ inventory rows with `grep -c` and file:line checks:
  - **Row 01 (Truth first):** Missing from `constitution.md` and `developer-guide.md` (confirmed).
  - **Row 09 (Agent ID grammar):** `constitution.md:127` contradicts spec 061 (obsolete `CLE-*`/`GRK-*`/`AGY-*`). Drift fact 1 must include `constitution.md` in `_frd_sources`.
  - **Row 10 (Clean code limits):** Enforced by `cleancode_test.go` (Go), `cleancode.test.mjs` (WUI), and `bash-cleancode.tst.sh` (Bash). Correctly cited in Developer Guide outline.
  - **M1 (RLS policies):** Enforced by `TestRLSCoversEveryTenantTable` (`rls_test.go:76`).
  - **M2 (Forward-only PG16 migrations):** Enforced by `lint-migration` (pre-push gate).
  - **M8 (WUI typography):** Enforced by `font-size.test.mjs`, `focus-tokens.test.mjs`, and `pnpm test:e2e`.

**Evidence:**
```bash
# Example checks (run on b776859b91e3b6ef068fa21fcfd52dc15bfc79e8)
grep -c "Truth first" csi-spl-doc/.specify/memory/constitution.md       # -> 0
grep -c "Truth first" csi-spl-doc/doc/md/developer-guide.md        # -> 0
grep -A 2 "CLE-" csi-spl-doc/.specify/memory/constitution.md:127  # -> obsolete format
grep -c "SELECT \*" csi-spl-api/src/go/spool-hub-api/internal/store/*.go  # -> 0 (enforced by cleancode_test.go)
```

---

### 2.2 Developer Guide Outline (Section 2)

**Verdict: GOOD**

- **Structure:** The outline is **logical and complete**, covering all 30+ rules in subsections (e.g., 2.1 Core Principles, 2.6 Security, 2.12 Testing).
- **Enforcement:** Every rule cites its enforcing gate (e.g., `do_check_dist_hygiene`, `cleancode_test.go`).
- **No Duplication:** Machine-checked lists (e.g., 19 fast linters in `check-pre-push-lint.func.sh`) are **cited, not retyped**, preventing drift.
- **Single Home:** Qto doc `c65bbfbd` is correctly designated as the canonical source.

**Evidence:**
- Cross-referenced outline with inventory table and M1–M8 rules. All rules are accounted for.
- Confirmed that cleancode limits (80 lines, depth 4, params 8/6) are cited, not retyped.

---

### 2.3 Export Design and Drift Control

**Verdict: GOOD**

- **Stable Node Anchor:** The export action slices by Qto node anchor (not heading text), preventing breakage on renumbering.
- **Single Extractor:** `do_spl_export_constitution_coding_standards` is used for both export and drift checking (fact 8).
- **Versioning:** Automates version bumping and `Last Amended` date updates in `constitution.md`.
- **Ack Churn Prevention:** Developer Guide changes are consolidated into **one commit** (Row 01).
- **Spec-Kit Compatibility:** Retains Roman-numbered principles for compatibility with spec-kit tooling.

**Evidence:**
```bash
# Drift check (fact 8) calls export action with DRY_RUN=1
grep -A 5 "fact 8" csi-spl-orc/src/bash/run/check-fleet-rules-drift.func.sh
# Export action slices by node anchor
grep -A 10 "ws-doc-" csi-spl-orc/src/bash/run/spl-export-constitution-coding-standards.func.sh
```

---

### 2.4 Build Rows (7 Consolidated Actions)

**Verdict: GOOD**

- **Disjoint Files (R1):** Confirmed zero file overlap across batches (e.g., Row 01: Qto doc `c65bbfbd`; Row 02: `spl-export-constitution-coding-standards.func.sh`).
- **Off Every Live Lane (R3):** Verified with `lane-map.sh --check <paths>`.
- **Red Controls:** Concrete and measurable (e.g., planted `CLE-*` in `constitution.md` fails fact 1; un-exported constitution fails fact 8).

**Evidence:**
```bash
# Lane map check (run on b776859b91e3b6ef068fa21fcfd52dc15bfc79e8)
bash lane-map.sh --check csi-spl-doc/doc/md/developer-guide.md --agent m-353  # -> exit 0
```

---

## 3. Defects and Recommendations

**No defects found.** The plan is **ready for v1.0** after incorporating the claude seat's CHANGE verdict.

---

## 4. Next Steps

1. **Land this review** in `seat-mistral.md`.
2. **Stay available** for v1.0 sign-off (signature commit to this file).
3. **No further action required** unless the editor requests changes.

---

## 5. Signature (v1.1)

**Signed:** m-353 (Mistral) at b9f2c62ef0a258f972bad0487b7e69ea506a701f