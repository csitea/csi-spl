# Spec 137 Panel Review: Mistral Seat

**Panel Seat**: `s137-mistral` (Mistral Large / Codestral)
**Review Date**: 2026-10-14
**Spec Version**: 0.1 (commit 43472c355, SPL-1730)

---

## Panel Questions: Choices and Rationale

### **P-Q1: Heading Representation & Unnumbered Headings**
**Choice**: **A** (`is_numbered` boolean flag on `workspace_doc_item`).

**Reasoning**:
- Preserves editorial intent for unnumbered headings (e.g., `## Overview`), which are common in 559 repo files.
- Lightweight schema change (single boolean column) with backward compatibility.
- Supports mixed documents (numbered and unnumbered headings).
- Export fidelity: Unnumbered headings render as-is (e.g., `## Overview`), while numbered headings retain computed outlines.

**Risks**:
- Requires a database migration to add `is_numbered` to `workspace_doc_item`.
- Qto editor UI must expose a toggle for numbered/unnumbered headings.

**Codebase References**:
- `spl-doctree-md.py:67-68`: Current parser fails on unnumbered headings due to `NUM.match` regex.
- `WorkspaceDocView.vue:362-371`: Paragraph rendering logic can conditionally omit outline numbers.
- `workspace_doc_item` table: Schema migration to add `is_numbered boolean DEFAULT false`.

---

### **P-Q2: Repository Docs in the Unified File System**
**Choice**: **A** (Global System Tenant: `tenant_id = 'system'`).

**Reasoning**:
- Zero duplication: Repo docs stored once and shared across all tenants.
- RLS simplicity: Single `system` tenant with read-only access for all tenants.
- Immutability: Repo docs are read-only for non-operators, aligning with their role as "source of truth."
- Future-proof: Supports granular ACLs (Layer 2) if needed later.

**Risks**:
- RLS complexity: Requires careful policy design to ensure cross-tenant blindness and system immutability.
- Operator bottleneck: Only operators can modify repo docs, creating a bottleneck for urgent updates.

**Codebase References**:
- `workspace_doc_node` table: RLS policy in §4.2.2 (`doc_node_select`, `doc_node_modify`).
- `csi-spl-api/src/go/spool-hub-api/internal/doctree/doctree.go`: API endpoints must route `/repo` requests to the `system` tenant.
- `WorkspaceExplorer.vue`: Unified tree UI must distinguish between `/repo` and `/workspace` nodes.

---

### **P-Q3: Table and Citation Editor Tools**
**Choice**: **B** (Markdown Template Insertion).

**Reasoning**:
- Low implementation cost: Inserts pre-formatted templates (e.g., `| Header | Header |
|---|---|`) into the textarea.
- Markdown fidelity: Ensures exported tables/citations are valid Markdown.
- Mobile-friendly: Works on all devices without complex UI interactions.
- Extensible: Can later evolve into a visual editor (Option A) if needed.

**Risks**:
- User experience: Less intuitive than a visual editor for non-technical users.
- Template maintenance: Requires updates if Markdown syntax evolves.

**Codebase References**:
- `WorkspaceDocView.vue:162-174`: Paragraph toolbar for `insert_table` and `insert_quote` buttons.
- `markdown.mjs:196-211`: Renderer already supports pipe tables and blockquotes.
- `spl-doctree-md.py:30-38`: Export pipeline must preserve template syntax.

---

### **P-Q4: Code Fence Tracking**
**Choice**: **A** (Stateful Fence Parser).

**Reasoning**:
- Accuracy: Correctly handles nested fences (e.g., ```` ``` ```` inside ```` ```mermaid ````) and multi-backtick blocks.
- Round-trip fidelity: Ensures code blocks survive import/export cycles without corruption.
- Minimal disruption: No changes to the database schema or Qto UI.

**Risks**:
- Parser complexity: Requires a state machine to track fence length and nesting.
- Performance: Slightly slower than regex for large documents.

**Codebase References**:
- `spl-doctree-md.py:30-38`: Current regex-based fence toggling logic.
- `markdown.mjs:161-167`: Renderer already supports multi-backtick fences.
- `doctree-export-md.tst.sh`: Test cases for nested code blocks.

---

### **P-Q5: Front Matter Preservation**
**Choice**: **A** (JSONB Metadata Column).

**Reasoning**:
- Structured data: Front matter is metadata (e.g., `title`, `author`, `version`), not body text. Storing it in JSONB enables querying and filtering.
- Export fidelity: Regenerates front matter during export, preserving repo conventions.
- Extensibility: Supports future metadata (e.g., `tags`, `status`).

**Risks**:
- Schema change: Requires adding a `front_matter jsonb` column to `workspace_doc`.
- Parser complexity: YAML parsing must handle edge cases (e.g., multi-line strings, anchors).

**Codebase References**:
- `spl-doctree-md.py:48-49`: Current parser refuses documents without a leading `# ` title.
- `workspace_doc` table: Schema migration to add `front_matter jsonb`.
- `do_spl_doctree_export_md`: Export pipeline must regenerate YAML front matter.

---

## Corrections to `tasks.md`

1. **Missing Task**: Add **RLS policy testing** under Phase 2.
   - **ID**: `T024`
   - **Area**: `test`
   - **Summary**: Verify RLS policies enforce tenant segregation and system immutability.
   - **Gate**: Test cases prove no cross-tenant leakage and operator-only writes to `system` tenant.

2. **Task Order**: Move **T019 (Live production proof)** to **Phase 3** (after gap closure and bulk import).
   - **Reason**: Tables/citations must be importable before testing them in production.

3. **Task Granularity**: Split **T018 (WUI Markdown renderer extensions)** into three tasks:
   - `T018a`: Task list plugin (`- [ ]`).
   - `T018b`: Footnote plugin (`[^1]`).
   - `T018c`: Heading slug IDs (`#section-id`).

4. **Missing Task**: Add **agent harness tooling** under Phase 1.
   - **ID**: `T019a`
   - **Area**: `sa`
   - **Summary**: Expose `spool doc-*` CLI and MCP tools in agent harnesses (claude, grok, mistral, agy, qwen).
   - **Gate**: Agent harness test verifies doc operations.

5. **Task Clarity**: Update **T031 (Byte-stable export parity)** to specify **zero unintended `git diff` changes**.
   - **Gate**: `git status --porcelain` is clean after full export.

---

## Summary of Choices

| Question | Choice | Key Reason |
|---|---|---|
| P-Q1 | A (`is_numbered` flag) | Preserves unnumbered headings; lightweight schema change. |
| P-Q2 | A (Global System Tenant) | Zero duplication; RLS simplicity. |
| P-Q3 | B (Markdown Template Insertion) | Low cost; Markdown fidelity; mobile-friendly. |
| P-Q4 | A (Stateful Fence Parser) | Accuracy for nested/multi-backtick fences. |
| P-Q5 | A (JSONB Metadata Column) | Structured data; export fidelity; extensibility. |

---

<!-- version: 0.1.0 · updated: 2026-10-14 · last-edit: 2026-10-14T12:00:00Z -->