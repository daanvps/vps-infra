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
| `conf.d/00-default.conf` | shared HTTP settings, health endpoint, ACME challenges, catch-all for unknown hosts on port 80 and 443 |
| `conf.d/<domain>.conf` | one vhost per site |
| `conf.d/include/` | shared TLS and proxy settings (not loaded directly by nginx) |
| `scripts/add-site.sh` | scaffolds a new vhost |
| `scripts/validate-config.sh` | checks the Compose file and runs `nginx -t` with stub certificates |

## Adding a site

```bash
./scripts/add-site.sh example.nl example-web 8080
git add conf.d/example.nl.conf && git commit -m "feat: serve example.nl" && git push
```

The application's own compose file must put its container on `edge-net`.
On a small VPS, also cap its memory, CPU, and logs. The numbers below are
upper ceilings: Docker charges the memory only while the process uses it.
384m / 0.50 CPU is a starting point for a modest app such as these Blazor
sites. Raise the memory ceiling if the app is OOM-killed, and check
`docker stats` after deploy. Leave room for the OS. The edge proxy may use
up to 256m and certbot up to 384m while they are working.

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

Point the A records for `example.nl` and `www.example.nl` at the VPS. On
deploy the workflow requests a certificate and enables the site. Until a
certificate exists the vhost is parked as `.pending`, so a site awaiting
DNS cannot break the others.

## Certificates

`edge-certbot` runs `certbot renew` on startup and then every 12 hours.
Renewals use the shared webroot, so nothing needs to stop. The deploy hook
touches a flag file and the proxy reloads within about a minute.

Certificates live in `/etc/letsencrypt` on the host, shared by every site.

Let's Encrypt emails expiry warnings only when the account has a contact
address. Set `CERTBOT_EMAIL` (see below) and deploy. The workflow passes
that address to new certificate requests and runs `certbot update_account`
so the existing account is updated too. Until it is set, issuance still
works, but it keeps using `--register-unsafely-without-email` and the
deploy log warns.

Renewal is HTTP-01: port 80 on the public internet must reach this proxy.
See [Port 80](#port-80).

## Port 80

Port 443 can be open while port 80 is filtered. Certificate renewal still
fails in that case, and the sites go dark when the current certificates
expire. The last check found those certificates expiring on **2026-11-18**.
Let's Encrypt starts renewing when 30 days remain, which is **2026-10-19**.

Confirm from outside the VPS, not only on the machine:

```bash
curl --max-time 10 http://<vps-ip>/healthz
```

That must print `ok`. A timeout means something in front of nginx is
dropping port 80. Connection refused means nothing is listening.

On the VPS:

```bash
ss -lnt | grep -E ':80|:443'
curl --max-time 5 http://127.0.0.1/healthz
sudo ufw status verbose
```

If ufw is active and 80 is not allowed:

```bash
sudo ufw allow 80/tcp comment 'HTTP-01 ACME and redirects'
sudo ufw allow 443/tcp comment 'HTTPS'
```

Also open TCP 80 and 443 in the provider firewall (Hetzner, DigitalOcean,
and the like). That firewall does not show up in `ufw` or `iptables`.
Docker publishing `80:80` is not enough when the provider drops the packets.

The **Inspect VPS** workflow (Actions → Inspect VPS → Run workflow) does
this from both sides: a public probe of ports 80 and 443 plus `/healthz`,
and an SSH report of listeners, ufw/nft/iptables, and certificate expiry.
The workflow is read-only. A red run means renewal is at risk; the log
says which check failed.

## Resource limits

`edge-proxy` is capped at 256m of memory, 0.75 CPU, and 128 processes.
`edge-certbot` is capped at 384m, 0.50 CPU, and 64 processes. Neither
container can swap. Both use the json-file log driver with three 10m
files, and `no-new-privileges`.

The nginx and certbot images are pinned to a version and a digest. Weekly
Dependabot updates those digests and the GitHub Actions SHAs.

## Edge defaults

These apply to every site. They are there so one quiet box stays quiet.

- `server_tokens off`.
- Unknown port 80 hosts get an empty close (`444`). Scanners are not
  written to the access log.
- Unknown HTTPS hosts are rejected with `ssl_reject_handshake`, so a
  request that does not match a `server_name` never receives another
  site's certificate.
- Gzip for text, JSON, SVG, and WASM responses.
- A per-IP limit of 30 requests/second on proxied locations, with a burst
  of 400 so a Blazor WebAssembly load does not return 429. The response
  when the limit is hit is 429. Raise `burst` in `conf.d/include/proxy.conf`
  if a real client hits it.
- TLS headers: HSTS, `X-Content-Type-Options`, `Referrer-Policy`,
  `X-Frame-Options: SAMEORIGIN`, and `X-XSS-Protection: 0`. Applications
  set `Content-Security-Policy` themselves; the proxy leaves that header
  unset. Remove `X-Frame-Options` from `conf.d/include/tls.conf` if a site
  must be embedded by another origin.

OCSP stapling uses `1.1.1.1` and `1.0.0.1`. App proxy locations keep using
Docker's DNS (`127.0.0.11`) and are not affected.

## Safety properties

These are deliberate, and each one is load bearing:

- **A dead application cannot take down other sites.** Backends are resolved
  per request through Docker's DNS, so nginx starts even when a container is
  missing; that site returns 502 and the rest keep serving.
- **A malformed vhost never reaches the VPS.** CI runs `nginx -t` against the
  whole `conf.d` tree with stubbed certificates, and `docker compose config`
  must succeed. The deploy workflow runs the same check before it copies
  anything.
- **A missing certificate never blocks a deploy.** The vhost is parked and the
  workflow warns instead of failing.
- **A failed certificate reload is retried.** The proxy drops the renewal
  flag only after `nginx -s reload` succeeds.

## Required secrets and variables

| Name | Kind | Purpose |
| --- | --- | --- |
| `VPS_HOST` | secret | VPS hostname or IP |
| `VPS_USER` | secret | SSH user |
| `VPS_SSH_KEY` | secret | SSH private key |
| `CERTBOT_EMAIL` | secret, or variable if you prefer | Inbox for Let's Encrypt expiry warnings. A secret is masked in Actions logs. |
| `VPS_INFRA_PATH` | variable, optional | Deploy directory. Defaults to `/home/deploy/vps-infra`. Not a credential. |

`VPS_HOST`, `VPS_USER`, and `VPS_SSH_KEY` are organization secrets on
`daanvps`, shared by every repository that deploys to the VPS. Set
`CERTBOT_EMAIL` on this repository (or on the organization) before the
next deploy so the existing account starts receiving expiry mail.

Workflows request `contents: read`, except Inspect, which requests nothing.

This repository is public, so it must never contain keys, certificates or
`.env` files.
