# vps-infra

Shared nginx reverse proxy for the sites on the VPS. It owns ports 80 and
443, routes each domain to the right container by `server_name`, and keeps
Let's Encrypt certificates renewed.

Individual applications no longer run their own nginx or publish ports.
They join the external `edge-net` network and are reached by container name.

## Layout

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | the `edge-proxy` and the `edge-certbot` renewal sidecar |
| `conf.d/00-default.conf` | catch-all: health endpoint, ACME challenges, drops unknown hosts |
| `conf.d/<domain>.conf` | one vhost per site |
| `conf.d/include/` | shared TLS and proxy settings (not loaded directly by nginx) |
| `scripts/add-site.sh` | scaffolds a new vhost |

## Adding a site

```bash
./scripts/add-site.sh example.nl example-web 8080
git add conf.d/example.nl.conf && git commit -m "feat: serve example.nl" && git push
```

The application's own compose file must put its container on `edge-net`:

```yaml
services:
  web:
    container_name: example-web
    expose:
      - "8080"
    networks:
      - edge-net

networks:
  edge-net:
    external: true
```

Point the A records for `example.nl` and `www.example.nl` at the VPS. On
deploy the workflow requests a certificate and enables the site. Until a
certificate exists the vhost is parked as `.pending`, so a site awaiting
DNS cannot break the others.

## Certificates

`edge-certbot` runs `certbot renew` every 12 hours. Renewals use the shared
webroot, so nothing needs to stop. On success it touches a flag file and the
proxy reloads within 6 hours to pick up the new certificate.

Certificates live in `/etc/letsencrypt` on the host, shared by every site.

## Safety properties

These are deliberate, and each one is load bearing:

- **A dead application cannot take down other sites.** Backends are resolved
  per request through Docker's DNS, so nginx starts even when a container is
  missing; that site returns 502 and the rest keep serving.
- **A malformed vhost never reaches the VPS.** CI runs `nginx -t` against the
  whole `conf.d` tree with stubbed certificates.
- **A missing certificate never blocks a deploy.** The vhost is parked and the
  workflow warns instead of failing.

## Required secrets

| Secret | Purpose |
| --- | --- |
| `VPS_HOST` | VPS hostname or IP |
| `VPS_USER` | SSH user |
| `VPS_SSH_KEY` | SSH private key |

These are organization secrets on `daanvps`, shared by every repository that
deploys to the VPS.

The deploy directory defaults to `/home/deploy/vps-infra`. Override it with a
repository or organization **variable** named `VPS_INFRA_PATH` if needed — a
path is not a credential, so it is not a secret.

This repository is public, so it must never contain keys, certificates or
`.env` files.
