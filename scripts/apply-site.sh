#!/bin/sh
# Installs or replaces one site file and reloads Caddy. If Caddy rejects the
# new configuration, the previous file is put back, so a broken site file can
# never take the other sites down. Run on the VPS:
#
#   sh /home/deploy/vps-infra/scripts/apply-site.sh ./example.nl.caddy
#
# The file name decides which file it replaces: sites/<name>.caddy.
set -eu

src=${1:?usage: apply-site.sh <file.caddy>}
[ -f "$src" ] || { echo "no such file: $src" >&2; exit 1; }
name=$(basename "$src")
case "$name" in
    *.caddy) ;;
    *) echo "the file name must end in .caddy" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
target="sites/$name"
backup="sites/.$name.previous"

reload() {
    docker exec edge-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
}

had_previous=false
if [ -f "$target" ]; then
    cp "$target" "$backup"
    had_previous=true
fi
cp "$src" "$target"

if reload; then
    rm -f "$backup"
    echo "applied $target"
    exit 0
fi

echo "Caddy rejected $name; restoring the previous configuration" >&2
if $had_previous; then
    mv "$backup" "$target"
else
    rm -f "$target"
fi
reload
exit 1
