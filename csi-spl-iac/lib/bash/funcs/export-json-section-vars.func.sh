#!/bin/bash
#------------------------------------------------------------------------------
# @description Export every STRING value of one section of a cnf json file as
# @description an upper-cased env var (key "tf_proj" -> TF_PROJ), a leading ~
# @description expanded to $HOME. Non-string values (objects, arrays, numbers)
# @description are skipped. A section absent from the file is a WARNING and a
# @description no-op (return 0). A missing file or an empty section argument
# @description returns 1: this file is sourced into the ./run shell, so it
# @description returns rather than exits and the caller decides (`|| return 1`).
# @description HAZARD: each value is spliced into an unquoted `eval` (the
# @description `export` line below), so a cnf value carrying `$(...)`, a
# @description backtick or a double quote is executed or breaks the export.
# @description Only feed it trusted cnf.
# @param $1 the json file, e.g. <ORG>-<APP>-cnf/<ORG>-<APP>/dev.env.json
# @param $2 the jq path of the section, e.g. '.env.steps."001-enable-gcp-services"'
# @param $3 (optional) any non-empty value: log the keys only, never the values
# @example do_export_json_section_vars "$JSON_ENV_FILE" '.env.steps."001-enable-gcp-services"'
# dependencies: jq, perl
#------------------------------------------------------------------------------
do_export_json_section_vars() {

  json_file="$1"
  shift 1
  [[ -f "$json_file" ]] || { do_log "FATAL the json_file: $json_file does not exist !!! Nothing to do"; return 1; }

  section="$1"
  [[ -n "$section" ]] || { do_log "FATAL the section in do_export_json_section_vars is empty !!! Nothing to do !!!"; return 1; }
  shift 1

  sensitiveness="${1:-}"
  if [ $# -gt 0 ]; then shift 1; fi

  # Skip if the section does not exist in the JSON file
  section_check=$(cat "$json_file" | jq -r "$section // empty" 2>/dev/null)
  if [ -z "$section_check" ]; then
    do_log "WARNING section $section not found in $json_file, skipping"
    return 0
  fi

  do_log "INFO exporting vars from cnf $json_file: "
  while read -r l; do
    key=$(echo $l | cut -d':' -f1 | tr a-z A-Z)
    val=$(echo "$l" | cut -d':' -f2-)

    #val="${val/#\~/$HOME}" # for some reason does not work !!
    val=$(echo $val | perl -ne 's|~|'$HOME'|g;print')
    eval "$(echo -e 'export '$key=\"\"$val\"\")"

    # does not do_log sensitive values
    if [[ "${sensitiveness}" == "" ]]; then
      do_log "INFO ${key}=${val}"
    else
      do_log "WARNING SENSITIVE ${key}=*****************"
    fi

    # done < <(cat "$json_file"| jq -r "$section"'|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""')
  done < <(cat "$json_file" | jq -r "$section"'|to_entries| map(select(.value | type == "string"))|from_entries|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""')
  # thanks ChatGPT: 'to_entries | map(select(.value | type == "string")) | from_entries'
  # ok cat <ORG>-<APP>-cnf/<ORG>-<APP>/dev.env.json | jq -r '.env.steps."004-aws-iam"|to_entries| map(select(.value | type == "string"))|from_entries|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""'
}
