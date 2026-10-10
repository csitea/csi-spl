#!/bin/bash

#------------------------------------------------------------------------------
# @description Gcp import to cloudsql.
# @example ENV=dev SERVICE_KEY_FILE=$HOME/.gcp/.csi/key-sa-ci-csi-spl-dev-rdb.json GS_UTIL_URI=gs://csi-spl-dev-backups/csi-spl_db_backup_20250121.sql ./run -a do_gcp_import_to_cloudsql
# @example ENV=stg SERVICE_KEY_FILE=$HOME/.gcp/.csi/key-sa-ci-csi-spl-stg-rdb.json GS_UTIL_URI=gs://csi-spl-stg-backups/csi-spl_db_backup_20250121.sql ./run -a do_gcp_import_to_cloudsql
# @example ENV=prd SERVICE_KEY_FILE=$HOME/.gcp/.csi/key-sa-ci-csi-spl-prd-rdb.json GS_UTIL_URI=gs://csi-spl-prd-backups/csi-spl_db_backup_20250121.sql ./run -a do_gcp_import_to_cloudsql
#------------------------------------------------------------------------------
do_gcp_import_to_cloudsql() {
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
  do_gcp_log_identity "${PROJ_ID:-<unset>}" "${account}" "do_gcp_import_to_cloudsql"

  # Required variables for organization and application
  do_resolve_oap ORG
  do_resolve_oap APP
  do_require_var ENV ${ENV:-}
  do_require_var SERVICE_KEY_FILE ${SERVICE_KEY_FILE:-}
  do_require_var GS_UTIL_URI ${GS_UTIL_URI}

  PROJ_ID="${ORG}-${APP}-${ENV}"
  CNF_PATH="$APP_PATH/${ORG}-${APP}-cnf/${ORG}-${APP}/${ENV}.env.json"
  CLOUDSQL_INSTANCE=$(cat $CNF_PATH | jq -r '.env.rdb.cloud_sql_instance')
  APP_DB=$(cat $CNF_PATH | jq -r '.env.rdb.app_db')
  # Schema the dump populates; public unless the caller overrides it.
  APP_SCHEMA="${APP_SCHEMA:-public}"
  PGHOST=$(cat $CNF_PATH | jq -r '.env.rdb."pg-host"')

  echo using:
  printf "%-20s %-20s\n" "Variable" "Value"
  printf "%-20s %-20s\n" "ORG" "$ORG"
  printf "%-20s %-20s\n" "APP" "$APP" 
  printf "%-20s %-20s\n" "ENV" "${ENV:-}"
  printf "%-20s %-20s\n" "SERVICE_KEY_FILE" "${SERVICE_KEY_FILE:-}"
  printf "%-20s %-20s\n" "GS_UTIL_URI" "${GS_UTIL_URI}"
  printf "%-20s %-20s\n" "PROJ_ID" "${PROJ_ID}"
  printf "%-20s %-20s\n" "CLOUDSQL_INSTANCE" "${CLOUDSQL_INSTANCE}"
  printf "%-20s %-20s\n" "APP_DB" "${APP_DB}"
  printf "%-20s %-20s\n" "PGHOST" "${PGHOST}"

  test -f "$SERVICE_KEY_FILE" || quit_on "The service key file does not exist: $SERVICE_KEY_FILE"

  gcloud auth activate-service-account --key-file="$SERVICE_KEY_FILE" --quiet
  account=$(do_gcp_isolated_active_account) || quit_on "re-pin --account to the identity just activated in the isolated gcloud config"
  quit_on "Authenticating the service account with the key file"

  gcloud config set project "$PROJ_ID" --quiet
  quit_on "Setting project to $PROJ_ID"

  gcloud storage objects describe "$GS_UTIL_URI" --account="${account}" >/dev/null 2>&1 || quit_on "Backup file $GS_UTIL_URI not found for environment $ENV"
  do_log "INFO restoring from the following GS_UTIL_URI: $GS_UTIL_URI"

  # Test connectivity to the database
  PGDATABASE="postgres"
  PGUSER="postgres"
  PGPASSWORD=$(gcloud secrets versions access latest --secret="$PROJ_ID-api-pwd-cloud-sql-postgres" --account="${account}" --project="$PROJ_ID")
  PGHOST=$PGHOST PGUSER=$PGUSER PGPASSWORD=$PGPASSWORD PGDATABASE=$PGDATABASE psql -c '\l'
  quit_on "There is no connectivity to the database at $PGHOST with the user $PGUSER"


  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql -At -c "
  SELECT 'SELECT pg_terminate_backend(' || pg_stat_activity.pid || ');'
  FROM pg_stat_activity
  WHERE datname = '$APP_DB' AND pid <> pg_backend_pid();
  " | PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql -At



  # Fetch the secret values
  SECRET_NAME="$PROJ_ID-cloudsql_credentials"
  SECRET_JSON=$(gcloud secrets versions access latest --secret="$SECRET_NAME" --account="${account}" --project="$PROJ_ID")
  APP_USR=$(echo "$SECRET_JSON" | jq -r '.DB_USER')
  APP_PWD=$(echo "$SECRET_JSON" | jq -r '.DB_PASS')

  # Create the user if it doesn't exist
  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql <<EOF_CREATE_APP_USR
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$APP_USR') THEN
    CREATE ROLE $APP_USR LOGIN PASSWORD '$APP_PWD';
  END IF;
END
\$\$;
EOF_CREATE_APP_USR

  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql -c "GRANT $APP_USR TO postgres;"
  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql -c '\du $APP_USR'



  # Recreate the application database
  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=postgres psql <<EOF
DROP DATABASE IF EXISTS $APP_DB;
CREATE DATABASE $APP_DB OWNER $APP_USR;
ALTER DATABASE $APP_DB OWNER TO $APP_USR;


-- 1) Change ownership of the DB (optional, but easiest way to ensure full rights)
ALTER DATABASE $APP_DB 
  OWNER TO $APP_USR;

-- 2) Make the $APP_USR user own the schema as well (optional, but recommended):
ALTER SCHEMA $APP_SCHEMA 
  OWNER TO $APP_USR;

-- 3) Grant all privileges on all existing tables:
GRANT ALL PRIVILEGES ON ALL TABLES 
  IN SCHEMA $APP_SCHEMA 
  TO $APP_USR;

-- 4) Grant all privileges on all existing sequences (for autoincrement fields, etc.):
GRANT ALL PRIVILEGES ON ALL SEQUENCES 
  IN SCHEMA $APP_SCHEMA 
  TO $APP_USR;

-- 5) Ensure any *future* tables also grant privileges automatically:
ALTER DEFAULT PRIVILEGES 
  IN SCHEMA $APP_SCHEMA
  GRANT ALL ON TABLES 
  TO $APP_USR;


SELECT table_schema, table_name, grantee, privilege_type
FROM information_schema.table_privileges
WHERE grantee = '$APP_USR'
ORDER BY table_schema, table_name;


EOF
  quit_on "Re-creating the application database: $APP_DB"

  # # Import the database
  # #gcloud sql import sql $CLOUDSQL_INSTANCE $GS_UTIL_URI --project=$PROJ_ID --database=$APP_DB -q
  # gcloud sql import sql $CLOUDSQL_INSTANCE $GS_UTIL_URI --project=$PROJ_ID --database=$APP_DB --user=$APP_USR -q

  # Import the database
  if [[ "$GS_UTIL_URI" == *.tar.gz ]]; then
    echo "Detected a binary dump file (.tar.gz). Using 'gcloud sql import sql'..."
    gcloud sql import sql $CLOUDSQL_INSTANCE $GS_UTIL_URI --project=$PROJ_ID --database=$APP_DB --user=$APP_USR -q --account="${account}"
    quit_on "Importing the database from binary dump $GS_UTIL_URI"
  elif [[ "$GS_UTIL_URI" == *.sql ]]; then
    echo "Detected a plain SQL file (.sql). Downloading and applying with psql..."
    
    # Download the file
    mkdir -p $APP_PATH/dat/sql/
    LOCAL_SQL_FILE=$APP_PATH/dat/sql/$(basename "$GS_UTIL_URI")
    gcloud storage cp "$GS_UTIL_URI" "$LOCAL_SQL_FILE" --account="${account}"
    quit_on "Downloading the SQL file from $GS_UTIL_URI"

    # Apply the SQL file using psql
    PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=$APP_DB psql < "$LOCAL_SQL_FILE"
    quit_on "Applying the SQL file $LOCAL_SQL_FILE with psql"
  else
    echo "Unsupported file format: $GS_UTIL_URI"
    return 1
  fi


  # Recreate the application database
  PGHOST=$PGHOST PGUSER=postgres PGPASSWORD=$PGPASSWORD PGDATABASE=$APP_DB psql <<EOF
grant usage on schema $APP_SCHEMA to $APP_USR;
EOF
  quit_on "ensure the $APP_USR does have : $APP_DB"


  quit_on "Importing the application database: $APP_DB from $GS_UTIL_URI"

  do_log "INFO successfully imported the application database: $APP_DB from $GS_UTIL_URI"

}
