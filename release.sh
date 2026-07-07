#!/usr/bin/env bash
set -e

#######################################################################################
# Releases in this repository are defined by a tag with the version number as its     #
# name and the release notes as its description. This script automates the task of    #
# bumping the version number, updating RELEASE_NOTES.md, committing the result and    #
# creating the tag. Use it instead of editing RELEASE_NOTES.md or creating tags.      #
#######################################################################################


##################################
# Ask user for version bump type #

read -rp "Version bump (p/patch/m/minor/M/major) [patch]: " bump
if [[ "$bump" == "" || "$bump" == "p" ]]; then
  bump="patch"
elif [[ "$bump" == "m" ]]; then
  bump="minor"
elif [[ "$bump" == "M" ]]; then
  bump="major"
fi

if [[ "$bump" != "patch" && "$bump" != "minor" && "$bump" != "major" ]]; then
  echo "Invalid bump type: $bump" >&2
  exit 1
fi

################
# Bump version #

latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
version_number="${latest_tag#v}"
IFS='.' read -r major minor patch <<< "$version_number"

case "$bump" in
  patch) patch=$((patch + 1)) ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  major) major=$((major + 1)); minor=0; patch=0 ;;
esac

version="v${major}.${minor}.${patch}"

#####################
# Get release notes #

echo "Release note dot points for $version (blank line to finish):"
release_notes=""
while IFS= read -rp "- " point; do
  [[ -z "$point" ]] && break
  release_notes+="- ${point}"$'\n'
done
release_notes="${release_notes%$'\n'}"

if [[ -z "$release_notes" ]]; then
  echo "No release notes entered, aborting." >&2
  exit 1
fi

########################################
# Update release notes, commit and tag #

{
  echo "## $version"
  echo
  echo "$release_notes"
  echo
  [[ -f RELEASE_NOTES.md ]] && cat RELEASE_NOTES.md
} > RELEASE_NOTES.md.tmp
mv RELEASE_NOTES.md.tmp RELEASE_NOTES.md

git add RELEASE_NOTES.md
git commit -m "Release $version"
git tag -f -a "$version" -m "$release_notes"

##########
# Finish #

echo ""
echo "Version bumped to $version and tag created."
echo "Run 'git push --follow-tags' to push the release."
