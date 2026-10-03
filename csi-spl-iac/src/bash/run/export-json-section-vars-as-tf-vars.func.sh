#!/bin/bash

#------------------------------------------------------------------------------
# @description usage example: clear ; source lib/bash/funcs/export-json-section-vars.func.sh do_export_json_section_vars $org/dev.env.json '.env.steps."004-aws-iam"' dependencies: jq
#------------------------------------------------------------------------------
do_export_json_section_vars_as_tf_vars(){

   json_file="$1"
   shift 1;
   test -f "$json_file" || do_log "FATAL the json_file: $json_file does not exist !!! Nothing to do"
   test -f "$json_file" || exit 1

   section="$1"
   test -z "$section" && do_log "FATAL the section in do_export_json_section_vars_as_tf_vars is empty !!! Nothing to do !!!"
   test -z "$section" && exit 1
   shift 1;

   sensitiveness="${1:-}"
   if [ $# -gt 0 ]; then shift 1; fi

   # Skip if the section does not exist in the JSON file
   section_check=$(jq -r "$section // empty" "$json_file" 2>/dev/null)
   if [ -z "$section_check" ]; then
      do_log "WARNING section $section not found in $json_file, skipping"
      return 0
   fi

   do_log "INFO exporting vars from cnf $json_file: "
   while read -r l ; do
      key=$(echo $l|cut -d':' -f1|tr a-z A-Z)
      val=$(echo "$l"|cut -d':' -f2-)

      #val="${val/#\~/$HOME}" # for some reason does not work !!
      val=$(echo $val|perl -ne 's|~|'$HOME'|g;print')
      eval "$(echo -e 'export TF_VAR_'$key=\"\"$val\"\")"

      # does not do_log sensitive values
      if [[ "${sensitiveness}" == "" ]]; then
         do_log "INFO TF_VAR_${key}=${val}"
      else
         do_log "WARNING SENSITIVE ${key}=*****************"
      fi

   # done < <(cat "$json_file"| jq -r "$section"'|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""')
   done < <(jq -r "$section"'|to_entries| map(select(.value | type == "string"))|from_entries|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""' "$json_file")
  # thanks ChatGPT: 'to_entries | map(select(.value | type == "string")) | from_entries'
  # ok cat <ORG>-<APP>-cnf/<ORG>-<APP>/dev.env.json | jq -r '.env.steps."004-aws-iam"|to_entries| map(select(.value | type == "string"))|from_entries|keys_unsorted[] as $key|"\($key):\"\(.[$key])\""'
}
