#!/bin/sh
# Creates a database and its owner role in shared-db, or updates the role's
# password when they already exist. Safe to run on every deploy.
#
#   printf '%s' "$DB_PASSWORD" | sh scripts/ensure-database.sh <database> <role>
#
# The password is read from stdin so it never shows up in a process list.
# Names: lowercase letters, digits and underscores. Password: at least 24
# letters and digits.
set -eu

db=${1:?usage: ensure-database.sh <database> <role> (password on stdin)}
role=${2:?usage: ensure-database.sh <database> <role> (password on stdin)}

valid_name() {
    case "$1" in
        ''|[!a-z]*|*[!a-z0-9_]*) return 1 ;;
    esac
}
valid_name "$db" || { echo "invalid database name: $db" >&2; exit 1; }
valid_name "$role" || { echo "invalid role name: $role" >&2; exit 1; }
case "$db$role" in postgres*|template*) echo "reserved name" >&2; exit 1 ;; esac

password=$(cat)
case "$password" in
    *[!A-Za-z0-9]*) echo "the password may only contain letters and digits" >&2; exit 1 ;;
esac
[ "${#password}" -ge 24 ] || { echo "the password must be at least 24 characters" >&2; exit 1; }

# psql connects over the container's local socket, which the official image
# trusts, so no superuser password is needed here. Values reach psql through
# \set on stdin, never as command-line arguments.
{
    printf "\\\\set db '%s'\n\\\\set role '%s'\n\\\\set pw '%s'\n" "$db" "$role" "$password"
    cat <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
 WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'role')
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
REVOKE ALL ON DATABASE :"db" FROM PUBLIC;
GRANT ALL ON DATABASE :"db" TO :"role";
-- App roles only reach their own database, not the maintenance ones.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
SQL
} | docker exec -i shared-db psql --quiet -v ON_ERROR_STOP=1 -U postgres -d postgres

echo "database $db is ready for role $role"
