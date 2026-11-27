#!/bin/sh
# Creates the secrets the stack needs, once. Run on the VPS from the infra
# directory. Existing secrets are never overwritten.
set -eu
[ -f docker-compose.yml ] || { echo "run this from the infra directory" >&2; exit 1; }

umask 077
mkdir -p secrets
chmod 700 secrets

if [ ! -s secrets/db_superuser_password ]; then
    # 48 letters and digits.
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48 > secrets/db_superuser_password
    echo "created secrets/db_superuser_password"
fi
# Readable inside the database container, which runs as its own user; the
# directory itself stays private to the deploy user.
chmod 644 secrets/db_superuser_password
