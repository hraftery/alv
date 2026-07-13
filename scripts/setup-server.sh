#!/usr/bin/env bash
set -euo pipefail

#######################################################################################
# One-time server setup for the "From a fork" deployment workflow. Runs as root and   #
# is normally copied and run over SSH by the command that scripts/setup-fork.sh       #
# prints:                                                                             #
#                                                                                     #
#   scp scripts/setup-server.sh admin@server:/tmp/                                    #
#   ssh -t admin@server 'sudo bash /tmp/setup-server.sh "<PUBLIC_KEY>"'               #
#                                                                                     #
# (The -t allocates a terminal so sudo can prompt for the admin password.)            #
#                                                                                     #
# Creates the alv user (adm group to read nginx logs, docker group to run docker),    #
# authorises the deploy key, and creates /opt/alv. Safe to re-run.                    #
#######################################################################################

[[ $EUID -eq 0 ]] || { echo "This script must run as root." >&2; exit 1; }
[[ $# -eq 1 && -n "$1" ]] || { echo "Usage: $0 <PUBLIC_KEY>" >&2; exit 1; }
pubkey=$1

echo ""
echo "Starting server setup..."
echo ""

getent group docker >/dev/null \
  || { echo "No 'docker' group found. Install Docker first (see README prerequisites)." >&2; exit 1; }

groups="docker"
if getent group adm >/dev/null; then
  groups="adm,docker"
else
  echo "Warning: no 'adm' group found. The alv user may not be able to read"
  echo "/var/log/nginx — grant it read access according to your distribution."
fi

if id alv >/dev/null 2>&1; then
  echo "User alv already exists. Ensuring group membership..."
  usermod -aG "$groups" alv
else
  echo "Creating the alv user..."
  useradd -m -G "$groups" alv
fi

echo "Authorising the deploy key..."
install -d -m 700 -o alv -g alv /home/alv/.ssh
echo "$pubkey" > /home/alv/.ssh/authorized_keys
chmod 600 /home/alv/.ssh/authorized_keys
chown alv:alv /home/alv/.ssh/authorized_keys

echo "Creating /opt/alv..."
mkdir -p /opt/alv
chown alv:alv /opt/alv

echo ""
echo "Server setup complete. Trigger the deploy workflow to deploy."
