#!/usr/bin/env bash
# rel-clock-sync-cron.sh - reliability round row 09 (spec 146) from the box
# crontab: manifest row rel-clock-sync, `# csi-spl:box-cron:rel-clock-sync`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" clock-sync
