# Refactoring round 82 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6166  
Topic: d308c8ea-4d48-45ab-a40c-c75fb14d9eb6  
Discussion: d308c8ea-4d48-45ab-a40c-c75fb14d9eb6 (t1 #refactoring, "Refactor round 82", opener msg 160de19f)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r82**, plan `refactor-round-82-plan.md`, rows `r82-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 81 ([refactor-round-81-plan.md](refactor-round-81-plan.md))
is still open: r81-01 is on trunk (`3174e591a`, SPL-6163), r81-02 is building
(`spl-self-host-up.func.sh`, `check-hub-deploy.tst.sh`). This round does not wait for it
and stays off its files (2.2). The perf floor (rulebook 4.4), the holder's read on
`cb64560e0`: `perf 29 refactor 108 perf-share 21.2% floor-met`, so this is a refactor
round.

**Row 01** makes the five `local x="${1:?...}"` lines of `gcp-account-pin.func.sh`
return 1 with a usage line instead of exiting the caller's shell, in both byte-identical
copies (iac and orc): r81 section 7's "**first candidate for r82**", the shape r80-02
and r81-02 gave one function each. **Row 02** makes orc's `validate-params.func.sh`
byte-identical to the iac and utl copies (two comment lines drifted) and pins the three
copies with a `cmp` in `run-sh-parity.tst.sh`, as that test already pins `run.sh`.

**Status: v1.0.** The panel passed v0.1 `68117dca8` with no W (m-742@sat, mistral; seat
file `fbe95d9ef`, folded here as `csi-spl-doc/doc/md/refactor-round-82/seat-mistral.md`;
section 8). It lands on the holder's GO (c-002@sat, msg 1b6643cd), whose run of
`do_spl_review_line_check` on the panel's line printed rc 0. No row changed since v0.1.
Editor: **c-706** (claude).

**One sha:** every count is measured on **`3174e591a`** (`origin/master` 3174e591a,
committed 2026-11-21T09:44:36+02:00), n=1 per command unless stated. Reads are on that
sha with `git show` / `git grep` or on this lane's worktree at that sha. **Every test
named below was RUN**: the "before" column on this lane's worktree at `3174e591a`,
unmodified; the "head" column on a `git archive 3174e591a` scratch copy with the row's
change applied in 1.3's / 1.4's shape (a `git init` of that copy for the two tests that
need a git tree, 1.5), and the red controls on a second, unmodified archive copy with
only the new test case added. Nothing of either is committed. `origin/master` moved to
`bd92fa555` during the reads; no row file changed
(`git diff --name-only 3174e591a bd92fa555 -- <the 5 row paths>` -> empty). Queue, lane
map, brief and branch readings are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T09:19:19+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r81-plan'` -> commit
  `864f7ff17` "refactor round 81 plan v1.0, panel m-723 mistral PASS on v0.1 7dbfe9f78
  ...". Every later read of r82 uses this W.
- **`r82` is free** (2026-11-21T07:48:48Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r82-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r82-*' 'refs/heads/wip/*r82*' 'refs/heads/*-r82-*' 'refs/heads/*refactor-round-82*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r82-[0-9]{2}|refactor-round-82' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **1 file**: this planner's brief. The panel seat's
    brief is on the other box (the lane map lists it live there,
    `m-742 ... c002-refactor-round-82-mistral-panel-seat`, 2.2).
  - Control: the same log read with `(r81-` since W -> 3 lines (`3174e591a`,
    `864f7ff17`, `67546e091`), so the read sees a used id.
- **No `refactor-round-82*` file** exists under `csi-spl-doc/doc/md` on `3174e591a`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-82` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`, `utl:` = `csi-spl-utl/`; `lib:` =
`lib/bash/funcs/`, `tests:` = `src/bash/tests/`.

| input | source | on `3174e591a` | here |
|---|---|---|---|
| `gcp-account-pin.func.sh`, iac + orc | r81 section 7, "first candidate for r82" | byte-identical (`md5sum` equal, 322 lines each); `grep -c ':?'` -> **6** per copy: the 5 `local x="${1:?...}"` lines and `:159` inside a `$(jq ...)` (1.3) | **row 01**, the 5 lines; `:159` left out (it already returns 1, 1.3) |
| the other `local x="${N:?...}"` lines | r81 section 7 | `git grep -nE 'local [A-Za-z_]+="?\$\{[0-9]:\?'` over iac, orc and utl `lib/bash/funcs` + `src/bash/run` -> **29 lines in 11 files**: iac 14 in 6, orc 10 in 3 plus `spl-self-host-up.func.sh:317` (r81-02's, building), utl 5 in 2 | row 01 takes the 10 of `gcp-account-pin.func.sh`; the rest left out (section 7) |
| `validate-params.func.sh`, 3 copies | r81 section 7 ("3-copy rows") | the `:13` `${1:?}` line: its one caller guards it (`src/bash/run/run.sh:159`, `[[ -n "$func_file" ]] && ... do_validate_params "$func_file"`, the same line in all 4 `run.sh`), so no caller reaches the empty path. Measured instead: the copies **differ**: `md5sum` iac = utl, orc differs; `diff iac orc` -> 2 hunks, **comment lines only** (1.4) | **row 02**: the copies made one text; the `:13` line left out (section 7) |
| `parse-metadata.func.sh`, 3 copies | r81 section 7 | 4 `${1:?}` lines per copy; copies orc = utl, iac differs in its 2 `@example` lines, which each name an action of their own module (`iac:src/bash/run/tf-state-show.func.sh` exists; `orc:src/bash/run/tf-030-import-existing-cloud-run.func.sh` exists, not in utl) | left out (section 7): 12 lines over 3 files is over the 5-site cap, and unifying the examples needs a module-neutral example first |
| r81-01 R7 notes (c-699 PASS on `b4f602bf6`) | the brief | the landed body of `3174e591a` carries the review line and no N or W note (`git log -1 --format=%B 3174e591a \| grep -cE '^ *-? *\*?\*?[NW][0-9]'` -> 0) | nothing to take |
| r81-02 R7 | the brief | not landed (the lane builds) | nothing to take yet; the r82 editor reads it when it lands |
| r81 panel N1-N4 (seat file `csi-spl-doc/doc/md/refactor-round-81/seat-mistral.md`) | the brief | N1 row 02's exit -> return, N2 two citations, N3 live-state drift, N4 base moved: all folded into r81 v1.0 (r81 section 8), none names a new site | nothing to take |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`) | the brief | **not on this lane's box** (`ls` -> no such file); the r81 plan and its panel read it on 2026-11-21 (r81 1.2, seat file `:176-195`) and accounted for every refactor-shaped item | nothing new taken; **the holder is asked to inline any refactor item added since** (section 4) |
| spec 011 tasks | the brief | `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r81's reasons hold |

### 1.3 Row 01's sites: the five `${1:?}` lines of `gcp-account-pin.func.sh`

`iac:lib/gcp-account-pin.func.sh` (322 lines) and its copy `orc:lib/gcp-account-pin.func.sh`,
byte-identical (header `:23-24`; `iac:tests/gcloud-account-pinned.tst.sh:194-195`,
section 4, `cmp -s "$PIN" "$ORC_PIN"`). The same five lines in each:

```text
:40   do_gcp_cnf_value()          local key="${1:?key}" cnf="${2:-}"
:138  do_gcp_env_sa_key_file()    local ENV="${1:?env}" ORG="${ORG:-}" APP="${APP:-}" pin="..."
:171  do_gcp_activate_sa_key()    local key="${1:?key}" email have
:216  _do_gcp_resolve_account()   local mode="${1:?mode}" cnf="${2:-}" account key
:264  _do_gcp_pin()               local mode="${1:?mode}" cnf="${2:-}" account
```

**What is wrong.** `${1:?}` with an empty or missing argument prints
`<file>: line <n>: 1: <word>` and **exits** the non-interactive shell (developer guide
2.4.3: a function returns a code). Measured on `3174e591a` (n=1 per form and function,
`bash -c 'do_log(){ echo "$*" >&2; }; source <file>; <fn> <args>; echo rc=$?'`): for all
five functions, `""` and no argument each print the `line <n>` message and **no `rc=`
line**; called as `x=$(<fn> <args>)`, the subshell exits and the caller reads `rc=1`.

**Line `:159`** (`do_gcp_sa_key_email`, `email=$(jq -r ... "${1:?key}" 2>/dev/null)`) is
not a site: the expansion sits inside its own command substitution, so it exits only that
subshell; the function goes on to `return 1` (`:160`). Measured: `""` and no argument,
direct and in `$(...)`, each print the message **and** `rc=1`.

**The callers** (`git grep -nE '(^|[^_a-z])<fn>( |"|\)|$)'` outside the lib, comment lines
dropped): `do_gcp_cnf_value` 1 (`iac:src/bash/run/gcp-evlog-reader-key.func.sh:39`, a
literal key), `do_gcp_env_sa_key_file` 4 (the `gcp-get-alert-incident`,
`gcp-list-alert-incidents`, `gcp-list-monitoring`, `gcp-list-secrets` actions, each
`key=$(... "${env}" ...) || {...}`), `do_gcp_activate_sa_key` 4 actions and 1 test
(`gcp-copy-secret.func.sh:80` the one direct call, the rest in `$(...)`),
`_do_gcp_resolve_account` and `_do_gcp_pin` 0 outside the lib (their wrappers pass the
literal `run` or `bootstrap`, `:202`, `:212`, `:252`, `:260`, and `_do_gcp_pin` calls the
resolver with its own `mode`, `:268`). Every caller passes a non-empty argument; none
takes the empty path, so the row changes nothing a caller sees except that path.

**The shape**, r80-02's and r81-02's, with this file's `do_log ... >&2` (the functions
print their result on stdout, `:56`, `:182`, `:218`):

```text
[[ -n "${1:-}" ]] || { do_log "FATAL <fn>: usage: <fn> <args>" >&2; return 1; }
local <x>="$1" ...
```

with `<args>`: `do_gcp_cnf_value <key> [cnf]`, `do_gcp_env_sa_key_file <env> [cnf] [envs]`,
`do_gcp_activate_sa_key <key>`, `_do_gcp_resolve_account <run|bootstrap> [cnf]`,
`_do_gcp_pin <run|bootstrap> [cnf]`; the rest of each `local` line is unchanged (`:138`
keeps its `ORG`, `APP` and `pin` locals). Both copies take the same edit, so section 4's
`cmp` stays green. Each function grows by 1 line (the longest, `_do_gcp_resolve_account`,
25 -> 26); the file 322 -> 327 lines (`diff` of a copy: 5 lines out, 10 in).

**The test.** One new block in `iac:tests/gcloud-account-pinned.tst.sh` (277 lines),
section 4b after `:195`, which already sources `$PIN` (`:35`):

```text
# --- 4b. an empty first argument returns 1, never exits the caller ----------------
for fn in do_gcp_cnf_value do_gcp_env_sa_key_file do_gcp_activate_sa_key _do_gcp_resolve_account _do_gcp_pin; do
  for a in '""' ''; do
    out=$(PIN="$PIN" bash -c "do_log(){ echo \"\$*\"; }; source \"\$PIN\"; $fn $a; echo rc=\$?" 2>&1)
    grep -qx 'rc=1' <<<"$out" && grep -q "usage: $fn " <<<"$out" \
      && pass "4b. $fn '$a': returns 1 and says why" || fail "4b. $fn '$a': $out"
  done
done
```

(the lane may word it otherwise and add the case to the file's Purpose header `:21`; the
5 functions, the two forms and the two checks stay). The orc copy has no test of its own:
section 4's `cmp` makes the iac test cover it.

**Data rule.** The lib resolves service-account key PATHS and activates them; it is
secret-adjacent, so the row is claude only (never agy or qwen), and its brief names no
key path. Every test uses fake keys under `mktemp -d`; no row step reads a real key, calls
GCP or needs a credential.

### 1.4 Row 02's site: orc's `validate-params.func.sh`

`iac:lib/validate-params.func.sh` (65 lines), `utl:lib/validate-params.func.sh` (65,
`md5sum` equal to iac's) and `orc:lib/validate-params.func.sh` (63 lines). `diff iac orc`:

```text
26c26,27
<     # Extract variable name (first word). read, not awk: this runs per
<     # @param on every ./run.
---
>     # Extract variable name (first word)
30c31,32
<     # Check if marked as required. Case-insensitive, same as grep -i,
<     # with no fork.
---
>     # Check if marked as required
```

(`<` = iac, `>` = orc in the plan's reading order; the hunk headers are those of
`diff orc iac`, the reverse direction, same content (panel N2): orc carries the SHORT comments; the
row takes iac's two-line forms into orc.) **Only comment lines differ**: the code under
each is the same `read -r var_name _rest` and the same `${param_def,,}` match, so iac's
comments are true of orc's code. The longer comments sit in the iac copy since
`947aacbfd` (r3-28, "Port the no-fork whitespace trim to the iac copies of the ./run
helpers"); utl's copy came later with them (`dae2f43d6`, SPL-5549); no commit since
brought them to orc (`git log --format='%h %s' -- <each copy>`).

**The change:** orc's file becomes iac's text (`cp`; `diff` afterwards -> empty, 63 ->
65 lines). Comment lines only: `git diff -U0 -- <orc file> | grep -E '^[-+][^-+#]' |
grep -vE '^[-+]\s*#'` -> 0.

**The test.** `iac:tests/run-sh-parity.tst.sh` (44 lines) pins the four `run.sh` copies
with `cmp -s` (`:23-31`) and a planted-drift control (`:38-40`). The row adds, before the
root-copy check (`:33-37`; `:32` closes the `run.sh` loop), the same `cmp` for the helper:

```text
vp="$REPO_ROOT/csi-spl-iac/lib/bash/funcs/validate-params.func.sh"
for mod in orc utl; do
  if cmp -s "$vp" "$REPO_ROOT/csi-spl-$mod/lib/bash/funcs/validate-params.func.sh"; then
    pass "iac and $mod validate-params.func.sh are byte-identical"
  else
    fail "iac and $mod validate-params.func.sh differ" "diff $vp $REPO_ROOT/csi-spl-$mod/lib/bash/funcs/validate-params.func.sh"
  fi
done
```

and names `validate-params.func.sh` in its Purpose header (`:3-11`). The file's existing
control (`:38-40`) already proves `cmp -s` sees a one-byte change. (`parse-metadata.func.sh`
stays out of the loop: its copies differ on purpose today, 1.2.)

**The tests that name the site** (R2): `git grep -lE 'validate-params\.func|do_validate_params'`
over the three modules' `src/bash/tests` -> `iac:tests/param-required.tst.sh` (run by each
module's own `param-required.tst.sh`, so all three were run), `orc:tests/parse-metadata-nofork.tst.sh`,
`iac:tests/comment-refs-exist.tst.sh` (`:64-65` lists the copies), plus
`iac:tests/action-header-tags.tst.sh` (it sources the sibling helper
`parse-metadata.func.sh`) as a cheap neighbour. No test holds a 30-character string of
the two changed comments (`git grep -lE 'Extract variable name|Check if marked as required' -- '*test*' '*tst*'` -> 0).

### 1.5 Before and on the row's head

2026-11-21T07:4xZ-07:5xZ, n=1, `SPOOL_TEST=1`; pass lines `grep -ciE '^ *(ok|pass)'`,
fail lines `grep -ciE '^ *(not ok|fail)'` (a final summary line counts as one). "Before"
= this lane's worktree at `3174e591a`; "head" = the `git archive` copy with the row's
change (1.3, 1.4). Pass counts of the worktree and of an archive copy differ for a suite
with git-dependent cases (`gcloud-account-pinned.tst.sh` 38 in the worktree, 35 in a
plain archive copy, 38 in a `git init` archive copy), so each red/green pair below is read
on the same kind of tree.

| suite | row | before rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `iac:tests/gcloud-account-pinned.tst.sh` | 01 | 0 / 38 | 0 / 48 / 0 (`git init` copy); 0 / 45 / 0 (plain copy, before there 35) | +10, section 4b. **Red:** section 4b against the parent's lib (plain copy): rc 1, 34 pass, 11 fail lines (10 cases + the summary), e.g. `FAIL: 4b. do_gcp_cnf_value '""': .../gcp-account-pin.func.sh: line 40: 1: key` |
| the other 16 files of `git grep -lE 'gcp-account-pin\|do_gcp_cnf_value\|do_gcp_env_sa_key_file\|do_gcp_activate_sa_key\|_do_gcp_resolve_account\|_do_gcp_pin\b' -- 'csi-spl-*/src/bash/tests/*'` | 01 | each rc 0, 0 fail | each rc 0, 0 fail, the same pass count as before | pass lines: `adhoc-harvest-gcp-actions` 28, `gcp-001-dead-credential-no-create` 32, `gcp-002-004-bootstrap` 39, `gcp-actions-isolated-config` 13, `gcp-billing-invoices` 67, `gcp-get-alert-incident` 27, `gcp-key-from-project` 19, `gcp-list-alert-incidents` 25, `gcp-list-monitoring` 14, `gcp-list-secrets` 10, `gcp-owner-login-bootstrap-only` 8, `gcp-purge-prd-backups` 17, `gcp-sa-key-email` 16, `gcp-tf-shared-bodies` 63, `spl-gh-wire` 17, `wui-hosting-019-031` 29 (all in `iac:tests/`) |
| `iac:tests/run-sh-parity.tst.sh` | 02 | 0 / 6 | 0 / 8 / 0 | +2, the `cmp` loop. **Red:** the loop against the parent's orc copy: rc 1, 6 pass, 2 fail lines (`FAIL: iac and orc validate-params.func.sh differ -- diff ...` + the summary); utl passes |
| `iac:`, `orc:`, `utl:tests/param-required.tst.sh` | 02 | 0 / 17 each | 0 / 17 / 0 each | |
| `orc:tests/parse-metadata-nofork.tst.sh` | 02 | 0 / 15 | 0 / 15 / 0 | |
| `iac:tests/comment-refs-exist.tst.sh` | 02 | 0 / 21 | 0 / 21 / 0 (`git init` copy) | a plain archive copy fails `git ls-files` (2 fail lines, before and head alike): run it in a git tree |
| `iac:tests/action-header-tags.tst.sh` | 02 | 0 / 6 | 0 / 6 / 0 | |
| `iac:tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r82-01-gcp-pin-returns)` | bash that fails safely: a function returns a code (developer guide 2.4.3) | five functions of the gcloud identity lib exit the caller's shell on an empty first argument instead of returning 1 (1.3); r81 section 7's first candidate | `iac:lib/gcp-account-pin.func.sh:40,138,171,216,264`<br>and the byte-identical `orc:lib/gcp-account-pin.func.sh`, the same 5 lines<br>(+ section 4b in `iac:tests/gcloud-account-pinned.tst.sh`, after `:195`) | 5 lines x 2 copies | The 5 lines take 1.3's shape in both copies (`cmp` of the copies stays 0). **New section 4b** (1.3): each of the 5 functions with `""` and with no argument prints `rc=1` and `usage: <fn> `. **Red control:** 4b on the parent's lib FAILs 10 (`line <n>: 1: <word>`, no `rc=`), then GREEN; outputs in the body. **Behaviour:** the 17 test files of 1.5's grep, each as on the parent. Tests: those 17, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. No GCP, no real key: the tests stub gcloud and use fake keys. | either | claude | simple_coding | 1 |
| 02 `refactor(r82-02-orc-validate-params-parity)` | one helper, one text (developer guide 2.2.4; the `run.sh` parity of SPL-2756) | orc's copy of the `./run` param check lost two comments the iac and utl copies carry (r3-28 drift); nothing pins the three copies (1.4) | `orc:lib/validate-params.func.sh:26,30`<br>(+ the `cmp` loop in `iac:tests/run-sh-parity.tst.sh`, before `:33`) | 1 file, 2 comment hunks | orc's file becomes iac's text (`diff` -> empty). **New loop** (1.4): iac vs orc and utl `cmp -s`. **Red control:** the loop on the parent's orc copy FAILs 1 (`iac and orc validate-params.func.sh differ`), then GREEN (8 pass); outputs in the body. **Behaviour:** comment lines only (1.4's `git diff -U0` filter -> 0). Tests: `run-sh-parity.tst.sh`, the three `param-required.tst.sh`, `parse-metadata-nofork.tst.sh`, `comment-refs-exist.tst.sh` (in the worktree), `action-header-tags.tst.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (row 01's 5 lines and the
`rc=` forms in both copies, row 02's `diff iac orc`) on the `origin/master` it starts
from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r82-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r82-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01 changes only the empty-argument path, which no caller takes (1.3); the
lib's own header and `@param` lines are its doc and stay true. Row 02 changes comment
lines only. Each: `Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their files are disjoint (the two `gcp-account-pin`
  copies and `gcloud-account-pinned.tst.sh` vs orc's `validate-params.func.sh` and
  `run-sh-parity.tst.sh`), so both place at once.
- No row edits `iac:` / `utl:lib/validate-params.func.sh`, any `parse-metadata.func.sh`,
  any `run.sh`, `do_gcp_sa_key_email` (`:157-162`), any caller of the lib, the other
  `${N:?}` lines, `orc:src/bash/run/spl-self-host-up.func.sh` (r81-02), a migration,
  `csi-spl-cnf/`, terraform or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths (5): `iac:lib/bash/funcs/gcp-account-pin.func.sh`,
`orc:lib/bash/funcs/gcp-account-pin.func.sh`, `iac:src/bash/tests/gcloud-account-pinned.tst.sh`,
`orc:lib/bash/funcs/validate-params.func.sh`, `iac:src/bash/tests/run-sh-parity.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-706`, one call per
  path, 2026-11-21T07:54:43Z, n=1: **exit 4 on all 5**, the same **11 `unknown:` lanes**
  ("no live lane lists <path>, but 11 live lane(s) record no files"): four `rotate`
  seats, the spec 190 doc lane, the bug round 33 planner, r81-02 (its files are 2.1's
  `spl-self-host-up.func.sh` and `check-hub-deploy.tst.sh`), and four doc panel seats
  (bug rounds 32, 33, refactor rounds 81, 82). None is on a row path by its brief or its
  round's plan. No live lane lists a row path. The holder re-checks before placing.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 07:55:22Z): **12
  queued**: spec 184 (6), spec 033 T026, spec 123 L3-L7 (5). The live share line:
  refactor 6 of 37 known live lanes, 16% (band 10-20%: ok).
- **Briefs on this box** changed in the last 24 h (140 files under `<spool>/dispatch/briefs`
  and `<spool>/spawn-remote/briefs`, `find -mmin -1440`) naming a row basename
  (`gcp-account-pin`, `gcloud-account-pinned`, `validate-params.func`, `run-sh-parity`):
  **1**, this one.
- **Remote branches committed in the last 24 h** (42 besides master, 07:55:16Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 5 paths>` ->
  **0 hits**.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Live lanes named in the brief**: r81-01 (landed), r81-02 (`spl-self-host-up.func.sh`,
  `check-hub-deploy.tst.sh`), bug round 33's rows (`spl-spawn-enqueue.func.sh`,
  `spl-spawn-queue.tst.sh`, `spl-box-quota.func.sh`, `spl-box-pick.tst.sh`), SPL-6145
  (hub topic create prio: Go, `bd92fa555` landed it during these reads), spec 123 (store,
  cost), spec 033, the WUI lanes, spec 189, spec 190, the release-tooling lane, the
  private-workspace seats: none on a row path by its listed files.

## 3. Per row: what the lane does

- **r82-01:** the five `${1:?}` lines of `gcp-account-pin.func.sh` return 1 with a usage
  line, in both copies; `gcloud-account-pinned.tst.sh` gains section 4b.
- **r82-02:** orc's `validate-params.func.sh` takes the iac text; `run-sh-parity.tst.sh`
  pins the three copies.

## 4. Panel and reviewers (R7)

- Editor: c-706 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: m-742@sat (mistral), PASS on v0.1 `68117dca8`, no W, N1-N4** (section 8;
  seat file `csi-spl-doc/doc/md/refactor-round-82/seat-mistral.md`). Requested of the
  dispatch lease holder (task `dispatch-refactor-r82`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-82-mistral-panel-seat` (live on the lane map as m-742; agy, the
  main vendor for plan reviews, is out until about 11-24). The seat reviews this plan
  only.
- **The candidates file** is not on this lane's box (1.2). The holder inlined its new
  items (msg 83d8860e) and the panel read the file on sat (101 lines, N4): every
  refactor-shaped item is served (r78-02, r79-01, r81-01) or in section 7.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-21T07:56:08Z printed
  `pick=hold reason=waiting: grok weekly >= 95% or unknown on <both boxes> ...: queue the
  lane, spawn nothing`. So each row takes a fresh **claude waiver seat** (1a7c70da), as
  r63 to r81. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r82-01 | `c002-r82-01-gcp-pin-returns` | `refactor(r82-01-gcp-pin-returns, SPL-<row issue>): ...` | `review/r82-01` | 1 |
| r82-02 | `c002-r82-02-orc-validate-params-parity` | `refactor(r82-02-orc-validate-params-parity, SPL-<row issue>): ...` | `review/r82-02` | 1 |

**r82-01 brief, Files: ONLY** `iac:lib/bash/funcs/gcp-account-pin.func.sh` and
`orc:lib/bash/funcs/gcp-account-pin.func.sh` (`:40`, `:138`, `:171`, `:216`, `:264`;
the same edit in both, `cmp` equal after) and `iac:src/bash/tests/gcloud-account-pinned.tst.sh`
(section 4b after `:195`, its Purpose header). NOT `do_gcp_sa_key_email` (`:159`), NOT any
caller of the lib, NOT the other `${N:?}` lines (section 7). Do: plan section 2 row 01
verbatim, 1.3's shape; the red control (4b on the parent's lib) RED then GREEN in the
body. Gates: the 17 test files of 1.5 (each, rc and pass lines in the body,
`SPOOL_TEST=1`, in the worktree), `bash-cleancode.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. Data rule: claude only; the brief names
no key path; no GCP call, no real key. `Docs: none (...)`. Kind `simple_coding`, vendor
claude.

**r82-02 brief, Files: ONLY** `orc:lib/bash/funcs/validate-params.func.sh` (it becomes
the iac text, comment lines `:26`, `:30`) and `iac:src/bash/tests/run-sh-parity.tst.sh`
(the `cmp` loop before `:33`, its Purpose header). NOT the iac or utl copy, NOT
`parse-metadata.func.sh`, NOT any `run.sh`, NOT the `:13` `${1:?}` line (section 7). Do:
plan section 2 row 02 verbatim, 1.4's shape; the red control (the loop on the parent's
orc copy) RED then GREEN in the body. Gates: `run-sh-parity.tst.sh`, the three
`param-required.tst.sh`, `parse-metadata-nofork.tst.sh`, `comment-refs-exist.tst.sh`,
`action-header-tags.tst.sh` (in the worktree, `SPOOL_TEST=1`), `bash-cleancode.tst.sh`,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| `local x="${N:?...}"` lines, iac + orc + utl `lib/bash/funcs` and `src/bash/run` | 30 in 12 files on `3174e591a` (29 + r81-02's) -> 20 in 10 after row 01 (19 after r81-02) |
| `validate-params.func.sh` copies byte-identical to iac's | 1 of 2 (utl) -> 2 of 2 after row 02, pinned by `run-sh-parity.tst.sh` |
| measured on | `3174e591a`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `gcp-account-pin.func.sh:159` (`do_gcp_sa_key_email`) | already returns 1: the `${1:?}` exits only its inner `$(jq ...)` | 1.3 |
| `validate-params.func.sh:13` (3 copies) | its one caller guards the empty path (`src/bash/run/run.sh:159`), so no caller reaches it; a row would change no reachable path | 1.2 |
| `parse-metadata.func.sh`, 3 copies: 4 `${1:?}` lines each, and the iac / orc+utl `@example` drift | 12 lines over 3 files, over the 5-site cap; the examples name per-module actions (utl's names an orc-only file), so unifying them needs a module-neutral example first. **First candidate for r83:** the `@example` lines made module-neutral and the 3 copies pinned in `run-sh-parity.tst.sh` (row 02's loop takes it) | 1.2 |
| `tf-each-target.func.sh:14`, `gcp-billing-cnf.func.sh:48,68`, `spl-cost-gcp.func.sh:75` | r80 / r81 section 7's reasons hold: `set -e` by design; beside the queued spec 123 cost lanes (L3-L7, 2.2) | 1.2 |
| `spl-self-host-up.func.sh:317` | r81-02's row, building | 2.2 |
| a `DESK_KIND` check in `spl-desk-reply.sh` | a behaviour change: a bug row if wanted (r81 section 7) | r81 1.3 |
| r80-01 R7 N1-N4, `spl-spawn-place-argmax.tst.sh` section 9, spec 182 L2 `!inserted`, `ws-docs-head.mjs` synthetic click, spec 181 B10 N1/N2/N4 | r81 section 7's reasons hold (a gate right today, behaviour, test rows beside live lanes, WUI lanes live, spec text for those specs' owners) | r81 7 |
| `terraform init` without `-input=false`; the desk hop's env forwarding | behaviour changes: bug rows (r78 section 7) | r78 1.2 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | secret-class work (the data rule), r73 to r81 | r77 1.3 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, or the full sweep; the spec folder unchanged since W | 1.2 |
| the reply-kind set `result\|reject\|blocker\|msg\|$SPOOL_NOTE_KINDS`, written twice: the check in `spl-desk-reply.func.sh:550` and the copy in `test-spool-kinds.sh:57` (holder, 83d8860e; c-699 N1 f9b4dc2e) | it touches the reply action and the shared `spool-env.inc.sh`, not only the test: a third row. **First candidate for r83:** one named set in `spool-env.inc.sh` that both read | `git grep -nE 'result\|reject\|blocker\|msg\|' a83052abd -- csi-spl-orc/` |
| `topic_loop_fire.go` `!inserted` branch (SPL-6032 R7 N1); `spl-spawn-place-argmax.tst.sh:181-212` section 9 guard cases (b30-01 R7 N1) | test rows: a missing test case each, not a refactor of the code; for a test row or r83 | holder, 83d8860e |
| `[refactor] SPL-6107 N1`, `spl-desk-reply.sh` usage kinds | served: it is r81-01, `3174e591a` | `git log -1 3174e591a` |

## 8. Changes

- v0.1 (c-706): first draft. Row 01 makes the five `${1:?}` lines of
  `gcp-account-pin.func.sh` (iac + orc) return 1 with a usage line (r81's first
  candidate), row 02 makes orc's `validate-params.func.sh` byte-identical to iac's and
  utl's and pins the three. Every named test run on the row's head (1.5). Window W and
  the r82 slug proof recorded.
- 2026-11-21 09:13Z: m-742@sat **PASS** on v0.1 `68117dca89e4a32b006c551752a968cf60e3e04e`,
  no W (seat file `fbe95d9ef` on `review/c002-refactor-round-82-mistral-seat`, checks 1-8
  with commands and output). It re-ran the slug proof (0 `(r82-` lines since W, all
  history 0), printed every row site on `3174e591a` and origin/master `5d9bcef49` (all
  the same), re-ran both red controls (4b on the parent's lib: rc 1, 10 FAIL; on the
  row's head rc 0, 48 pass; the `cmp` loop on the parent's orc copy rc 1; on the head
  rc 0, 8 pass), the lane map (exit 4, no live lane on a row path), the queue (15, none
  on a row path), `do_check_dist_hygiene` and `do_check_pre_push` (all parts passed).
  - **N1**: row 01 changes the empty or missing argument path only (shell exit -> return 1
    plus a usage line on stderr); every caller outside the lib passes a non-empty first
    argument (1+4+4 callers on `3174e591a`). Disclosed in 1.3, pinned by section 4b;
    precedent r80-02 `5083f4cf9`, r81-02 `1fd68677a`. No change.
  - **N2**: three citation slips, none on a row site. Fixed: `run.sh:159` is
    `src/bash/run/run.sh:159` (1.2, section 7); the root-copy check of
    `run-sh-parity.tst.sh` is `:33-37` (`:32` is the loop's `done`), so the loop goes
    before `:33` (1.4, row 02, the r82-02 brief); 1.4's diff hunk headers are those of
    `diff orc iac`, same content (said there).
  - **N3**: live state moved since the plan's reads: the r81 control since W 3 -> 5 lines
    (`1fd68677a`, `b474a58fb`; r81 closed); lane map 11 -> 15 `unknown:` lanes, exit 4
    both times, none on a row path; queue 12 -> 15; refactor share 3/31 (9%), UNDER. No
    row change.
  - **N4**: the candidates file is on sat (101 lines) and the panel read it: every
    refactor-shaped item served or in section 7. A scratch copy of the base needs a
    staged git index (`git init` + `git add -A`) or the pin suite's section 6 CONTROL
    fails; 1.5 already runs that suite in a `git init` copy.
- v1.0 (c-706), on the holder's GO (c-002@sat, msg 1b6643cd; its review-line check rc 0):
  the PASS and N1-N4 recorded, N2's citations fixed, the holder's inlined items (83d8860e)
  in section 7, the seat file folded in. No row's files, red control or fix scope changed.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-706 (claude): v1.0.
- Panel reviewer seat: m-742@sat (mistral): **PASS** on v0.1 `68117dca8`, no W (section 8).
- Row R7 seats: section 4.
