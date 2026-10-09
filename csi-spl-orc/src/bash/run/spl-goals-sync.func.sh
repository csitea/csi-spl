#!/usr/bin/env bash
#
# do_spl_goals_sync: Sync goal deadlines and milestones to the calendar (spec 112, ORC-2).
#
# Reads:
#   csi-spl-doc/goals/*/goal.yaml
#   csi-spl-cnf/csi-spl/all.env.yaml (env.roadmap.tenant_id, env.roadmap.approver_role, env.hub.base_url)
#
# Writes:
#   PUT /v1/calendar/sync (deploy identity only)
#
# Fails fast if:
#   - env.roadmap.tenant_id or env.roadmap.approver_role is missing
#   - HUB_BASE_URL is missing
#   - DEPLOY_ID_TOKEN is missing
#
# Usage:
#   source spl-goals-sync.func.sh
#   do_spl_goals_sync

set -euo pipefail

do_spl_goals_sync() {
    local repo_root
    local goals_dir
    local cnf_file
    local tenant_id
    local approver_role
    local hub_base_url
    local deploy_token
    local batch_file
    local batch=()
    local goal_file
    local goal_id
    local goal_deadline
    local goal_approval_msg_id
    local goal_owner_role
    local goal_milestones
    local goal_title
    local event_title
    local event_date
    local event_kind
    local event_source_key
    local event_audience
    local event_json
    local milestone_key
    local milestone_date
    local milestone_title
    local response
    local response_code
    local response_body

    repo_root="$(git rev-parse --show-toplevel)"
    goals_dir="${repo_root}/csi-spl-doc/goals"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

    # Fail fast if cnf keys are missing
    if ! grep -q "^env:" "${cnf_file}"; then
        echo "ERROR: ${cnf_file} missing \"env:\" section" >&2
        exit 1
    fi

    tenant_id="$(yq eval ".env.roadmap.tenant_id // \"\"" "${cnf_file}")"
    approver_role="$(yq eval ".env.roadmap.approver_role // \"\"" "${cnf_file}")"
    hub_base_url="$(yq eval ".env.hub.base_url // \"\"" "${cnf_file}")"

    if [[ -z "${tenant_id}" || -z "${approver_role}" ]]; then
        echo "ERROR: env.roadmap.tenant_id or env.roadmap.approver_role missing in ${cnf_file}" >&2
        exit 1
    fi

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

    # Build batch: goal deadlines and milestones
    for goal_file in "${goals_dir}"/*/goal.yaml; do
        if [[ ! -f "${goal_file}" ]]; then
            continue
        fi

        goal_id="$(yq eval ".id // \"\"" "${goal_file}")"
        goal_deadline="$(yq eval ".deadline // \"\"" "${goal_file}")"
        goal_approval_msg_id="$(yq eval ".approval.msg_id // \"\"" "${goal_file}")"
        goal_owner_role="$(yq eval ".owner_role // \"\"" "${goal_file}")"
        goal_milestones="$(yq eval ".milestones // []" "${goal_file}")"
        goal_title="$(basename "$(dirname "${goal_file}")")"

        if [[ -z "${goal_id}" || -z "${goal_deadline}" || -z "${goal_owner_role}" ]]; then
            echo "WARNING: Skipping malformed goal ${goal_file}" >&2
            continue
        fi

        # Skip if not approved (D2)
        if [[ -z "${goal_approval_msg_id}" ]]; then
            echo "INFO: Skipping unapproved goal ${goal_id}" >&2
            continue
        fi

        # Deadline event
        event_title="${goal_title}: Deadline"
        event_date="${goal_deadline}"
        event_kind="goal"
        event_source_key="goal:${goal_id}"
        event_audience="public"

        event_json="{\
            \"tenant_id\": \"${tenant_id}\", \
            \"title\": \"${event_title}\", \
            \"date\": \"${event_date}\", \
            \"kind\": \"${event_kind}\", \
            \"source_key\": \"${event_source_key}\", \
            \"audience\": \"${event_audience}\", \
            \"remind_at\": \"${goal_deadline}T00:00:00Z\"\
        }"

        batch+=("${event_json}")

        # Milestones
        local milestone_count
        milestone_count="$(echo "${goal_milestones}" | yq eval 'length' -)"
        for ((i=0; i<milestone_count; i++)); do
            milestone_key="$(echo "${goal_milestones}" | yq eval ".[${i}].key // \"\"" -)"
            milestone_date="$(echo "${goal_milestones}" | yq eval ".[${i}].date // \"\"" -)"
            milestone_title="$(echo "${goal_milestones}" | yq eval ".[${i}].title // \"\"" -)"

            if [[ -z "${milestone_key}" || -z "${milestone_date}" || -z "${milestone_title}" ]]; then
                continue
            fi

            event_title="${goal_title}: ${milestone_title}"
            event_date="${milestone_date}"
            event_kind="milestone"
            event_source_key="goal:${goal_id}:${milestone_key}"
            event_audience="public"

            event_json="{\
                \"tenant_id\": \"${tenant_id}\", \
                \"title\": \"${event_title}\", \
                \"date\": \"${event_date}\", \
                \"kind\": \"${event_kind}\", \
                \"source_key\": \"${event_source_key}\", \
                \"audience\": \"${event_audience}\", \
                \"remind_at\": \"${milestone_date}T00:00:00Z\"\
            }"

            batch+=("${event_json}")
        done
    done

    if [[ ${#batch[@]} -eq 0 ]]; then
        echo "INFO: No goals to sync" >&2
        rm -f "${batch_file}"
        return 0
    fi

    # Write batch to file
    printf "%s\n" "${batch[@]}" > "${batch_file}"

    # Send to hub
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
        echo "ERROR: Sync failed with HTTP ${response_code}: ${response_body}" >&2
        exit 1
    fi

    echo "INFO: Synced ${#batch[@]} events to calendar" >&2
}
