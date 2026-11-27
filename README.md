# vps-infra

Shared infrastructure for the sites on the VPS:

- **Caddy** (`edge-caddy`) owns ports 80 and 443, routes each domain to the
  right container, and obtains and renews HTTPS certificates by itself.
- **Postgres 18** (`shared-db`) holds one database per app, on an internal
  network with no published port, with a nightly backup (`shared-db-backup`).

Applications do not run their own proxy or publish ports. They join the
external `edge-net` network (and `db-net` when they use the database) and
are reached by container name.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Caddy, the database and the backup job |
| `Caddyfile` | global settings, shared headers (`common`), health endpoint, imports `sites/` |
| `sites/<domain>.caddy` | one file per site |
| `scripts/apply-site.sh` | installs one site file on the VPS and reloads Caddy, rolling back if Caddy rejects it |
| `scripts/ensure-database.sh` | creates or updates an app's database and role |
| `scripts/add-site.sh` | scaffolds a site file in this repo |
| `scripts/init-secrets.sh` | creates the database superuser password on the VPS, once |
| `scripts/validate-config.sh` | checks the Compose file and runs `caddy validate` and `caddy fmt` |

## Adding a site

A site needs a container on `edge-net` and a site file:

```caddy
example.nl {
	import common
	reverse_proxy example-web:8080
}

www.example.nl {
	redir https://example.nl{uri} permanent
}
```

Point the A records for `example.nl` and `www.example.nl` at the VPS. Caddy
requests the certificate the first time it sees the name; there is nothing
else to do.

There are two ways to deliver the file.

**From the app's own GitHub Actions workflow** (no change to this repo).
Keep the file in the app repo, copy it to the VPS and apply it:

```yaml
- name: Upload site file
  uses: appleboy/scp-action@917f8b81dfc1ccd331fef9e2d61bdc6c8be94634 # v0.1.7
  with:
    host: ${{ secrets.VPS_HOST }}
    username: ${{ secrets.VPS_USER }}
    key: ${{ secrets.VPS_SSH_KEY }}
    source: deploy/example.nl.caddy
    target: /home/deploy/example-app
    strip_components: 1

- name: Apply site file
  uses: appleboy/ssh-action@029f5b4aeeeb58fdfe1410a5d17f967dacf36262 # v1.0.3
  with:
    host: ${{ secrets.VPS_HOST }}
    username: ${{ secrets.VPS_USER }}
    key: ${{ secrets.VPS_SSH_KEY }}
    script: sh /home/deploy/vps-infra/scripts/apply-site.sh /home/deploy/example-app/example.nl.caddy
```

`apply-site.sh` copies the file to `sites/`, reloads Caddy, and puts the
previous file back if Caddy rejects the new one, so one app cannot break
the others. The file name decides which site file it replaces.

**In this repo**, for sites without their own pipeline:

```bash
./scripts/add-site.sh example.nl example-web 8080
git add sites/example.nl.caddy && git commit -m "feat: serve example.nl" && git push
```

The app's compose file puts its container on `edge-net`. On a small VPS,
also cap its memory, CPU and logs. The numbers are ceilings: Docker charges
memory only while the process uses it.

```yaml
services:
  web:
    container_name: example-web
    expose:
      - "8080"
    mem_limit: 384m
    memswap_limit: 384m
    cpus: "0.50"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    networks:
      - edge-net

networks:
  edge-net:
    external: true
```

## Using the database

Small sites are often better off with SQLite in their own volume: no server,
no password, and the backup is one file. Use the shared database when an app
needs a real database server.

1. Generate a password of at least 24 letters and digits and store it as a
   secret in the app repo, for example `DB_PASSWORD`:
   `LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40`
2. In the app's deploy workflow, before starting the app, create the
   database (safe to run on every deploy; it also updates the password):

   ```yaml
   - name: Ensure the database
     uses: appleboy/ssh-action@029f5b4aeeeb58fdfe1410a5d17f967dacf36262 # v1.0.3
     env:
       DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
     with:
       host: ${{ secrets.VPS_HOST }}
       username: ${{ secrets.VPS_USER }}
       key: ${{ secrets.VPS_SSH_KEY }}
       envs: DB_PASSWORD
       script: printf '%s' "$DB_PASSWORD" | sh /home/deploy/vps-infra/scripts/ensure-database.sh example_db example
   ```

3. Put the app container on `db-net` and connect to host `shared-db`:

   ```yaml
   services:
     api:
       environment:
         ConnectionStrings__Default: Host=shared-db;Port=5432;Database=example_db;Username=example;Password=${DB_PASSWORD}
       networks:
         - edge-net
         - db-net

   networks:
     edge-net:
       external: true
     db-net:
       external: true
   ```

Each app role owns only its own database and cannot connect to another
app's database or to the maintenance databases.

`db-net` is an internal network: no published port and no route to the
internet. Administer the database on the VPS as the deploy user:

```bash
docker exec -it shared-db psql -U postgres
docker exec -it shared-db psql -U postgres -d example_db
```

The superuser password is in `secrets/db_superuser_password` on the VPS.
It is only needed by the backup job; `docker exec` uses the local socket.

Tuning (`docker-compose.yml`): `shared_buffers=64MB`, `max_connections=40`,
memory capped at 256m. Raise these when an app needs more.

## Backups

`shared-db-backup` writes `backups/all-YYYY-MM-DD.sql.gz` (all databases,
roles included) once a day and keeps 14 days. Copy `backups/` off the VPS
as well (restic, rclone, …) and keep `secrets/` somewhere safe.

Restore one database from a dump:

```bash
gunzip -c backups/all-2026-01-01.sql.gz | docker exec -i shared-db psql -U postgres
```

That replays every database in the file; extract the part for one database
first when only that one needs restoring.

## Certificates

Caddy stores certificates in the `edge-caddy-data` volume and renews them
about 30 days before they expire. It uses HTTP-01 on port 80 or TLS-ALPN-01
on port 443, so either port open is enough, but keep both open: port 80 also
carries the redirect to HTTPS.

## Ports 80 and 443

Confirm from outside the VPS:

```bash
curl --max-time 10 http://<vps-ip>/healthz
```

That must print `ok`. A timeout means a firewall drops port 80.

The **Inspect VPS** workflow (Actions → Inspect VPS → Run workflow) probes
ports 80 and 443, checks every site's certificate from outside, and reports
containers, listeners, the firewall, the Caddy logs, the database and the
latest backups. It is read-only.

## Edge defaults

These apply to every site through the `common` snippet:

- HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options: SAMEORIGIN` and `X-XSS-Protection: 0`. Applications set
  their own `Content-Security-Policy`.
- The `Server`, `X-Powered-By` and ASP.NET version headers are removed.
- zstd and gzip compression.
- `www.` redirects to the bare domain.
- Plain HTTP redirects to HTTPS. Unknown names get no answer on port 80 and
  a failed handshake on port 443, so they never land on another site.
- HTTP/1.1 and HTTP/2 (HTTP/3 would need UDP 443).

Caddy sets `X-Forwarded-For` to the real client address and ignores the
header when a client sends it.

There is no per-IP rate limit at the edge any more; core Caddy has none.
Applications that need one (login forms) set it themselves, as Hart voor
Elkaar does in its own nginx.

## Safety properties

- **A dead application cannot take down other sites.** Upstreams are
  resolved per request, so Caddy starts even when a container is missing;
  that site returns 502 and the rest keep serving.
- **A bad site file never replaces a working configuration.** CI runs
  `caddy validate` on every push. `caddy reload` keeps the running
  configuration when the new one is invalid, and `apply-site.sh` restores
  the previous file in that case.
- **The database is not on the internet.** No published port; `db-net` is
  internal. Each app has its own role and database.

## Rolling back to nginx

The previous nginx + certbot setup is in git history, and its certificates
are still in `/etc/letsencrypt` on the VPS (valid until mid-January 2027;
certbot renews them again once it runs). To go back:

1. On the VPS: `docker rm -f edge-caddy` (frees ports 80 and 443).
2. Revert the commit that introduced Caddy and push; the deploy starts
   nginx and certbot again.

The database is separate from the proxy and keeps running.

## Required secrets and variables

| Name | Kind | Purpose |
| --- | --- | --- |
| `VPS_HOST` | secret | VPS hostname or IP |
| `VPS_USER` | secret | SSH user |
| `VPS_SSH_KEY` | secret | SSH private key |
| `VPS_INFRA_PATH` | variable, optional | Deploy directory. Defaults to `/home/deploy/vps-infra`. |

`VPS_HOST`, `VPS_USER` and `VPS_SSH_KEY` are organization secrets on
`daanvps`, shared by every repository that deploys to the VPS.

This repository is public, so it must never contain keys, certificates,
passwords or `.env` files.
