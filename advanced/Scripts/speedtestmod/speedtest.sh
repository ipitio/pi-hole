#!/bin/bash
FILE=/tmp/speedtest.log
start=$(date -u --rfc-3339='seconds')
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
sqlite3 /etc/pihole/speedtest.db "$create_table"

speedtest() {
    if grep -q official <<< "$(/usr/bin/speedtest --version)"; then
        if [[ -z "${serverid}" ]]; then
            /usr/bin/speedtest --accept-gdpr --accept-license -f json-pretty
        else
            /usr/bin/speedtest -s $serverid --accept-gdpr --accept-license -f json-pretty
        fi
    else
        if [[ -z "${serverid}" ]]; then
            /usr/bin/speedtest --json --share --secure
        else
            /usr/bin/speedtest -s $serverid --json --share --secure
        fi
    fi
}

internet() {
    stop=$(date -u --rfc-3339='seconds')
    res="$(</tmp/speedtest_results)"
    server_name=$(jq -r '.server.name' <<< "$res")
    servers="$(curl 'https://www.speedtest.net/api/js/servers' --compressed -H 'Upgrade-Insecure-Requests: 1' -H 'DNT: 1' -H 'Sec-GPC: 1')"
    server_dist=$(jq --arg id "$server_id" '.[] | select(.id == $id) | .distance' <<< "$servers")
    if [ -z "$server_dist" ]; then
        server_dist=-1
    fi

    if grep -q official <<< "$(/usr/bin/speedtest --version)"; then
        download=$(jq -r '.download.bandwidth' <<< "$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
        upload=$(jq -r '.upload.bandwidth' <<< "$res" | awk '{$1=$1*8/1000/1000; print $1;}' | sed 's/,/./g')
        isp=$(jq -r '.isp' <<< "$res")
        server_ip=$(jq -r '.server.ip' <<< "$res")
        from_ip=$(jq -r '.interface.externalIp' <<< "$res")
        server_ping=$(jq -r '.ping.latency' <<< "$res")
        share_url=$(jq -r '.result.url' <<< "$res")
        server_id=$(jq -r '.server.id' <<< "$res")
    else
        download=$(jq -r '.download' <<< "$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
        upload=$(jq -r '.upload' <<< "$res" | awk '{$1=$1/1000/1000; print $1;}' | sed 's/,/./g')
        isp=$(jq -r '.client.isp' <<< "$res")
        server_ip=$(jq -r '.server.host' <<< "$res")
        from_ip=$(jq -r '.client.ip' <<< "$res")
        server_ping=$(jq -r '.ping' <<< "$res")
        share_url=$(jq -r '.share' <<< "$res")
        server_dist=$(jq -r '.server.d' <<< "$res")
    fi

    jq . /tmp/speedtest_results
    sqlite3 /etc/pihole/speedtest.db "insert into speedtest values (NULL, '${start}', '${stop}', '${isp}', '${from_ip}', '${server_name}', ${server_dist}, ${server_ping}, ${download}, ${upload}, '${share_url}');"
    mv -f "$FILE" /var/log/pihole/speedtest.log
    exit 0
}

nointernet(){
    stop=$(date -u --rfc-3339='seconds')
    rm -f /tmp/speedtest_results
    echo "No Internet"
    sqlite3 /etc/pihole/speedtest.db "insert into speedtest values (NULL, '${start}', '${stop}', 'No Internet', '-', '-', 0, 0, 0, 0, '#');"
    mv -f "$FILE" /var/log/pihole/speedtest.log
    exit 1
}

notInstalled() {
    if [ -x "$(command -v yum)" ] || [ -x "$(command -v dnf)" ]; then
        rpm -q "$1" &>/dev/null || return 0
    elif [ -x "$(command -v apt-get)" ]; then
        dpkg -s "$1" &>/dev/null || return 0
    else
        echo "Unsupported package manager!"
        mv -f "$FILE" /var/log/pihole/speedtest.log
        exit 1
    fi
    return 1
}

tryagain(){
    if notInstalled speedtest-cli; then
        if [ -x "$(command -v apt-get)" ]; then
            apt-get install -y speedtest-cli speedtest-
        else
            yum install -y --allowerasing speedtest-cli
        fi
    else
        if [ -x "$(command -v apt-get)" ]; then
            apt-get install -y speedtest speedtest-cli-
        else
            yum install -y --allowerasing speedtest
        fi
    fi
    speedtest > /tmp/speedtest_results && internet || nointernet
}

main() {
    if [ $EUID != 0 ]; then
        sudo "$0" "$@"
        exit $?
    fi
    echo "Test has been initiated, please wait..."
    speedtest > /tmp/speedtest_results && internet || tryagain
}

rm -f "$FILE"
main | tee -a "$FILE"
