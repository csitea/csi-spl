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

_build_backfill_batch() {
    local repo_root="$1"
    local tenant_id="$2"
    local batch=()
    local milestones_file="${repo_root}/csi-spl-doc/goals/milestones.yaml"
    local milestone_line
    local milestone_date
    local milestone_title
    local tag
    local tag_date
    local tag_message
    local event_title
    local event_date
    local event_kind
    local event_source_key
    local event_audience
    local event_json

    # Backfill from milestones.yaml (starting with 2026-09-17 spool-hub started)
    if [[ -f "${milestones_file}" ]]; then
        while IFS= read -r milestone_line; do
            if [[ "${milestone_line}" =~ ^# || -z "${milestone_line}" ]]; then
                continue
            fi

            milestone_date="$(echo "${milestone_line}" | cut -d' ' -f1)"
            milestone_title="$(echo "${milestone_line}" | cut -d' ' -f2-)"

            if [[ -z "${milestone_date}" || -z "${milestone_title}" ]]; then
                continue
            fi

            event_title="Release: ${milestone_title}"
            event_date="${milestone_date}"
            event_kind="release"
            event_source_key="release:${milestone_date}"
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
        done < "${milestones_file}"
    fi

    # Backfill from git tags (v*.0 only, skip patch tags)
    while IFS= read -r tag; do
        if [[ "" != "v1.2.0"         if [[ "" != "v1.2.0"         if [[ "" != "v1.2.0"         if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then        if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then        if [[ "" != "v1.2.0"         if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then        if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then        if [[ "" != "v1.2.0"         if [[ "" != "v1.2.0"         if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then        if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then        if [[ "" != "v1.2.0"         if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then        if [[ "${tag}" != "v1.2.0" && "${tag}" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then "" != "v1.3.0" ]]; then
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

    echo "${batch[@]}"
}

do_spl_goals_backfill_git() {
    local repo_root
    local cnf_file
    local tenant_id
    local hub_base_url
    local deploy_token
    local batch_file
    local batch

    repo_root="$(git rev-parse --show-toplevel)"
    cnf_file="${repo_root}/csi-spl-cnf/csi-spl/all.env.yaml"

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

    batch=($(_build_backfill_batch "${repo_root}" "${tenant_id}"))
    if [[ ${#batch[@]} -eq 0 ]]; then
        echo "INFO: No events to backfill" >&2
        rm -f "${batch_file}"
        return 0
    fi

    printf "%s\n" "${batch[@]}" > "${batch_file}"
    _send_to_hub "${hub_base_url}" "${deploy_token}" "${batch_file}"
    rm -f "${batch_file}"
}