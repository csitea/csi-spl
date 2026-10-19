# Local-only secret files of the root docker-compose.yml

These three files are the PUBLIC defaults of the standalone stack, so that
`docker compose up -d` works on a laptop with no setup. They are not secrets:
the same values were the compose env defaults before SPL-2158. compose reads
them while `SPOOL_SECRETS_DIR` is unset.

| file | read as |
|---|---|
| `db_superuser_password` | `POSTGRES_PASSWORD_FILE` (pg), `SPOOL_SUPERUSER_PASSWORD_FILE` (hub-init) |
| `s3_secret_key` | `AWS_SECRET_ACCESS_KEY` (s3, via `secret-env.sh`), `SPOOL_S3_SECRET_KEY_FILE` (hub) |
| `mail_smtp_password` | `SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE` (hub); empty: no SMTP login |

Anything reachable beyond this machine sets `SPOOL_SECRETS_DIR=./secrets` in
`.env` and keeps its own three files there (git-ignored): DEPLOY.md,
"Secret files". hub-init refuses the default superuser password off
localhost. Never write a real value into this directory.
