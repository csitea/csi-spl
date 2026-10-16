#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1960 (security round 1, row 3): leave a docker swarm that
# @description nothing uses, so dockerd stops listening on the manager port
# @description :2377 and the gossip port :7946 on every interface. Unused =
# @description this is the only node, and there are no services, no secrets,
# @description no configs and no swarm network but the default ingress. It
# @description prints each measure; any use REFUSES (and names it). Standalone
# @description containers are not restarted by a leave. DRY_RUN=0 runs
# @description `docker swarm leave --force` (a single-node manager needs
# @description --force) and checks the node state is inactive and nothing
# @description listens on those two ports. Dry run unless DRY_RUN=0.
# @param DOCKER_BIN (optional) - default docker
# @param SS_BIN (optional) - default ss
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_docker_swarm_leave
# @example DRY_RUN=0 ./run -a do_spl_docker_swarm_leave
#------------------------------------------------------------------------------
do_spl_docker_swarm_leave() {
  local dk="${DOCKER_BIN:-docker}" ss="${SS_BIN:-ss}" apply=1 state nodes svc sec cfg nets used=0 lis
  if spl_dry_run; then apply=0; else local drc=$?; [[ $drc -eq 1 ]] || return 1; fi
  state="$("$dk" info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" || { do_log "FATAL docker info failed"; return 1; }
  if [[ "$state" == inactive ]]; then do_log "OK docker swarm: not in a swarm, nothing to do"; return 0; fi
  nodes="$("$dk" info --format '{{.Swarm.Nodes}}')"
  svc="$("$dk" service ls -q 2>/dev/null | grep -c .)"
  sec="$("$dk" secret ls -q 2>/dev/null | grep -c .)"
  cfg="$("$dk" config ls -q 2>/dev/null | grep -c .)"
  nets="$("$dk" network ls --filter scope=swarm --format '{{.Name}}' | grep -vx ingress | tr '\n' ' ')"
  lis="$("$ss" -tlnH '( sport = :2377 or sport = :7946 )' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"
  echo "swarm state=$state nodes=$nodes services=$svc secrets=$sec configs=$cfg swarm networks besides ingress=${nets:-none}"
  lis="${lis% }"; echo "listening now: ${lis:-none}"
  [[ "$nodes" =~ ^[01]$ ]] || { echo "REFUSED: $nodes nodes in this swarm"; used=1; }
  (( svc == 0 )) || { echo "REFUSED: $svc swarm service(s): $("$dk" service ls --format '{{.Name}}' | tr '\n' ' ')"; used=1; }
  (( sec == 0 && cfg == 0 )) || { echo "REFUSED: swarm secrets ($sec) or configs ($cfg) exist"; used=1; }
  [[ -z "$nets" ]] || { echo "REFUSED: swarm networks in use: $nets"; used=1; }
  (( used )) && { do_log "FAIL docker swarm is in use: not leaving it"; return 1; }
  if (( ! apply )); then
    do_log "INFO DRY_RUN would: $dk swarm leave --force (single node, unused; no container restarted)"
    do_log "OK DRY_RUN nothing was changed. Re-run with DRY_RUN=0 to leave the swarm."
    return 0
  fi
  "$dk" swarm leave --force || { do_log "FATAL docker swarm leave failed"; return 1; }
  state="$("$dk" info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
  lis="$("$ss" -tlnH '( sport = :2377 or sport = :7946 )' 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"
  [[ "$state" == inactive && -z "$lis" ]] || { do_log "FAIL after the leave: state=$state listening=${lis% }"; return 1; }
  do_log "OK docker swarm left: state inactive, nothing listens on :2377 / :7946"
}
