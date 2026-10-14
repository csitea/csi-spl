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
# shot.png, so the WUI shows it as the image it is. spl_desk_attach_check
# refuses a path with no known extension before anything is sent.
#------------------------------------------------------------------------------
spl_desk_attach_args() {
  local f
  for f in "$@"; do ids+=(--put-file "$f"); done
}

# The extensions a desk attachment may carry: what the WUI shows inline (an
# image), opens in a viewer or saves as a file a reader's tools recognise.
SPL_DESK_ATTACH_EXTS="png jpg jpeg gif webp svg pdf txt md csv tsv json yaml yml
  html xml log diff patch sh py go js ts sql zip tar gz tgz mp4 webm mov mp3 wav
  ogg docx xlsx pptx odt ods odp"

# spl_desk_attach_check <file>...: 0 when every path ends in a known extension
# (SPL_DESK_ATTACH_EXTS, any case), else 1 with the FATAL naming the first
# that does not. Owner, prd t1 4f98d07c msg 33435b09: "no more hidden txt
# files - the real file extensions are needed"; the rule is how-to-post.md
# rule 13. A hash-named blob copy (no dot) and a `.tmp` are refused alike.
spl_desk_attach_check() {
  local f base ext
  for f in "$@"; do
    base="${f##*/}"; ext="${base##*.}"; ext="${ext,,}"
    if [[ "$base" != *.* || "$base" == .* && "${base#.}" != *.* ]] ||
        [[ " ${SPL_DESK_ATTACH_EXTS//$'\n'/ } " != *" $ext "* ]]; then
      do_log "FATAL DESK_FILES entry has no known file extension: '$f'. Attach the file under its real type, e.g. cp it to shot.png (how-to-post.md rule 13; known: $(tr -s ' \n' ' ' <<<"$SPL_DESK_ATTACH_EXTS"))"
      return 1
    fi
  done
}
