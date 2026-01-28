#!/bin/bash

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
  mkdir $repo_dir
  (
    cd $repo_dir
    git init
    git remote add origin https://${GIT_USER}:${GIT_PAT}@github.com/bu-ist/wp-manifests.git
    git pull --depth 1 origin master
  )
}

# Pull a wordpress repo from github and extract its content to the wp-content directory
pullGitRepo() {
  local repo_dir="${WORKSPACE}/$1"
  local target_dir="${REPO_TARGET_DIR}/${section['dest']}"
  local repo="$(echo ${section['source']} | cut -d'@' -f2 | cut -d'@' -f2 | sed 's|:|/|')"

  # Override revision for weblogin-plugin to use multi-header-compat branch
  local revision="${section['rev']}"
  if [[ "$1" == "weblogin-plugin" ]]; then
    revision="multi-header-compat"
    echo "*** Overriding weblogin-plugin revision to use multi-header-compat branch instead of ${section['rev']} ***"
  fi
  
  echo "Pulling ${repo} (revision: ${revision})..."
  rm -rf $repo_dir 2> /dev/null || true
  mkdir $repo_dir
  [ ! -d $target_dir ] && mkdir -p $target_dir
  (
    cd $repo_dir
    git init
    git remote add origin https://${GIT_USER}:${GIT_PAT}@${repo}
    git fetch --depth 1 origin ${revision}  ## when no longer overriding, change back to section['rev']
    git archive --format=tar FETCH_HEAD | (cd $target_dir && tar xf -)
  )
}

pullSvnRepo() {
  local repo_dir="${WORKSPACE}/$1"
  export target_dir="${REPO_TARGET_DIR}/${section['dest']}"
  local repo="${section['source']}?p=${section['rev']}"
  echo "Pulling ${repo}..."
  rm -rf $repo_dir 2> /dev/null || true
  mkdir $repo_dir
  [ ! -d $target_dir ] && mkdir -p $target_dir

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

  # "Pull" just the revision (Make sure level=0, which allows for infinite recursion, as opposed to the default depth of 5)
  wget -r --level 0 $repo --accept-regex=.*/${path}/.* --reject=index.html*

  # Copy the content of the downloaded svn repo to the target directory.
  # The querystring portion of the revision is retained by wget on the end of the file names, so also strip these off while copying.
  function copyAndFilterSvnRepo() {
    local src="$1"
    if [ -d $src ] ; then
      mkdir -p $target_dir/$src
    else
      [ "${src:0:2}" == './' ] && src=${src:2}
      # local exclude="?p=${section['rev']}"
      # local $target=$(echo $src | sed 's/'${exclude}'//')
      local dest=${target_dir}/$(echo $src | cut -d'?' -f1)
      cp $src $dest
    fi
  }
  export -f copyAndFilterSvnRepo

  (
    cd ${domain}/${path}
    find . -exec bash -c "copyAndFilterSvnRepo \"{}\"" \;
  )
}



# Load a single section, identified by section name, from the specified .ini file.
# What gets loaded is about 6 lines from the ini file that contain all information needed to pull the specific
# content from a github repo bound for the wp-content directory for the repo identified by the section name.
loadSection() {
  local section_name="$1"
  local first_line='true'

  echo "Loading $section_name data from ${inifile}..."

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
      pullGitRepo "${section['name']}" ;;
    svn)
      pullSvnRepo "${section['name']}" ;;
    default)
      echo "Unknown repo type: ${section['name']}" ;;
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

    echo "Processing ${repo}..."

    loadSection $repo

    processSingleRepo  $repo

  }
  if [ -n "$REPOS" ] ; then
    # REPOS is a comma-delimited single line string. Iterate over each delimited value (repo).
    for repo in $(echo "$REPOS" | awk 'BEGIN{RS = ","}{print $1}') ; do
      processRepo $repo
    done
  else
    for repo in $(grep  -Po '(?<=\[)[^\]]+(?=\])' $inifile) ; do
      processRepo $repo
    done
  fi
}


printDuration() {
  local seconds=$((end-start))
  [ -n "$1" ] && seconds=$1
  let S=${seconds}%60
  let MM=${seconds}/60 # Total number of minutes
  let M=${MM}%60
  let H=${MM}/60

  # Display "01h02m03s" format
  [ "$H" -gt "0" ] && printf "%02d%s" $H "h"
  [ "$M" -gt "0" ] && printf "%02d%s" $M "m"
  printf "Build duration: %02d%s\n" $S "s"
}

build() {

  start=$(date +%s)

  pullManifestRepo

  processIniFile

  end=$(date +%s)

  printDuration
}


build
