#!/usr/bin/env bash
# Scaffold a vhost for a new site.
#
#   ./scripts/add-site.sh example.nl example-web 8080
#
# Then commit the generated file and push; the deploy workflow issues the
# certificate and reloads the proxy.
set -euo pipefail

domain=${1:?usage: add-site.sh <domain> <container> [port]}
container=${2:?usage: add-site.sh <domain> <container> [port]}
port=${3:-8080}

target="$(dirname "$0")/../conf.d/${domain}.conf"

if [ -e "$target" ]; then
    echo "error: $target already exists" >&2
    exit 1
fi

cat > "$target" <<EOF
server {
    listen 80;
    server_name ${domain} www.${domain};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${domain} www.${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/nginx/conf.d/include/tls.conf;

    location / {
        resolver 127.0.0.11 valid=10s;
        set \$upstream http://${container}:${port};
        proxy_pass \$upstream;
        include /etc/nginx/conf.d/include/proxy.conf;
    }
}
EOF

echo "Created $target"
echo "Ensure '${container}' joins the edge-net network, then commit and push."
