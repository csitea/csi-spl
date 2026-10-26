#!/usr/bin/env bash
# workspace-repo.inc.sh — a lane whose work lands in a workspace's own repo
# files, moves and closes its issue IN THAT WORKSPACE, where its members and
# agent seats see it (owner HUM-10, msgs ca8a036d and dbead7a1: the issues are
# "used in the software development lifecycle" of the workspace's site and
# "visible to all of the agents and humans in the workspace"). The rule and
# its commands: csi-spl-doc/doc/md/lane-issue-and-docs.md section 5.
#
# A brief names its workspace with a header line `Workspace: <tenant>`. The
# box map ($SPOOL_WORKSPACE_REPOS_MAP, default $SPOOL_ROOT/workspace-repos.tsv;
# box-side, never in git: a customer's tenant, repo and host are not shipped)
# gives that workspace its repo, one TAB-separated row per workspace:
#
#   tenant  env  repo  clone  trunk  live_url  desk_agent  desk_box
#
#   tenant      the workspace's tenant id
#   env         the hub of its desk: dev, prd or self
#   repo        the repo's short name, for comments
#   clone       the absolute path of its clone on this box (fetched by the closer)
#   trunk       the branch a landing is on, "-" = origin/HEAD, master, main
#   live_url    the served site, https://..., named in the done comment
#   desk_agent  the seated desk agent of that workspace that files and moves
#   desk_box    that desk's box
#
# Callers: li_brief_epic_spec and li_gate (lane-issue.inc.sh),
# do_spl_lane_issue (place and end), do_spl_issue_close_landed
# (ISSUE_CLOSE_WORKSPACE) and its cron, issue-close-landed-cron.sh.

WR_TENANT_RE='[a-z0-9][a-z0-9-]{0,62}'

# wr_map -> the map file's path.
wr_map() { printf '%s' "${SPOOL_WORKSPACE_REPOS_MAP:-${SPOOL_ROOT:-/var/spool-hub}/workspace-repos.tsv}"; }

# wr_tenant_of_brief BRIEF -> the tenant on the brief's first `Workspace:`
# line; nothing (rc 1) for none, or for t1, the fleet's own workspace.
wr_tenant_of_brief() {
  local t
  [ -r "${1:-}" ] || return 1
  t="$(sed -nE "s/^[-*_ >]*Workspace[*_ ]*:[*_\` ]*(${WR_TENANT_RE})[*_\` ]*([[:space:]].*)?\$/\1/p" "$1" | sed -n 1p)"
  [ -n "$t" ] && [ "$t" != t1 ] || return 1
  printf '%s\n' "$t"
}

# wr_row TENANT -> the map row's fields after the tenant, TAB-separated:
# env, repo, clone, trunk, live_url, desk_agent, desk_box. rc 1: no map or no
# row; rc 2: a malformed row, one FATAL line on stderr.
wr_row() {
  local m t e r c b u a x rest
  m="$(wr_map)"
  [ -r "$m" ] || return 1
  while IFS=$'\t' read -r t e r c b u a x rest; do
    [ "$t" = "$1" ] || continue
    if [[ ! "$e" =~ ^(dev|prd|self)$ || ! "$r" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$c" != /* || "$c" == *..* ||
          ! "$b" =~ ^(-|[A-Za-z0-9][A-Za-z0-9._/-]*)$ || ! "$u" =~ ^https://[^[:space:]]+$ ||
          ! "$a" =~ ^[A-Za-z]{1,3}-[0-9]{2,5}$ || ! "$x" =~ ^[a-z0-9][a-z0-9-]*$ || -n "$rest" ]]; then
      echo "FATAL $m: the row of workspace $1 is malformed: want tenant, env (dev|prd|self), repo, /abs/clone, trunk (or -), https://live-url, desk agent, desk box" >&2
      return 2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e" "$r" "$c" "$b" "$u" "$a" "$x"
    return 0
  done < <(grep -v '^[[:space:]]*#' "$m")
  return 1
}

# wr_field ROW N -> the Nth field of a wr_row answer (1 = env .. 7 = desk_box).
wr_field() { cut -f"$2" <<<"$1"; }

# wr_tenants -> every tenant the map names, one per line.
wr_tenants() {
  local m
  m="$(wr_map)"
  [ -r "$m" ] || return 0
  grep -v '^[[:space:]]*#' "$m" | cut -f1 | grep -xE "$WR_TENANT_RE" | sort -u
}
