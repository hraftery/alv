#!/usr/bin/env bash
set -euo pipefail

#######################################################################################
# One-time setup for the "From a fork" deployment workflow. Run locally, from your    #
# fork's clone. Generates the deploy SSH key pair, sets the GitHub Actions secrets    #
# on your fork, and prints the single command that completes the setup on the server. #
# Safe to re-run: existing keys are kept and secrets are simply set again.            #
#######################################################################################

KEY_PATH=~/.ssh/id_alv

# Execute all commands from the repo root.
cd "$(dirname "$0")/.."

##################################################
# Check we have an authenticated gh, and a fork  #

command -v gh >/dev/null || { echo "The GitHub CLI (gh) is required: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null || { echo "Log in first with: gh auth login" >&2; exit 1; }

# This fails if gh can't resolve which GitHub repo the clone belongs to — e.g. it has
# multiple remotes and no default set, as is common after cloning upstream directly.
if ! repo=$(gh repo view --json nameWithOwner -q .nameWithOwner); then
  echo "Couldn't determine this clone's GitHub repository (see gh's message above)." >&2
  echo "Make sure you've cloned YOUR FORK, and if gh mentions a default repository," >&2
  echo "run 'gh repo set-default' and select your fork." >&2
  exit 1
fi

# Setting secrets requires admin rights on the repo. Lacking them usually means gh is
# pointed at the upstream repository rather than your fork — commonly the case when
# the clone has an "upstream" remote and it was chosen as gh's default.
permission=$(gh repo view --json viewerPermission -q .viewerPermission)
if [[ "$permission" != "ADMIN" ]]; then
  echo "You don't have admin rights on $repo, so secrets can't be set on it." >&2
  echo "If that's the upstream repository, point gh at your fork instead with:" >&2
  echo "  gh repo set-default" >&2
  exit 1
fi

# Final sanity check. Just a soft check to see if gh thinks it's a fork. Will fail
# for legitimate cases like using upstream itself, or a renamed or manually-created
# repo. So just prompts to make sure.
is_fork=$(gh repo view --json isFork -q .isFork)
if [[ "$is_fork" != "true" ]]; then
  echo "Warning: $repo doesn't look like a fork. Secrets will be set on it directly."
  read -rp "Continue anyway? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || exit 1
fi


########################
# Gather configuration #

read -rp "Server hostname or IP: " host
[[ -n "$host" ]] || { echo "A server is required." >&2; exit 1; }
read -rp "Admin user on the server, for the one-time setup command [$USER]: " admin
admin="${admin:-$USER}"
read -rp "MaxMind account ID (blank to skip geolocation): " maxmind_id
if [[ -n "$maxmind_id" ]]; then
  read -rsp "MaxMind license key: " maxmind_key; echo ""
fi

########################################
# Create the key pair, if not present  #

if [[ -f "$KEY_PATH" ]]; then
  echo "Using the existing key pair at $KEY_PATH."
else
  echo "Generating a passwordless SSH key pair at $KEY_PATH..."
  ssh-keygen -t ed25519 -C "alv - Access Log Visualiser" -f "$KEY_PATH" -N "" >/dev/null
fi

#############################
# Scan the server host key  #

echo "Scanning the server's host key..."
known_host=$(ssh-keyscan -t ed25519 "$host" 2>/dev/null)
[[ -n "$known_host" ]] || { echo "Could not reach $host to scan its host key." >&2; exit 1; }
echo "  $known_host"


###########################
# Set the GitHub secrets  #

echo ""
echo "Setting GitHub Actions secrets on $repo..."
gh secret set DEPLOY_HOST --body "$host"
gh secret set DEPLOY_KNOWN_HOST --body "$known_host"
gh secret set DEPLOY_SSH_KEY < "$KEY_PATH"
if [[ -n "$maxmind_id" ]]; then
  gh secret set MAXMIND_ACCOUNT_ID --body "$maxmind_id"
  gh secret set MAXMIND_LICENSE_KEY --body "$maxmind_key"
else
  echo "Skipping the MaxMind secrets: geolocation panels will be empty (see README)."
fi

##########
# Finish #

pubkey=$(cat "$KEY_PATH.pub")

echo ""
echo "Done."
echo "Now run these two command from the repo root to complete the setup on the server:"
echo ""
echo "  scp scripts/setup-server.sh ${admin}@${host}:/tmp/"
echo "  ssh -t ${admin}@${host} 'sudo bash /tmp/setup-server.sh \"${pubkey}\"'"
echo ""
echo "Then deploy alv with:"
echo ""
echo "  gh workflow run deploy.yml -f ingest_history=true   # first deployment"
echo "  gh workflow run deploy.yml                          # thereafter"
