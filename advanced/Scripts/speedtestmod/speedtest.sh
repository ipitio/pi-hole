#!/bin/bash
#
# The Test Script, Speedtest Mod for Pi-hole Run Supervisor
# Please run this with the --help option for usage information
#
# shellcheck disable=SC2015
#

declare -r OUT_FILE=/tmp/speedtest.log
declare -r CREATE_TABLE="create table if not exists speedtest (
id integer primary key autoincrement,
start_time text,
stop_time text,
from_server text,
from_ip text,
server text,
server_dist real,
server_ping real,
download real,
upload real,
share_url text
);"
declare START
declare SERVER_ID
START=$(date -u --rfc-3339='seconds')
SERVER_ID=$(grep 'SPEEDTEST_SERVER' "/etc/pihole/setupVars.conf" | cut -d '=' -f2)
readonly START SERVER_ID

# shellcheck disable=SC1091
source /opt/pihole/speedtestmod/lib.sh

#######################################
# Run the speedtest
# Globals:
#   SERVER_ID
# Arguments:
#   None
# Outputs:
#   The speedtest results
#######################################
speedtest() {
    if /usr/bin/speedtest --version | grep -q "official"; then
        [[ -n "${SERVER_ID}" ]] && /usr/bin/speedtest -s "$SERVER_ID" --accept-gdpr --accept-license -f json || /usr/bin/speedtest --accept-gdpr --accept-license -f json
    else
        [[ -n "${SERVER_ID}" ]] && /usr/bin/speedtest --server "$SERVER_ID" --json --share --secure || /usr/bin/speedtest --json --share --secure
    fi
}

#######################################
# Check if the package is available
# Globals:
#   PKG_MANAGER
# Arguments:
#   $1: Package name
# Returns:
#   0 if available, 1 if not
#######################################
isAvailable() {
    if [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
        # Check if there is a candidate and it is not "(none)"
        apt-cache policy "$1" | grep -q "Candidate:" && ! apt-cache policy "$1" | grep -q "Candidate: (none)" && return 0 || return 1
    elif [[ "$PKG_MANAGER" == *"dnf"* || "$PKG_MANAGER" == *"yum"* ]]; then
        $PKG_MANAGER list available "$1" &>/dev/null && return 0 || return 1
    else
        echo "Unsupported package manager!"
        exit 1
    fi
}

#######################################
# Run the speedtest and save the results
# Globals:
#   PKG_MANAGER
#   START
# Arguments:
#   $1: Number of attempts (optional, 3 by default)
#   $2: Current attempt (optional, 0 by default)
# Returns:
#   1 if the speedtest failed, 0 if successful
#######################################
run() {
    local isp="No Internet"
    local from_ip="-"
    local server_name="-"
    local server_dist=0
    local server_ping=0
    local download=0
    local upload=0
    local share_url="#"
    local res
    local stop

    if [[ "${2:-0}" -gt 0 || ! -f /usr/bin/speedtest ]]; then
        if notInstalled speedtest && notInstalled speedtest-cli; then
            [[ ! -f /usr/bin/speedtest ]] || rm -f /usr/bin/speedtest
            ! ooklaSpeed && ! swivelSpeed && libreSpeed || :
        elif ! notInstalled speedtest && isAvailable speedtest-cli; then
            ! swivelSpeed && ! libreSpeed && ooklaSpeed || :
        else
            ! libreSpeed && ! ooklaSpeed && swivelSpeed || :
        fi
    fi

    if [[ "${1}" -gt "${2:-0}" ]]; then
        [[ -n "${2:-}" ]] || echo "Running Test..."
        speedtest | jq . >/tmp/speedtest_results || echo "Attempt ${2:-0} Failed!"
        stop=$(date -u --rfc-3339='seconds')

        if [[ -s /tmp/speedtest_results ]]; then
            res=$(</tmp/speedtest_results)

            if jq -e '.server' /tmp/speedtest_results &>/dev/null; then
                local server_id
                local servers
                server_id=$(jq -r '.server.id' <<<"$res")
                servers="$(curl 'https://www.speedtest.net/api/js/servers' --compressed -H 'Upgrade-Insecure-Requests: 1' -H 'DNT: 1' -H 'Sec-GPC: 1')"
                server_dist=$(jq --arg id "$server_id" '.[] | select(.id == $id) | .distance' <<<"$servers")

                if /usr/bin/speedtest --version | grep -q "official"; then # ookla
                    server_name=$(jq -r '.server.name' <<<"$res")
                    download=$(jq -r '.download.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
                    upload=$(jq -r '.upload.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
                    isp=$(jq -r '.isp' <<<"$res")
                    from_ip=$(jq -r '.interface.externalIp' <<<"$res")
                    server_ping=$(jq -r '.ping.latency' <<<"$res")
                    share_url=$(jq -r '.result.url' <<<"$res")
                    [[ -n "$server_dist" ]] || server_dist="-1"
                else # speedtest-cli
                    server_name=$(jq -r '.server.sponsor' <<<"$res")
                    download=$(jq -r '.download' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
                    upload=$(jq -r '.upload' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
                    isp=$(jq -r '.client.isp' <<<"$res")
                    from_ip=$(jq -r '.client.ip' <<<"$res")
                    server_ping=$(jq -r '.ping' <<<"$res")
                    share_url=$(jq -r '.share' <<<"$res")
                    [[ -n "$server_dist" ]] || server_dist=$(jq -r '.server.d' <<<"$res")
                fi
            else # if jq -e '.[].server' /tmp/speedtest_results &>/dev/null; then # librespeed
                server_name=$(jq -r '.[].server.name' <<<"$res" | sed 's/Sponsor: (.*) @/\1/')
                download=$(jq -r '.[].download' <<<"$res")
                upload=$(jq -r '.[].upload' <<<"$res")
                isp="Unknown"
                from_ip=$(curl -sSL https://ipv4.icanhazip.com)
                server_ping=$(jq -r '.[].ping' <<<"$res")
                share_url=$(jq -r '.[].share' <<<"$res")
                server_dist="-1"
            fi
        else
            run $1 $((${2:-0} + 1))
        fi
    else
        echo "Limit Reached!"
    fi

    local -r rm_empty='
  def nonempty: . and length > 0 and (type != "object" or . != {}) and (type != "array" or any(.[]; . != ""));
  if type == "array" then map(walk(if type == "object" then with_entries(select(.value | nonempty)) else . end)) else walk(if type == "object" then with_entries(select(.value | nonempty)) else . end) end
'
    local -r temp_file=$(mktemp)
    local -r json_file="/tmp/speedtest_results"
    jq "$rm_empty" "$json_file" >"$temp_file" && mv -f "$temp_file" "$json_file"
    rm -f "$temp_file"
    chmod 644 /tmp/speedtest_results
    mv -f /tmp/speedtest_results /var/log/pihole/speedtest.log
    \cp -af /var/log/pihole/speedtest.log /etc/pihole/speedtest.log
    sqlite3 /etc/pihole/speedtest.db "$CREATE_TABLE"
    sqlite3 /etc/pihole/speedtest.db "insert into speedtest values (NULL, '${START}', '${stop}', '${isp}', '${from_ip}', '${server_name}', ${server_dist}, ${server_ping}, ${download}, ${upload}, '${share_url}');"
    [[ "$isp" == "No Internet" ]] && return 1 || return 0
}

#######################################
# Display the help message
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   The help message
#######################################
help() {
    echo "Usage: $0 [attempts]"
    echo "  attempts: Number of attempts to run the speedtest, cycling through the packages (default: 3)"
    exit 1
}

#######################################
# Main function
# Globals:
#   PKG_MANAGER
# Arguments:
#   None
# Outputs:
#   The speedtest results
#######################################
main() {
    local -r short_opts=-h
    local -r long_opts=help
    local -r parsed_opts=$(getopt --options ${short_opts} --longoptions ${long_opts} --name "$0" -- "$@")
    local POSITIONAL=()
    local attempts="3"
    eval set -- "${parsed_opts}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -h | --help) help ;;
        *) POSITIONAL+=("$1") ;;
        esac
        shift
    done

    set -- "${POSITIONAL[@]}"

    if [[ "$1" != "--" ]]; then
        [[ "$1" =~ ^[0-9]+$ ]] && attempts="$1" || help
    fi

    run $attempts
    run_status=$?
}

declare -i run_status=0

if [[ $EUID != 0 ]]; then
    sudo "$0" "$@"
    exit $?
fi

rm -f "$OUT_FILE"
touch "$OUT_FILE"
main "$@" 2>&1 | tee -a "$OUT_FILE"
mv -f "$OUT_FILE" /var/log/pihole/speedtest-run.log || rm -f "$OUT_FILE"
exit $run_status
