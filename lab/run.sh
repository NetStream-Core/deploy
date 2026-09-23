#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

scenario=${1:?usage: lab/run.sh <scenario> [key=value ...] (see the scenario table in README.md)}
shift

declare -A param=(
    [duration]=30
    [rate]=
    [port]=80
    [ports]=1-1024
    [timing]=4
    [qtype]=mixed
    [keep]=0
    [flood]=0
    [conns]=50
    [size]=512
)
for argument in "$@"; do
    param[${argument%%=*}]=${argument#*=}
done

case $scenario in
    syn_flood) : "${param[rate]:=1000}" ;;
    port_scan) : "${param[rate]:=100}" ;;
    dns_tunnel) : "${param[rate]:=20}" ;;
    c2_beacon) : "${param[rate]:=2}" ;;
    udp_flood) : "${param[rate]:=1000}" ;;
    icmp_flood) : "${param[rate]:=1000}" ;;
    slow_scan) : "${param[rate]:=2}"; param[ports]=${param[ports]/1-1024/1-60} ;;
    slowloris) : "${param[rate]:=50}" ;;
    iodine_tunnel) : ;;
    bulk_download) : "${param[rate]:=100}" ;;
    udp_stream) : "${param[rate]:=5}" ;;
    video_stream) : "${param[rate]:=2000}" ;;
    cdn_dns | dkim_dns | reputation_dns) : "${param[rate]:=20}" ;;
esac

attacker_ip=10.10.0.10
victim_ip=10.20.0.10
tunnel_ip=10.20.0.20
client_ip=10.10.0.20
source_host=attacker
source_ip=$attacker_ip
ssh="sshpass -p lab ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=5 lab@$victim_ip"

compose() { docker compose -f compose.yml -f lab/compose.lab.yml "$@"; }
now_ms() { compose exec -T gateway date +%s%3N; }
clickhouse() { compose exec -T clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream "$@" </dev/null; }

case $scenario in
    benign)
        label=benign
        tool=benign.py
        command="sleep ${param[duration]}"
        ;;
    syn_flood)
        label=syn_flood
        tool=hping3
        keep=""
        [ "${param[keep]}" = "1" ] && keep="--keep"
        if [ "${param[flood]}" = "1" ]; then
            pace="--flood"
        else
            pace="-i u$((1000000 / param[rate]))"
        fi
        command="timeout -s INT ${param[duration]} hping3 -S -p ${param[port]} $pace $keep $victim_ip 2>&1 | grep -o '[0-9]* packets transmitted' || true"
        ;;
    port_scan)
        label=port_scan
        tool=nmap
        command="nmap -sS -n -Pn -T${param[timing]} --max-rate ${param[rate]} --max-retries 1 -p ${param[ports]} $victim_ip >/dev/null"
        ;;
    dns_tunnel)
        label=dns_tunnel
        tool=dns_tunnel.py
        command="python3 /lab/dns_tunnel.py --server $victim_ip --rate ${param[rate]} --duration ${param[duration]} --qtype ${param[qtype]}"
        ;;
    c2_beacon)
        label=c2_beacon
        tool=beacon.py
        command="python3 /lab/beacon.py --server $victim_ip --rate ${param[rate]} --duration ${param[duration]}"
        ;;
    udp_flood)
        label=udp_flood
        tool=hping3
        if [ "${param[flood]}" = "1" ]; then
            pace="--flood"
        else
            pace="-i u$((1000000 / param[rate]))"
        fi
        command="timeout -s INT ${param[duration]} hping3 --udp -p 5000 -d ${param[size]} $pace $victim_ip 2>&1 | grep -o '[0-9]* packets transmitted' || true"
        ;;
    icmp_flood)
        label=icmp_flood
        tool=hping3
        if [ "${param[flood]}" = "1" ]; then
            pace="--flood"
        else
            pace="-i u$((1000000 / param[rate]))"
        fi
        command="timeout -s INT ${param[duration]} hping3 --icmp -d ${param[size]} $pace $victim_ip 2>&1 | grep -o '[0-9]* packets transmitted' || true"
        ;;
    slow_scan)
        label=port_scan
        tool=nmap
        command="nmap -sS -n -Pn -T2 --max-rate ${param[rate]} --max-retries 0 -p ${param[ports]} $victim_ip >/dev/null"
        ;;
    slowloris)
        label=slowloris
        tool=slowhttptest
        command="slowhttptest -c ${param[conns]} -H -i 10 -r ${param[rate]} -t GET -u http://$victim_ip/ -x 24 -p 3 -l ${param[duration]} >/dev/null 2>&1 || true"
        ;;
    iodine_tunnel)
        label=dns_tunnel
        tool=iodine
        victim_ip=$tunnel_ip
        command="iodine -f -r -P lab-secret $tunnel_ip t.tunnel.test >/tmp/iodine.log 2>&1 & pid=\$!; for _ in \$(seq 1 40); do ip addr show dns0 2>/dev/null | grep -q 10.99.0.2 && break; sleep 0.5; done; curl -s -o /dev/null --max-time ${param[duration]} http://10.99.0.1:8000/big || true; kill \$pid; wait \$pid 2>/dev/null || true"
        ;;
    bulk_download)
        label=benign
        tool=iperf3
        source_host=client
        source_ip=$client_ip
        command="iperf3 --client $victim_ip --time ${param[duration]} --bitrate ${param[rate]}M --format m 2>&1 | grep -E 'sender' | tail -1 || true"
        ;;
    udp_stream)
        label=benign
        tool=iperf3
        source_host=client
        source_ip=$client_ip
        command="iperf3 --client $victim_ip --udp --length 1200 --time ${param[duration]} --bitrate ${param[rate]}M 2>&1 | grep -E 'receiver' | tail -1 || true"
        ;;
    video_stream)
        label=benign
        tool=curl
        source_host=client
        source_ip=$client_ip
        command="curl -s -o /dev/null --limit-rate ${param[rate]}k --max-time ${param[duration]} http://$victim_ip/big.bin || true"
        ;;
    web_burst)
        label=benign
        tool=ab
        source_host=client
        source_ip=$client_ip
        command="ab -q -c ${param[conns]} -t ${param[duration]} -n 100000000 http://$victim_ip/ 2>&1 | sed -n 's/^Complete requests: *\([0-9]*\)$/completed \1 requests/p'"
        ;;
    ssh_session)
        label=benign
        tool=ssh
        source_host=client
        source_ip=$client_ip
        command="$ssh 'for i in \$(seq 1 ${param[duration]}); do echo tick; sleep 1; done' >/dev/null || true"
        ;;
    backup)
        label=benign
        tool=ssh
        source_host=client
        source_ip=$client_ip
        command="dd if=/dev/zero bs=1M status=none | timeout ${param[duration]} $ssh 'cat > /dev/null' || true"
        ;;
    cdn_dns | dkim_dns | reputation_dns)
        label=benign
        tool=dns_profile.py
        source_host=client
        source_ip=$client_ip
        command="python3 /lab/dns_profile.py --server $victim_ip --kind ${scenario%_dns} --rate ${param[rate]} --duration ${param[duration]}"
        ;;
    admin_scan)
        label=benign
        tool=nmap
        source_host=client
        source_ip=$client_ip
        command="nmap -sS -n -Pn -T3 --max-rate ${param[rate]:-200} -p ${param[ports]} $victim_ip >/dev/null"
        ;;
    *)
        echo "unknown scenario: $scenario" >&2
        exit 2
        ;;
esac

run_id=$(cat /proc/sys/kernel/random/uuid)

echo "run $run_id: $scenario $*"
start=$(now_ms)
output=$(compose exec -T "$source_host" sh -c "$command")
end=$(now_ms)
echo "$output"

sent=$(echo "$output" | sed -n 's/^sent \([0-9]*\) queries$/\1/p; s/^\([0-9]*\) packets transmitted.*/\1/p; s/^completed \([0-9]*\) requests$/\1/p' | head -1)
params_json=$(python3 -c 'import json,sys; p = dict(a.split("=", 1) for a in sys.argv[2:]); s = sys.argv[1]; s and p.update(sent=int(s)); print(json.dumps(p))' "$sent" "$@")

clickhouse --query "INSERT INTO labels (run_id, scenario, label, tool, params, attacker_ip, victim_ip, start_ts, end_ts) VALUES ('$run_id', '$scenario', '$label', '$tool', '$(echo "$params_json" | sed "s/'/\\\\'/g")', '$source_ip', '$victim_ip', fromUnixTimestamp64Milli($start), fromUnixTimestamp64Milli($end))"
echo "labelled $(( (end - start) / 1000 )) s window as $label"
