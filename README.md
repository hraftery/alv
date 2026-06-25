# alv — Access Log Viewer

A self-hosted dashboard for nginx access and error logs, built on the Grafana ALG stack and packaged as a Docker container.

## Stack

| Component | Role |
|-----------|------|
| **Alloy** | Log collector — tails nginx logs, parses fields, enriches with GeoIP |
| **Loki** | Log storage (port 3100, localhost only) |
| **Grafana** | Dashboard (port 3000, exposed externally) |

## Prerequisites

- Docker with Compose plugin
- A MaxMind account to download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database.

## Usage

### Production

```sh
docker compose up -d
```

Grafana is then available at `http://localhost:3000`.

The stack expects nginx is writing logs to `/var/log/nginx/access.log` and `/var/log/nginx/error.log` on the host.

### Local / test

Download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database and move it to `alloy/GeoLite2-City.mmdb`.

Then, run the test environment with:

```sh
docker compose -f test/compose.yml up
```

This seeds historical access and error logs, starts a local nginx, and generates live traffic. Grafana runs with anonymous admin access (no login required).

To regenerate seed data:

```sh
cd test
python3 generate_access_logs.py   # produces initial_access.log
python3 generate_error_logs.py    # produces initial_error.log
```

Both scripts accept `--help` for options (line count, date range, output file).

## Deployment

Pushes to `deploy` trigger the [deploy workflow](.github/workflows/deploy.yml), which rsyncs the repo to `/opt/alv` on the server and runs `docker compose up -d`.

Required setup:

1. Add the following GitHub Actions secrets (Settings → Secrets → Actions):
  - `DEPLOY_HOST` — your server's hostname or IP
  - `DEPLOY_KNOWN_HOST` — output of `ssh-keyscan -t ed25519 your-server`, assuming you've added the server as a known host locally.
  - `DEPLOY_SSH_KEY` — the private key for the `alv` user on the server
  - `MAXMIND_ACCOUNT_ID` - your MaxMind account ID, so a GeoLite2-City database can be downloaded to the server.
  - `MAXMIND_LICENSE_KEY` - generate a key via the "Manage license keys" section of your MaxMind account page.
1. Then, on the server:
  1. The `alv` user on the server needs to be in the `docker` group (so `docker compose` works without sudo), and `/opt/alv` should be pre-created and owned by `alv`.

Note: I removed this from the `rsync` command: `            --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r \`

## First time

Concatenate all the historical logs into a single file:

```
{ ls -tr /var/log/nginx/access.log.*.gz 2>/dev/null | xargs zcat; cat /var/log/nginx/access.log.1; } > /tmp/historical.log
```

Then run:

```
HISTORICAL_LOG=/tmp/historical_access.log docker compose up alloy loki
```

Watch the Loki logs or query line count to know when it's done, then Ctrl-C to shut it down. The system is then ready for normal deployment.

## Data persistence

Named Docker volumes (`loki-data`, `grafana-data`) survive `docker compose down`. Use `docker compose down -v` to wipe them.
