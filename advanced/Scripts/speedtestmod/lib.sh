#!/bin/bash
#
# The Library Script, Speedtest Mod for Pi-hole Helper Functions
#
# shellcheck disable=SC2015
#

declare PKG_MANAGER
PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
readonly PKG_MANAGER

#######################################
# Get the version of a repository, either from a local clone or from the installed package
# Globals:
#   None
# Arguments:
#   $1: The path to, or name of, the repository
#   $2: Non-empty string to get the hash, empty string to get the tag if it exists
# Returns:
#   The version of the repository
#######################################
getVersion() {
    local found_version=""

    if [[ -d "$1" ]]; then
        pushd "$1" &>/dev/null || exit 1
        found_version=$(git status --porcelain=2 -b | grep branch.oid | awk '{print $3;}')
        [[ $found_version != *"("* ]] || found_version=$(git rev-parse HEAD 2>/dev/null)

        if [[ -z "${2:-}" ]]; then
            local tags
            local found_tag=$found_version
            tags=$(git ls-remote -t origin || git show-ref --tags)
            ! grep -q "$found_version" <<<"$tags" || found_tag=$(grep "$found_version" <<<"$tags" | awk '{print $2;}' | cut -d '/' -f 3 | sort -V | tail -n1)
            [[ -z "$found_tag" ]] || found_version=$found_tag
        fi

        popd &>/dev/null || exit 1
    elif [[ -x "$(command -v pihole)" ]]; then
        local versions
        versions=$(pihole -v | grep "$1")
        found_version=$(cut -d ' ' -f 6 <<<"$versions")

        if [[ "$found_version" != *.* ]]; then
            local found_branch
            found_branch="$(git status --porcelain=2 -b | grep branch.head | awk '{print $3;}')"
            [[ $found_branch != *"("* ]] || found_branch=$(git show-ref --heads | grep "$(git rev-parse HEAD)" | awk '{print $2;}' | cut -d '/' -f 3)
            [[ "$found_version" != "$found_branch" ]] || found_version=$(cut -d ' ' -f 7 <<<"$versions")
        fi
    fi

    echo "$found_version"
}

#######################################
# Fetch a repository, optionally a specific version
# Globals:
#   None
# Arguments:
#   $1: The path to download the repository to
#   $2: The name of the repository
#   $3: The URL of the repository
#   $4: The desired version, hash or tag, to download (optional, none by default)
#   $5: The branch to download (optional, master by default)
#   $6: Whether to snap to the tag (optional, true by default)
# Outputs:
#   The repository at the desired version
#######################################
download() {
    local path=$1
    local name=$2
    local url=$3
    local desired_version="${4:-}"
    local branch="${5:-master}"
    local snap_to_tag="${6:-true}"
    local dest=$path/$name
    local aborting=false

    [[ ! -d "$dest" || -d "$dest/.git" ]] || mv -f "$dest" "$dest.old"
    [[ -d "$dest" ]] || git clone --depth=1 -b "$branch" "$url" "$dest" -q
    pushd "$dest" &>/dev/null || exit 1
    git config --global --add safe.directory "$dest"

    if [[ -n "$desired_version" && "$desired_version" != *.* ]]; then
        local repos=("Pi-hole" "web" "speedtest")

        for repo in "${repos[@]}"; do
            if [[ "$desired_version" == *"$repo"* ]]; then
                aborting=true
                break
            fi
        done
    fi

    if ! $aborting; then
        ! git remote -v | grep -q "old" && git remote -v | grep -q "origin" && git remote rename origin old || :
        ! git remote -v | grep -q "origin" || git remote remove origin
        git remote add -t "$branch" origin "$url"
    elif git remote -v | grep -q "old"; then
        ! git remote -v | grep -q "origin" || git remote remove origin
        git remote rename old origin
        url=$(git remote get-url origin)
    fi

    [[ "$url" != *"ipitio"* ]] || snap_to_tag=$(grep -q "true" <<<"$snap_to_tag" && echo "false" || echo "true")
    git fetch origin --depth=1 "$branch":refs/remotes/origin/"$branch" -q
    git reset --hard origin/"$branch" -q
    git checkout -B "$branch" -q
    local current_hash
    local tags
    current_hash=$(getVersion "$dest" hash)
    tags=$(git ls-remote -t origin || git show-ref --tags)

    if [[ -z "$desired_version" ]]; then # if empty, get the latest version
        local latest_tag=""
        [[ "$snap_to_tag" != "true" ]] || latest_tag=$(awk -F/ '{print $3}' <<<"$tags" | grep '^v[0-9]' | grep -v '\^{}' | sort -V | tail -n1)
        [[ -n "$latest_tag" ]] && desired_version=$latest_tag || desired_version=$current_hash
    elif $aborting; then
        desired_version=$(getVersion "$desired_version" hash)
    fi

    if [[ "$desired_version" == *.* ]]; then
        grep -q "$desired_version$" <<<"$tags" && desired_version=$(grep "$desired_version$" <<<"$tags" | awk '{print $1;}') || desired_version=$current_hash
    fi

    if [[ "$current_hash" != "$desired_version" ]]; then
        git fetch origin --depth=1 "$desired_version" -q
        git reset --hard "$desired_version" -q
    fi

    popd &>/dev/null || exit 1
}

#######################################
# Check if a package is installed, only used below when --continuous is not
# Globals:
#   None
# Arguments:
#   $1: The package to check
# Returns:
#   0 if the package is not installed, 1 if it is
#######################################
notInstalled() {
    if [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [[ "$PKG_MANAGER" == *"dnf"* || "$PKG_MANAGER" == *"yum"* ]]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        exit 1
    fi

    return 1
}

#######################################
# Set a key-value pair in a configuration file, used below for --reinstall
# Globals:
#   None
# Arguments:
#   $1: The key to set
#   $2: The value to set
#   $3: The configuration file to set the key-value pair in
#   $4: Whether to replace the value if it already exists
# Outputs:
#   The configuration file with the key-value pair set
#######################################
setCnf() {
    grep -q "^$1=" "$3" || echo "$1=$2" >>"$3"
    [[ "${4:-false}" == "true" ]] || sed -i "s|^$1=.*|$1=$2|" "$3"
}

#######################################
# Get a key-value pair from a configuration file, used below for --reinstall
# Globals:
#   None
# Arguments:
#   $1: The configuration file to get the key-value pair from
#   $2: The key to get the value of
#   $3: Non-empty string to get the hash, empty string to get the tag if it exists
# Returns:
#   The value of the key-value pair
#######################################
getCnf() {
    local keydir
    local value
    keydir=$(echo "$2" | sed 's/^mod-//;s/^org-//')
    value=$(grep "^$2=" "$1" | cut -d '=' -f 2)
    [[ -n "$value" ]] || value=$(getVersion "$keydir" "${3:-}")
    echo "$value"
}

#######################################
# Download and install librespeed
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Returns:
#   0 if the installation was successful, 1 if it was not
#######################################
libreSpeed() {
    echo "Installing LibreSpeed..."
    $PKG_MANAGER remove -y speedtest-cli speedtest >/dev/null 2>&1

    if notInstalled golang; then
        if grep -q "Raspbian" /etc/os-release; then
            if [[ ! -f /etc/apt/sources.list.d/testing.list ]] && ! grep -q "testing" /etc/apt/sources.list; then
                echo "Adding testing repo to sources.list.d"
                echo "deb http://archive.raspbian.org/raspbian/ testing main" >/etc/apt/sources.list.d/testing.list
                printf "Package: *\nPin: release a=testing\nPin-Priority: 50" >/etc/apt/preferences.d/limit-testing
                $PKG_MANAGER update
            fi

            $PKG_MANAGER install -y -t testing golang
        else
            $PKG_MANAGER install -y golang
        fi
    fi

    download /etc/pihole librespeed https://github.com/librespeed/speedtest-cli
    pushd /etc/pihole/librespeed &>/dev/null || return 1
    [[ ! -d out ]] || rm -rf out
    ./build.sh
    rm -f /usr/bin/speedtest
    mv -f out/* /usr/bin/speedtest
    popd &>/dev/null || return 1
    chmod +x /usr/bin/speedtest
    [[ -x /usr/bin/speedtest ]] && return 0 || return 1
}

#######################################
# Swap between two packages, speedtest and speedtest-cli by default
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Outputs:
#   The swapped package
#######################################
swivelSpeed() {
    local candidate="${1:-speedtest-cli}"
    local target="${2:-speedtest}"
    [[ ! -f /usr/bin/speedtest ]] || rm -f /usr/bin/speedtest

    case "$PKG_MANAGER" in
    /usr/bin/apt-get) "$PKG_MANAGER" install -y "$candidate" "$target"- ;;
    /usr/bin/dnf) "$PKG_MANAGER" install -y --allowerasing "$candidate" ;;
    /usr/bin/yum) "$PKG_MANAGER" install -y --allowerasing "$candidate" ;;
    esac

    ! notInstalled "$candidate"
}

#######################################
# Add the Ookla speedtest CLI source
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Outputs:
#   The source for the speedtest CLI
#######################################
ooklaSpeed() {
    if [[ "$PKG_MANAGER" == *"yum"* || "$PKG_MANAGER" == *"dnf"* ]]; then
        if [[ ! -f /etc/yum.repos.d/ookla_speedtest-cli.repo ]]; then
            echo "Adding speedtest source for RPM..."
            curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
        fi

        yum list speedtest | grep -q "Available Packages" && $PKG_MANAGER install -y speedtest || :
    elif [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
        if [[ ! -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]]; then
            echo "Adding speedtest source for DEB..."
            if [[ -e /etc/os-release ]]; then
                # shellcheck disable=SC1091
                source /etc/os-release
                local -r base="ubuntu debian"
                local os=${ID}
                local dist=${VERSION_CODENAME}
                # shellcheck disable=SC2076
                if [[ -n "${ID_LIKE:-}" && "${base//\"/}" =~ "${ID_LIKE//\"/}" && "${os}" != "ubuntu" ]]; then
                    os=${ID_LIKE%% *}
                    [[ -z "${UBUNTU_CODENAME:-}" ]] && UBUNTU_CODENAME=$(/usr/bin/lsb_release -cs)
                    dist=${UBUNTU_CODENAME}
                    [[ -z "$dist" ]] && dist=${VERSION_CODENAME}
                fi
                wget -O /tmp/script.deb.sh https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh >/dev/null 2>&1
                chmod +x /tmp/script.deb.sh
                os=$os dist=$dist /tmp/script.deb.sh
                rm -f /tmp/script.deb.sh
            else
                curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
            fi

            sed -i 's/g]/g allow-insecure=yes trusted=yes]/' /etc/apt/sources.list.d/ookla_speedtest-cli.list
            apt-get update
        fi
    else
        echo "Unsupported package manager!"
        exit 1
    fi

    swivelSpeed speedtest speedtest-cli
}
