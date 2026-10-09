#!/usr/bin/env bash
#
# do_spl_goals_backfill_git: Backfill release events from git history (spec 112, ORC-2).
#
# Reads:
#   git tags (v*.0 only)
#   csi-spl-doc/goals/milestones.yaml
#   csi-spl-cnf/csi-spl/all.env.yaml (env.roadmap.tenant_id, env.hub.base_url)
#
# Writes:
#   PUT /v1/calendar/sync (deploy identity only)
#
# Fails fast if:
#   - HUB_BASE_URL is missing
#   - DEPLOY_ID_TOKEN is missing
#
# Usage:
#   source spl-goals-backfill-git.func.sh
#   do_spl_goals_backfill_git

set -euo pipefail

do_spl_goals_backfill_git() {
    if [[ -z "${DEPLOY_ID_TOKEN:-}" ]]; then
        echo "ERROR: DEPLOY_ID_TOKEN not set" >&2
        exit 1
    fi
    local repo_root
    local cnf_file
    local tenant_id
    local hub_base_url
    local deploy_token
    local batch_file
    local batch=()
    local tag
    local tag_date
    local tag_message
    local event_title
    local event_date
    local event_kind
    local event_source_key
    local event_audience
    local event_json
    local response
    local response_code
    local response_body
    local milestones_file
    local milestone_line
    local milestone_date
    local milestone_title

    repo_root="$(git rev-parse --show-toplevel)"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"
    milestones_file="${repo_root}/csi-spl-doc/goals/milestones.yaml"

    # Fail fast if cnf keys are missing
    if [[ ! -f "${cnf_file}" ]]; then
        echo "ERROR: ${cnf_file} does not exist" >&2
        exit 1
    fi
    if ! grep -q "^env:" "${cnf_file}"; then
        echo "ERROR: ${cnf_file} missing \"env:\" section" >&2
        exit 1
    fi

    tenant_id="$(yq eval ".env.roadmap.tenant_id // \"\"" "${cnf_file}")"
    
    hub_base_url="$(yq eval ".env.hub.base_url // \"\"" "${cnf_file}")"

    if [[ -z "${hub_base_url}" ]]; then
        echo "ERROR: env.hub.base_url missing in ${cnf_file}" >&2
        exit 1
    fi

    if [[ -z "${DEPLOY_ID_TOKEN:-}" ]]; then
        echo "ERROR: DEPLOY_ID_TOKEN not set" >&2
        exit 1
    fi

    deploy_token="${DEPLOY_ID_TOKEN}"
    batch_file="$(mktemp)"

    # Backfill from milestones.yaml is NOT part of the git backfill (spec 112, ORC-2)
    # Only git tags are processed in this function.

    # Backfill from git tags (v*.0 only, skip patch tags)
    for tag in $(git tag -l); do
        if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.0$ ]]; then
            continue
        fi

        tag_date="$(git log -1 --format=%aI "${tag}")"
        tag_message="$(git tag -l --format='%(contents)' "${tag}")"

        if [[ -z "${tag_date}" || -z "${tag_message}" ]]; then
            continue
        fi

        event_title="Release: ${tag_message}"
        event_date="${tag_date%T*}"
        event_kind="release"
        event_source_key="release:${tag}"
        event_audience="public"

        event_json="{\
            \"tenant_id\": \"${tenant_id}\", \
            \"title\": \"${event_title}\", \
            \"date\": \"${event_date}\", \
            \"kind\": \"${event_kind}\", \
            \"source_key\": \"${event_source_key}\", \
            \"audience\": \"${event_audience}\", \
            \"remind_at\": \"${event_date}T00:00:00Z\"\
        }"

        batch+=("${event_json}")
    done < <(git tag -l)

    if [[ ${#batch[@]} -eq 0 ]]; then
        echo "INFO: No events to backfill" >&2
        rm -f "${batch_file}"
        return 0
    fi

    # Write batch to file
    printf "%s\n" "${batch[@]}" > "${batch_file}"

    # Send to hub
    cat "${batch_file}" >&2
    response="$(curl -s -w "\n%{http_code}" -X PUT "${hub_base_url}/v1/calendar/sync" \
        -H "Authorization: Bearer ${deploy_token}" \
        -H "Content-Type: application/json" \
        -d "@${batch_file}")"

    response_code="$(echo "${response}" | tail -n1)"
    response_body="$(echo "${response}" | sed "$ d")"

    rm -f "${batch_file}"

    if [[ "${response_code}" -eq 503 && "${response_body}" == *roadmap_not_configured* ]]; then
        echo "WARNING: Roadmap not configured (503 roadmap_not_configured)" >&2
        return 0
    elif [[ "${response_code}" -ne 200 ]]; then
        echo "ERROR: Backfill failed with HTTP ${response_code}: ${response_body}" >&2
        exit 1
    fi

    echo "INFO: Backfilled ${#batch[@]} events to calendar" >&2
}
