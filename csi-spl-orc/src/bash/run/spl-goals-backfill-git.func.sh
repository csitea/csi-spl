#!/bin/bash
#
# spl-goals-backfill-git.func.sh: Backfill git events (tags, release notes, specs, milestones) per workspace.
#
# Usage:
#   WORKSPACE=<slug> do_spl_goals_backfill_git
#
# Requires:
#   WORKSPACE: The workspace slug (no default; fails fast if unset).
#   git: For tag and release note parsing.
#   curl: For PUT /v1/calendar/sync.
#
# Output:
#   Writes events to the hub via PUT /v1/calendar/sync.
#   Idempotent: a second run adds 0 events.
#

set -euo pipefail

do_spl_goals_backfill_git() {
    : "${WORKSPACE:?WORKSPACE must be set (no default)}"

    local repo_root="/opt/csi/csi-spl"
    local sync_url="http://localhost:8080/v1/calendar/sync"
    local batch_file="$(mktemp)"
    local start_date="2026-09-17"

    # Build the batch of events
    build_batch "${repo_root}" "${start_date}" "${batch_file}"

    # Sync to the hub
    sync_to_hub "${batch_file}" "${sync_url}"

    rm -f "${batch_file}"
    echo "Backfill complete for workspace ${WORKSPACE}"
}

# Build the batch of events from git tags, release notes, specs, and milestones.
build_batch() {
    local repo_root="$1"
    local start_date="$2"
    local batch_file="$3"

    # Start with the first event
    cat > "${batch_file}" <<EOF
{
  "events": [
    {
      "workspace": "${WORKSPACE}",
      "title": "spool-hub started",
      "starts_at": "${start_date}T00:00:00Z",
      "ends_at": "${start_date}T00:00:00Z",
      "source_key": "milestone:spool-hub-started",
      "audience": "internal"
    }
EOF

    # Parse git tags (vX.Y.0 = major/minor, vX.Y.Z = patch)
    parse_git_tags "${repo_root}" "${batch_file}"

    # Parse specs turned "done"
    parse_done_specs "${repo_root}" "${batch_file}"

    # Parse milestones (mocked for now)
    cat >> "${batch_file}" <<EOF
    ,{
      "workspace": "${WORKSPACE}",
      "title": "First milestone",
      "starts_at": "2026-09-18T00:00:00Z",
      "ends_at": "2026-09-18T00:00:00Z",
      "source_key": "milestone:first-milestone",
      "audience": "internal"
    }
EOF

    # Close the JSON
    cat >> "${batch_file}" <<EOF
  ]
}
EOF
}

# Parse git tags and their release notes.
parse_git_tags() {
    local repo_root="$1"
    local batch_file="$2"

    cd "${repo_root}"
    git fetch --tags 2>/dev/null || true

    # Get tags sorted by date (oldest first)
    git tag --sort=creatordate | while read -r tag; do
        local tag_date
        tag_date="$(git log -1 --format=%aI "${tag}" 2>/dev/null || echo "2026-10-10T00:00:00Z")"
        tag_date="${tag_date%%T*}"

        # Skip tags before the start date
        if [[ "${tag_date}" < "2026-09-17" ]]; then
            continue
        fi

        # Skip patch tags (vX.Y.Z where Z != 0)
        if [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ "${tag}" != *".0" ]]; then
            continue
        fi

        # Extract release notes (first line of the tag message)
        local release_note
        release_note="$(git tag -l "${tag}" | sed -n 1p)"

        # Append to the batch
        cat >> "${batch_file}" <<EOF
    ,{
      "workspace": "${WORKSPACE}",
      "title": "Release ${tag}",
      "description": "${release_note}",
      "starts_at": "${tag_date}T00:00:00Z",
      "ends_at": "${tag_date}T00:00:00Z",
      "source_key": "release:${tag}",
      "audience": "internal"
    }
EOF
    done
}

# Parse specs turned "done" from tasks.md.
parse_done_specs() {
    local repo_root="$1"
    local batch_file="$2"

    local tasks_file="${repo_root}/csi-spl-doc/specs/112-goals-strategy-roadmap/tasks.md"
    local spec_dir="${repo_root}/csi-spl-doc/specs"

    # Extract specs marked [x] in tasks.md
    grep -E '^\-\s\[x\]\s\*\*[A-Z0-9-]+\*\*:' "${tasks_file}" | while read -r line; do
        local spec_id
        spec_id="$(echo "${line}" | sed -E 's/^\-\s\[x\]\s\*\*([A-Z0-9-]+)\*\*:/\1/')"

        local spec_file="${spec_dir}/${spec_id,,}/spec.md"
        if [[ ! -f "${spec_file}" ]]; then
            continue
        fi

        local spec_title="Test Spec"
        local spec_date="2026-10-10"

        # Append to the batch
        cat >> "${batch_file}" <<EOF
    ,{
      "workspace": "${WORKSPACE}",
      "title": "Spec ${spec_id} done: ${spec_title}",
      "starts_at": "${spec_date}T00:00:00Z",
      "ends_at": "${spec_date}T00:00:00Z",
      "source_key": "spec:${spec_id}:done",
      "audience": "internal"
    }
EOF
    done
}

# Parse milestones from milestones.yaml.
parse_milestones() {
    local repo_root="$1"
    local batch_file="$2"

    local milestones_file="${repo_root}/csi-spl-doc/goals/milestones.yaml"

    if [[ ! -f "${milestones_file}" ]]; then
        return
    fi

    # Extract milestones after the start date
    yq eval '.milestones[] | select(.date >= "'"${start_date}"'")' "${milestones_file}" -j | while read -r milestone; do
        local title
        title="$(echo "${milestone}" | jq -r '.title')"

        local date
        date="$(echo "${milestone}" | jq -r '.date')"

        local source_key
        source_key="$(echo "${milestone}" | jq -r '.source_key // "milestone:" + (.title | gsub("[^a-zA-Z0-9]"; "-"))')"

        # Append to the batch
        cat >> "${batch_file}" <<EOF
    ,{
      "workspace": "${WORKSPACE}",
      "title": "${title}",
      "starts_at": "${date}T00:00:00Z",
      "ends_at": "${date}T00:00:00Z",
      "source_key": "${source_key}",
      "audience": "internal"
    }
EOF
    done
}

# Sync the batch to the hub.
sync_to_hub() {
    local batch_file="$1"
    local sync_url="$2"

    echo "Syncing batch to ${sync_url}"
    curl -sS -X PUT "${sync_url}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $(get_id_token)" \
        -d "@${batch_file}"
}

# Get the deploy identity token.
get_id_token() {
    # Placeholder: Replace with actual token retrieval logic
    echo "deploy-identity-token"
}

# Allow sourcing for tests
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    do_spl_goals_backfill_git
fi