#!/usr/bin/env bash
# rel-box-beat-cron.sh - reliability round row 12 (spec 146) from the box
# crontab: manifest row rel-box-beat, `# csi-spl:box-cron:rel-box-beat`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" box-beat
