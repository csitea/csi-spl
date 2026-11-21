#!/bin/bash
#------------------------------------------------------------------------------
# @description A topic as a PDF file on this machine (spec 183 row P3, the
# @description names of spec 182 row L6): a thin wrapper of
# @description `spool topic-pdf`. The hub renders exactly what the person
# @description this box works for reads in the web UI (spec 183 7.1.1); the
# @description verb asks through this box's desks of ENV (the link's
# @description workspace first), writes the file and prints one JSON line
# @description {task_id, path, bytes, rows, pictures, sha256}. Exit codes are
# @description the verb's: 3 no such topic for that person, 4 name the
# @description operator (TYPED_BY), or no_operator: this box has none bound
# @description (do_spl_box_operator_grant), 5 the renderer could not make it.
# @param TOPIC_ID (required) - the topic: its uuid or a WUI link (/t/<uuid>)
# @param ENV (required) - dev or prd: whose desks are asked
# @param OUT (optional) - the file to write, replaced when it exists; default <spool root>/<agent id>/exports/<the hub's name>
# @param TYPED_BY (optional) - HUM-<n>: the operator to export as, when several are bound to the box
# @param TOPIC_PDF_DESKS (optional) - the desk dir, default <desk root>/<ENV>/desk
# @param TOPIC_PDF_SPOOL_CMD (optional, tests) - replaces the spool binary
# @example TOPIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e ENV=dev ./run -a do_spl_topic_pdf
# @example TOPIC_ID=https://t1.example.com/t/0f8fad5b-d9cb-469f-a165-70867728950e ENV=prd OUT=./topic.pdf ./run -a do_spl_topic_pdf
#------------------------------------------------------------------------------
do_spl_topic_pdf() {
  spl_require_cloud_env || return 1
  [[ -n "${TOPIC_ID:-}" ]] || { do_log "FATAL TOPIC_ID must be set: a topic uuid or a WUI link"; return 1; }
  local desks
  desks="$(spl_topic_pdf_desks)" || return 1
  local -a cmd args=(topic-pdf --task "$TOPIC_ID" --desks "$desks" --desk-box "$(spl_desk_box_default)")
  [[ -n "${OUT:-}" ]] && args+=(--out "$OUT")
  [[ -n "${TYPED_BY:-}" ]] && args+=(--typed-by "$TYPED_BY")
  if [[ -n "${TOPIC_PDF_SPOOL_CMD:-}" ]]; then
    read -r -a cmd <<<"$TOPIC_PDF_SPOOL_CMD"
  else
    do_spl_desk_cnf || return 1
    spl_host_spool || return 1
    cmd=("$SPL_SPOOL")
  fi
  SPOOL_AGENT_ID="${SPOOL_AGENT_ID:-${AGENT_ID:-}}" "${cmd[@]}" "${args[@]}"
}

# spl_topic_pdf_desks: this box's desk dir of ENV, the one spool-mcp.sh and
# topic-text.sh read (<desk root>/<env>/desk).
spl_topic_pdf_desks() {
  if [[ -n "${TOPIC_PDF_DESKS:-}" ]]; then printf '%s\n' "$TOPIC_PDF_DESKS"; return 0; fi
  local lib root
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib" && pwd)"
  declare -F spool_desk_state >/dev/null || source "$lib/spool-env.inc.sh"
  declare -F spool_desk_root >/dev/null || source "$lib/desk-root.inc.sh"
  root="$(spool_desk_root "$HOME")" || { do_log "FATAL no desk root for $(id -un): set TOPIC_PDF_DESKS"; return 1; }
  printf '%s\n' "$root/$ENV/desk"
}
