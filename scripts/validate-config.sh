#!/usr/bin/env bash
# Validates docker-compose.yml and the Caddy configuration.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "Validating docker-compose.yml"
# The secret file only exists on the VPS; give Compose a placeholder.
mkdir -p secrets
created_secret=false
if [ ! -e secrets/db_superuser_password ]; then
    echo placeholder > secrets/db_superuser_password
    created_secret=true
fi
trap '$created_secret && rm -f secrets/db_superuser_password' EXIT
docker compose config --quiet

image=$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["caddy"]["image"])')
echo "Validating the Caddyfile with ${image}"
docker run --rm \
  -v "$root/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$root/sites:/etc/caddy/sites:ro" \
  "$image" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

echo "Checking formatting"
for f in Caddyfile sites/*.caddy; do
  docker run --rm -i "$image" caddy fmt - < "$f" | diff -u "$f" - \
    || { echo "$f is not formatted; run: caddy fmt --overwrite $f" >&2; exit 1; }
done
