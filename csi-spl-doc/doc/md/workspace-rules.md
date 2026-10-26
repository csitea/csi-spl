# Workspace rules: one section per workspace

> Generated from qto doc `28f00408-013e-4fa1-8c13-772377568a61`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

A rule the owner set for ONE workspace lives here, in that workspace's
section, named only by its workspace id. A dispatcher writing a brief for a
lane that works for a workspace copies that workspace's section into the
brief ([runbook-dispatcher.md](runbook-dispatcher.md) section 6, step 4).
This page is the one home of each rule below
([fleet-rules-index.md](fleet-rules-index.md) section 2).

`csi-spl` is public: no company, customer or person names here, only the
workspace id. The owner's words are paraphrased and cited by message id.

<a id="ws-doc-e583e19c-48c4-4e74-8f8d-638efc5c3845"></a>
## 1. ws-b

<a id="ws-doc-0f7a5a44-821f-4732-8fd7-6f4fd007ef7f"></a>
### 1.1 Every doc is bilingual: English and Bulgarian

Owner, HUM-10 in the ws-b workspace (topic eb7f4883, msg c3ae5158),
paraphrased: all of the workspace's documentation is written in both
Bulgarian and English. A doc is named `<doc name>.en.md` or
`<doc name>.bg.md`. English is the default, and the documentation exists in
Bulgarian as well, because the people it is written for are native Bulgarian
speakers.

How to apply:

- Every ws-b doc, in the workspace Docs and in its private repo, exists
  twice: `<name>.en.md` (the default, written first) AND `<name>.bg.md`.
- The `.bg.md` is written by agy, which has the final word on the Bulgarian
  (the fleet language rule, global rule `20-spawn-an-agent.md`). With no agy
  free, a claude lane drafts it and it waits for an agy review; it never
  ships unreviewed.
- A lane that adds or changes a `.en.md` updates, or asks for, its `.bg.md`
  in the same task.
