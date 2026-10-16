#!/usr/bin/env bash
# go-ask-guard.inc.sh - refuse a free-text go-ask to the owner (SDLC round 1
# row 12, SPL-2280; plan csi-spl-doc/doc/md/sdlc-round-1-plan.md section 3).
#
# Measured for the plan on the hub: 66 owner go/yes/ok nudges in a week across
# 47 topics, 60 of them right after an agent post. Most work needs no owner go
# (rulebook 1.4): the agent just does the step. A question that really needs
# one is a ```poll form (how-to-post.md rule 10 and section 7, the (GO) button).
#
# spl_go_ask_check <body>: 0 = may be sent; 1 = a free-text go-ask, and the
# sentence that asks is printed on stdout. Never refused:
#   - a body that carries a ```poll form (the sanctioned way to ask);
#   - a body that names a real owner gate (terraform apply, IAM, prd, a key or
#     secret, GCP, an access change, a root /etc write, a restart, a delete):
#     the repo CLAUDE.md "Nothing mutates GCP without the owner" asks for it.
# Not read for the ask: fenced code, inline `code`, and > quote lines (a
# quote is the owner's words, not the agent's ask); the gate is looked for in
# the whole body, code included (`/etc/logrotate.d` names a root write).
# A sentence asks when it holds a '?' and a permission phrase (shall I, should we, do you want me to, your go, ok to,
# proceed, can you approve) or, with no '?', a plain request for a go
# ("your go, please", "waiting for your go", "needs your go").
# SPOOL_GO_ASK_OK=1 skips the check (the caller says so). Reads nothing else.

SPL_GO_ASK_QUESTION='\b(shall|should|may|can) (i|we)\b|\bdo you want (me|us|[a-z]-[0-9]{3}|a lane|the lane|it) to\b|\bgo( ahead| on)?[[:space:]]*\?|\byour (go|ok|okay|approval|confirmation|green light)\b|\b(can|could|would|will) you (approve|confirm)\b|\bok(ay)? to\b|\bproceed\b'
SPL_GO_ASK_REQUEST='\byour (go|ok|okay|approval|confirmation)[,:]? please\b|\bplease (approve|confirm|say go|give (me|us) (a|the|your) go)\b|\bwait(ing)? (for|on) your (go|ok|okay|approval|confirmation)\b|\bneeds? your (go|ok|okay|approval|confirmation)\b'
SPL_GO_ASK_GATE='\bterraform\b|\bapply\b|\biam\b|\bprd\b|\bprod(uction)?\b|\bsecrets?\b|\bkeys?\b|\bcredentials?\b|\bbilling\b|\bforce[- ]push\b|\bgcp\b|\bgoogle cloud\b|\bcloud (run|sql)\b|\bssh\b|\baccess\b|/etc/|\broot\b|\brestart|\boutage\b|\bdelet(e|es|ed|ing|ion)\b'

# The body as the reader sees the agent's own words: no fenced code, no
# inline code, no > quotes; one sentence per line.
spl_go_ask_sentences() {
  awk '/^[[:space:]]*```/ { f = !f; next } !f' <<<"$1" |
    grep -vE '^[[:space:]]*>' |
    sed -E 's/`[^`]*`//g; s/([.!?][*_)"'"'"']*)[[:space:]]+/\1\n/g'
}

spl_go_ask_check() {
  local body="$1" text line
  [ "${SPOOL_GO_ASK_OK:-0}" = 1 ] && return 0
  grep -qE '^[[:space:]]*```poll' <<<"$body" && return 0
  text="$(spl_go_ask_sentences "$body")"
  line="$(grep -iE "$SPL_GO_ASK_QUESTION" <<<"$text" | grep -m1 -F '?')" ||
    line="$(grep -m1 -iE "$SPL_GO_ASK_REQUEST" <<<"$text")" || return 0
  grep -qiE "$SPL_GO_ASK_GATE" <<<"$body" && return 0
  printf '%s\n' "$line"
  return 1
}

# The one refusal text, for every caller.
spl_go_ask_refusal() {  # SENTENCE
  printf '%s\n' "a free-text go-ask to the owner: \"$1\". Most steps need no owner go (rounds rulebook 1.4): just do it and report. If it truly needs the owner, ask with a \`\`\`poll form (csi-spl-doc/doc/help/how-to-post.md rule 10, the (GO) button), or name the gate it needs (terraform apply, IAM, prd, a key). Nothing was sent."
}
