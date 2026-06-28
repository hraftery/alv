# alv — Access Log Visualiser

A self-contained tool to ingest, parse and visualise the access and error logs typically produced by web servers like nginx and Apache.

`alv` is based on the Grafana ALG stack and packaged as a Docker container. By default it serves a front end web interface on port 3000. The first time you log in the username is `admin` and the password is `admin`, and you'll be prompted to change it. The dashabord can then be found under "Dashboards" in the menu on the left hand side.

![Screenshot](screenshot.png)

## Prerequisites

- A web server running and logging to `/var/log/nginx` in the usual fashion.
   - `alv` only interacts with the log files, so is web server agnostic. Changing the log path to suit a different web server is straightforward.
	- Out of the box, `alv` expects logs in the [`vhost_combined`](https://gorbe.io/posts/nginx/logging/#vhost-combined) format, and will categorise logs by their virtual host. Adjusting to your preferred log format is straightforward.
- Docker installed on the server, with the Compose plugin.
- A MaxMind account to download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database for data geolocation.
- 1GB of RAM available.

## Usage

`alv` is designed to **automatically deploy** to your server using the built-in [deploy workflow](.github/workflows/deploy.yml). It takes care of:

1. getting the necessary files on to the server,
1. (optional) ingesting historical logs, and
1. bringing up the system (or reloading after an update).

Alternatively, `alv` can be run **manually**, directly from the source folder. The [deploy workflow](.github/workflows/deploy.yml) is still the best place to learn how to perform the three steps above. The GitHub secrets and initial `rsync` will be unnecessary.

A **test environment** is also available to evaluate the system before deployment and is good place to start. Skip to the [Testing section](#testing) for further details.

### Automatic Deployment

The deploy workflow `rsync`s the repo to `/opt/alv` on your server, downloads a fresh GeoLite2 database to geolocate the access data, and brings up the system on the server.

Complete the **Preparation** below, and then trigger the workflow from the GitHub website, or with the `gh` CLI:

```sh
gh workflow run deploy.yml -f ingest_history=true  # see "Ingest History" below
gh workflow run deploy.yml                         # normal deployment
```

Deployment is done from the `main` branch by default. Override by adding `--ref <branch-name>` to the command.

Normal deployment can also be triggered by pushing to the `deploy` branch.

### Preparation

Each step includes an example command to complete that step. Adjust to suit your environment as required.

1. On your local computer:
  1. Create a passwordless SSH key pair for `alv` (or pick an existing pair to use).
      - `ssh-keygen -t ed25519 -C "alv - Access Log Visualiser" -f ~/.ssh/id_alv -N ""`.
1. On the server:
  1. Create the `alv` user. Add it to the `adm` group so it can read logs created by nginx, and the `docker` group so it can run docker without sudo.
      - For example, `sudo useradd -m -G adm,docker alv`.
          - `-m` creates a home directory to conveniently contain the SSH files
          - `-G` adds secondary groups to the default `alv` group.
  1. Add the SSH folder for the `alv` user.
      - `sudo mkdir /home/alv/.ssh && sudo chmod 700 /home/alv/.ssh`
  1. Add the public key from the key pair created in Step 1.
      - `echo "<THE_PUB_KEY_FROM_STEP_ONE>" | sudo tee /home/alv/.ssh/authorized_keys`
  1. And set permissions and ownership.
      - `sudo chmod 600 /home/alv/.ssh/authorized_keys && sudo chown -R alv:alv /home/alv/.ssh`
  1. Finally, create `/opt/alv`, owned by `alv`.
      - `sudo mkdir -p /opt/alv && sudo chown alv:alv /opt/alv`.
1. In your GitHub account, add the following GitHub Actions secrets (with `gh secret set <SECRET_NAME>`, or on the GitHub website via Settings → Secrets → Actions):
    - `DEPLOY_HOST`: your server's hostname or IP address.
    - `DEPLOY_KNOWN_HOST`: output of `ssh-keyscan -t ed25519 your-server`, assuming you've added the server as a known host locally.
    - `DEPLOY_SSH_KEY`: the private key from key pair created in Step 1. Include the "-----BEGIN OPENSSH PRIVATE KEY-----" and "-----BEGIN END PRIVATE KEY-----" lines. For example:
        - `gh secret set DEPLOY_SSH_KEY < ~/.ssh/id_alv`.
    - `MAXMIND_ACCOUNT_ID`: your MaxMind account ID, so a GeoLite2-City database can be downloaded to the server.
    - `MAXMIND_LICENSE_KEY`: generate via "Manage license keys" in your MaxMind account webpage.


### Ingest History

To seed the log database with logs from files that have already been rotated, run the workflow with `ingest_history=true` first. Because logs have to be sequential, this must be done on an empty database. Doing it as the first deployment is ideal.

```sh
gh workflow run deploy.yml -f ingest_history=true
```

The `workflow run` command only triggers the workflow. While `gh run watch` can be used to view the output, the website is a much better interface. Open the URL that the `workflow run` command provides to see the workflow result.

Just like a normal deployment, this syncs files and downloads the GeoLite2 database. It then concatenates rotated access logs it finds on the server into a historical file, and then brings up the system to ingest it instead of the live access log.

There's no great way to detect the import has finished, so this is a good opportunity to manually look around to see if everything is in order. Verify the three `alv` containers are up and running:

```sh
# Must be run on the server
docker ps
```


You can poll Loki's ingested line count with something like this, and wait for the count to settle:

```sh
# Must be run on the server
curl -sf http://localhost:3100/metrics | grep "^loki_distributor_lines_received_total"
```

Grafana is also accessible at [http://your.server.url:3000](http://your.server.url:3000), but it may take some time for the data to appear there.

See the [Troubleshooting section](#troubleshooting) for more suggestions.

Once stable, a normal deployment that monitors the live access logs can be started.

### Normal Deployment

Run the deployment script without arguments:

```sh
gh workflow run deploy.yml
```

The deploy script takes care of checking if an Ingest History action is underway, by looking for the history files at `/tmp/historical_*.log`. If they exist, the services **are brought down first** and the history files are removed. If this is not done and the services are simply stopped, the read position of the historical log file will be retained and the live log files will not be read entirely when the system is next started.

### Data persistence

Named Docker volumes (`loki-data`, `grafana-data`) survive `docker compose down`. Use `docker compose down -v` to wipe them. After doing so, Ingest History can be run again.

## Testing

### Preparation

Download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database and move it to `alloy/GeoLite2-City.mmdb`.

### Ingest History

The test environment replicates the Ingest History feature. To exercise it, run:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml up
```

Monitor the ingestion count to ensure the history has been processed:

```sh
curl -sf http://localhost:3100/metrics | grep loki_distributor_lines_received_total
```

With the default seed data, 9000 lines (7500 access logs and 1500 error logs) should be ingested from the history. When all are ingested, bring the system down, preserving the named volumes:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml down
```

`down` is important because it will clear Alloy's position file, which is stored in the container's ephemeral overlay filesystem. That will allow the log files to be treated as new when the system is brought back up. However, it is not necessary to wait until flushing is complete because Loki writes a WAL (Write-Ahead Log) to disk as entries arrive, before they're flushed to chunks. The WAL lives at `/loki/wal`, which is inside the loki-data named volume, so survives `down`.

### Live Test Environment

The live test enviornment can then be brought up:

```sh
docker compose -f test/compose.yml up
```

This loads the live seed data files, starts a local nginx, and starts generating new traffic.

In the test environment, Grafana runs with anonymous admin access (no login required).

### Seed Data

Test data is automatically created when the test environment is brought up. To generate it manually:

```sh
cd test
python3 generate_access_logs.py   # produces access.log, access.log.1, access.log.2.gz, etc.
python3 generate_error_logs.py    # produces error.log, error.log.1, error.log.2.gz, etc.
```

Both scripts accept `--help` for options (line count, date range, output file).

By default, `generate_access_logs.py` produces 10,000 lines and `generate_error_logs.py` produces 2000 lines. Both sets of logs are spread evenly over four files each - the active log file and three historical log files. Thus the default result is 2500 lines in `access.log` and 7500 lines across the three historical access files, plus 500 lines in `error.log` and 1500 lines across the three historical error files.

## Troubleshooting

### Missing Logs

The stack takes its sweet time making new logs visible. The delay seems to be in flushing streams from memory to disk, which is partially governed by `chunk_idle_period` with a default of 30 minutes. Until Loki flushes chunks to disk, Grafana can't see them, even though they've been ingested. After about 10 seconds, logs from loki with `msg="flushing stream"` start appearing, but only a subset get flushed. To check how many lines have been ingested (not necessarily flushed!), run:

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

### HTTPS / Secure Connection

By default, Grafana only supports HTTP. Modern browsers can make using HTTP very difficult. If your browser is attempting to redirect to HTTPS and therefore failing to connect, consider the answers [here](https://superuser.com/questions/565409/how-to-stop-an-automatic-redirect-from-http-to-https-in-chrome).

If you already have a certificate for your domain it may ultimately be fruitless trying to convince the browser not to use it for `alv`. Instead, try using your server's IP address instead of the domain name.

## Tech Details

### Tech Stack

| Component | Role | Access |
|-----------|------|--------|
| Alloy | Log collector. Tails log files and parses fields. | Port 12345 in test environment only. |
| Loki | Log storage and querying. | Port 3100, localhost only. |
| Grafana | Dashboard. Data visualisations. | Port 3000. |
