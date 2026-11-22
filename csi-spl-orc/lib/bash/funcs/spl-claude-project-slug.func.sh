#!/bin/bash
#------------------------------------------------------------------------------
# @description Claude Code keeps a session's transcript under
# @description ~/.claude/projects/<slug>/, the slug being the session's cwd with
# @description every character that is not a letter or a digit made a dash.
# @description The one copy of that rule (r88-01, SPL-6245); a file sourced
# @description outside ./run loads it with a declare -F guard.
#------------------------------------------------------------------------------
# spl_claude_project_slug PATH -> Claude Code's project dir name for a cwd
spl_claude_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
