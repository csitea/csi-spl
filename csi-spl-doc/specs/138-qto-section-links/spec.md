# 138 Qto section links: a URL that opens a document at one section

Status: decided 2026-10-15 (section 3), built in SPL-1966. Issue: SPL-1939. Owner HUM-10, t1 msg 34ea2893 (topic 36247645): "QTO links,
which can point to the exact sections of the document so that the sections
will be at the top of the screen with HTML anchors in the URL. Check the old
QTO implementation". Discussion: t1 #spool-hub-devel topic 7c968b85 (kickoff
msg d6d91e62, poll A-D).

## 1. What the old Qto did

The old Qto clone under `/opt/<user>/qto` on the main box, read only (1344 commits, HEAD cde86e48b 2026-06-20; the
view-doc and md-export files last changed in a19ffe39, 2020-09-19). Paths
below are under `src/perl/qto/`.

- **Form = table + row id, never the number or the title.** Every heading
  carries `id="<table>-<id>"` and `href="#<table>-<id>"`, e.g. `#readme_doc-42`
  (`templates/pages/view-doc/components/view-doc-items-list.xt.html.ep:12-14`).
  The number (`logical_order`) and the level are only in the `title` tooltip
  (line 16). So a rename or a renumber never broke a link; a deleted row did.
- **A `#` permalink before each title** (`:13-14`), hidden until hover
  (`public/themes/thme-blue/css/screen/controls/view-doc.css:131-139`), and the
  right-hand contents repeat it per row (`:51-52`). There was no copy-link
  button: the user copied the `#` link's address. The right-click menu had
  open as doc / open as list / export md / export xls
  (`components/right-click-menu.xt.html.ep:9-30`).
- **Scroll on open**: `mounted` waits 1500 ms, then `scrollToHash` takes
  `location.hash`, `getElementById(...).scrollIntoView(true)` and clicks it
  (`templates/pages/view-doc/js/vue_app.js.html.ep:403-421`). The fixed 40 px
  top bar (`css/screen/site/top-bar.css:54-62`) was cleared with the old
  `.permalink { display:block; height:30px; margin-top:-30px }` trick
  (`view-doc.css:131-135`); `body { scroll-behavior: smooth }`
  (`css/screen/site/site.css:7`).
- **The md export used GitHub slugs instead**: headings are
  `#… <logical_order> <name>` (`lib/Qto/App/IO/Out/WtrGitHubMd.pm:84-95`) and
  the TOC links `#<number without dots>-<lowercased title, spaces to ->`
  (`:188-199`), so links inside an exported .md broke on every rename and
  renumber, while links into the live view never did.

## 2. What the WUI does today

Most of section 1 is already ported (`csi-spl-wui/src/components/workspace-docs/`):

- Anchor `ws-doc-<item uuid>` (`WorkspaceDocView.vue:333,424`; the id is
  `workspace_doc_item.id uuid`), on the `<h3>` (`:86`), a `#` permalink per
  heading (`:98`) and in the contents (`:265`). The URL is
  `/workspace/docs?doc=<doc uuid>&view=doc#ws-doc-<item uuid>`
  (`WorkspaceDocsPage.vue:153,203`, `QtoFileTree.vue:628`).
- Scroll: `goTo` does `scrollIntoView({block:'start'})` + `replaceState`
  (`WorkspaceDocView.vue:837-843`); on mount, once after `load()` +
  `nextTick` (`:859-864`); `scroll-margin-top: 4rem` on the heading (`:951`)
  under the sticky bar (`:884-887`).
- Copy link: only in the file tree's menu (`QtoFileTree.vue:595,608,657`),
  not on the heading.
- md export (`-doctree-export.ts:33-41`): `# <outline> <title>` headings, no
  anchors; repo md uses GitHub slugs (`csi-spl-doc/doc/md/SYS.md:11`).

Gaps: (G1) the mount scroll fires once, before images and auto-grown
textareas settle, so the section can drift down; (G2) no copy-link on the
section itself; (G3) the uuid hash is long and says nothing to a reader;
(G4) an exported .md has no anchors at all; (G5) no e2e proves the
section's top is at the viewport top.

## 3. Anchor form (the owner's poll)

| | form | example | rename | renumber | readable |
|---|---|---|---|---|---|
| A | item id (today, Qto's form) | `#ws-doc-3f2a…` (36 chars) | keeps | keeps | no |
| B | outline number | `#1.2.3` | keeps | breaks | yes |
| C | GitHub title slug | `#1-2-3-title-words` | breaks | breaks | yes |
| D | number + slug, id behind it | `#1.2.3-title-words~3f2a91c0` | resolves by id | resolves by id | yes |

**Decided, owner HUM-10, t1 topic 7c968b85, 2026-10-15:**

- What "Copy link" writes (poll 6dfb8721, msg 748ecf3c): "B - The stable id
  only (today's #ws-doc-..., long but never breaks)", this table's **A**.
- The anchor in general (poll d6d91e62, msg 7f2f7bd9): "C - Both: a readable
  anchor that still resolves through a stable id after a move", this
  table's **D**, resolved only through its id.

So A is the canonical anchor and the one the copy button writes; the
resolver on open tries, in order: the full id (A), then the 8-hex id suffix
of a readable anchor (`~3f2a91c0` = the id's first 8 hex digits, D), and
nothing else. A bare outline number (B) or a title slug (C) is not resolved:
after a move it would open another section, so it is an unknown anchor. The
poll labels differ from this table's; matched by content above. The
resolver: `csi-spl-wui/src/components/workspace-docs/-doc-anchor.ts`.

## 4. Behaviour

- **Scroll**: the section's heading top at the top of the content viewport,
  just below the sticky bar (`scroll-margin-top` = the bar's measured height,
  not a fixed 4rem). On open, scroll after the load and again while the
  layout still grows (a `ResizeObserver` on the document for up to 2 s, or
  until the user scrolls), fixing G1 without Qto's blind 1500 ms wait.
- **Unknown anchor** (deleted item, stale slug): open the document at its
  top and say so in one status line; never a blank page.
- **Rename / renumber / move**: A and D links keep working (by id); B and C
  are not resolved (section 3). The copy button always writes A.
- **Copy link**: "Copy link to section" in the heading's section menu and on
  long-press of the `#`, using the tree's `docHref(doc, item)` (G2). A `#`
  click keeps scrolling and setting the hash.
- **Export**: the md export writes `<a id="ws-doc-<id>"></a>` before each
  heading, so a link copied from the WUI still lands in the .md, and GitHub's
  own slug keeps working beside it (G4). Print keeps its contents list.
- **Phone**: a deep link skips the phone list and opens the document view at
  the section; the contents drawer stays closed; the offset is the phone
  bar's height.

## 5. Proof (e2e)

One new case in an existing e2e file (a new file reddens the shard control):
open `/workspace/docs?doc=<d>&view=doc#ws-doc-<item>` for an item well below
the fold, with an image above it; after the 2 s settle assert
`abs(heading.getBoundingClientRect().top - bar.bottom) <= 2` px and that the
hash is unchanged; repeat at 390x844 (phone); repeat with a D anchor whose
number and title are stale; the copy-link item and a long press of the `#`
put the A link on the clipboard; a B, a C and an unknown anchor open the top
with the status line. Control: the same check with the re-scroll removed
fails. Built in `csi-spl-wui/tests/e2e/workspace-doctree.test.mjs` (the
"spec 138" cases), the resolver in `tests/unit/doc-anchor.test.mjs`, the
export in `csi-spl-orc/src/bash/tests/doctree-export-md.tst.sh` case 20.

## 6. Out of scope

The doc editor itself, the DevOps guide, links into the grid view.
