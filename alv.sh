#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Server-side operations for alv. The deploy workflow invokes these same commands over
# SSH, so a manual clone and an automated deployment share a single code path.

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  up              Start (or restart) the live services. Cleans up after an
                  Ingest History run first, if one is found.
  update          Pull the latest mainline (git clones only) and restart the
                  live services. Discards any local edits to the dashboard —
                  customisations belong in a fork.
  ingest-history  Concatenate rotated logs into historical files and bring the
                  system up to ingest them instead of the live logs. Must be
                  done on an empty database. Follow with '$0 up' once the
                  ingestion count settles (see README).
  down            Stop the services. Data survives in the named volumes.
  update-geodb    Download a fresh GeoLite2-City database. Requires
                  MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY, from the
                  environment or a .env file next to this script.
EOF
  exit 1
}

# Optional configuration, e.g. MaxMind credentials.
[ -f .env ] && . ./.env

#############
# Internals #

geodb=alloy/GeoLite2-City.mmdb
dashboard=grafana/provisioning/dashboards/access-log.json

have_maxmind_creds() {
  [[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]]
}

update_geodb() {
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

ensure_geodb() {
  # With credentials, download a fresh db. Without credentials, an existing db
  # (however the user obtained it) is left alone, and as a last resort the
  # bundled test db keeps the pipeline running minus meaningful geolocation.
  if have_maxmind_creds; then
    update_geodb
  elif [ ! -f "$geodb" ]; then
    echo "No MaxMind credentials and no $geodb: falling back to the bundled test" >&2
    echo "database. Geolocation panels will be empty. See the README to enable" >&2
    echo "geolocation." >&2
    cp alloy/GeoLite2-City-Test.mmdb "$geodb"
  fi
}

stamp_version() {
  # The dashboard title carries the version of the release it was committed in, baked
  # in by release.sh. If we're running something else — an unreleased commit, deployed
  # or checked out — re-stamp the title in place with the tag (if the current commit
  # has one) or the SHA. On a clone this dirties the tracked file; 'update' discards
  # the stamp before pulling so it can't conflict. The deploy workflow passes
  # ALV_VERSION in because the files it syncs exclude .git.
  version="${ALV_VERSION:-$(git describe --tags --exact-match 2>/dev/null \
                            || git rev-parse --short HEAD 2>/dev/null \
                            || true)}"
  if [ -z "$version" ]; then
    return 0
  fi
  if ! grep -qF "alv ${version} - Access Log Visualiser" "$dashboard"; then
    sed "s/alv[^\"]* Access Log Visualiser/alv ${version} - Access Log Visualiser/" \
      "$dashboard" > "$dashboard.tmp"
    mv "$dashboard.tmp" "$dashboard"
  fi
}

############
# Commands #

cmd_ingest_history() {
  # Alloy is designed to monitor a file for new logs continuously. To seed the log
  # database with the rotated log files already on disk, we need a temporary instance
  # that just processes the existing files. Since logs must be processed chronologically
  # (otherwise the chunk span is too big, or we have to increase cardinality with
  # multiple streams), we concatenate all the historical logs into a single file first.
  # The system is then run as normal, except with "compose.historical.yml" overlaid to
  # substitute the historical log file for the real access.log.
  { ls -tr /var/log/nginx/access.log.*.gz 2>/dev/null | xargs zcat 2>/dev/null || true
    cat /var/log/nginx/access.log.1 2>/dev/null || true
  } > /tmp/historical_access.log
  { ls -tr /var/log/nginx/error.log.*.gz 2>/dev/null | xargs zcat 2>/dev/null || true
    cat /var/log/nginx/error.log.1 2>/dev/null || true
  } > /tmp/historical_error.log

  ensure_geodb
  stamp_version
  docker compose -f compose.yml -f compose.historical.yml up -d
}

cmd_up() {
  # If historical log files exist, an Ingest History run is still in progress (or was
  # interrupted). Tear it down cleanly before starting the live services. If this is not
  # done and the services are simply stopped, the read position of the historical log
  # file will be retained and the live log files will not be read entirely.
  if ls /tmp/historical_*.log >/dev/null 2>&1; then
    docker compose -f compose.yml -f compose.historical.yml down
    rm /tmp/historical_*.log
  fi

  ensure_geodb
  stamp_version
  docker compose up -d
}

cmd_update() {
  # Update a clone to the latest mainline and restart. The version stamp (and any other
  # local edit to the dashboard — customisations belong in a fork) is discarded first
  # so the pull can't conflict on it.
  if [ ! -d .git ]; then
    echo "Not a git clone. Automated deployments update by re-running the deploy workflow." >&2
    exit 1
  fi
  git checkout -- "$dashboard"
  git pull --ff-only
  cmd_up
}

cmd_down() {
  # The historical overlay is included so this works regardless of which mode is up.
  docker compose -f compose.yml -f compose.historical.yml down
}

case "${1:-}" in
  up)             cmd_up ;;
  update)         cmd_update ;;
  ingest-history) cmd_ingest_history ;;
  down)           cmd_down ;;
  update-geodb)
    have_maxmind_creds || { echo "MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY are required." >&2; exit 1; }
    update_geodb
    ;;
  *) usage ;;
esac
