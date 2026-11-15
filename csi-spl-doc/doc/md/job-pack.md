# Job-application pack: `do_job_pack`

One named action builds a job-application pack from a vacancy link and the
master CVs (SPL-5555, csitea weekly item 12, spec 135). Before it, each pack
lane copied the previous pack's generator into its dispatch dir and edited it
by hand: four packs in one week, four different `gen.py` (`md5sum
*/work/gen/gen.py` -> 4 hashes), and the slowest took 3 hours and 8 poll
answers (c-518's count, SPL-5505). The action is that generator, folded into one versioned tool.

- Action: `csi-spl-orc/src/bash/run/job-pack.func.sh` (`do_job_pack`)
- Tool: `csi-spl-orc/src/bash/scripts/job-pack.py`, with the page styles in
  `csi-spl-orc/src/bash/scripts/job-pack-assets/`
- Test: `csi-spl-orc/src/bash/tests/job-pack.tst.sh`, on the synthetic
  fixture `csi-spl-orc/src/bash/tests/fixtures/job-pack/`

## 1. What it makes

Per language of the CONTENT (`LANGS`, e.g. `en`, `fi`, `sv`), five
documents, each as html, pdf and docx:

| # | document | from |
|---|---|---|
| 1 | CV | the base CV with this vacancy's kicker, tagline and key table |
| 2 | Highlights | `HL`, `HL_TAIL` |
| 3 | Projects per requirement | `REQ` (a summary, then one section per requirement) |
| 4 | Requirements per project | `REQ`, `PROJ_ORDER`, `PROJ_HOW` |
| 5 | Why-letter (the cover letter) | `LETTER`: the recipient, subject, body and the contact table |

Then an index page per language (`index.<lang>.html`, the first language also
as `index.html`) and one zip to send, `<Name>-<ROLE>-<DATE>.zip`, holding all
of it under one folder. Beside the pack, never in the zip:

| file | holds |
|---|---|
| `vacancy/vacancy.txt`, `vacancy/contacts.txt` | the ad as text; every e-mail address in it (the recipient, rule 5) |
| `internal/pick.md` | every candidate base CV with its score, the picked one marked |
| `internal/fit.md` | the fit table (section 4) |
| `internal/files.md` | every file with bytes and pdf pages, and the zip's sha256 |
| `internal/md/` | the markdown sources of documents 2-4 |

Rendering: pandoc (md -> html and docx, html -> docx), headless Chrome
(html -> pdf), pdfinfo (page counts only).

## 2. How to run it

Each step runs when its input is set, so a pack is two runs: one to read the
ad and pick the base CV, one to build once the CONTENT is written.

```bash
cd csi-spl-orc && OUT_DIR=<work dir> VACANCY_URL=<ad url> MASTER_CV_DIR=<cv dir> ./run -a do_job_pack
```

It writes `vacancy/` and `internal/pick.md`, and prints `NEXT`. Write the
CONTENT (section 3) from the vacancy text, the picked CV and the latest
pack's CONTENT, then:

```bash
cd csi-spl-orc && OUT_DIR=<work dir> MASTER_CV_DIR=<cv dir> CONTENT=<work dir>/content.py ./run -a do_job_pack
```

| variable | |
|---|---|
| `OUT_DIR` | required: the pack's work dir, e.g. the topic's dispatch work dir. Refused inside a git checkout: the pack holds personal data. The build replaces `OUT_DIR/out/` only when an earlier build wrote it (its `.job-pack` marker) |
| `VACANCY_URL` | the ad, `https://` or `file://`; without it the `vacancy/vacancy.txt` of an earlier run is used |
| `MASTER_CV_DIR` | a dir of base CV html files: every `*cv*.html` under it, its language from `<html lang>` or a `-en`/`-fi`/`-sv` in the name |
| `CONTENT` | the per-vacancy content file (section 3) |
| `JOB_PACK_PANDOC`, `JOB_PACK_CHROME`, `JOB_PACK_PDFINFO` | the tools, default `pandoc`, `google-chrome`, `pdfinfo` |

Exit: 0 done, 1 a usage refusal, 2 a build refusal (the CONTENT lacks a key,
a base CV lacks what the CV step needs, a replace text is not found exactly
once, a foreign `out/`, pandoc or Chrome cannot be run, a `ROLE` that is not
a plain name of letters, digits, `.`, `_` and `-`), 3 the ad could not be
fetched. A missing pdfinfo only leaves the page counts as `–`.

The pick: per language, the base CV whose skills table (`<table
class="skills">`, first cell of each row) names the most technologies the ad
names; a tie goes to the larger file name, as the names carry their date.
`CV["base"]` in the CONTENT overrides it per language.

## 3. The CONTENT contract

A python file that sets these names; the fixture
`csi-spl-orc/src/bash/tests/fixtures/job-pack/content.py` is a complete,
synthetic example. It lives outside git, next to its pack, as does every
real CV: the action and its repo hold no personal data.

| name | shape |
|---|---|
| `NAME` | the applicant's name; the file names use it with `-` for spaces |
| `ROLE`, `ROLE_TITLE` | the file-name slug (`Data-Engineer`) and the title shown in the index |
| `DATE` | `YYYY-MM-DD`, default today (UTC) |
| `LANGS` | the languages, e.g. `["en", "fi", "sv"]` |
| `CONTACT` | the contact line under the name |
| `T` | `role`, `terms`, `avail`, `date`, each `{lang: text}` |
| `L` | the labels `hl`, `ppr`, `rpp`, `ppr_intro`, `rpp_intro`, `summary`, `req`, `reqs`, `projs`, `proj`, `how`, each `{lang: text}` |
| `PR`, `PROJ_ORDER` | `{project id: {lang: name}}` and the project ids in order |
| `REQ` | `[(id, {lang: title}, [(project id, {lang: how})], {lang: note})]` |
| `PROJ_HOW` | `{project id: {lang: text}}` |
| `HL`, `HL_TAIL` | `{lang: [(point, text)]}` and `{lang: text}` |
| `IDX`, `NAMES` | the index page: `{lang: {toc, cols (4), grp, rows (5)}}` and `{lang: [5 document names]}` |
| `LETTER` | `{lang: {copy (2), to, re, att, recipient, subject, h1, hi, p1, hook, p2, why, li [(point, text)], adj, demo (may be empty), p3, rows [(label, value)], call, sign}}`; `W` is read when `LETTER` is not set |
| `CV` | `kicker`, `tagline {LANG: text}`, `key_head {LANG: 6 headers}`, `key {LANG: [(technology, level, experience, last used, projects)]}`, optional `base {lang: path}` (relative to `MASTER_CV_DIR`), `skills_drop [technology]`, `replace [(old, new)]` or `{LANG: [(old, new)]}`, each old text found exactly once |

`KEYWORDS` (optional): the technologies the ad names, for the fit table;
without it, the base CV's technologies the ad names.

The CV step keeps the base CV and changes only what the CONTENT names: the
title, kicker and tagline; the key table (replaced, or put after the tagline
when the base has none); the dropped skills rows; the replace pairs.

Checked 2026-11-15 on the latest real pack (dispatch topic f1133a10, read on
the box, never copied into git): its own `content.py` and `cv.py` data mapped
onto this contract, the action rebuilt the same 49 files, 28 of 28 html and
markdown byte-identical to the hand-built pack and every pdf with the same
page count.

## 4. The owner's rules it applies

From the owner's answers in the first such pack (csitea topic e4588efb),
generalised by the dispatch holder (SPL-5555, msg fd94e292):

1. The projects keep the latest master CV's format and are otherwise
   unchanged: the CV step changes only what the CONTENT names.
2. Extra weight for the technologies the ad names: the pick scores them, and
   the key table lists them.
3. Unrelated technology is trimmed: `CV["skills_drop"]`.
4. Years of experience only as the master CVs back them, never invented:
   `internal/fit.md` sets, per language, each key-table row against that
   language's base CV skills table (`backed`, or `CHECK: master CV says N`,
   or `CHECK: not in the master CV skills table`, or `CHECK: the pack gives
   no years` / `CHECK: the master CV gives no years`) and lists each
   technology the ad names that the CV lacks; the run ends with
   `WARN fit: <n> row(s) to CHECK`. Years are read as a number or a number
   word (`5`, `5+ years`, `five years`, `viisi vuotta`); months count as a
   twelfth of a year, so `3 months` against a master 3 is a CHECK. A CHECK row
   is put to the owner as a question before the pack goes out; the action
   never changes a number by itself.
5. The deliverable is the whole zip plus the recipient address from the ad
   (`vacancy/contacts.txt`, `LETTER[lang]["recipient"]`).

The fleet data rule decides who may touch a pack: it carries personal data,
so only a claude, grok or mistral seat builds it or reviews its Finnish or
Swedish text, never agy or qwen (global `CLAUDE.md`, "Spawn an agent").
Nothing is sent by the action.
