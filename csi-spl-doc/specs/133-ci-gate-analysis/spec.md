# 133: CI gate analysis and measurable axes

Status: **v1.0, signed** (editor c-296, 2026-10-12). Doc only: no code, no
workflow edit. Builders start only after the editor signs **v1.0**.

## 0. The owner's ask

prd t1 topic f67e3656, HUM-10, 2026-10-12 06:18Z, verbatim:

> "I thought we had the functionality to not test everything when only a
> certain part of the system is changing."

> "pause everything else and bring more experts to start tackling this
> problem because this is the biggest blocker right now."

> "First, proper analysis, then a proper set of measurable axes on how to
> improve"

## 1. What this spec delivers

1. [analysis.md](analysis.md): one analysis of why the master gate
   (`.github/workflows/10_ci-quality.yml`, "wf 10") almost never gives a
   verdict, folded from the seat drafts.
2. ONE set of 5-8 measurable axes, each with its exact command, baseline and
   target (analysis.md section 4).
3. The candidate fixes, ranked by expected axis gain per effort (analysis.md
   section 5). After v1.0 the standing CI-refactor seat takes them one per
   round, each round measured on the axes.

## 2. The panel

| seat | file | area | agent |
|---|---|---|---|
| editor | `analysis.md`, `spec.md` | fold, axes, ranking, sign-off | c-296 |
| A | `seat-a.md` | wall time vs queue wait, runner capacity | c-298 |
| B | `seat-b.md` | red causes, why pre-push missed them, flakes | g-858 |
| C | `seat-c.md` | per-part test selection (the owner's question) | c-297 |
| D | `seat-d.md` | the slow suites | a-295 |
| E | `seat-e.md` | workflow triggers, concurrency, the supersede model | m-857 |

Each seat writes ONLY its own file; the editor alone writes analysis.md and
spec.md. Spool task for review and send-backs: `ci-gate-analysis`.

## 3. Rules for every number and claim

- Every number carries the command (or `gh api` query), the tree or sha it ran
  on, and n.
- A claim about a file cites the grep that proves it.
- Every seat file ends with 3-5 measurable axes: name, exact command,
  baseline now, proposed target.

## 4. Sign-off

| version | date | by | what |
|---|---|---|---|
| v0.1 | 2026-10-12 | c-296 | skeleton, starting facts, empty axis table |
| **v1.0** | 2026-10-12 | c-296 | analysis.md v1.0: five seats folded, axes X1..X8, fixes F0..F6 ranked |
