#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_poll_check: a ```poll form that would not render is refused before
# it is sent (SPL-3062; how-to-post.md section 7). Owner HUM-10, msg
# fb2b4cdf: "some of the forms are not rendering properly" - an agent wrote
# its options as `[ ] (A) text`, the WUI showed the fence as a code block, and
# the owner saw it before the writer did. do_spl_desk_reply and
# do_spl_desk_post now refuse (FATAL, nothing sent) a body whose ```poll fence
# does not parse as a form, or that holds a second ```poll fence.
# The verdict is the WUI's own parser: pollProblems of
# csi-spl-wui/src/utils/poll.mjs, run by node, so the rule has one copy. A
# body with no ```poll line never starts node. No node or no poll.mjs on this
# box: one WARN and the post is sent (the check is lost, not the post).
# Env: POLL_CHECK_MJS (default <checkout>/csi-spl-wui/src/utils/poll.mjs).
#------------------------------------------------------------------------------

# spl_desk_poll_check <body>: 0 when the body has no ```poll fence or its one
# fence is a form; else one FATAL per problem, the valid syntax, and 1.
spl_desk_poll_check() {
  local body="$1" mjs="${POLL_CHECK_MJS:-$PROJ_PATH/../csi-spl-wui/src/utils/poll.mjs}" out rc=0
  grep -qE '^`{3,}poll[[:space:]]*$' <<<"${body//$'\r'/}" || return 0
  if ! command -v node >/dev/null 2>&1 || [[ ! -r "$mjs" ]]; then
    do_log "WARN the poll form was not checked (no node or no $mjs on this box): the post is sent unchecked"
    return 0
  fi
  out="$(printf '%s' "$body" | node --input-type=module -e '
    const { pollProblems } = await import(process.argv[1])
    const chunks = []
    for await (const c of process.stdin) chunks.push(c)
    const p = pollProblems(Buffer.concat(chunks).toString("utf8"))
    if (p.length) { console.log(p.join("\n")); process.exit(3) }
  ' "$(realpath "$mjs")" 2>&1)" || rc=$?
  (( rc == 0 )) && return 0
  if (( rc != 3 )); then
    do_log "WARN the poll form was not checked (node exit $rc: ${out%%$'\n'*}): the post is sent unchecked"
    return 0
  fi
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && do_log "FATAL poll form: $line"
  done <<<"$out"
  do_log "FATAL nothing was sent: the form would show as a code block. One \`\`\`poll fence per message; a question line, then its options, each \`(A) text\` (pick one) or \`[A] text\` (pick any), never both in one form, a key once per question (how-to-post.md section 7)"
  return 1
}
