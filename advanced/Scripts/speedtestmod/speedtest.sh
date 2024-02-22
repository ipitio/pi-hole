#!/bin/bash
start=$(date -u --rfc-3339='seconds')
out=/tmp/speedtest.log
serverid=$(grep 'SPEEDTEST_SERVER' "/etc/pihole/setupVars.conf" | cut -d '=' -f2)
create_table="create table if not exists speedtest (
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

speedtest() {
    if grep -q official <<<"$(/usr/bin/speedtest --version)"; then
        if [[ -z "${serverid}" ]]; then
            /usr/bin/speedtest --accept-gdpr --accept-license -f json
        else
            /usr/bin/speedtest -s $serverid --accept-gdpr --accept-license -f json
        fi
    else
        if [[ -z "${serverid}" ]]; then
            /usr/bin/speedtest --json --share --secure
        else
            /usr/bin/speedtest -s $serverid --json --share --secure
        fi
    fi
}

savetest() {
    local start_time=$1
    local stop_time=$2
    local isp=${3:-"No Internet"}
    local from_ip=${4:-"-"}
    local server=${5:-"-"}
    local server_dist=${6:-0}
    local server_ping=${7:-0}
    local download=${8:-0}
    local upload=${9:-0}
    local share_url=${10:-"#"}
    sqlite3 /etc/pihole/speedtest.db "$create_table"
    sqlite3 /etc/pihole/speedtest.db "insert into speedtest values (NULL, '${start_time}', '${stop_time}', '${isp}', '${from_ip}', '${server}', ${server_dist}, ${server_ping}, ${download}, ${upload}, '${share_url}');"
    mv -f /tmp/speedtest_results /var/log/pihole/speedtest.log
    cp -af /var/log/pihole/speedtest.log /etc/pihole/speedtest.log
    rm -f "$out"
    [ "$isp" == "No Internet" ] && exit 1 || exit 0
}

swaptest() {
    if [ -x "$(command -v apt-get)" ]; then
        apt-get install -y $1 $2-
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y --allowerasing $1
    else
        yum install -y --allowerasing $1
    fi
}

notInstalled() {
    if [ -x "$(command -v apt-get)" ]; then
        dpkg -s "$1" &>/dev/null || return 0
    elif [ -x "$(command -v dnf)" ] || [ -x "$(command -v yum)" ]; then
        rpm -q "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        mv -f "$out" /var/log/pihole/speedtest.log
        exit 1
    fi

    return 1
}

run() {
    speedtest | jq . >/tmp/speedtest_results || echo "Attempt ${2:-1} Failed!" >/tmp/speedtest_results
    local stop=$(date -u --rfc-3339='seconds')
    if jq -e '.server.id' /tmp/speedtest_results &>/dev/null; then
        local res=$(</tmp/speedtest_results)
        local server_id=$(jq -r '.server.id' <<<"$res")
        local servers="$(curl 'https://www.speedtest.net/api/js/servers' --compressed -H 'Upgrade-Insecure-Requests: 1' -H 'DNT: 1' -H 'Sec-GPC: 1')"
        local server_dist=$(jq --arg id "$server_id" '.[] | select(.id == $id) | .distance' <<<"$servers")

        if grep -q official <<<"$(/usr/bin/speedtest --version)"; then
            local server_name=$(jq -r '.server.name' <<<"$res")
            local download=$(jq -r '.download.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
            local upload=$(jq -r '.upload.bandwidth' <<<"$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
            local isp=$(jq -r '.isp' <<<"$res")
            local from_ip=$(jq -r '.interface.externalIp' <<<"$res")
            local server_ping=$(jq -r '.ping.latency' <<<"$res")
            local share_url=$(jq -r '.result.url' <<<"$res")
            if [ -z "$server_dist" ]; then
                server_dist="-1"
            fi
        else
            local server_name=$(jq -r '.server.sponsor' <<<"$res")
            local download=$(jq -r '.download' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
            local upload=$(jq -r '.upload' <<<"$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
            local isp=$(jq -r '.client.isp' <<<"$res")
            local from_ip=$(jq -r '.client.ip' <<<"$res")
            local server_ping=$(jq -r '.ping' <<<"$res")
            local share_url=$(jq -r '.share' <<<"$res")
            if [ -z "$server_dist" ]; then
                server_dist=$(jq -r '.server.d' <<<"$res")
            fi
        fi

        savetest "$start" "$stop" "$isp" "$from_ip" "$server_name" "$server_dist" "$server_ping" "$download" "$upload" "$share_url"
    elif [ "${1}" == "${2:-}" ] || [ "${1}" -le 1 ]; then
        echo "Test Failed!" >/tmp/speedtest_results
        savetest "$start" "$stop"
    else
        if notInstalled speedtest; then
            local PKG_MANAGER=$(command -v apt-get || command -v dnf || command -v yum)
            if [[ "$PKG_MANAGER" == *"yum"* || "$PKG_MANAGER" == *"dnf"* ]]; then
                if [ ! -f /etc/yum.repos.d/ookla_speedtest-cli.repo ]; then
                    echo "Adding speedtest source for RPM..."
                    curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
                fi
            elif [[ "$PKG_MANAGER" == *"apt-get"* ]]; then
                if [ ! -f /etc/apt/sources.list.d/ookla_speedtest-cli.list ]; then
                    echo "Adding speedtest source for DEB..."
                    if [ -e /etc/os-release ]; then
                        . /etc/os-release
                        local base="ubuntu debian"
                        local os=${ID}
                        local dist=${VERSION_CODENAME}
                        if [ ! -z "${ID_LIKE-}" ] && [[ "${base//\"/}" =~ "${ID_LIKE//\"/}" ]] && [ "${os}" != "ubuntu" ]; then
                            os=${ID_LIKE%% *}
                            [ -z "${UBUNTU_CODENAME-}" ] && UBUNTU_CODENAME=$(/usr/bin/lsb_release -cs)
                            dist=${UBUNTU_CODENAME}
                            [ -z "$dist" ] && dist=${VERSION_CODENAME}
                        fi
                        wget -O /tmp/script.deb.sh https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh >/dev/null 2>&1
                        chmod +x /tmp/script.deb.sh
                        os=$os dist=$dist /tmp/script.deb.sh
                        rm -f /tmp/script.deb.sh
                    else
                        curl -sSLN https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | sudo bash
                    fi
                fi
            fi
            swaptest speedtest speedtest-cli
        else
            swaptest speedtest-cli speedtest
        fi

        run $1 $((${2:-1} + 1))
    fi
}

main() {
    if [ $EUID != 0 ]; then
        sudo "$0" "$@"
        exit $?
    fi

    echo "Running Test..."
    run $1 # Number of attempts
}

main ${1:-3} >"$out"
