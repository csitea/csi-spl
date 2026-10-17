#!/bin/bash
#
# do_box_pkg_flag: Check for service takeovers by installed packages.
#
# Usage:
#   do_box_pkg_flag
#
# Output:
#   Lines starting with "FLAG:" for every service takeover detected.
#   Format: "FLAG: <package> takes <service> from <expected_owner>"
#
# Depends:
#   - cnf env.box.pkg_services (map of service -> expected owner)
#   - dpkg-query (to list installed packages and their files)
#   - systemctl (to check active services)
#

set -euo pipefail

# Load the service map from cnf
PKG_SERVICES_MAP="${BOX_PKG_SERVICES_MAP:-}"
if [[ -z "$PKG_SERVICES_MAP" ]]; then
    echo "ERROR: env.box.pkg_services not set in cnf" >&2
    exit 1
fi

# Parse the service map into an associative array
# Format: "service:owner"
declare -A SERVICE_OWNERS
while IFS=: read -r service owner; do
    SERVICE_OWNERS["$service"]="$owner"
done <<< "$PKG_SERVICES_MAP"

# Check each service in the map
for service in "${!SERVICE_OWNERS[@]}"; do
    expected_owner="${SERVICE_OWNERS[$service]}"
    
    # Skip if the service is not active
    if ! systemctl is-active --quiet "$service"; then
        continue
    fi
    
    # Get the actual owner of the service
    actual_owner="$(systemctl show "$service" -p UnitFileState --value)"
    if [[ "$actual_owner" != "enabled" ]]; then
        # Fallback to the unit file path if UnitFileState is not "enabled"
        unit_path="$(systemctl show "$service" -p FragmentPath --value)"
        if [[ -n "$unit_path" ]]; then
            actual_owner="$(basename "$(dirname "$unit_path")")"
        else
            actual_owner="unknown"
        fi
    fi
    
    # Compare actual vs expected owner
    if [[ "$actual_owner" != "$expected_owner" ]]; then
        # Find which package owns the conflicting unit file
        unit_path="$(systemctl show "$service" -p FragmentPath --value)"
        if [[ -n "$unit_path" ]]; then
            package="$(dpkg-query -S "$unit_path" 2>/dev/null | awk -F: '{print $1}' | head -1)"
            if [[ -z "$package" ]]; then
                package="unknown"
            fi
        else
            package="unknown"
        fi
        
        echo "FLAG: $package takes $service from $expected_owner"
    fi
done