#!/bin/bash
#
# The Mod Script, Speedtest Mod for Pi-hole Installation Manager
# Please run this with the --help option for usage information
#
# shellcheck disable=SC2015
#

getVersion() {
    local foundVersion=""

    if [[ -d "$1" ]]; then
        cd "$1"
        foundVersion=$(git status --porcelain=2 -b | grep branch.oid | awk '{print $3;}')

        if [[ -z "${2:-}" ]]; then
            local tags
            local foundTag=$foundVersion
            tags=$(git ls-remote -t origin)
            ! grep -q "$foundVersion" <<<"$tags" || foundTag=$(grep "$foundVersion" <<<"$tags" | awk '{print $2;}' | cut -d '/' -f 3 | sort -V | tail -n1)
            [[ -z "$foundTag" ]] || foundVersion=$foundTag
        fi

        cd - &>/dev/null
    elif [ -x "$(command -v pihole)" ]; then
        local versions
        versions=$(pihole -v | grep "$1")
        foundVersion=$(cut -d ' ' -f 6 <<<"$versions")

        if [[ "$foundVersion" != *.* ]]; then
            [[ "$foundVersion" != "$(git status --porcelain=2 -b | grep branch.head | awk '{print $3;}')" ]] || foundVersion=$(cut -d ' ' -f 7 <<<"$versions")
        fi
    fi

    echo "$foundVersion"
}

download() {
    local path=$1
    local name=$2
    local url=$3
    local desiredVersion="${4:-}"
    local branch="${5:-master}"
    local snapToTag="${6:-true}"
    local dest=$path/$name
    local aborting=false

    [[ ! -d "$dest" || -d "$dest/.git" ]] || mv -f "$dest" "$dest.old"
    [[ -d "$dest" ]] || git clone --depth=1 -b "$branch" "$url" "$dest" -q
    cd "$dest"
    git config --global --add safe.directory "$dest"

    if [[ -n "$desiredVersion" && "$desiredVersion" != *.* ]]; then
        local repos=("Pi-hole" "web" "speedtest")

        for repo in "${repos[@]}"; do
            if [[ "$desiredVersion" == *"$repo"* ]]; then
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

    [[ "$url" != *"ipitio"* ]] || snapToTag=$(grep -q "true" <<<"$snapToTag" && echo "false" || echo "true")
    git fetch origin --depth=1 "$branch":refs/remotes/origin/"$branch" -q
    git reset --hard origin/"$branch" -q
    git checkout -B "$branch" -q
    local currentHash
    local tags
    currentHash=$(getVersion "$dest" hash)
    tags=$(git ls-remote -t origin)

    if [[ -z "$desiredVersion" ]]; then # if empty, get the latest version
        local latestTag=""
        [[ "$snapToTag" != "true" ]] || latestTag=$(awk -F/ '{print $3}' <<<"$tags" | grep '^v[0-9]' | grep -v '\^{}' | sort -V | tail -n1)
        [[ -n "$latestTag" ]] && desiredVersion=$latestTag || desiredVersion=$currentHash
    elif $aborting; then
        desiredVersion=$(getVersion "$desiredVersion" hash)
    fi

    if [[ "$desiredVersion" == *.* ]]; then
        grep -q "$desiredVersion$" <<<"$tags" && desiredVersion=$(grep "$desiredVersion$" <<<"$tags" | awk '{print $1;}') || desiredVersion=$currentHash
    fi

    if [[ "$currentHash" != "$desiredVersion" ]]; then
        git fetch origin --depth=1 "$desiredVersion" -q
        git reset --hard "$desiredVersion" -q
    fi

    cd ..
}

notInstalled() {
    if [[ -x "$(command -v apt-get)" ]]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [[ -x "$(command -v dnf)" ]] || [[ -x "$(command -v yum)" ]]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        exit 1
    fi

    return 1
}

setCnf() {
    grep -q "^$1=" "$3" || echo "$1=$2" >>"$3"
    [[ "${4:-false}" == "true" ]] || sed -i "s|^$1=.*|$1=$2|" "$3"
}

getCnf() {
    local keydir
    local value
    keydir=$(echo "$2" | sed 's/^mod-//;s/^org-//')
    value=$(grep "^$2=" "$1" | cut -d '=' -f 2)
    [[ -n "$value" ]] || value=$(getVersion "$keydir" "${3:-}")

    if [[ -n "${3:-}" && "$value" == *.* ]]; then
        cd "$keydir"
        local tags
        tags=$(git ls-remote -t origin)
        grep -q "$value$" <<<"$tags" && value=$(grep "$value$" <<<"$tags" | awk '{print $1;}') || value=$(git rev-parse HEAD)
        cd - &>/dev/null
    fi

    echo "$value"
}

# allow to source the above helper functions without running the whole script
if [[ "${SKIP_MOD:-}" != true ]]; then
    declare -r HTML_DIR="/var/www/html"
    declare -r CORE_DIR="/etc/.pihole"
    declare -r OPT_DIR="/opt/pihole"
    declare -r ETC_DIR="/etc/pihole"
    declare -r MOD_DIR="/etc/pihole-speedtest"
    declare -r CURR_WP="$OPT_DIR/webpage.sh"
    declare -r CURR_DB="$ETC_DIR/speedtest.db"
    declare -r LAST_DB="$CURR_DB.old"
    declare -r DB_TABLE="speedtest"
    declare -i aborted=0
    st_ver=""
    mod_core_ver=""
    mod_admin_ver=""
    cleanup=true

    set +u
    # shellcheck disable=SC2034
    SKIP_INSTALL=true
    # shellcheck disable=SC1091
    source "$CORE_DIR/automated install/basic-install.sh"
    set -u

    help() {
        local -r help_text=(
            "The Mod Script"
            "Usage: sudo bash /path/to/mod.sh [options]"
            "  or: curl -sSLN //link/to/mod.sh | sudo bash [-s -- options]"
            "(Re)install the latest release of the Speedtest Mod, and/or the following options:"
            ""
            "Options:"
            "  -u, --update,    up      also update Pi-hole, unless Systemd is not being used (ie. not in Docker)"
            "  -b, --backup             preserve stock Pi-hole files for faster offline restore"
            "  -o, --online             force online restore of stock Pi-hole files even if a backup exists"
            "  -i, --install            skip restore of stock Pi-hole*"
            "  -r, --reinstall          keep current version of the mod, if installed*"
            "  -t, --testing            install the latest commit"
            "  -n, --uninstall, un      remove the mod and its files, but keep the database"
            "  -d, --database,  db      flush/restore the database if it's not/empty (and exit if this is the only arg given)"
            "  -v, --version            display the version of the mod"
            "  -x, --verbose            show the commands being run"
            "  -c, --continuous         skip check for missing dependencies"
            "  -h, --help               display this help message"
            ""
            "  *for when not updating Pi-hole nor switching repos"
            ""
            "Examples:"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh -ubo"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh -i -r -d"
            "  sudo bash /opt/pihole/speedtestmod/mod.sh --uninstall"
            "  curl -sSLN https://github.com/arevindh/pi-hole/raw/master/advanced/Scripts/speedtestmod/mod.sh | sudo bash -s -- -u"
        )

        printf "%s\n" "${help_text[@]}"
    }

    isEmpty() {
        [ -f "$1" ] && sqlite3 "$1" "select * from $DB_TABLE limit 1;" &>/dev/null && [ -n "$(sqlite3 "$1" "select * from $DB_TABLE limit 1;")" ] && return 1 || return 0
    }

    swapScripts() {
        set +u
        installScripts >/dev/null 2>&1
        set -u
    }

    restore() {
        [ -d "$1".bak ] || return 1
        [ ! -e "$1" ] || rm -rf "$1"
        mv -f "$1".bak "$1"
        cd "$1"
        git tag -l | xargs git tag -d >/dev/null 2>&1
        git fetch --tags -f -q
    }

    purge() {
        if [ -f /etc/systemd/system/pihole-speedtest.timer ]; then
            rm -f /etc/systemd/system/pihole-speedtest.service
            rm -f /etc/systemd/system/pihole-speedtest.timer
            systemctl daemon-reload
        fi

        rm -rf $OPT_DIR/speedtestmod
        rm -rf $CORE_DIR.bak
        rm -rf $HTML_DIR/admin.bak
        rm -rf $CORE_DIR.mod
        rm -rf $HTML_DIR/admin.mod
        rm -f "$CURR_DB".*
        rm -f $ETC_DIR/last_speedtest.*
        ! isEmpty $CURR_DB || rm -f $CURR_DB
    }

    # shellcheck disable=SC2317
    abort() {
        if $cleanup; then
            echo "Process Aborting..."
            aborted=1

            if [ -d "$CORE_DIR"/.git/refs/remotes/old ]; then
                download /etc .pihole "" Pi-hole
                swapScripts

                if [ -d "$CORE_DIR"/advanced/Scripts/speedtestmod ]; then
                    \cp -af "$CORE_DIR"/advanced/Scripts/speedtestmod/. "$OPT_DIR"/speedtestmod/
                    pihole -a -s
                fi
            fi

            [ -d "$MOD_DIR" ] && [ -d "$MOD_DIR"/.git/refs/remotes/old ] && download /etc pihole-speedtest "" speedtest || :
            [ ! -d "$HTML_DIR"/admin/.git/refs/remotes/old ] || download "$HTML_DIR" admin "" web
            [ -f "$LAST_DB" ] && [ ! -f "$CURR_DB" ] && mv "$LAST_DB" "$CURR_DB" || :
            [ -f "$CURR_WP" ] && ! grep -q SpeedTest "$CURR_WP" && purge || :
            printf "Please try again before reporting an issue.\n\n%s\n" "$(date)"
        fi
    }

    # shellcheck disable=SC2317
    commit() {
        if $cleanup; then
            for dir in $CORE_DIR $HTML_DIR/admin; do
                [ ! -d "$dir" ] && continue || cd "$dir"
                ! git remote -v | grep -q "old" || git remote remove old
                git clean -ffdx
            done
            printf "Done!\n\n%s\n" "$(date)"
        fi
    }

    main() {
        set -Eeuo pipefail
        trap 'abort' INT TERM
        shopt -s dotglob

        local update=false
        local backup=false
        local online=false
        local install=false
        local reinstall=false
        local stable=true
        local uninstall=false
        local database=false
        local verbose=false
        local chk_dep=true
        local -i dashes=0
        local -r SHORT=-uboirtndvxch
        local -r LONG=update,backup,online,install,reinstall,testing,uninstall,database,version,verbose,continuous,help
        local -r PARSED=$(getopt --options ${SHORT} --longoptions ${LONG} --name "$0" -- "$@")
        declare -a POSITIONAL EXTRA_ARGS
        eval set -- "${PARSED}"
        local -ri num_args=$#

        while [[ $# -gt 0 ]]; do
            case "$1" in
            -u | --update) update=true ;;
            -b | --backup) backup=true ;;
            -o | --online) online=true ;;
            -i | --install) install=true ;;
            -r | --reinstall) reinstall=true ;;
            -t | --testing) stable=false ;;
            -n | --uninstall) uninstall=true ;;
            -d | --database) database=true ;;
            -v | --version)
                getVersion $MOD_DIR
                cleanup=false
                exit 0
                ;;
            -x | --verbose) verbose=true ;;
            -c | --continuous) chk_dep=false ;;
            -h | --help)
                help
                cleanup=false
                exit 0
                ;;
            --) dashes=1 ;;
            *) [[ $dashes -eq 0 ]] && POSITIONAL+=("$1") || EXTRA_ARGS+=("$1") ;;
            esac
            shift
        done

        set -- "${POSITIONAL[@]}"

        for arg in "$@"; do
            case $arg in
            up) update=true ;;
            un) uninstall=true ;;
            db) database=true ;;
            *)
                help
                cleanup=false
                exit 0
                ;;
            esac
        done

        readonly update backup online install reinstall stable uninstall database verbose chk_dep cleanup
        trap '[ "$?" -eq "0" ] && commit || abort' EXIT
        printf "Thanks for using Speedtest Mod!\nScript by @ipitio\n\n%s\n\n" "$(date)"
        ! $verbose || set -x

        if $database; then
            if [ -f $CURR_DB ] && ! isEmpty $CURR_DB; then
                echo "Flushing Database..."
                mv -f $CURR_DB $LAST_DB
                [ ! -f $ETC_DIR/last_speedtest ] || mv -f $ETC_DIR/last_speedtest $ETC_DIR/last_speedtest.old

                if [ -f /var/log/pihole/speedtest.log ]; then
                    mv -f /var/log/pihole/speedtest.log /var/log/pihole/speedtest.log.old
                    rm -f $ETC_DIR/speedtest.log
                fi
            elif [ -f $LAST_DB ]; then
                echo "Restoring Database..."
                mv -f $LAST_DB $CURR_DB
                [ ! -f $ETC_DIR/last_speedtest.old ] || mv -f $ETC_DIR/last_speedtest.old $ETC_DIR/last_speedtest

                if [ -f /var/log/pihole/speedtest.log.old ]; then
                    mv -f /var/log/pihole/speedtest.log.old /var/log/pihole/speedtest.log
                    \cp -af /var/log/pihole/speedtest.log $ETC_DIR/speedtest.log
                fi
            fi
        fi

        if ! $database || [ "$num_args" -gt 1 ]; then
            local -r working_dir=$(pwd)
            cd ~

            if [ -f $CURR_WP ] && grep -q SpeedTest "$CURR_WP"; then
                if $reinstall; then
                    for repo in $CORE_DIR $HTML_DIR/admin $MOD_DIR; do
                        if [ -d "$repo" ]; then
                            local hash_tag
                            hash_tag=$(getVersion "$repo") # if hashes are the same, we may be on an older tag
                            [ "$(getVersion "$repo" hash)" != "$(getCnf $MOD_DIR/cnf mod-"$repo" hash)" ] || hash_tag=$(getCnf $MOD_DIR/cnf mod-"$repo")

                            case "$repo" in
                            "$CORE_DIR") mod_core_ver=$hash_tag ;;
                            "$HTML_DIR/admin") mod_admin_ver=$hash_tag ;;
                            "$MOD_DIR") st_ver=$hash_tag ;;
                            esac
                        fi
                    done
                fi

                if ! $install; then
                    echo "Restoring Pi-hole$($online && echo " online..." || echo "...")"
                    pihole -a -s -1

                    local core_ver=""
                    local admin_ver=""

                    if [ -f $MOD_DIR/cnf ]; then
                        core_ver=$(getCnf $MOD_DIR/cnf org-$CORE_DIR)
                        admin_ver=$(getCnf $MOD_DIR/cnf org-$HTML_DIR/admin)
                    fi

                    readonly core_ver admin_ver

                    ! $online && restore $HTML_DIR/admin || download $HTML_DIR admin https://github.com/pi-hole/AdminLTE "$admin_ver"
                    ! $online && restore $CORE_DIR || download /etc .pihole https://github.com/pi-hole/pi-hole "$core_ver"
                    [ ! -d $MOD_DIR ] || rm -rf $MOD_DIR
                    swapScripts
                fi
            fi

            if ! $install && $update; then
                if [ -d /run/systemd/system ]; then
                    echo "Updating Pi-hole..."
                    PIHOLE_SKIP_OS_CHECK=true sudo -E pihole -up
                else
                    echo "Systemd not found. Skipping Pi-hole update..."
                fi
            fi

            if ! $install && $uninstall; then
                echo "Purging Mod..."
                purge
            else
                if $chk_dep; then
                    if [ ! -f /usr/local/bin/pihole ]; then
                        echo "Installing Pi-hole..."
                        curl -sSL https://install.pi-hole.net | sudo bash
                    fi

                    echo "Checking Dependencies..."
                    local -r php_version=$(php -v | head -n 1 | awk '{print $2}' | cut -d "." -f 1,2)
                    local -r pkg_manager=$(command -v apt-get || command -v dnf || command -v yum)
                    local -r pkgs=(bc sqlite3 jq tar tmux wget "php$php_version-sqlite3")
                    local missingpkgs=()

                    for pkg in "${pkgs[@]}"; do
                        ! notInstalled "$pkg" || missingpkgs+=("$pkg")
                    done

                    readonly missingpkgs
                    if [ ${#missingpkgs[@]} -gt 0 ]; then
                        [[ "$pkg_manager" != *"apt-get"* ]] || apt-get update
                        echo "Installing Missing..."
                        $pkg_manager install -y "${missingpkgs[@]}"
                    fi
                fi

                if $backup; then
                    echo "Backing up Pi-hole..."
                    download /etc .pihole.mod https://github.com/ipitio/pi-hole "$mod_core_ver" ipitio $stable
                    download $HTML_DIR admin.mod https://github.com/ipitio/AdminLTE "$mod_admin_ver" master $stable
                fi

                $reinstall && echo "Reinstalling Mod..." || echo "Installing Mod..."
                download /etc pihole-speedtest https://github.com/arevindh/pihole-speedtest "$st_ver" master $stable
                [ -f $MOD_DIR/cnf ] || touch $MOD_DIR/cnf
                setCnf mod-$MOD_DIR "$(getVersion $MOD_DIR)" $MOD_DIR/cnf $reinstall
                local stockTag

                for repo in $CORE_DIR $HTML_DIR/admin; do
                    if [ -d "$repo" ]; then
                        stockTag=$(getVersion "$repo")
                        setCnf org-"$repo" "$stockTag" $MOD_DIR/cnf

                        if $backup; then
                            if [ ! -d "$repo".bak ] || [ "$(getVersion "$repo".bak)" != "$stockTag" ]; then
                                rm -rf "$repo".bak
                                mv -f "$repo" "$repo".bak
                            fi

                            rm -rf "$repo"
                            mv -f "$repo".mod "$repo"
                        fi
                    fi
                done

                $backup || download /etc .pihole https://github.com/ipitio/pi-hole "$mod_core_ver" ipitio $stable
                swapScripts
                \cp -af $CORE_DIR/advanced/Scripts/speedtestmod/. $OPT_DIR/speedtestmod/
                pihole -a -s
                $backup || download $HTML_DIR admin https://github.com/ipitio/AdminLTE "$mod_admin_ver" master $stable
                setCnf mod-$CORE_DIR "$(getVersion $CORE_DIR)" $MOD_DIR/cnf $reinstall
                setCnf mod-$HTML_DIR/admin "$(getVersion $HTML_DIR/admin)" $MOD_DIR/cnf $reinstall
            fi

            pihole updatechecker
            [ -d "$working_dir" ] && cd "$working_dir"
        fi

        exit 0
    }

    if [ $EUID != 0 ]; then
        sudo "$0" "$@"
        exit $?
    fi

    rm -f /tmp/pimod.log
    touch /tmp/pimod.log
    main "$@" 2>&1 | tee -a /tmp/pimod.log
    $cleanup && mv -f /tmp/pimod.log /var/log/pihole/mod.log || rm -f /tmp/pimod.log
    exit $aborted
fi
