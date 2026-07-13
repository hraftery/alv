# alv — Access Log Visualiser

*A self-contained tool to ingest, parse and visualise the access and error logs typically produced by web servers like nginx and Apache.*

`alv` is based on a Grafana stack and is packaged as a Docker container. It reads the access logs from the host, stores them in a named volume, and serves the Grafana front end on port 3000. The first time you log in to Grafana, the username is `admin` and the password is `admin`, and you'll be prompted to change it.

![Screenshot](screenshot.png)

## Try It

Evaluating `alv` is easy. Ensure Docker is running, and then:

```sh
git clone https://github.com/hraftery/alv.git
cd alv
./demo.sh
```

The demo generates a few weeks of synthetic web traffic, ingests it, then starts a local nginx and a traffic generator so new entries keep flowing. When it finishes, open [http://localhost:3000](http://localhost:3000) (no login required) and find the dashboard under "Dashboards" in the menu on the left hand side.

When you're finished, `./demo.sh down` removes everything, including the ingested data.

## Deploying

`alv` runs on the server that produces the logs. The [alv.sh](alv.sh) script makes deployment easy. There are two ways to deploy:

1. **Directly from a clone:** simple but limited. Your server runs the version of `alv` you clone, and `./alv.sh update` keeps it current. Use this if you don't need to track your own changes.
2. **Remotely from a fork:** for automatic deployment and your own customisations. Your fork deploys itself to your server and runs the necessary `alv.sh` commands using the built-in [deploy workflow](.github/workflows/deploy.yml). You're free to adapt the dashboard, log formats and anything else locally, and then deploy with one command.

Either way, note the [Prerequisites](#prerequisites) below and then consult either the [From a clone](#from-a-clone) or [From a fork](#from-a-fork) section.

#### Prerequisites

- A web server running and logging to `/var/log/nginx` in the usual fashion.
   - `alv` only interacts with the log files, so is web server agnostic. Changing the log path to suit a different web server is straightforward.
	- Out of the box, `alv` expects logs in the [`vhost_combined`](https://gorbe.io/posts/nginx/logging/#vhost-combined) format, and will categorise logs by their virtual host. Adjusting to your preferred log format is straightforward.
- Docker installed on the server, with the Compose plugin.
- At least 1GB of RAM available.
- (Optional) A MaxMind account to download the [GeoLite2-City](https://dev.maxmind.com/geoip/geolite2-free-geolocation-data) database for data geolocation. Without one, `alv` falls back to the bundled test database and geolocation will not be accurate.

### From a clone

On the server, as a user that can run Docker (eg. is in the `docker` group) and read the access logs (eg. is in the `adm` group on Debian/Ubuntu):

```sh
git clone https://github.com/hraftery/alv.git
cd alv
./alv.sh ingest-history   # optional: seed the database from already-rotated logs. See "Ingest History" below.
./alv.sh up
```

To enable geolocation, put your MaxMind credentials in a `.env` file next to `alv.sh`:

```sh
MAXMIND_ACCOUNT_ID=<your MaxMind account id>
MAXMIND_LICENSE_KEY=<see "Manage license keys" in your MaxMind account webpage>
```

With valid credentials set, `alv.sh` will download a fresh database each time it brings the system up.

To update `alv` to the latest release:

```sh
./alv.sh self-update
```

Note `./alv.sh self-update` **discards any local edits** to your dashboard. If you want to customise the dashboard and keep the changes, deploy from a fork instead.

### From a fork

`alv` is designed to **automatically deploy** to your server using the built-in [deploy workflow](.github/workflows/deploy.yml). It takes care of:

1. getting the necessary files on to the server,
1. (optional) ingesting historical logs, and
1. bringing up the live system (or reloading it after an update).

The deploy workflow `rsync`s the repo to `/opt/alv` on your server and runs `alv.sh` there. Complete the [Preparation steps](#preparation) below, and then trigger the workflow from the GitHub website, or with the `gh` CLI like so:

```sh
gh workflow run deploy.yml -f ingest_history=true  # see "Ingest History" below
gh workflow run deploy.yml                         # normal deployment
```

Deployment is done from the `main` branch by default. Override by adding `--ref <branch-name>` to the command.

Normal deployment can also be triggered by pushing to the `deploy` branch.

Note that the `workflow run` command only triggers the workflow. While `gh run watch` can be used to view the progress, the website is a much better interface. Open the URL that the `workflow run` command provides to see the workflow result.

#### Preparation

Each step below includes an example command to complete that step. Adjust to suit your environment as required.

1. On your local computer:
    1. Fork the project so you have your own to run GitHub Actions on, and clone it locally.
    1. Create a passwordless SSH key pair for `alv` (or pick an existing pair to use).
        - `ssh-keygen -t ed25519 -C "alv - Access Log Visualiser" -f ~/.ssh/id_alv -N ""`
            - `-t ed25519` is the modern standard for public-key cryptography
            - `-C` adds an optional comment string
            - `-f` specifies the filename for the private key (the public key file will have a `.pub` suffix)
            - `-N ""` disables the passphrase
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
    - (Optional) `MAXMIND_ACCOUNT_ID` and `MAXMIND_LICENSE_KEY`: to enable geolocation. Generate the license key via "Manage license keys" in your MaxMind account webpage.

### Ingest History

To seed the log database with logs from files that have already been rotated, first run `./alv.sh ingest-history` (for a clone deployment) or `gh workflow run deploy.yml -f ingest_history=true` (for a fork deployment). Because logs have to be sequential, this must be done on an empty database. Doing it as the first deployment is ideal.

Ingest History concatenates the rotated access and error logs it finds on the server into historical files, and then brings up the system to ingest those files instead of the live logs.

There's no great way to detect the import has finished, so this is a good opportunity to manually look around to see if everything is in order. Verify the three `alv` containers are up and running:

```sh
# Must be run on the server
docker ps
```

And poll the line count ingested by VictoriaLogs with something like this, waiting for the count to settle:

```sh
# Must be run on the server
curl -sf http://localhost:9428/metrics | grep "^vl_rows_ingested_total"
```

Grafana is also accessible at [http://your.server.url:3000](http://your.server.url:3000).

See the [Troubleshooting section](#troubleshooting) for more suggestions.

Once stable, switch to monitoring the live logs with `./alv.sh up` (for a clone deployment) or `gh workflow run deploy.yml` (for a fork deployment). Either way, `alv.sh` will detect that an Ingest History run is underway and **brings the services down first**, which is necessary for the live log files to be read entirely.

### Data persistence

Named Docker volumes (`victorialogs-data`, `grafana-data`) survive `docker compose down`. Use `docker compose down -v` to wipe them. After doing so, Ingest History can be run again.

## Testing

The test environment is what `./demo.sh` runs: generated logs, a local nginx, a traffic generator, and Grafana with anonymous admin access (no login required). For development, its phases can be driven manually. No preparation is required — the test environment uses a bundled [test GeoIP database](https://github.com/maxmind/MaxMind-DB) (Apache 2.0), so no MaxMind account is needed.

### Ingest History

The test environment replicates the Ingest History feature. To exercise it, run:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml up
```

Monitor the ingestion count to ensure the history has been processed:

```sh
curl -sf http://localhost:9428/metrics | grep "^vl_rows_ingested_total"
```

With the default seed data, 9000 lines (7500 access logs and 1500 error logs) should be ingested from the history. When all are ingested, bring the system down, preserving the named volumes:

```sh
docker compose -f test/compose.yml -f test/compose.historical.yml down
```

`down` is important because it will clear Alloy's position file, which is stored in the container's ephemeral overlay filesystem. That will allow the log files to be treated as new when the system is brought back up.

### Live Test Environment

The live test environment can then be brought up:

```sh
docker compose -f test/compose.yml up
```

This loads the live seed data files, starts a local nginx, and starts generating new traffic.

### Seed Data

Test data is automatically created when the test environment is brought up. To generate it manually:

```sh
cd test
python3 generate_access_logs.py   # produces access.log, access.log.1, access.log.2.gz, etc.
python3 generate_error_logs.py    # produces error.log, error.log.1, error.log.2.gz, etc.
```

Both scripts accept `--help` for options (line count, date range, output file).

By default, `generate_access_logs.py` produces 10,000 lines and `generate_error_logs.py` produces 2000 lines. Both sets of logs are spread evenly over four files each - the active log file and three historical log files. Thus the default result is 2500 lines in `access.log` and 7500 lines across the three historical access files, plus 500 lines in `error.log` and 1500 lines across the three historical error files.

Most generated client IPs are drawn from the networks present in the bundled test GeoIP database, so the geolocation panels are populated; the mappings are fabricated, but the locations are real.

## Troubleshooting

### Missing Logs

VictoriaLogs writes data to disk on arrival, so logs are typically queryable within seconds. If data is missing, verify Alloy received and forwarded the lines:

```sh
curl -sf http://localhost:12345/metrics | grep loki_write_sent_entries_total
```

and cross-check with VictoriaLogs:

```sh
curl -sf http://localhost:9428/metrics | grep vl_rows_ingested_total
```

### HTTPS / Secure Connection

By default, Grafana only supports HTTP. Modern browsers can make using HTTP very difficult. If your browser is attempting to redirect to HTTPS and therefore failing to connect, consider the answers [here](https://superuser.com/questions/565409/how-to-stop-an-automatic-redirect-from-http-to-https-in-chrome).

If you already have a certificate for your domain it may ultimately be fruitless trying to convince the browser not to use it for `alv`. Instead, try using your server's IP address instead of the domain name.

## Tech Details

### Tech Stack

| Component | Role | Access |
|-----------|------|--------|
| Alloy | Log collector. Tails log files and parses fields. | Port 12345 in test environment only. |
| VictoriaLogs | Log storage and querying. | Port 9428, localhost only. |
| Grafana | Dashboard. Data visualisations. | Port 3000. |
