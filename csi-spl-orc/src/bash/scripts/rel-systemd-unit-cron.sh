#!/usr/bin/env bash
# rel-systemd-unit-cron.sh - reliability round row 01 (spec 146) from the box
# crontab: manifest row rel-systemd-unit, `# csi-spl:box-cron:rel-systemd-unit`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" systemd-unit
