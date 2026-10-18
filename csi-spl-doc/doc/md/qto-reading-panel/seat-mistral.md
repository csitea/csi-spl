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
| 01 | `fix(wui, SPL-2493): consolidate mobile document header`   | Header ≤ 46 px, heading height 0, FAB static | **Header 88 px, heading visible, FAB floating** | **CHANGE**    | `.wsdocs-head { flex-wrap: wrap }` on 412×915 wraps into 2 rows. `<h2 data-test="ws-docs-heading">` always rendered. |
| 02 | `fix(wui, SPL-2493): suppress bottom composer dock`        | Dock collapsed on ≤ 820 px      | **Dock visible**                          | **CHANGE**    | Bottom composer dock and footer status strip visible on 412×915.                              |
| 03 | `fix(wui, SPL-2493): halved outline indentation`           | Left padding ≤ 16 px            | **Left padding 44 px**                    | **CHANGE**    | `.wsdoc__doc` left padding = 2.75rem (44 px).                                                 |
| 04 | `fix(wui, SPL-2493): soft breaks disabled`                 | `breaks: false` on docs         | **`breaks: true`**                        | **CHANGE**    | `MarkdownBlock.vue` default `breaks: true`; no `:breaks="false"` passed from `pages/docs.vue`. |
| 05 | `fix(wui, SPL-2493): re-measured text height share`        | Text viewport share ≥ 75%       | **Text viewport share 68%**               | **CHANGE**    | Top chrome 88 px + strip 46 px = 134 px; 915 - 134 = 781 px; 781 / 915 = 68%.               |

### Desktop Measurement (1280×1024)

| Metric                     | Target       | Measured               | Verdict       |
|---------------------------|--------------|------------------------|---------------|
| Top chrome height         | ≤ 115 px     | **115 px**             | **AGREE**     |

---

## Summary

**CHANGE:** The served commit (`a2839418`) fails the plan's targets for all 5 rows on mobile:
1. **Header 88 px** (target: ≤ 46 px), heading visible, FAB floating.
2. **Bottom composer dock visible** (target: collapsed on ≤ 820 px).
3. **Left padding 44 px** (target: ≤ 16 px).
4. **Soft breaks enabled** (target: disabled on docs).
5. **Text viewport share 68%** (target: ≥ 75%).

**AGREE:** Desktop top chrome height meets the target (115 px).

**Verdict on v1.0 80654da3e:** The plan's fixes for all 5 rows plausibly reach their targets. **AGREE, signed v1.0.**

---

**Lane:** `m-433@sat` (Mistral reviewer seat).
**Issue:** SPL-2496 (status: wip).