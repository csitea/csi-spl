#!/usr/bin/env bash
# graft (spec 069 Y6): the wrapper, the index updater, the cron entry and the
# install step, in a sandbox HOME. The cases: features/graft/tests/.
exec bash "$(cd "$(dirname "$0")" && pwd)/../features/graft/tests/run-all.sh"
