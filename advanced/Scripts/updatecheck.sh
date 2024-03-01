#!/usr/bin/env bash
# Pi-hole: A black hole for Internet advertisements
# (c) 2017 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Checks for local or remote versions and branches
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

function get_local_branch() {
    # Return active branch
    cd "${1}" 2> /dev/null || return 1
    git rev-parse --abbrev-ref HEAD || return 1
}

function get_local_version() {
    # Return active version
    cd "${1}" 2> /dev/null || return 1
    git tag --sort=-creatordate | head -n 1 || return 1
}

function get_local_hash() {
    cd "${1}" 2> /dev/null || return 1
    git rev-parse --short=8 HEAD || return 1
}

function get_remote_version() {
    curl -s "https://api.github.com/repos/arevindh/${1}/releases/latest" 2> /dev/null | jq --raw-output .tag_name || { curl -s "https://api.github.com/repos/pi-hole/${1}/releases/latest" 2> /dev/null | jq --raw-output .tag_name || return 1; }
}


function get_remote_hash(){
    git ls-remote "https://github.com/arevindh/${1}" --tags "${2}" | awk '{print substr($0, 0,8);}' || { git ls-remote "https://github.com/pi-hole/${1}" --tags "${2}" | awk '{print substr($0, 0,8);}' || return 1; }
}

# Source the setupvars config file
# shellcheck disable=SC1091
. /etc/pihole/setupVars.conf

# Source the utils file for addOrEditKeyValPair()
# shellcheck disable=SC1091
. /opt/pihole/utils.sh

# Remove the below three legacy files if they exist
rm -f "/etc/pihole/GitHubVersions"
rm -f "/etc/pihole/localbranches"
rm -f "/etc/pihole/localversions"

# Create new versions file if it does not exist
VERSION_FILE="/etc/pihole/versions"
touch "${VERSION_FILE}"
chmod 644 "${VERSION_FILE}"

# if /pihole.docker.tag file exists, we will use it's value later in this script
DOCKER_TAG=$(cat /pihole.docker.tag 2>/dev/null)
regex='^([0-9]+\.){1,2}(\*|[0-9]+)(-.*)?$|(^nightly$)|(^dev.*$)'
if [[ ! "${DOCKER_TAG}" =~ $regex ]]; then
  # DOCKER_TAG does not match the pattern (see https://regex101.com/r/RsENuz/1), so unset it.
  unset DOCKER_TAG
fi

# used in cronjob
if [[ "$1" == "reboot" ]]; then
        sleep 30
fi


# get Core versions

CORE_VERSION="$(get_local_version /etc/.pihole)"
addOrEditKeyValPair "${VERSION_FILE}" "CORE_VERSION" "${CORE_VERSION}"

CORE_BRANCH="$(get_local_branch /etc/.pihole)"
addOrEditKeyValPair "${VERSION_FILE}" "CORE_BRANCH" "${CORE_BRANCH}"

CORE_HASH="$(get_local_hash /etc/.pihole)"
addOrEditKeyValPair "${VERSION_FILE}" "CORE_HASH" "${CORE_HASH}"

GITHUB_CORE_VERSION="$(get_remote_version pi-hole)"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_CORE_VERSION" "${GITHUB_CORE_VERSION}"

GITHUB_CORE_HASH="$(get_remote_hash pi-hole "${CORE_BRANCH}")"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_CORE_HASH" "${GITHUB_CORE_HASH}"


# get Web versions

if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then

    WEB_VERSION="$(get_local_version /var/www/html/admin)"
    addOrEditKeyValPair "${VERSION_FILE}" "WEB_VERSION" "${WEB_VERSION}"

    WEB_BRANCH="$(get_local_branch /var/www/html/admin)"
    addOrEditKeyValPair "${VERSION_FILE}" "WEB_BRANCH" "${WEB_BRANCH}"

    WEB_HASH="$(get_local_hash /var/www/html/admin)"
    addOrEditKeyValPair "${VERSION_FILE}" "WEB_HASH" "${WEB_HASH}"

    GITHUB_WEB_VERSION="$(get_remote_version web)"
    addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_WEB_VERSION" "${GITHUB_WEB_VERSION}"

    GITHUB_WEB_HASH="$(get_remote_hash web "${WEB_BRANCH}")"
    addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_WEB_HASH" "${GITHUB_WEB_HASH}"

fi

# get FTL versions

FTL_VERSION="$(pihole-FTL version)"
addOrEditKeyValPair "${VERSION_FILE}" "FTL_VERSION" "${FTL_VERSION}"

FTL_BRANCH="$(pihole-FTL branch)"
addOrEditKeyValPair "${VERSION_FILE}" "FTL_BRANCH" "${FTL_BRANCH}"

FTL_HASH="$(pihole-FTL --hash)"
addOrEditKeyValPair "${VERSION_FILE}" "FTL_HASH" "${FTL_HASH}"

GITHUB_FTL_VERSION="$(get_remote_version FTL)"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_FTL_VERSION" "${GITHUB_FTL_VERSION}"

GITHUB_FTL_HASH="$(get_remote_hash FTL "${FTL_BRANCH}")"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_FTL_HASH" "${GITHUB_FTL_HASH}"


# get Docker versions

if [[ "${DOCKER_TAG}" ]]; then
    addOrEditKeyValPair "${VERSION_FILE}" "DOCKER_VERSION" "${DOCKER_TAG}"

    GITHUB_DOCKER_VERSION="$(get_remote_version docker-pi-hole)"
    addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_DOCKER_VERSION" "${GITHUB_DOCKER_VERSION}"
fi


# get Speedtest versions

SPEEDTEST_VERSION="$(get_local_version /etc/pihole/speedtest)"
addOrEditKeyValPair "${VERSION_FILE}" "SPEEDTEST_VERSION" "${SPEEDTEST_VERSION}"

SPEEDTEST_BRANCH="$(get_local_branch /etc/pihole/speedtest)"
addOrEditKeyValPair "${VERSION_FILE}" "SPEEDTEST_BRANCH" "${SPEEDTEST_BRANCH}"

SPEEDTEST_HASH="$(get_local_hash /etc/pihole/speedtest)"
addOrEditKeyValPair "${VERSION_FILE}" "SPEEDTEST_HASH" "${SPEEDTEST_HASH}"

GITHUB_SPEEDTEST_VERSION="$(get_remote_version pihole-speedtest)"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_SPEEDTEST_VERSION" "${GITHUB_SPEEDTEST_VERSION}"

GITHUB_SPEEDTEST_HASH="$(get_remote_hash pihole-speedtest "${SPEEDTEST_BRANCH}")"
addOrEditKeyValPair "${VERSION_FILE}" "GITHUB_SPEEDTEST_HASH" "${GITHUB_SPEEDTEST_HASH}"
