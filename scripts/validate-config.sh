#!/usr/bin/env bash
# Validate docker-compose.yml and the nginx configuration.
# Vhosts reference certificates that exist only on the VPS, so stub them.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

echo "Validating docker-compose.yml"
docker compose config --quiet

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

shopt -s nullglob
for conf in conf.d/*.conf; do
  if ! grep -qE '^[[:space:]]*ssl_certificate[[:space:]]' "$conf"; then
    continue
  fi
  domain=$(basename "$conf" .conf)
  mkdir -p "$workdir/live/$domain"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$workdir/live/$domain/privkey.pem" \
    -out "$workdir/live/$domain/fullchain.pem" \
    -subj "/CN=$domain" 2>/dev/null
  echo "stubbed certificate for $domain"
done

image=$(docker compose config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["proxy"]["image"])')
echo "Testing nginx config with ${image}"
docker run --rm \
  -v "$root/conf.d:/etc/nginx/conf.d:ro" \
  -v "$workdir:/etc/letsencrypt:ro" \
  "$image" nginx -t
