#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_attach_args <file>...: append "--put-file <file>" per file to the
# caller's ids[] (a local of do_spl_desk_reply / do_spl_desk_post), so `spool
# send` blobs each file and attaches it under its own base name.
#
# SPL-1776 (owner, prd t1 4f98d07c, msgs 800a1472 / 33435b09): the desk used
# to `put-file` first and attach the id with `send --file-id`, and a blob
# attached by id is named by its 64-hex sha, with no extension. 45 owner-topic
# posts carried valid PNGs that the WUI offered as nameless downloads, which
# opened as "jiberrish" and "corrupted". `--put-file` keeps shot.png as
# shot.png, so the WUI shows it as the image it is.
#------------------------------------------------------------------------------
spl_desk_attach_args() {
  local f
  for f in "$@"; do ids+=(--put-file "$f"); done
}
