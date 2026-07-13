#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

####################################################
# Deployment operations for alv.
# 
# Can be run manually from a clone on the server, or automatically from a local fork
# over SSH using the deploy workflow.

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  version         Print the version of the working copy: the release tag, or the
                  commit SHA if unreleased.
  update-geodb    Download a fresh GeoLite2-City database. Requires
                  MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY, from the
                  environment or an .env file next to this script.
  ingest-history  Concatenate rotated logs into historical files and bring the
                  system up to ingest them instead of the live logs. Must be
                  done on an empty database. Follow with '$0 up' once the
                  ingestion count settles (see README).
  up              Start (or restart) the live services. Cleans up after an
                  Ingest History run first, if one is found.
  down            Stop the services. Data survives in the named volumes.
  wipe            Stop the services and DELETE ALL DATA: the ingested logs and
                  any Grafana customisations. Ingest History can be run afresh
                  afterwards.
  self-update     For the clone workflow only. Pull the latest mainline and restart
                  the live services. Discards any local edits to the dashboard.
EOF
  exit 1
}

#############
# Constants #

GEODB_PATH=alloy/GeoLite2-City.mmdb
DASHBOARD_CONFIG_PATH=grafana/provisioning/dashboards/access-log.json

# Optional configuration, e.g. MaxMind credentials.
[ -f .env ] && . ./.env


#############
# Internals #

_have_maxmind_creds()
{
  [[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]]
}

_update_geodb()
{
  # Download a fresh db. Handy way to keep up to date, and while we could check the
  # LastModified date to avoid unnecessary replacements, the hard work is already done
  # contacting the server anyway, so the download and untar is relatively minor given
  # how infrequently this will happen.
  # Here's the tar command breakdown:
  # tar -xz                    : extract and decompress gzip
  #     --strip-components=1   : remove "GeoLite2-City_20260601" enclosing directory
  #     -C alloy/              : put it here
  #     '*.mmdb'               : only the mmdb file, ignore the README etc.
  curl -sfL -u "${MAXMIND_ACCOUNT_ID}:${MAXMIND_LICENSE_KEY}" \
    'https://download.maxmind.com/geoip/databases/GeoLite2-City/download?suffix=tar.gz' \
    | tar -xz --strip-components=1 -C alloy/ --wildcards '*.mmdb'
}

_ensure_geodb()
{
  # With credentials, download a fresh db. Without credentials, any existing db
  # (however the user obtained it) is left alone, or if there is none the bundled
  # test db is used to keep the pipeline running albeit without meaningful geolocation.
  if _have_maxmind_creds; then
    # Status messages go to stderr: stdout is reserved for command output (see 'version').
    echo "Downloading a fresh GeoLite2-City database (can take a minute)..." >&2
    _update_geodb
  elif [ ! -f "$GEODB_PATH" ]; then
    echo "No MaxMind credentials and no $GEODB_PATH: falling back to the test database." >&2
    echo "Geolocation panels will be empty. See the README to enable geolocation." >&2
    cp alloy/GeoLite2-City-Test.mmdb "$GEODB_PATH"
  fi
}

_stamp_version()
{
  # The dashboard title carries the version of the release it was committed in, baked
  # in by release.sh. If we're running something else — an unreleased commit, deployed
  # or checked out — re-stamp the title in place with the tag (if the current commit
  # has one) or the SHA. On a clone this dirties the tracked file; 'self-update'
  # discards the stamp before pulling so it can't conflict.
  version=$(cmd_version)
  if [ -z "$version" ]; then
    return 0
  fi
  if ! grep -qF "alv ${version} - Access Log Visualiser" "$DASHBOARD_CONFIG_PATH"; then
    sed "s/alv[^\"]* Access Log Visualiser/alv ${version} - Access Log Visualiser/" \
      "$DASHBOARD_CONFIG_PATH" > "$DASHBOARD_CONFIG_PATH.tmp"
    mv "$DASHBOARD_CONFIG_PATH.tmp" "$DASHBOARD_CONFIG_PATH"
  fi
}

############
# Commands #

cmd_version()
{
  # Use ALV_VERSION if set. If not, a git working copy is required, and the tag
  # will be used if the current commit has one, otherwise the SHA.
  echo "${ALV_VERSION:-$(git describe --tags --exact-match 2>/dev/null \
                         || git rev-parse --short HEAD 2>/dev/null \
                         || true)}"
}

cmd_ingest_history()
{
  # Alloy is designed to monitor a file for new logs continuously. To seed the log
  # database with the rotated log files already on disk, we need a temporary instance
  # that just processes the existing files. Since logs must be processed chronologically
  # (otherwise the chunk span is too big, or we have to increase cardinality with
  # multiple streams), we concatenate all the historical logs into a single file first.
  # The system is then run as normal, except with "compose.historical.yml" overlaid to
  # substitute the historical log file for the real access.log.
  echo "" >&2
  echo "Concatenating rotated logs into historical files..." >&2

  { ls -tr /var/log/nginx/access.log.*.gz 2>/dev/null | xargs zcat 2>/dev/null || true
    cat /var/log/nginx/access.log.1 2>/dev/null || true
  } > /tmp/historical_access.log
  { ls -tr /var/log/nginx/error.log.*.gz 2>/dev/null | xargs zcat 2>/dev/null || true
    cat /var/log/nginx/error.log.1 2>/dev/null || true
  } > /tmp/historical_error.log

  _ensure_geodb
  _stamp_version

  echo "" >&2
  echo "Bringing up the system to ingest the historical logs..." >&2

  docker compose -f compose.yml -f compose.historical.yml up -d

  echo "" >&2
  echo "Ingestion has begun. Follow the count with:" >&2
  echo "  curl -sf http://localhost:9428/metrics | grep '^vl_rows_ingested_total'" >&2
  echo "Once it settles, run '$0 up' to switch to the live logs." >&2
}

cmd_up()
{
  # If historical log files exist, an Ingest History run is still in progress (or was
  # interrupted). Tear it down cleanly before starting the live services. If this is not
  # done and the services are simply stopped, the read position of the historical log
  # file will be retained and the live log files will not be read entirely.
  if ls /tmp/historical_*.log >/dev/null 2>&1; then
    echo "" >&2
    echo "Cleaning up after an Ingest History run..." >&2
    docker compose -f compose.yml -f compose.historical.yml down
    rm /tmp/historical_*.log
  fi

  _ensure_geodb
  _stamp_version

  echo "" >&2
  echo "Bringing up the live services..." >&2

  docker compose up -d

  echo "" >&2
  echo "alv is up. The dashboard is served on port 3000." >&2
}

cmd_update()
{
  # Update a clone to the latest mainline and restart. The version stamp (and any other
  # local edit to the dashboard) is discarded first so the pull can't conflict on it.
  if [ ! -d .git ]; then
    echo "Not a git clone. For automated deployments, use the deploy workflow instead." >&2
    exit 1
  fi
  git checkout -- "$DASHBOARD_CONFIG_PATH"
  git pull --ff-only
  cmd_up
}

cmd_down()
{
  # The historical overlay is included so this works regardless of which mode is up.
  docker compose -f compose.yml -f compose.historical.yml down
}

cmd_wipe()
{
  # Removing the named volumes empties the database (and Grafana's state), returning
  # the system to a blank slate where Ingest History can be run again.
  read -rp "Delete all ingested data and any Grafana customisations? [y/N] " reply
  if [[ "$reply" != "y" && "$reply" != "Y" ]]; then
    echo "Aborted."
    exit 1
  fi
  docker compose -f compose.yml -f compose.historical.yml down -v
}

case "${1:-}" in
  version)        cmd_version ;;
  update-geodb)   _have_maxmind_creds || { echo "MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY are required." >&2; exit 1; }
                  _update_geodb
                  ;;
  ingest-history) cmd_ingest_history ;;
  up)             cmd_up ;;
  down)           cmd_down ;;
  wipe)           cmd_wipe ;;
  self-update)    cmd_update ;;
  *)              usage ;;
esac
