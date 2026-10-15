# Round 12 Claude Seat Verdict

> Generated from qto doc `775fea32-0cd5-4e19-9a79-04da0cb0843b`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Seat: `c-212@sat` (claude), issue SPL-2005. Reviews plan **v0.2**
(`89ceb79ec`). v0.2 changes only seat ids (`git diff --stat f8f703de3 89ceb79ec`
-> 1 file, the plan), so the rows are the v0.1 rows.

Every number below comes from a command run in this session on `sat`, on
`f8f703de3` (the code is identical at `89ceb79ec`), n=1 per command. Journal:
`c-212@sat:/tmp/c212-r12/journal.txt`.

<a id="ws-doc-65b99f32-2a73-4a82-92f4-2f8ff746a145"></a>
## Summary

5 agree (01, 03, 04, 05, 06), 4 agree with changes (07, 08, 09, 10),
1 disagree (02). R1 holds.

| Row | Practice | Verdict | Command | Output |
|-----|-----------|-----------|---------|---------|
| 01 | `ci(r12-01-review-line-check-agy-support)` | agree | `git grep -i agy f8f703de3 -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh \| wc -l` | `0` |
| 02 | `ci(r12-02-review-line-check-remote-box)` | **disagree** | `git grep -c 'exit 2' f8f703de3 -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh` | no output (0 matches); `'return 2'` -> `1` |
| 03 | `refactor(r12-03-wui-small-store-channel)` | agree | `sed -n '/channel\.ts/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/channel.ts <anon>', 576],` |
| 04 | `refactor(r12-04-wui-small-create-live-client)` | agree | `sed -n '/createLiveClient/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/utils/live-ws.mjs createLiveClient', 499],` |
| 05 | `refactor(r12-05-wui-small-create-spool-client)` | agree | `sed -n '/createSpoolClient/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/utils/spool-client.mjs createSpoolClient', 545],` |
| 06 | `refactor(r12-06-bash-cleancode-ceilings-lowered)` | agree | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \| grep -c "NOTE LONG"` | `2` (174 under 175, 119 under 120), rc 0 |
| 07 | `refactor(r12-07-bash-small-run-execute-step)` | agree with changes | `git grep -n 'execute_step 99' f8f703de3 -- csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh \| wc -l` | `2` (lines 27, 31) |
| 08 | `test(r12-08-go-coverage-blob-avatar-key)` | agree with changes | `go test -coverprofile=/tmp/c212-r12/blob.cov ./internal/blob && go tool cover -func=/tmp/c212-r12/blob.cov \| grep -E 'AvatarKey\|total'` | `blob.go:40: AvatarKey 0.0%`, total `66.2%` |
| 09 | `test(r12-09-go-coverage-action-json-helper)` | agree with changes | `go test -coverprofile=/tmp/c212-r12/action.cov ./internal/action && go tool cover -func=/tmp/c212-r12/action.cov \| grep -E 'action.go:398\|total'` | `action.go:398: JSON 0.0%`, total `72.4%` |
| 10 | `test(r12-10-no-box-path-source-expand-dirs)` | agree with changes | `git grep -c 'csi-spl-api' f8f703de3 -- csi-spl-iac/src/bash/tests/no-box-path-source.tst.sh` | no output, rc 1 (0 matches) |

Go commands ran with `export PATH="/usr/local/go/bin:$PATH"` from
`csi-spl-api/src/go/spool-hub-api`.

<a id="ws-doc-43f6f272-5af5-4268-960d-e383d5b3d772"></a>
## 1. Per row

<a id="ws-doc-07e129ff-1fd7-4e25-a2c1-11d993e54674"></a>
### 1.1 Row 01: agree

The gap is real, and here is a red control for it. A real agy transcript
(`~/.gemini/antigravity-cli/brain/ba1f8200-.../.system_generated/logs/transcript.jsonl`)
has `grep -c '"run_command"'` -> `68`, `grep -c CommandLine` -> `68` and
`grep -o '"command"' | wc -l` -> `0`. The python walker collects only a
`"command"` key (`spl-review-line-check.func.sh:93`). A one-line fixture in
that shape,
`{"tool_calls":[{"name":"run_command","args":{"CommandLine":"bash csi-spl-orc/src/bash/tests/spl-review-line-check.tst.sh"}}]}`,
checked with `REVIEW_LINE_BOX=sat REVIEW_LINE='review: a-1@sat agy PASS <0x40> ran: bash spl-review-line-check.tst.sh | read: x | log: a-1@sat:/tmp/c212-r12/agy-fixture.jsonl' ./run -a do_spl_review_line_check`
-> `MISSING spl-review-line-check.tst.sh`, `FAIL 0 of 1 ... (0 commands read)`,
status 3. Row 01 can use that fixture as its red control.

<a id="ws-doc-874e729c-8420-433b-9523-fcbe3f1c907a"></a>
### 1.2 Row 02: disagree

- **The measurement does not reproduce:** `exit 2` has 0 matches. The
  refusal is `return 2` at `spl-review-line-check.func.sh:37` (1 match).
- **The refusal is the designed contract, not a defect:** the header says
  `Never fetches a log from another box: run it on the reviewer's`
  (`:18`) and `Exit 2: the log is on another box (named).` (`:21`). Run
  with a `PC` log on `sat`, it prints
  `REFUSED the log is on box 'PC', this is 'sat': run it on PC (never fetched)`,
  status 2. That message already says what to do instead.
- **"verify via SSH peer" assumes a path that is not there:** from sat,
  `timeout 15 ssh -o BatchMode=yes <editor box tag> true` -> `Could not
  resolve hostname`, rc 255. A fetch also copies a reviewer's transcript across
  boxes, which the round 11 design ruled out.
- **"passes or delegates on new script" is not a red control:** it names no
  input that fails before and passes after.

Proposal: drop row 02 from round 12, or rewrite it with an explicit
mechanism that runs the check on the log's own box (for example the
reviewer runs `do_spl_review_line_check` there and pastes the `OK n of n`
line), plus a red control. That rewrite needs its own measurement first.

<a id="ws-doc-90ba8bcc-2815-4754-9ead-9b1a6fe8913b"></a>
### 1.3 Rows 03, 04, 05: agree

The sites match: `channel.ts:67` is `export const useChannelStore = defineStore('channel', () => {`,
`live-ws.mjs:209` is `export function createLiveClient({`, and
`spool-client.mjs:272` is `export function createSpoolClient({`. The LONG
map has 3 entries (`sed -n '/^const LONG/,/^\])/p'`). The unit tests the
rows name exist: `live-ws.test.mjs`, `spool-client.test.mjs` and 10
`channel-*.test.mjs` files.

<a id="ws-doc-4e45c7b3-b6c4-4edc-b59b-4ca5f780a856"></a>
### 1.4 Row 06: agree

The 2 NOTE lines read `is 174 lines, under its ceiling 175` and
`is 119 lines, under its ceiling 120`. The ceilings are at
`bash-cleancode.tst.sh:23,24` (`sed -n 20,35p`).

<a id="ws-doc-ede93f52-6bc2-4f44-99fd-6a48a79a8c76"></a>
### 1.5 Row 07: agree with changes

`execute_step` is 99 lines in both copies (`sed -n '/^execute_step/,/^}/p' <f> | wc -l`
-> `99`, `99`), and the bodies are identical (`diff` -> empty). The whole
files differ, though: `cmp` -> `differ: byte 19283, line 552`. The LONG
list has 12 entries (`grep -cE` -> `12`).

- **Kind `complex_coding`, not `simple_coding`:** `run.sh` is the
  entrypoint of every `./run -a` action in iac and orc. A slip breaks every
  action on both trees, which is how r10-05 broke every iac action.
- **Name the smoke test** instead of "`./run` actions smoke test", for
  example `./run -a do_check_dist_hygiene` from both `csi-spl-iac` and
  `csi-spl-orc`. Also require that the two `execute_step` bodies stay
  identical (`diff` of the two `sed` extracts is empty after the change).

<a id="ws-doc-da3933bc-d0e1-489a-bf3b-e99c1c4c3b59"></a>
### 1.6 Row 08: agree with changes (the floor of 67.5 cannot be reached)

From `blob.cov`, `AvatarKey` is 3 statements (`blob.go:40.47`, `41.35`,
`44.2`) out of 435 in the package, with 288 covered. Covering `AvatarKey`
fully gives 291/435 = **66.9%**. Raising the floor to 67.5 would turn the
row's own lane red.

- Raise the floor 66.2 -> **66.9**, not 67.5 (or cover more of
  `internal/blob` and measure it).
- The red control then holds: without the tests, 66.2 < 66.9 fails.
- Path fix: with the plan's `api:` prefix (`csi-spl-api/src/go/spool-hub-api/`),
  `api:src/bash/tests/go-coverage-floor.txt` does not resolve. The file is
  `csi-spl-api/src/bash/tests/go-coverage-floor.txt` (line 19,
  `internal/blob 66.2`). The same fix applies to row 09.

<a id="ws-doc-8b9ab836-1f5a-45f5-9302-bcca64ea32da"></a>
### 1.7 Row 09: agree with changes (the red control cannot fail)

`internal/action` already measures **72.4%**, against a floor of 70.3
(`go-coverage-floor.txt:14`). A floor of 71.5 passes without any new test,
so "without new tests, raised floor fails" is false. `JSON` is 2 statements
(`action.go:398.25,401.2 2 0`) out of 645, with 467 covered. Covered, the
package reads 469/645 = **72.7%**.

- Raise the floor to **72.7**. Without the tests, 72.4 < 72.7 fails, so
  the red control holds.
- Note: `action_test.go` does not exist yet, so the row creates it
  (`ls internal/action/`).

<a id="ws-doc-fc4b2909-9e34-44c6-9602-d8499abcb8c6"></a>
### 1.8 Row 10: agree with changes (the site is the dir list, not `scan()`)

`scan()` (`no-box-path-source.tst.sh:19-22`) already takes any dirs. What
limits the scope is the `for d in ...` list at `:47` (4 dirs: iac/orc
`src/bash/run` and `lib`). The row's site should be `:46-47`, not `:15-30`.
Today the tree has `git ls-files 'csi-spl-api/*.sh' | wc -l` -> `26` and
`csi-spl-wui` -> `1`. The same regex over `csi-spl-api csi-spl-wui` finds
`0` sites, so the extended test lands green.

Red control: plant the `/opt/` source line in a temp copy, never in the
committed tree. The test already builds its fixtures in `mktemp -d`.

<a id="ws-doc-933d1c9f-a121-45cf-b678-4fa9f6ffd748"></a>
## 2. R1: no path in two rows of one batch

I parsed the path lists of section 3.1 into (batch, row, path) rows with
`sed -n '/^### 3.1/,/^### 3.2/p' | awk ...` (18 rows), then ran
`sort | uniq -d` on (batch, path) -> **0**. R1 holds.

The shared paths sit in different batches, in order: `spl-review-line-check.func.sh`
(01 then 02), `cleancode.test.mjs` (03, 04, 05), `bash-cleancode.tst.sh`
(06 then 07) and `go-coverage-floor.txt` (08 then 09).

One gap: row 02's 3.1 entry leaves out the test file its table row names,
`orc:src/bash/tests/spl-review-line-check.tst.sh`. It is still disjoint
within batch 2.

<a id="ws-doc-ae76925b-b89d-4790-99eb-f989926dd5d9"></a>
## 3. Signature

v1.0 (`26805ed51`) folds rows 07, 08, 09 and 10 as proposed
(`git diff aa5ff5a11 26805ed51 --stat` -> 1 file, the plan). Row 02 is now a
local syntax check with an rc 0 / rc 1 red control that never fetches a
log, which resolves my disagreement.

signed: c-212 on 26805ed517c89f170f011b1df103f797cdd52a8d
