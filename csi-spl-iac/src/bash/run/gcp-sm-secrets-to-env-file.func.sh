#!/bin/bash

#------------------------------------------------------------------------------
# @description export GCP Secret Manager secrets to a .env file for the API
# @example ORG=csi APP=csi-spl ENV=dev ./run -a do_gcp_sm_secrets_to_env_file
#------------------------------------------------------------------------------
do_gcp_sm_secrets_to_env_file() {
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
  # Pin the gcloud identity for this run (spec 012 C-2). `--project` says WHERE
  # a call lands, never WHO it lands as, and `~/.config/gcloud` is one directory
  # shared by every agent on this box — `gcloud config set account` and
  # `auth activate-service-account` are both global writes, so the ambient
  # account is whichever agent ran one last. Resolved ONCE here so another
  # agent cannot move this run's identity between two of its own calls, passed
  # explicitly to each call below, and logged before the first of them so the
  # identity is auditable afterwards rather than inferable from a config file
  # that will have moved by the time anyone looks.
  local account
  account=$(do_gcp_account) || quit_on "no gcloud identity could be resolved — set ACCOUNT or GCP_ACCOUNT"
  do_gcp_log_identity "<unset>" "${account}" "do_gcp_sm_secrets_to_env_file"


  # Ensure required variables are set
  do_require_var ORG ${ORG:-}
  do_require_var APP ${APP:-}
  do_require_var ENV ${ENV:-}
  
	# Parameterized output file path, which is the backend API .env file
	OUTPUT_FILE="${APP_PATH}/${ORG}-${APP}-api/backend_api/djangorest/.env"

	# Ensure the output file is empty before starting
	> "$OUTPUT_FILE"

	# Authenticate with the service account
	gcloud auth activate-service-account --key-file=$HOME/.gcp/.$ORG/key-sa-ci-${ORG}-${APP}-${ENV}-bck_srvs.json

  gcloud config set project ${ORG}_${APP}_${ENV}

	# Prefix to match for secrets
	SECRET_PREFIX=$(echo "${ORG}_${APP}_${ENV}_API_" | tr '[:lower:]' '[:upper:]')

	# Fetch all secrets starting with "csi-spl-dev-api-"
	secrets=($(gcloud secrets list --filter="name:${ORG}-${APP}-${ENV}-api-" --format="value(name)" --account="${account}" --project="${ORG}-${APP}-${ENV}"))

	# Write secrets to a temporary file for processing
	list_file=$(mktemp)
	printf "%s\n" "${secrets[@]}" > "$list_file"

	# Initialize counters
	c=0
	chunk_size=3

	# Process secrets in parallel with forking
	cat "$list_file" | {
		while read -r secret; do
			c=$((c + 1))

			# Fork after every $chunk_size secrets
			test $c -eq $chunk_size && sleep $c && export c=0

			# Forked process
			(
				do_log "INFO working on $secret secret"

				# Fetch the secret description (if available)
				description=$(gcloud secrets describe "$secret" --format="value(description)" --account="${account}" --project="${ORG}-${APP}-${ENV}" || echo "")

				# Fetch the latest value of the secret
				value=$(gcloud secrets versions access latest --secret="$secret" --account="${account}" --project="${ORG}-${APP}-${ENV}" 2>/dev/null || echo "")

				# Convert secret name to UPPER_SNAKE_CASE
				variable_name=$(echo "$secret" | sed -E 's/-/_/g' | tr '[:lower:]' '[:upper:]')

				# Remove the prefix (e.g., "ILM_OPA_DEV_API_")
				clean_variable_name=$(echo "$variable_name" | perl -ne  "s|${SECRET_PREFIX}||g;print")

        # skip any json containing secret values and write the rest to the .env file
        if ! [[ "$value" =~ [{] || "$value" =~ [}] ]]; then
        {
          echo "# $description" 
          echo "${clean_variable_name}=\"${value}\""
          echo
        } >> "$OUTPUT_FILE"
        fi

				do_log "INFO Processed secret: $secret"
			) &
		done

		wait
	}

	rm -f "$list_file"

	do_log "INFO .env file created at $OUTPUT_FILE"
}
