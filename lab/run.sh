#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

scenario=${1:?usage: lab/run.sh <benign|syn_flood|port_scan|dns_tunnel|c2_beacon> [key=value ...]}
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
)
for argument in "$@"; do
    param[${argument%%=*}]=${argument#*=}
done

case $scenario in
    syn_flood) : "${param[rate]:=1000}" ;;
    port_scan) : "${param[rate]:=100}" ;;
    dns_tunnel) : "${param[rate]:=20}" ;;
    c2_beacon) : "${param[rate]:=2}" ;;
esac

attacker_ip=10.10.0.10
victim_ip=10.20.0.10

compose() { docker compose -f compose.yml -f lab/compose.lab.yml "$@"; }
now_ms() { compose exec -T gateway date +%s%3N; }
clickhouse() { compose exec -T clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream "$@"; }

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
    *)
        echo "unknown scenario: $scenario" >&2
        exit 2
        ;;
esac

run_id=$(cat /proc/sys/kernel/random/uuid)

echo "run $run_id: $scenario $*"
start=$(now_ms)
output=$(compose exec -T attacker sh -c "$command")
end=$(now_ms)
echo "$output"

sent=$(echo "$output" | sed -n 's/^sent \([0-9]*\) queries$/\1/p; s/^\([0-9]*\) packets transmitted.*/\1/p' | head -1)
params_json=$(python3 -c 'import json,sys; p = dict(a.split("=", 1) for a in sys.argv[2:]); s = sys.argv[1]; s and p.update(sent=int(s)); print(json.dumps(p))' "$sent" "$@")

clickhouse --query "INSERT INTO labels (run_id, scenario, label, tool, params, attacker_ip, victim_ip, start_ts, end_ts) VALUES ('$run_id', '$scenario', '$label', '$tool', '$(echo "$params_json" | sed "s/'/\\\\'/g")', '$attacker_ip', '$victim_ip', fromUnixTimestamp64Milli($start), fromUnixTimestamp64Milli($end))"
echo "labelled $(( (end - start) / 1000 )) s window as $label"
