#!/usr/bin/env bash
# S3 (spec 093 6.1): a bare shell. The agent's pane exists, no harness
# process runs under it (none carries its id, none is in the pane's process
# tree) and its foreground command is a shell. A lane whose workdir is gone
# finished (it tore down, then exited): not a hit.
# Usage: s3.sh ID PID PANE (WD_CTX set; see lib.inc.sh)
# shellcheck source=lib.inc.sh
. "$(dirname "$0")/lib.inc.sh"
[[ -z "$WD_PID" && -n "$WD_PANE" ]] || exit 0
wd_has pane || exit 0
wd_has rundir_gone && exit 0
grep -qxE 'claude|grok|agy|qwen|node|bun' <<<"$(wd_f tree)" && exit 0
fg="$(wd_f fg)"
grep -qxE 'sh|bash|zsh|dash|fish|sudo|su' <<<"$fg" || exit 0
echo "HIT S3 pane $WD_PANE runs only '$fg', no harness process carries $WD_ID"
