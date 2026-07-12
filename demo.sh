#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# One-command evaluation of alv. Starts the self-contained test environment: synthetic
# logs are generated and ingested, then a local nginx and a traffic generator keep new
# entries flowing. No accounts, downloads or configuration required — just Docker.
#
#   ./demo.sh        start fresh (wipes any previous demo data)
#   ./demo.sh down   stop and remove the demo, including its data

compose_test="docker compose -f test/compose.yml"
compose_hist="$compose_test -f test/compose.historical.yml"

if [[ "${1:-}" == "down" ]]; then
  $compose_hist down -v
  exit 0
fi

######################################################
# Start clean: previous data would confuse the story #

$compose_hist down -v --remove-orphans 2>/dev/null || true
rm -rf test/seed

################################################################
# Phase 1: generate seed logs and ingest the historical portion #

echo "Ingesting historical logs (takes a minute or two)..."
$compose_hist up -d

# Ingestion is done when the row count settles. With default seed data that's 9000
# rows (7500 access + 1500 error), but don't rely on the exact number.
sleep 1
prev=-1
while true; do
  count=$(curl -sf http://localhost:9428/metrics 2>/dev/null \
          | awk '/^vl_rows_ingested_total/{sum+=$NF} END{print sum+0}') || count=0
  [[ "$count" -gt 0 && "$count" -eq "$prev" ]] && break
  prev=$count
  sleep 0.5
done
echo "Ingested $count rows."

###############################################################################
# Phase 2: switch to the live environment, which tails logs from real traffic #

# 'down' is important: it clears Alloy's position file (stored in the container's
# ephemeral filesystem) so the log files are treated as new when brought back up.
# The named volumes, holding the ingested data, survive.
$compose_hist down
$compose_test up -d

echo ""
echo "Demo is up. Open http://localhost:3000 and find the dashboard under"
echo "Dashboards in the left-hand menu. No login is required. New traffic is"
echo "being generated continuously."
echo ""
echo "When you're finished: ./demo.sh down"
