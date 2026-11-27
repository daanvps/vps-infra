#!/bin/sh
# Scaffolds a site file for a site whose configuration lives in this repo.
#
#   ./scripts/add-site.sh example.nl example-web 8080
#
# Commit the file and push; the deploy workflow reloads Caddy, which
# requests the certificate by itself. Apps can also ship their own site file
# with scripts/apply-site.sh instead (see the README).
set -eu

domain=${1:?usage: add-site.sh <domain> <container> [port]}
container=${2:?usage: add-site.sh <domain> <container> [port]}
port=${3:-8080}

target="$(dirname "$0")/../sites/${domain}.caddy"
[ -e "$target" ] && { echo "error: $target already exists" >&2; exit 1; }

cat > "$target" <<SITE
${domain} {
	import common
	reverse_proxy ${container}:${port}
}

www.${domain} {
	redir https://${domain}{uri} permanent
}
SITE

echo "Created $target"
echo "Make sure '${container}' joins the edge-net network, then commit and push."
