#!/usr/bin/env bash
# rel-docker-prune-cron.sh - reliability round row 07 (spec 146) from the box
# crontab: manifest row rel-docker-prune, `# csi-spl:box-cron:rel-docker-prune`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" docker-prune
