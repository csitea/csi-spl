# 100 search index: reviewer r4 (agy, seat r4-agy)

> **Seat note:** agy voice on the panel (per owner rule 2026-10-05, t1 f0c3927e:
> a spec needs consensus of at least one agy and one grok). Reviewer seat r4
> (agent a-420), reviewing author c-372's `spec.md` (v0.8 / v1.0 on master
> `20792f7dc`) from task `2b25c535-fb6c-4e92-a9a5-9460fdd7ca70`.
>
> Brief: review the author's draft as a spec reader. Are the options complete,
> is the recommendation clear to a newcomer, and are the open owner questions
> the right ones? Record agree/disagree for the consensus line.

## 1. Executive Summary & Position

- **Position:** **AGREE / SIGN OFF** on `spec.md` v0.8 and v1.0 (`20792f7dc`).
- **Recommended option:** **S1r** (GIN on `messages (tenant_id, search_tsv)` via
  `btree_gin` read through a SECURITY DEFINER function `spool_search_candidates`
  owned by NOLOGIN role `spool_search_reader`, with a `FOR SELECT TO spool_search_reader USING (true)`
  policy).
- **Fallback option:** **B** (word table under FORCE RLS, btree on `(tenant_id, word, msg_id)`)
  if the owner refuses the single audited RLS lift (Q1) or if Cloud SQL dev refuses P0.
- **Consensus vote:** **AGREE (SIGNED v0.8 / v1.0)**.
- **Seat validation:** Provides the panel's required agy voice, fulfilling owner
  rule 2026-10-05 (t1 f0c3927e).

---

## 2. Review Lens 1: Are the Options Complete? (Section 4)

**Verdict: Yes, the options are complete.**

The comparison in Section 4 covers the full architectural design space across all
applicable layers:

1. **Status Quo / In-band filter (S0):**
   rdb 0135's 1024-bit Bloom signature + the proposed 512-char lane. Correctly
   identified as an interim patch: it avoids TOAST reads on long rows for
   multi-term queries, but remains an $O(N)$ sequential scan across all tenant rows.
   At 10x-A (188k rows) on db-f1-micro (128 MB `shared_buffers`), sequential scans
   inevitably fall out of cache and blow past the 5 s budget.

2. **In-Postgres with Audited RLS Lift (S1r & S2):**
   - **S1r (Recommended):** Reuses the stored generated column `search_tsv` and
     reinstates the GIN dropped by 0122, adding `tenant_id` via `btree_gin`.
     Zero synchronization lag, zero additional storage duplication, zero trigger
     overhead on inserts/updates.
   - **S2 (Side table + GIN without RLS):** Evaluated and rightly rejected. S2
     requires the exact same SECURITY DEFINER lift mechanism as S1r, but adds
     table duplication (~20 MB for 23 MB of messages), complex insert/update/delete
     triggers, cascading deletes, and expiry synchronization. S1r strictly dominates S2.

3. **In-Postgres without RLS Lift (B / Option A):**
   - Explored rigorously by r3 and refined by r2. Under FORCE RLS, btree operators
     on text (`texteq`, `text_lt`, `text_ge`) are LEAKPROOF on PostgreSQL 16.15
     (confirmed on prd catalogue: `search-idx-prd-reads-1529Z.md`), allowing Index
     Only Scans without RLS bypass.
   - The trade-offs are fully exposed: 78–82 distinct word postings per message,
     exploding row counts (~1.79 M postings today, ~190 MB; ~1.9 GB at 10x-A),
     plus massive trigger overhead on insert/update (rebuilding dozens of word rows)
     and inability to verify phrase positions without re-reading `messages`.
   - Properly designated as the exact fallback should the owner disallow any RLS lift.

4. **In-Process Hub Index (S3):**
   - Evaluated and rejected: memory overhead in Go process, cold-start index rebuilds
     on every deployment scanning the entire database, and architecture lock-in to
     `max_instances: 1`.

5. **External Hosted Search Service (S4):**
   - Evaluated and rejected: sends sensitive message text outside GCP, introduces
     asynchronous consistency lags on deletes/edits/expiry, and multiplies overall
     estate cost (current estate ~$60/env/month).

6. **Semantic / Vector Search (S5):**
   - Evaluated and rejected: does not solve the user query need (exact phrases,
     prefixes, `from:`, `in:`, Gmail-style search grammar). pgvector operators are
     not leakproof for WHERE conditions, HNSW recall degrades under post-index RLS
     filtering, and storage grows by ~3 KB per row (+560 MB at 10x-A).

The matrix spans every realistic solution category: storage-layer index lift,
storage-layer zero-lift relational decomposition, application-memory indexing,
managed search SaaS, and vector similarity. No viable option has been omitted.

---

## 3. Review Lens 2: Is the Recommendation Clear to a Newcomer? (Section 5)

**Verdict: Yes, exceptionally clear.**

A newcomer reading `spec.md` will quickly grasp both the core problem and the
solution mechanics:

### 3.1 The Core Problem
- PostgreSQL FORCE RLS forbids index scans when operators are not LEAKPROOF.
- `ts_match_vq` (`@@`) is not leakproof (`proleakproof = false` confirmed on prd).
- Consequently, Postgres defaults to a sequential scan of all tenant rows,
  de-TOASTing `search_tsv` and blowing the buffer budget on cold reads.

### 3.2 The Architectural Principle
- **"The index proposes, Postgres disposes"** (Section 5.1).
  This single sentence encapsulates the security architecture:
  1. The GIN index (via the SECURITY DEFINER function `spool_search_candidates`)
     merely proposes candidate `msg_id`s for the session tenant.
  2. The caller's outer query executes under standard FORCE RLS, applying all
     privacy doors, channel memberships, expiry filters, archive filters, and
     keyset pagination.
  3. A defect in the proposal mechanism cannot leak unauthorized data across tenants;
     at worst it yields a false negative or filters out rows in the outer query.

### 3.3 The Cap Switch and Execution Mechanics (v0.8 / v1.0 Refinement)
The v0.8/v1.0 refinement addresses the earlier candidate-truncation and paging risks
spelled out by r1 and r2:
- **Two-phase query in Go:**
  1. *Probe phase:* Call `spool_search_candidates(q, cap)` with `cap = 500`.
  2. *Statement phase:*
     - If candidate count $\le 500$: pass the IDs directly to the outer statement
       via `AND m.msg_id = ANY($ids::uuid[])`.
     - If candidate count $> 500$ (i.e. returns `cap + 1` rows): discard the truncated ID set
       and fall back to today's backward scan on `messages_received`.
- This ensures the ID filter is **never applied to a truncated candidate set**,
  guaranteeing that keyset pagination never skips rows across pages.
- For common words, the backward scan fills a page in <10 ms anyway (8.4 ms on prd).
- For rare words, the GIN probe returns the exact candidate set in <5 buffers.

### 3.4 Phased Implementation (Section 9)
The P0 through P5 progression provides an unmistakable step-by-step roadmap:
- **P0:** Cloud SQL dev validation of role creation, `btree_gin`, and plan verification.
- **P1:** Migration implementation with SHARE lock measurement.
- **P2:** Hub probe integration with environment kill switch `SPOOL_HUB_SEARCH_INDEX=off`.
- **P3:** Comprehensive test battery (T1–T10).
- **P4:** Production benchmark validation.
- **P5:** Retirement of 0135 Bloom signatures.

*Minor note for implementers:* In Go `store/search_postgres.go`, ensure the `cap`
parameter (500) is defined as a constant matching the spec, and that the single-call-per-page
guarantee is documented in the store method signature.

---

## 4. Review Lens 3: Are the Open Owner Questions the Right Ones? (Section 11)

**Verdict: Yes, the open questions are precise, exhaustive, and actionable.**

Section 11 correctly isolates the decisions that only the product and infrastructure
owner can make:

- **Q1 (Audited RLS lift acceptance):**
  The fundamental policy fork. Approving S1r gives an optimal, zero-lag, low-storage
  solution. Rejecting it directs the team immediately to fallback B.
- **Q2 (Message text leaving GCP estate):**
  Definitive security/data boundary question confirming the exclusion of S4 and S5.
- **Q3 (Throwaway Cloud SQL prd clone for benchmarks):**
  Safe operational path to achieve true cold ($n \ge 5$) buffer measurements without
  restarting production instances.
- **Q4 (10x growth shape & DB tier):**
  Distinguishes between single-tenant volume (10x-A) vs multi-tenant volume (10x-B),
  and acknowledges that db-f1-micro cannot cache 1.1 GB under any indexing option.
- **Q5 (Holding the 512-char signature lane):**
  Eliminates wasted migration churn on a stopgap that S1r renders obsolete.
- **Q6 (Relevance sorting):**
  Correctly withdrawn in v0.7/v0.8, as candidate-set ranking up to `cap` preserves the
  contract without changes.
- **Q7 (SHARE lock write stall during migration):**
  Identifies whether a brief (~seconds) write pause during GIN index creation is
  acceptable or if out-of-band `CONCURRENTLY` tooling is mandated.
- **Q8 (Added p95 insert latency budget):**
  Sets the acceptable ceiling for GIN index maintenance on new message posts.

No extraneous questions are included, and no blocking architectural uncertainties
remain unasked.

---

## 5. Verification of Production Data & Invariants

Reviewer r4 checked the catalogue and production read artifacts
(`/var/tmp/c-001/search-idx-prd-reads-1529Z.md` and `search-idx-prd-reads-c369-1532Z.md`):

1. **LEAKPROOF Operators on prd:**
   ```
   texteq=true, text_lt=true, text_ge=true, ts_match_vq=false, bitand=false, biteq=true
   ```
   Confirms that full-text match `@@` cannot be evaluated as an index condition under
   FORCE RLS on Cloud SQL pg 16.15.
2. **Role & Privilege Model:**
   `spool_hub_rt` has `rolbypassrls = false`. Only `cloudsqladmin` holds BYPASSRLS.
   Therefore, S1r's role-scoped policy (`FOR SELECT TO spool_search_reader USING (true)`)
   is the only viable in-database lift mechanism.
3. **Database & Relation Sizing:**
   - Database total: 162 MB; `messages` total: 132 MB (heap 39 MB, TOAST 76 MB, indexes 16 MB).
   - t1 has 19,244 rows and 1,580,634 word postings (88% of table rows).
   - Extension `btree_gin` is available (`-/1.3`), confirming multi-column GIN viability.

---

## 6. Consensus Statement

- **Seat:** `r4-agy` (agy voice, agent a-420)
- **Document Reviewed:** `csi-spl-doc/specs/100-search-index/spec.md` v0.8 & v1.0 (`20792f7dc`)
- **Vote:** **AGREE / SIGNED v0.8 & v1.0**
- **Recommendation:** Proceed with **S1r** (GIN on `(tenant_id, search_tsv)` via `btree_gin`
  + SECURITY DEFINER `spool_search_candidates`), with **B** as the documented fallback.
- **Consensus recorded:** Panel consensus now reflects all 5 seated agents (author c-372,
  reviewers c-369, c-370, c-371, and r4 a-420).
