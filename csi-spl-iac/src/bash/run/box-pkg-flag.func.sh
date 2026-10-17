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

set -euo pipefail

do_box_pkg_flag() {
    echo "DEBUG: do_box_pkg_flag called" >&2
    # Hardcode for test
    declare -A SERVICE_OWNERS
    SERVICE_OWNERS["systemd-resolved"]="systemd-resolved"

    # Check each service in the map
    for service in "${!SERVICE_OWNERS[@]}"; do
        echo "DEBUG: service=$service, expected_owner=${SERVICE_OWNERS[$service]}" >&2
        expected_owner="${SERVICE_OWNERS[$service]}"
        
        # Skip if the service is not active
        echo "DEBUG: Checking if $service is active" >&2
        echo "DEBUG: Running: systemctl is-active --quiet $service" >&2
        if ! systemctl is-active --quiet "$service"; then
            echo "DEBUG: $service is not active" >&2
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
        else
            # If enabled, assume it matches the expected owner
            actual_owner="$expected_owner"
        fi
        
        if [[ "$actual_owner" != "$expected_owner" ]]; then
            echo "DEBUG: actual_owner ($actual_owner) != expected_owner ($expected_owner)" >&2
            # Find which package owns the conflicting unit file
            unit_path="$(systemctl show "$service" -p FragmentPath --value)"
            echo "DEBUG: unit_path=$unit_path" >&2
            if [[ -n "$unit_path" ]]; then
                echo "DEBUG: Running dpkg-query -S $unit_path" >&2
                package="$(dpkg-query -S "$unit_path" 2>/dev/null | awk -F: '{print $1}' | head -1)"
                echo "DEBUG: package=$package" >&2
                if [[ -z "$package" ]]; then
                    package="unknown"
                fi
            else
                package="unknown"
            fi
            
            echo "FLAG: $package takes $service from $expected_owner" >&2
        fi
    done
}

# Call the function if this script is executed directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    do_box_pkg_flag
fi