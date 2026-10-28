#!/usr/bin/env bash
# rel-external-api-cron.sh - reliability round row 04 (spec 146) from the box
# crontab: manifest row rel-external-api, `# csi-spl:box-cron:rel-external-api`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" external-api
