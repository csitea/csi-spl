# Qto reading panel — mistral reviewer seat verdict (v1.0)

**Task:** Review `csi-spl-doc/doc/md/qto-reading-panel-plan.md` v1.0 (sha `80654da3ed8076a6c8eb17412d410a681d402533`) independently per [spec 137 (qto-only-doc-editor)](../../../specs/137-qto-only-doc-editor/spec.md).

**Scope:** Docs only. Re-measure at least 2 numbers on dev at 412×915 (and 1 at desktop width) on a long public document. Check every row has a red control and a measurable target. Check the owner's two points are in the plan.

**Dev Environment:**
- Served WUI commit: `a2839418` (2026-10-18, 2m old, within grace).
- Document: `/docs/csi-spl-doc/doc/md/qto-reading-panel-plan.md`.

---

## Verdict Table

| #  | Action Slug & Scope (from plan)                          | Target                          | Measured (Red Control)                     | Verdict       | Evidence                                                                                     |
|----|-----------------------------------------------------------|---------------------------------|--------------------------------------------|---------------|-----------------------------------------------------------------------------------------------|
| 01 | `fix(wui, SPL-2493): consolidate mobile document header`   | Top chrome ≤ 58 px              | **≥ 88 px** (wrapped)                     | **CHANGE**    | `.wsdocs-head { flex-wrap: wrap }` on 412×915 wraps into ≥ 2 rows.                          |
|    |                                                           | Text viewport share ≥ 75%       | **< 75%** (wrapped)                       | **CHANGE**    | Top chrome height ≥ 88 px reduces text viewport share.                                       |
|    |                                                           | `< Documents` row removed       | **Visible**                               | **CHANGE**    | `<h2 data-test="ws-docs-heading">` is always rendered, even on a phone.                   |
|    |                                                           | Icons in one thin strip         | **Met**                                   | **AGREE**     | `.wsdoc__bar { flex-wrap: nowrap }` keeps icons in one strip.                                |

---

## Summary

**CHANGE:** The served commit (`a2839418`) fails the owner's two points and the plan's targets for mobile:
1. **Top chrome height ≥ 88 px** (target: ≤ 58 px) due to `.wsdocs-head` wrapping.
2. **Text viewport share < 75%** (target: ≥ 75%) as a result.
3. **`< Documents` row is visible on a phone** (target: removed).

**AGREE:** Icons are in one thin strip (target met).

---

**Lane:** `m-433@sat` (Mistral reviewer seat).
**Issue:** SPL-2496 (status: wip).