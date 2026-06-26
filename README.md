# alv — Access Log Viewer

A self-hosted dashboard for nginx access and error logs, built on the Grafana ALG stack and packaged as a Docker container.

## Stack

| Component | Role |
|-----------|------|
| **Alloy** | Log collector — tails nginx logs, parses fields, enriches with GeoIP |
| **Loki** | Log storage (port 3100, localhost only) |
| **Grafana** | Dashboard (port 3000, exposed externally) |

## Prerequisites

- nginx running and logging to `/var/log/nginx` in the usual fashion
- Docker with Compose plugin
- A MaxMind account to download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database.

## Testing

### Preparation

Download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database and move it to `alloy/GeoLite2-City.mmdb`.

Then generate the seed data:

```sh
cd test
python3 generate_access_logs.py   # produces access.log, access.log.1, access.log.2.gz, etc.
python3 generate_error_logs.py    # produces error.log, error.log.1, error.log.2.gz, etc.
```

Both scripts accept `--help` for options (line count, date range, output file).

By default, `generate_access_logs.py` produces 10,000 lines and `generate_error_logs.py` produces 2000 lines. Both sets of logs are spread evenly over four files each - the current log file and three historical log files. Thus the default result is `access.log` with 2500 lines and 7500 in historical files, and `error.log` with 500 lines and 1500 in historical files.

### First Time Setup

Testing the first time setup feature requires the same steps as in production. First execute:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml up
```

And monitor the ingestion count to ensure the history has been processed:

```sh
curl -sf http://localhost:3100/metrics | grep loki_distributor_lines_received_total
```

With the default seed data, 9000 lines (7500 access logs and 1500 error logs) should be ingested from the history. When all are ingested, bring the system down, preserving the named volumes:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml down
```

`down` is important because it will clear the position file, which is stored in the container's ephemeral overlay filesystem. That will allow the log   files to be treated as new when the system is brought back up. On the other hand, it is not necessary to wait until flushing is complete, because Loki writes a WAL (Write-Ahead Log) to disk as entries arrive, before they're flushed to chunks. The WAL lives at `/loki/wal`, which is inside the loki-data named volume, so survives `down`.

### Live Test Environment

The live test enviornment can then be brought up:

```sh
docker compose -f test/compose.yml up
```

This loads the live seed data files, starts a local nginx, and starts generating new traffic. In the test environment, Grafana runs with anonymous admin access (no login required).

### Troubleshooting

The stack takes its sweet time ingesting the logs. The delay seems to be in flushing streams from memory to disk, which is partially governed by `chunk_idle_period` with a default of 30 minutes. Until Loki flushes chunks to disk, Grafana can't see them, even though they've been ingested. After about 10 seconds logs from loki with `msg="flushing stream"` start appearing, but only a subset get flushed! To check how many lines have been ingested (not necessarily flushed!), run:

```sh
# What Alloy sent
curl -sf http://localhost:12345/metrics | grep loki_write_sent_entries_total
# What Loki discarded
curl -sf http://localhost:3100/metrics | grep loki_discarded_samples_total
# What Loki received
curl -sf http://localhost:3100/metrics | grep loki_distributor_lines_received_total
# What is still in memory
curl -sf http://localhost:3100/metrics | grep loki_ingester_memory_chunks
```

Then, to save hours wondering why not all your logs are captured, execute this command to force a flush to disk:

```sh
curl -X POST http://localhost:3100/flush
```


### Production

```sh
docker compose up -d
```

Grafana is then available at `http://localhost:3000`.

The stack expects nginx is writing logs to `/var/log/nginx/access.log` and `/var/log/nginx/error.log` on the host.

## Deployment

The [deploy workflow](.github/workflows/deploy.yml) rsyncs the repo to `/opt/alv` on the server, downloads a fresh GeoLite2 database, and runs `docker compose up -d`. Trigger it with the `gh` CLI:

```sh
gh workflow run deploy.yml -f first_time_setup=true  # see below
gh workflow run deploy.yml                           # normal deployment
```

It can also be triggered by pushing to the `deploy` branch.

### Preparation

1. Add the following GitHub Actions secrets (Settings → Secrets → Actions):
  - `DEPLOY_HOST` - your server's hostname or IP
  - `DEPLOY_KNOWN_HOST` - output of `ssh-keyscan -t ed25519 your-server`, assuming you've added the server as a known host locally
  - `DEPLOY_SSH_KEY` - the private key for the `alv` user on the server
  - `MAXMIND_ACCOUNT_ID` - your MaxMind account ID, so a GeoLite2-City database can be downloaded to the server
  - `MAXMIND_LICENSE_KEY` - generate via "Manage license keys" in your MaxMind account webpage
1. On the server:
  1. Create the `alv` user. Add it to the `adm` group so it can read logs created by nginx, and the `docker` group so it can run docker without sudo.
  1. Create `/opt/alv` owned by `alv`.

### First time setup

To seed an empty database with historical logs, run the workflow with `first_time_setup=true`:

```sh
gh workflow run deploy.yml -f first_time_setup=true
```

This syncs files, downloads the GeoLite2 database, concatenates rotated nginx logs into a single historical file, and starts Loki and Alloy to ingest it. The "Start live services" step is skipped, giving you time to monitor the import.
There's no great way to detect the import has finished, so this is a good opportunity to manually look around to see if everything is in order. You can poll Loki's ingested line count with something like:

```sh
curl -sf http://localhost:3100/metrics | grep "^loki_distributor_lines_received_total"
```

and wait for it to settle. Grafana is also accessible, but it may take some time for the data to appear there.

Once stable, a normal deployment that monitors the live access.log can be started:

```sh
gh workflow run deploy.yml
```

Once the first time setup services have stopped, the temporary file they read from can be deleted: `rm /tmp/historical_access.log`.

## Data persistence

Named Docker volumes (`loki-data`, `grafana-data`) survive `docker compose down`. Use `docker compose down -v` to wipe them. After doing so, "first time setup" can be run.
