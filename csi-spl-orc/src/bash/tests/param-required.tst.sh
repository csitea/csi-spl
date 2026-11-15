#!/usr/bin/env bash
# Purpose: the @param (required) form and its enforcement for this module
# (SPL-5549); the checks and their red controls live in
# csi-spl-iac/src/bash/tests/param-required.tst.sh.
set -uo pipefail
APP_ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
PARAM_REQUIRED_MODULES=orc exec bash "$APP_ROOT/csi-spl-iac/src/bash/tests/param-required.tst.sh"
