#!/usr/bin/env bash
# rel-reboot-required-cron.sh - reliability round row 02 (spec 146) from the box
# crontab: manifest row rel-reboot-required, `# csi-spl:box-cron:rel-reboot-required`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" reboot-required
