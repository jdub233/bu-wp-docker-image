#!/bin/bash

# Build WordPress content from manifest .ini file

set -e  # Exit on error

validate_env() {
  local missing=()
  
  # Check required variables
  [ -z "$GIT_USER" ] && missing+=("GIT_USER")
  [ -z "$GIT_PAT" ] && missing+=("GIT_PAT")
  [ -z "$MANIFEST_INI_FILE" ] && missing+=("MANIFEST_INI_FILE")
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required environment variables:"
    for var in "${missing[@]}"; do
      echo "  - $var"
    done
    echo ""
    echo "These should be set in your .env file or passed as build arguments."
    echo "Build cannot proceed without credentials."
    exit 1
  fi
  
  echo "✓ All required environment variables are set"
  echo "  GIT_USER: $GIT_USER"
  echo "  MANIFEST_INI_FILE: $MANIFEST_INI_FILE"
  echo "  REPOS: ${REPOS:-<ALL REPOS FROM MANIFEST>}"
  echo ""
}

# Run validation before starting build
validate_env

WORKSPACE=${1:-"/tmp"}
MANIFEST_DIRNAME="wp-manifests"
REPO_TARGET_DIR="${WORKSPACE}/repos"

# Declare an associative array to contain the information for a single site (AKA, a "section") in the .ini file.
declare -A section=()

# Url encode a string to account for invalid characters.
urlencode() { (xxd -plain | tr -d '\n' | sed 's/\(..\)/%\1/g') < /dev/stdin; }
# Get the topmost directory in a path, ie: "usr" in "/usr/local/bin"
topname() { (rev | (basename "$(</dev/stdin)") | rev) < /dev/stdin; }
# "Pop" the topmost directory in a path off, ie: returns "local/bin" for "/usr/local/bin"
poptop() { (rev | (dirname "$(</dev/stdin)") | rev) < /dev/stdin; }
trim() {
  local input="${1:-$(</dev/stdin)}"
  echo -n "$(echo -n "$input" | sed -E 's/^[ \t\n]*//' | sed -E 's/[ \t\n]*$//')"
}

# Example MANIFEST_INI_FILE: wp-manifests/devl/jaydub-bulb.ini
if [ "$(echo $MANIFEST_INI_FILE | topname)" == $MANIFEST_DIRNAME ] ; then
  inifile="${WORKSPACE}/${MANIFEST_INI_FILE}"
else
  inifile="${WORKSPACE}/${MANIFEST_DIRNAME}/${MANIFEST_INI_FILE}"
fi

# Pull the manifest repo from github.
pullManifestRepo() {
  local repo_dir="${WORKSPACE}/${MANIFEST_DIRNAME}"
  echo "Pulling github.com/bu-ist/wp-manifests.git..."
  rm -rf $repo_dir 2> /dev/null || true
  mkdir $repo_dir || { echo "ERROR: Failed to create manifest repo directory: $repo_dir"; exit 1; }
  (
    set -e
    cd $repo_dir || { echo "ERROR: Failed to cd into manifest repo directory: $repo_dir"; exit 1; }
    git init || { echo "ERROR: git init failed for wp-manifests repo"; exit 1; }
    git remote add origin https://${GIT_USER}:${GIT_PAT}@github.com/bu-ist/wp-manifests.git || { echo "ERROR: git remote add failed for wp-manifests repo"; exit 1; }
    git pull --depth 1 origin master || { echo "ERROR: git pull failed for wp-manifests repo - check GIT_USER, GIT_PAT, and network connectivity"; exit 1; }
  ) || exit 1
}

# Pull a wordpress repo from github and extract its content to the wp-content directory
pullGitRepo() {
  local repo_dir="${WORKSPACE}/$1"
  local target_dir="${REPO_TARGET_DIR}/${section['dest']}"
  local repo="$(echo ${section['source']} | cut -d'@' -f2 | cut -d'@' -f2 | sed 's|:|/|')"
  local revision="${section['rev']}"

  echo "Pulling ${repo}..."
  rm -rf $repo_dir 2> /dev/null || true
  mkdir $repo_dir || { echo "ERROR: Failed to create repo directory for $1: $repo_dir"; exit 1; }
  mkdir -p $target_dir || { echo "ERROR: Failed to create target directory for $1: $target_dir"; exit 1; }
  (
    set -e
    cd $repo_dir || { echo "ERROR: Failed to cd into repo directory: $repo_dir"; exit 1; }
    git init || { echo "ERROR: git init failed for repo $1 (${repo})"; exit 1; }
    git remote add origin https://${GIT_USER}:${GIT_PAT}@${repo} || { echo "ERROR: git remote add failed for repo $1 (${repo})"; exit 1; }
    git fetch --depth 1 origin ${revision} || { echo "ERROR: git fetch failed for repo $1 (${repo}) at rev ${revision} - check that revision exists and GIT_USER/GIT_PAT are valid"; exit 1; }
    git archive --format=tar FETCH_HEAD | (cd $target_dir && tar xf -) || { echo "ERROR: git archive or extraction failed for repo $1 (${repo})"; exit 1; }
  ) || exit 1
}

pullSvnRepo() {
  local repo_dir="${WORKSPACE}/$1"
  export target_dir="${REPO_TARGET_DIR}/${section['dest']}"
  local repo="${section['source']}?p=${section['rev']}"
  echo "Pulling ${repo}..."
  rm -rf $repo_dir 2> /dev/null || true
  mkdir $repo_dir || { echo "ERROR: Failed to create repo directory for $1: $repo_dir"; exit 1; }
  mkdir -p $target_dir || { echo "ERROR: Failed to create target directory for $1: $target_dir"; exit 1; }

  # Get the portion of the http address that has the protocol, domain, and any trailing "/" removed.
  # Example: "https://plugins.svn.wordpress.org/akismet/tags/4.1.10/" becomes "akismet/tags/4.1.10"
  local path=$(echo ${section['source']} \
    | awk 'BEGIN {RS="/"} {if($1 != "") { if(NR>1) printf "\n"; printf $1}}' \
    | tail -n +3 \
    | tr '\n' '/')

  # Get the domain portion of the http address
  # Example: "https://plugins.svn.wordpress.org/akismet/tags/4.1.10/" becomes "plugins.svn.wordpress.org"
  local domain=$(echo ${section['source']} \
    | awk 'BEGIN {RS="/"} {if($1 != "") print $1}' \
    | sed -n '2 p')

  echo "  SVN download path: ${domain}/${path}"
  
  # "Pull" just the revision (Make sure level=0, which allows for infinite recursion, as opposed to the default depth of 5)
  # Use --tries=3 to retry on transient failures
  echo "  Running wget (this may take a while for large repos)..."
  wget -r --level 0 --tries=3 $repo --accept-regex=.*/${path}/.* --reject=index.html* 2>&1 | tail -5
  
  # Validate that files were actually downloaded (wget can exit with non-zero for non-critical errors like missing index.html)
  echo "  Validating downloaded files..."
  if [ ! -d "${domain}/${path}" ]; then
    echo "ERROR: Download directory not found: ${domain}/${path}"
    ls -la ${domain}/ 2>/dev/null || echo "  (${domain}/ directory does not exist)"
    exit 1
  fi
  
  local file_count=$(find "${domain}/${path}" -type f 2>/dev/null | wc -l)
  if [ "$file_count" -eq 0 ]; then
    echo "ERROR: wget failed for repo $1 (${repo}) - no files downloaded to ${domain}/${path}"
    exit 1
  fi
  echo "  ✓ Downloaded $file_count files"

  # Copy the content of the downloaded svn repo to the target directory.
  # The querystring portion of the revision is retained by wget on the end of the file names, so also strip these off while copying.
  function copyAndFilterSvnRepo() {
    local src="$1"
    if [ -d "$src" ] ; then
      mkdir -p "$target_dir/$src" 2>/dev/null || true
    else
      [ "${src:0:2}" == './' ] && src=${src:2}
      local dest="${target_dir}/${src}"
      dest=$(echo "$dest" | cut -d'?' -f1)
      mkdir -p "$(dirname "$dest")" 2>/dev/null || true
      cp "$src" "$dest" 2>/dev/null || true
    fi
  }
  export -f copyAndFilterSvnRepo

  echo "  Copying files to target directory..."
  (
    set -e
    cd "${domain}/${path}" || { echo "ERROR: Failed to cd into SVN download directory: ${domain}/${path}"; exit 1; }
    find . -type f -exec bash -c "copyAndFilterSvnRepo \"{}\"" \;
  )
  if [ $? -ne 0 ]; then
    echo "ERROR: SVN file copy/filter failed for repo $1"
    exit 1
  fi
  echo "  ✓ Files copied successfully"
}



# Load a single section, identified by section name, from the specified .ini file.
# What gets loaded is about 6 lines from the ini file that contain all information needed to pull the specific
# content from a github repo bound for the wp-content directory for the repo identified by the section name.
loadSection() {
  local section_name="$1"
  local first_line='true'

  while read line ; do
    if [ $first_line == 'true' ] ; then
      section["name"]="$(echo $line | grep -oP '[^\[\]]+' | trim)"
      first_line='false'
    else
      if [ -n "$(echo $line | trim)" ] ; then
        local fld="$(echo $line | cut -d'=' -f1 | trim)"
        local val="$(echo $line | cut -d'=' -f2 | trim)"
        section["$fld"]="$val"
      fi
    fi    
    first_line='false'
  done <<< $(cat $inifile | grep -A 6 -iP '^\s*\[\s*'${section_name}'\s*\]\s*$')
  
  # Verify section was actually loaded
  if [ -z "${section['name']}" ]; then
    return 1
  fi
  return 0
}

# Just for testing.
printSection() {
  for fld in ${!section[@]} ; do
    echo "$fld = ${section[$fld]}"
  done
}

# Pull a single "repo" from github and extract its content to the wp-content directory.
processSingleRepo() {
  local repo="$1"
  
  case "${section['scm']}" in
    git) 
      pullGitRepo "${section['name']}"
      return $?
      ;;
    svn)
      pullSvnRepo "${section['name']}"
      return $?
      ;;
    default)
      echo "ERROR: Unknown repo type: ${section['scm']} for ${section['name']}"
      return 1
      ;;
  esac
}

# For each repos in REPOS, pull from the corresponding git repo and extract its content to the wp-content directory.
processIniFile() {

  processRepo() {
    local repo=$1

    # Skip processing for "core" and "core-additions", they are not relevant to the containerized build, only the VMware virual machines.
    # The "core" package is just the wordpress core files, which are already included in the wordpress image.
    # The "core-additions" package represents configuration files that should now be generated by the container startup scripts.
    if [[ "$repo" == "core" || "$repo" == "core-additions" ]]; then
      echo "Skipping ${repo}..."
      return
    fi

    echo ""
    echo "========================================="
    echo "Processing ${repo}..."
    echo "========================================="

    if ! loadSection $repo; then
      echo "ERROR: Failed to load section data for repo: $repo"
      return 1
    fi

    # Validate that section was loaded with required fields
    if [ -z "${section['scm']}" ] || [ -z "${section['source']}" ] || [ -z "${section['dest']}" ]; then
      echo "ERROR: Section for $repo missing required fields (scm, source, or dest)"
      echo "  scm: ${section['scm']}"
      echo "  source: ${section['source']}"
      echo "  dest: ${section['dest']}"
      return 1
    fi

    echo "  SCM Type: ${section['scm']}"
    echo "  Source: ${section['source']}"
    echo "  Destination: ${section['dest']}"
    echo "  Revision: ${section['rev']}"

    if ! processSingleRepo $repo; then
      echo "ERROR: Failed to process repo: $repo"
      return 1
    fi

    echo "✓ Successfully processed ${repo}"
  }

  if [ -n "$REPOS" ] ; then
    # REPOS is a comma-delimited single line string. Iterate over each delimited value (repo).
    for repo in $(echo "$REPOS" | awk 'BEGIN{RS = ","}{print $1}') ; do
      if ! processRepo $repo; then
        echo ""
        echo "BUILD FAILED: Error processing repository $repo"
        return 1
      fi
    done
  else
    # No REPOS specified, process all repos from the manifest file
    for repo in $(grep  -Po '(?<=\[)[^\]]+(?=\])' $inifile) ; do
      if ! processRepo $repo; then
        echo ""
        echo "BUILD FAILED: Error processing repository $repo"
        return 1
      fi
    done
  fi
}


printDuration() {
  local seconds=$((end-start))
  [ -n "$1" ] && seconds=$1
  local S=$((seconds % 60))        # Use $(()) instead of let
  local MM=$((seconds / 60))
  local M=$((MM % 60))
  local H=$((MM / 60))

  # Display format
  echo ""
  echo "========================================="
  [ "$H" -gt "0" ] && printf "%02dh" $H
  [ "$M" -gt "0" ] && printf "%02dm" $M
  printf "%02ds\n" $S
  echo "========================================="
}

build() {

  start=$(date +%s)

  pullManifestRepo

  processIniFile

  end=$(date +%s)

  echo ""
  echo "✓✓✓ BUILD COMPLETED SUCCESSFULLY ✓✓✓"

  printDuration
  
  return 0

}


build
