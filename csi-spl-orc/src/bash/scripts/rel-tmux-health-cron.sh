#!/usr/bin/env bash
# rel-tmux-health-cron.sh - reliability round row 05 (spec 146) from the box
# crontab: manifest row rel-tmux-health, `# csi-spl:box-cron:rel-tmux-health`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" tmux-health
