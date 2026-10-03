---
name: graft
description: >
  Use for code search, symbol lookup, call-site tracing, and orientation
  before grep. How to use the local graft code index on this box, and -- more
  importantly -- when NOT to trust it. graft answers "what is this and how
  it is shaped"; grep answers "find every occurrence". Triggers: graft ask,
  graft skeleton, graft build, "use the index", "search the codebase",
  searching code, finding a function, orienting in an unfamiliar repo on this box.
---

# /graft — use the graft index for orientation, never for enumeration

The index on this box is **partial by construction**. Its grammars cover shell,
SQL, TypeScript, Python and JavaScript; the trees it runs over are 47-70% code
by file count on a good day, and the remainder -- JSON, Terraform, Markdown,
`.tpl`, `.mk`, `.pf_fragment`, generated SQL, everything unparsed -- is
**invisible to it**. Not ranked low. Absent.

That single fact drives every rule below.

## The rule

> **graft first for structure and orientation. `grep` / `git grep` remain
> authoritative for "find every occurrence". Never present a graft result as
> exhaustive.**

This inverts the guidance shipped with the tool, which tells the agent not to
fall back to `grep -rn`, and which describes `graft grep` as an "exhaustive
find". It is not exhaustive; it is exhaustive *over parsed files*, which is a
different claim wearing the same word.

Measured on a comparable tree: graft's own find returned **26 hits in 3 files**
where `git grep` returned **64 hits in 22 files** for the same pattern. The 19
files graft could not see were exactly the ones that had to change with the
other three. A rename driven off that first answer compiles, passes, and is
wrong in nineteen places. The same caveat applies to the MCP `graft_find_all`
tool, whose name is the strongest version of the claim and the least true.

## Use graft for

- **Orienting in a repo you have not read** -- what defines what, which module
  owns a concept, where the entry points are.
- **Structure questions**: who calls this function, what does this script
  source, which tables does this query read and write.
- **Narrowing before grepping**: let the index point at the subsystem, then
  grep that subsystem properly.

## Do NOT use graft for

- **"Find every X"** -- every rename, every call-site sweep, every
  "are we done removing this" check. Use `git grep -n` (tracked files) or
  `grep -rn` (everything, including untracked and generated).
- **Any answer whose value depends on the list being complete.** If being wrong
  by omission matters, graft is the wrong tool by construction.
- **Config, data, docs, templates.** Not indexed. A graft miss there means
  nothing at all.

## How to phrase a graft result

Say what it is:

> "The index shows 3 call sites in `csi-spl-orc/src/bash/run/`. It only covers shell and
> Python here, so this is not the full list -- `git grep` for the sweep."

Never:

> "There are 3 call sites." *(the index cannot support that sentence)*

If you have already answered from graft and the question turns out to be a
completeness question, **redo it with grep and say you did.** A quietly
narrowed answer is worse than a slow one.

## The commands (0.18.0)

| command | what it is for |
|---|---|
| `graft ask "<question>"` | ranked nodes + exact `file:line`. The orientation tool. |
| `graft skeleton <file>` | signatures-only view of one file -- the cheapest way to see its API surface |
| `graft build` | (re)build the repo's out-of-tree index from the code. Seconds, no key, no network. |
| `graft check` | fail if the index is stale relative to the code |
| `graft version` | what is installed (it also probes npm, and reports `latest: unreachable`, which is the zero-egress setup working) |

There is no `graft grep` in this version; `ask` is the retrieval path.

## Invocation on this box

Local only. Two things must stay true on every call:

- `DO_NOT_TRACK=1` is set and telemetry is disabled.
- **Never pass `--deep`.** It makes model calls. `GRAFT_API_KEY` is deliberately
  unset so that a `--deep` slip fails loudly instead of quietly sending source
  off the box.

Both are enforced by the `graft-safe.sh` wrapper that IS `graft` on PATH here,
so this is a description of what already happens rather than a discipline to
keep. It also refuses `graft init` and `graft upgrade`.

Never run `graft init`: it writes a `.mcp.json` that spawns
`npx -y @nanonets/graft`, which reaches the public registry from inside a repo,
plus a repo `.claude/settings.json` of hooks -- and it does that even with
`--no-mcp --no-hooks`. The integration here is hand-installed. If a repo grows
an `.mcp.json` or a `.claude/settings.json` full of graft hooks, something ran
`init` -- remove it and say so.

The index does NOT live in the repo. On this box `graft` is a wrapper that adds
`--dir $GRAFT_VAR_ROOT/index/<repo path with / as __>`
(`GRAFT_VAR_ROOT` defaults to `/var/csi/csi-spl/graft`) whenever you run it
inside a git repo, so `graft ask` reads the index the scheduled build writes and
`graft build` never creates `<repo>/graft`. Run
`graft-index-dir.sh` (in `csi-spl-orc/src/bash/features/graft/scripts/`) to print the path. A
`graft/` directory inside a repo is a leftover of an older in-tree build: it is
stale, do not read it, and say so.

## When the index is stale

It is a build artefact, not a live view. After someone else's push, after a
rebase, after a branch switch, it describes the tree as it was. If a graft
answer disagrees with the file in front of you, **the file is right.**
