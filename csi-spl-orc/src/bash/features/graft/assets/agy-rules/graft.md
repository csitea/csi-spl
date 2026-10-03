# Graft for code search

When searching, orienting, or tracing a codebase on this box, use `graft` first.
Do not open with grep, glob, find, or a full-tree read.

- `graft ask "<question>"` — structure, symbols, call sites, "where is this".
- `graft skeleton <file>` — one file's API surface.
- Then `git grep` / `grep` for completeness. Graft is not exhaustive: it only
  sees parsed languages. A graft miss is not evidence of absence.
- Phrase results as "the index shows …", never "there are N call sites".
- Never `graft init`, never `--deep`. Never read an in-repo `graft/` directory
  (stale leftover). The live index is out-of-tree under `$GRAFT_VAR_ROOT/index/`
  (`GRAFT_VAR_ROOT` defaults to `/var/csi/csi-spl/graft`).
- Indexed trees are listed in `$GRAFT_VAR_ROOT/repos.list` (or `GRAFT_REGISTRY`).
- Full procedure: the graft skill (`~/.gemini/config/skills/graft/SKILL.md`).
