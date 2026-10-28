#!/usr/bin/env bash
# rel-orphan-process-cron.sh - reliability round row 06 (spec 146) from the box
# crontab: manifest row rel-orphan-process, `# csi-spl:box-cron:rel-orphan-process`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" orphan-process
