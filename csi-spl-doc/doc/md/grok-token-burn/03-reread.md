# Grok token burn 3/6: re-reading the same file, listing or history

SPL-2216, owner HUM-10 topic t1 bd5579e7 (plan msg 0467b8be, analysis item
7). The pasted analysis guessed that Grok re-reads the same files and trees
within a session. Measured 2026-10-16: **it does, a little more than Claude,
but the re-reads carry 0.45 to 0.62% of Grok's input. That is under the 5%
bar of the brief, so nothing was changed.**

## 1. What is counted

`cd csi-spl-orc && ./run -a do_spl_token_reread` reads the lane sessions
(`csi-spl-wt/g-*`, `csi-spl-wt/c-*`) of the agent user:

- **A read** is a file tool (claude `Read`, grok `read_file`), a search tool
  (`Grep`, `Glob`, grok `grep`), or a shell command that only reads: `cat`,
  `sed -n`, `head`, `tail`, `ls`, `find`, `tree`, `git log/show/diff/status`,
  `grep`, `rg`.
- **A repeat** is a call with the same input as an earlier one, since the
  last compaction and the last edit of that file. After either, a fresh read
  is needed.
- **An overlap** is a file read of lines that were already read in that
  span. Its tokens are its share of those lines. Reading lines 1-50 and then
  41-90 counts 10 of 50.
- **Tokens** are the result's bytes / 4. That is an estimate, because neither
  harness records tokens per tool result. Grok's result is its `rawOutput`
  (`output_for_prompt`, `FileContent`, grep `stdout`). Claude's is the
  `tool_result` text.
- **Carried tokens** weigh each result by the model calls after it in its
  span, because a result is sent again on every later call. Divided by the
  session's input (grok `usage.json`, claude's summed `usage`), that is the
  share of the input the re-reads cost. Grok's call count (one per
  `streamStartMs`) equals `usage.json` `modelCalls` in 5 of 5 sessions
  checked.

## 2. The numbers

`TOKEN_REREAD_SINCE=2026-10-01T00:00 TOKEN_REREAD_UNTIL=2026-10-16T00:00`,
run on each box as the agent user:

| box | vendor | sessions | reads | repeats | overlaps | repeat + overlap tokens, share of tool output | carried, share of input | tool results carried, share of input |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| PC | grok | 218 | 16597 | 44 | 932 | 297639 (1.4%) | 0.03% + 0.42% | 40.7% |
| PC | claude | 892 | 17341 | 768 | 33 | 11614 (0.1%) | 0.01% + 0.00% | 14.3% |
| sat | grok | 108 | 8022 | 25 | 454 | 180786 (1.7%) | 0.02% + 0.60% | 39.0% |
| sat | claude | 951 | 15551 | 189 | 57 | 10173 (0.1%) | 0.01% + 0.00% | 13.4% |

Per session (repeats + overlaps carried, divided by the session's input):
no session on either box reaches 5%. The highest are grok 2.61% (PC, g-366)
and 4.87% (sat, g-799), and claude 0.37% and 1.92%.

What the numbers show:

- **Exact repeats are rare for both vendors.** Grok's 44 are 39 file reads,
  3 greps, 1 listing and 1 git command. Claude's 768 on the PC are almost all one
  role seat polling the tail of a log (`cat` class, 13 tokens each). That is
  polling, not waste.
- **Grok reads files in ranges and comes back to overlapping lines.** That
  is its 932 overlaps. A count by path alone would report 1960 re-reads, but
  most of those are new ranges of the same file or reads after an edit.
- Claude reads mostly through compound shell commands
  (`cd X; cat a; sed -n 1,80p b`), which no counter can split into files. Its
  overlap count is therefore a floor. That does not change the Grok result.

## 3. Seen on the way

Tool results make up about 40% of Grok's input and about 14% of Claude's
(carried, as above). Grok's results are bigger or are kept for more calls.
This belongs to the context-growth lane, [2/6](02-context-growth.md), and was
not changed here.

## 4. The check

`csi-spl-orc/src/bash/tests/spl-token-reread.tst.sh` uses synthetic grok and
claude sessions. It covers repeats, the line overlap, the resets after an
edit and after a compaction, and the carried weight. Two controls turn it
red: dropping the edit reset fails 4 checks, and counting a whole read as
overlap fails 3.
