#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove old grok session dirs (OLD_STORE_TARGET=grok) or old
# @description retired-agent dirs (OLD_STORE_TARGET=retired) of this box, or
# @description one owner-approved set of old Claude transcripts
# @description (OLD_STORE_TARGET=transcripts). Keeps
# @description anything restorable, live, held open, recent, of a role seat, or
# @description not from an agent worktree; one PLAN|REMOVE / KEEP line per dir.
# @description Dry run unless DRY_RUN=0. Run it once per owning user. By hand
# @description only: no cron and no sweep step runs it.
# @param OLD_STORE_TARGET (required) - grok, retired or transcripts
# @param OLD_TRANSCRIPT_SET (transcripts only) - human or role-seat
# @param DRY_RUN (optional) - 1 (default) or 0
# @param AGE_DAYS (optional) - idle days before removal, default 7
# @param GROK_SESSIONS (optional) - default $HOME/.grok/sessions
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example OLD_STORE_TARGET=retired ./run -a do_prune_old_stores
# @example OLD_STORE_TARGET=grok DRY_RUN=0 ./run -a do_prune_old_stores
# @example OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=human ./run -a do_prune_old_stores
#------------------------------------------------------------------------------
do_prune_old_stores() {
  DRY_RUN="${DRY_RUN:-1}" AGE_DAYS="${AGE_DAYS:-7}" bash "$PROJ_PATH/src/bash/scripts/old-stores-prune.sh"
}
