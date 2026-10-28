#!/usr/bin/env bash
# rel-cron-snitch-cron.sh - reliability round row 11 (spec 146) from the box
# crontab: manifest row rel-cron-snitch, `# csi-spl:box-cron:rel-cron-snitch`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" cron-snitch
