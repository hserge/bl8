#!/usr/bin/env bash
# Runs setup.sql to create the bl8 database and its two roles, then prints
# the connection strings and generated passwords. Assumes PostgreSQL is
# already installed and running on this machine, and that setup.sql is in
# the same directory as this script.
#
# Deliberately does NOT touch pg_hba.conf, listen_addresses, or any
# firewall/CIDR rules — network access control is handled separately, not
# by this script.
#
#   sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_NAME="${DB_NAME:-bl8}"
UI_ROLE="${UI_ROLE:-bl8_ui}"
REDIRECT_ROLE="${REDIRECT_ROLE:-bl8_redirect}"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

UI_PASSWORD=$(openssl rand -base64 24)
REDIRECT_PASSWORD=$(openssl rand -base64 24)

sudo -u postgres psql -v ON_ERROR_STOP=1 \
	-v db_name="$DB_NAME" \
	-v ui_role="$UI_ROLE" \
	-v redirect_role="$REDIRECT_ROLE" \
	-v ui_password="$UI_PASSWORD" \
	-v redirect_password="$REDIRECT_PASSWORD" \
	< "${SCRIPT_DIR}/setup.sql"

VM_IP=$(hostname -I | awk '{print $1}')

cat <<EOF

Postgres is up on ${VM_IP}:5432, database "${DB_NAME}".

Set these as GitHub Actions secrets:

  UI_DATABASE_URL=postgres://${UI_ROLE}:${UI_PASSWORD}@${VM_IP}:5432/${DB_NAME}?sslmode=disable
  REDIRECT_DATABASE_URL=postgres://${REDIRECT_ROLE}:${REDIRECT_PASSWORD}@${VM_IP}:5432/${DB_NAME}?sslmode=disable

sslmode=disable, not require: this script does not configure TLS, so traffic is unencrypted in
transit. Network-level access control (who can even reach port 5432) is handled outside this
script — make sure that's in place before relying on these credentials.

Then run ui/'s migration once, from a machine that can reach this VM:

  DATABASE_URL="postgres://${UI_ROLE}:${UI_PASSWORD}@${VM_IP}:5432/${DB_NAME}" pnpm exec drizzle-kit push

These passwords are shown once — they are not stored anywhere on this VM beyond Postgres's own
role table. Save them now.
EOF
