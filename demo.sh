#!/usr/bin/env bash
set -euo pipefail

# One-command evaluation of alv. Starts the self-contained test environment: synthetic
# logs are generated and ingested, then a local nginx and a traffic generator keep new
# entries flowing. No accounts, manual downloads or configuration required — just Docker.
#
#   ./demo.sh        start fresh (wipes any previous demo data)
#   ./demo.sh down   stop and remove the demo, including its data

compose_test="docker compose -f test/compose.yml"
compose_hist="$compose_test -f test/compose.historical.yml"

# Make sure we're in the same directory as the script.
cd "$(dirname "$0")"

if [[ "${1:-}" == "down" ]]; then
  # Use down on compose_test, not compose_hist. The historical overlay disables
  # traffic-gen, so "down" would leave that service (and the network) running.
  $compose_test down -v
  exit 0
fi

echo ""
echo "*** Starting alv demo ***"

######################################################
# Start clean: previous data would confuse the story #

echo ""
echo "Ensuring a clean slate..."

$compose_test down -v --remove-orphans 2>/dev/null || true
rm -rf test/seed

################################################################
# Phase 1: generate seed logs and ingest the historical portion #

echo ""
echo "Pulling images and bringing up containers..."
$compose_hist up -d

echo ""
echo "Ingesting historical logs..."

# Ingestion is done when the row count settles. With default seed data that's 9000
# rows (7500 access + 1500 error), but don't rely on the exact number.
sleep 1
prev=-1
while true; do
  count=$(curl -sf http://localhost:9428/metrics 2>/dev/null \
          | awk '/^vl_rows_ingested_total/{sum+=$NF} END{print sum+0}') || count=0
  [[ "$count" -gt 0 && "$count" -eq "$prev" ]] && break
  echo "Ingested $count rows..."
  prev=$count
  sleep 1
done

echo "Finished ingesting historical logs."

###############################################################################
# Phase 2: switch to the live environment, which tails logs from real traffic #

echo ""
echo "Bringing down the historical logs ingestor..."

# 'down' is important: it clears Alloy's position file (stored in the container's
# ephemeral filesystem) so the log files are treated as new when brought back up.
# The named volumes, holding the ingested data, survive.
$compose_hist down

echo "" 
echo "Bringing up the demo..."

$compose_test up -d

# An OSC 8 escape sequence makes the URL clickable in supporting terminals. Others just
# show the plain URL text. On macos, it looks plain but cmd+double-click will open it.
url=$'\e]8;;http://localhost:3000\e\\http://localhost:3000\e]8;;\e\\'

echo ""
echo "Demo is up. Open $url and find the alv dashboard under Dashboards"
echo "in the left-hand menu. No login is required. New traffic is now being generated"
echo "for \"localhost\", so the most recent data will start to show a rate spike."
echo ""
echo "When you're finished: ./demo.sh down"
