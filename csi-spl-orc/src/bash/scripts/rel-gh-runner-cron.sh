#!/usr/bin/env bash
# rel-gh-runner-cron.sh - reliability round row 08 (spec 146) from the box
# crontab: manifest row rel-gh-runner, `# csi-spl:box-cron:rel-gh-runner`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" gh-runner
