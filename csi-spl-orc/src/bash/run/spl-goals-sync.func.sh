#!/bin/bash
#
# spl-goals-sync.func.sh: Deploy-time goal sync per workspace (ORC-2).
#
# Reads every goal.yaml, builds a batch for PUT /v1/calendar/sync, and sends it.
# Each event and goal names its workspace. No audience is sent (HUB-2 sets it).
#
# Usage:
#   . spl-goals-sync.func.sh
#   do_spl_goals_sync
#
# Depends:
#   - yq (for YAML parsing)
#   - curl (for HTTP calls)
#   - HUB_ID_TOKEN (deploy identity token)
#   - HUB_URL (e.g., https://hub.csi.dev)
#

set -euo pipefail

do_spl_goals_sync() {
    local goals_dir="${GOALS_DIR:-/opt/csi/csi-spl-doc/goals}"
    local batch_file="$(mktemp)"
    local hub_url="${HUB_URL:-https://hub.csi.dev}"
    local hub_token="${HUB_ID_TOKEN:-fake_token}"
    local now_iso8601
    now_iso8601="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    echo "Building goal sync batch..."

    # Find all goal.yaml files and process them
    find "${goals_dir}" -name "goal.yaml" | while read -r goal_file; do
        local goal_dir="$(dirname "${goal_file}")"
        local goal_id="$(yq -r '.id' "${goal_file}")"
        local workspace="$(yq -r '.workspace' "${goal_file}")"
        local owner_role="$(yq -r '.owner_role' "${goal_file}" 2>/dev/null || echo)"
        local deadline="$(yq -r '.deadline' "${goal_file}" 2>/dev/null || echo)"
        local public="$(yq -r '.public' "${goal_file}" 2>/dev/null || echo)"
        local approval_msg_id="$(yq -r '.approval.msg_id' "${goal_file}" 2>/dev/null || echo)"
        local specs=()
        while IFS= read -r line; do
            specs+=("${line}")
        done < <(yq -r '.specs[]?' "${goal_file}" 2>/dev/null || true)
        
        local done_lines=()
        while IFS= read -r line; do
            done_lines+=("${line}")
        done < <(yq -r '.done_lines[]?' "${goal_file}" 2>/dev/null || true)
        
        local milestones=()
        while IFS= read -r line; do
            milestones+=("${line}")
        done < <(yq -r '.milestones[]? | .key + ":" + .date + ":" + .title' "${goal_file}" 2>/dev/null || true)

        # Fail fast if workspace is missing or null
        if [[ -z "${workspace}" || "${workspace}" == "null" || "${workspace}" == "" ]]; then
            echo "ERROR: Goal ${goal_id} (${goal_file}) is missing 'workspace'." >&2
            exit 1
        fi

        # Build the goal object
        cat <<EOF >> "${batch_file}"
        {
            "workspace": "${workspace}",
            "id": "${goal_id}",
            "owner_role": "${owner_role}",
            "deadline": "${deadline}",
            "public": ${public},
            "approval": {"msg_id": "${approval_msg_id}"},
            "specs": ["$(echo "${specs[@]}" | sed 's/ /","/g')"],
            "done_lines": ["$(echo "${done_lines[@]}" | sed 's/ /","/g')"]
        }
EOF

        # Build the deadline event
        local deadline_key="goal:${goal_id}:deadline"
        local roadmap_url="/roadmap?ws=${workspace}&goal=${goal_id}"
        cat <<EOF >> "${batch_file}"
        {
            "workspace": "${workspace}",
            "source_key": "${deadline_key}",
            "title": "Goal ${goal_id} deadline",
            "kind": "goal",
            "starts_at": "${deadline}T00:00:00Z",
            "ends_at": "${deadline}T23:59:59Z",
            "remind_at": "$(date -u -d "${deadline} -7 days" +'%Y-%m-%dT09:00:00Z')",
            "props": {
                "roadmap_url": "${roadmap_url}",
                "goal_id": "${goal_id}",
                "specs": ["$(echo "${specs[@]}" | sed 's/ /","/g')"],
                "done_lines": ["$(echo "${done_lines[@]}" | sed 's/ /","/g')"]
            }
        }
EOF

        # Build milestone events
        for milestone in "${milestones[@]}"; do
            local key="$(echo "${milestone}" | cut -d: -f1)"
            local date="$(echo "${milestone}" | cut -d: -f2)"
            local title="$(echo "${milestone}" | cut -d: -f3-)"
            local milestone_key="goal:${goal_id}:m:${key}"
            cat <<EOF >> "${batch_file}"
            {
                "workspace": "${workspace}",
                "source_key": "${milestone_key}",
                "title": "${title}",
                "kind": "milestone",
                "starts_at": "${date}T00:00:00Z",
                "ends_at": "${date}T23:59:59Z",
                "remind_at": "$(date -u -d "${date} -1 day" +'%Y-%m-%dT09:00:00Z')",
                "props": {
                    "roadmap_url": "${roadmap_url}",
                    "goal_id": "${goal_id}"
                }
            }
EOF
        done
    done

    # Wrap the batch in a JSON array and send it
    if [[ -s "${batch_file}" ]]; then
        echo "Sending goal sync batch to ${hub_url}/v1/calendar/sync..."
        {
            echo -n '{"goals": ['
            cat "${batch_file}" | jq -s '.' | sed '$s/,$//'
            echo -n '], "events": ['
            cat "${batch_file}" | jq -s '.' | sed '$s/,$//'
            echo ']}'
        } | curl -sS -X PUT "${hub_url}/v1/calendar/sync" \
            -H "Authorization: Bearer ${hub_token}" \
            -H "Content-Type: application/json" \
            -d @-

        echo "Goal sync batch sent."
    else
        echo "No goals found to sync."
    fi

    rm -f "${batch_file}"
}

if [[ "${0}" == "${BASH_SOURCE[0]}" ]]; then
    do_spl_goals_sync
fi