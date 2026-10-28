#!/usr/bin/env bash
# rel-cert-expiry-cron.sh - reliability round row 03 (spec 146) from the box
# crontab: manifest row rel-cert-expiry, `# csi-spl:box-cron:rel-cert-expiry`. The row's
# action and how it runs: reliability-check-cron.sh.
exec /bin/bash "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/reliability-check-cron.sh" cert-expiry
