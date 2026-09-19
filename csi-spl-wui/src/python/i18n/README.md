# i18n tooling (csi-spl-wui)

Workflow used to translate the WUI (19 locales, one nested JSON file
per locale under `i18n/locales/<code>.json`):

1. Builder writes real **en** values (the source language here — the donor
   WUI writes bg + en) in `i18n/locales/en.json` and copies the new keys into
   the other 18 (en values as placeholders).
2. `export_locale.py --codes en [--only-keys …] --out <WORKDIR>` →
   `en.json` for translators. `--only-keys` takes dotted paths
   (`nav.home,footer.legal_line`) and writes a nested subset — use that with
   `splice_locales.py --delta`.
3. Translators (LLM agents, batches of about 5 languages — the donor's
   practice, so every non-English catalogue is a machine draft until a native
   speaker reviews it; brief =
   `TRANSLATOR-BRIEF.template.txt` with `<WORKDIR>` filled) write
   `<WORKDIR>/<code>.json` with the identical nested key set.
4. `splice_locales.py --dir <WORKDIR> [--codes es,fi,...] [--delta]` merges
   them back into `i18n/locales/<code>.json`.
   * without `--delta`: every file must contain the full leaf-key set of
     `<WORKDIR>/en.json` (parity assertion).
   * with `--delta`: files contain only changed keys; they are deep-merged
     (every dotted key must already exist in the live locale, or in
     `<WORKDIR>/en.delta.json`).
5. `pnpm test` (includes `tests/unit/i18n-parity.test.mjs`, which CI runs
   through `pnpm run test:unit` in `.github/workflows/10_ci-quality.yml`).

Housekeeping: `find_dead_keys.py` lists the leaf keys no source under
`src/` or `tests/` can reach — literal `t('a.b.c')`, template-literal
(`` t(`a.b.status_${s}`) ``), `'a.b.' + x` concatenation and bare-identifier
completion all count as reachable, so the report is a shortlist that is safe
to delete rather than every unused key. Delete with a committed one-off so all 19
locales move in lockstep; `splice_locales.py` only ever merges.

Both tools print usage with `--help`. `--locales-dir` defaults to
`csi-spl-wui/i18n/locales` relative to the script, so they can be invoked
from any cwd.

Locales: `bg en es et el fi he lt lv mk nl pl ro ru sk sr sv tr uk`.

Rule (project-wide): every helper script used during work lives in the repo
(`src/python/…`, `src/bash/scripts/…`), never only in a scratch dir.
