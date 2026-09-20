#!/usr/bin/env bash
set -u

cd "$(dirname "$0")/../.."

[ -f lab/gateway/artifacts/network-monitor-agent ] && [ -f lab/gateway/artifacts/prog.bpf.o ] || {
    echo "agent artifacts are missing: run 'just lab-agent <path to the agent checkout>' first"
    exit 1
}

free_port() {
    python3 - <<'PYEOF'
import random, socket
while True:
    port = random.randint(20000, 29999)
    probe = socket.socket()
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        continue
    finally:
        probe.close()
    print(port)
    break
PYEOF
}

export COMPOSE_PROJECT_NAME=netstream-lab-e2e
export EDGE_GRPC_PORT=$(free_port) EDGE_HTTP_PORT=$(free_port) KAFKA_HOST_PORT=$(free_port) CLICKHOUSE_HTTP_PORT=$(free_port) CLICKHOUSE_NATIVE_PORT=$(free_port)
FAILED=0

compose() { docker compose -f compose.yml -f lab/compose.lab.yml "$@"; }
ch() { compose exec -T clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream --format TSV --query "$1"; }
gateway_ms() { compose exec -T gateway date +%s%3N | tr -d '\r'; }

cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        echo "KEEP=1: leaving the lab running as project $COMPOSE_PROJECT_NAME"
    else
        compose down -v >/dev/null 2>&1
    fi
}
trap cleanup EXIT

check() {
    local label=$1 actual=$2 expected=$3
    if [ "$actual" = "$expected" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        FAILED=1
    fi
}

echo "== starting the stack and the lab"
compose up -d --build kafka kafka-init clickhouse migrate otel-edge otel-gateway gateway victim attacker client >/dev/null 2>&1 \
    || { echo "docker compose up failed"; compose logs --tail 30; exit 1; }

for _ in $(seq 1 90); do
    tables=$(ch "SELECT count() FROM system.tables WHERE database = 'netstream' AND name IN ('flows','dns_queries','labels','labeled_flows','labeled_dns')" 2>/dev/null)
    ready=$(compose logs gateway 2>/dev/null | grep -c "Agent is ready")
    [ "$tables" = "5" ] && [ "$ready" -ge 1 ] && break
    sleep 1
done
check "stack is ready and the agent runs on the gateway" "$tables/$ready" "5/1"

echo "== warming up the background traffic of an ordinary client"
sleep 20

gateway_iface=$(compose exec -T gateway ip -o -4 addr show | awk 'index($4, "10.10.0.2/") == 1 {print $2}' | tr -d '\r')
gateway_rx() { compose exec -T gateway cat "/sys/class/net/$gateway_iface/statistics/rx_packets" | tr -d '\r'; }

echo "== running the scenarios"
./lab/run.sh syn_flood duration=12 rate=1000 | tail -1
./lab/run.sh port_scan ports=1-500 rate=100 | tail -1
./lab/run.sh port_scan ports=1-3000 rate=1000 | tail -1
./lab/run.sh dns_tunnel duration=12 rate=20 | tail -1
./lab/run.sh c2_beacon duration=10 rate=2 | tail -1

echo "== unbounded SYN flood, compared with the interface counter of the gateway"
rx_before=$(gateway_rx)
window_start=$(gateway_ms)
./lab/run.sh syn_flood flood=1 duration=8 | tail -1
rx_after=$(gateway_rx)
window_end=$(gateway_ms)
sleep 15

echo "== checking the labelled data"
check "six labelled runs" "$(ch "SELECT count() FROM labels")" 6

FIRST_FLOOD="(SELECT run_id FROM labels WHERE scenario = 'syn_flood' ORDER BY start_ts LIMIT 1)"
LAST_FLOOD="(SELECT run_id FROM labels WHERE scenario = 'syn_flood' ORDER BY start_ts DESC LIMIT 1)"

check "SYN flood: the SYN count matches what hping3 reports sending, within 5 percent" \
    "$(ch "WITH (SELECT toInt64(JSONExtractInt(params, 'sent')) FROM labels WHERE run_id = $FIRST_FLOOD) AS sent SELECT abs(sum(tcp_syn) - sent) / sent < 0.05 FROM labeled_flows WHERE run_id = $FIRST_FLOOD AND direction = 'receive' AND src_ip = toIPv4('10.10.0.10')")" 1

check "SYN flood: each flow record stands for at least five packets on average" \
    "$(ch "SELECT sum(packets) >= 3000 AND count() * 5 <= sum(packets) FROM labeled_flows WHERE run_id = $FIRST_FLOOD AND direction = 'receive' AND src_ip = toIPv4('10.10.0.10')")" 1

check "SYN flood: the victim answers with SYN-ACK" \
    "$(ch "SELECT sum(tcp_synack) >= 3000 FROM labeled_flows WHERE label = 'syn_flood' AND direction = 'transmit'")" 1

check "port scan: at least 450 distinct destination ports from one source" \
    "$(ch "SELECT uniqExact(dst_port) >= 450 FROM labeled_flows WHERE run_id = (SELECT run_id FROM labels WHERE scenario = 'port_scan' ORDER BY start_ts LIMIT 1) AND direction = 'receive' AND transport = 'tcp' AND src_ip = toIPv4('10.10.0.10')")" 1

check "fast port scan: destination ports stay distinct under the budget" \
    "$(ch "SELECT uniqExact(dst_port) >= 2700 FROM labeled_flows WHERE run_id = (SELECT run_id FROM labels WHERE scenario = 'port_scan' ORDER BY start_ts DESC LIMIT 1) AND direction = 'receive' AND transport = 'tcp' AND src_ip = toIPv4('10.10.0.10')")" 1

check "DNS tunnel: about 240 TXT or NULL queries" \
    "$(ch "SELECT count() BETWEEN 200 AND 260 AND countIf(qtype NOT IN ('TXT', 'NULL')) = 0 FROM labeled_dns WHERE label = 'dns_tunnel'")" 1

check "DNS tunnel: the unique-subdomain counter grows into the hundreds" \
    "$(ch "SELECT max(unique_subdomains) >= 200 FROM labeled_dns WHERE label = 'dns_tunnel'")" 1

check "DNS tunnel: long, high-entropy names" \
    "$(ch "SELECT avg(entropy) > 3.6 AND min(qname_length) > 40 FROM labeled_dns WHERE label = 'dns_tunnel'")" 1

check "ordinary client: short, low-entropy names and few subdomains" \
    "$(ch "SELECT count() >= 20 AND max(qname_length) < 30 AND avg(entropy) < 3.6 AND max(unique_subdomains) <= 20 FROM labeled_dns WHERE label = 'benign'")" 1

check "entropy separates the tunnel from ordinary lookups by at least 0.5 bit" \
    "$(ch "SELECT (SELECT avg(entropy) FROM labeled_dns WHERE label = 'dns_tunnel') - (SELECT avg(entropy) FROM labeled_dns WHERE label = 'benign') > 0.5")" 1

check "ordinary client has flows labelled benign" \
    "$(ch "SELECT count() > 0 FROM labeled_flows WHERE label = 'benign' AND src_ip = toIPv4('10.10.0.20')")" 1

check "C2 beacon: every lookup of the blocklisted domain is reported" \
    "$(ch "SELECT count() BETWEEN 15 AND 25 FROM blocklist_hits WHERE domain = 'malware-c2.example' AND src_ip = toIPv4('10.10.0.10') AND action = 'observed'")" 1

counted=$(ch "SELECT sum(packets) FROM flows WHERE direction = 'receive' AND ts >= fromUnixTimestamp64Milli($window_start) AND ts <= fromUnixTimestamp64Milli($window_end + 3000)")
received=$((rx_after - rx_before))
echo "  flood window: interface received $received packets, the agent counted $counted"

check "unbounded flood: the agent counts the packets the interface received, within 3 percent" \
    "$(python3 -c "print(int(abs($counted - $received) / $received < 0.03))")" 1

check "unbounded flood: at least ten thousand packets were actually sent" \
    "$(python3 -c "print(int($received >= 10000))")" 1

gateway_cpus=$(compose exec -T gateway nproc | tr -d '\r')
check "unbounded flood: records per second are bounded by the new-flow budget of every CPU" \
    "$(ch "SELECT count() <= 11 * ($gateway_cpus * 100 + 400) FROM labeled_flows WHERE run_id = $LAST_FLOOD AND direction = 'receive' AND src_ip = toIPv4('10.10.0.10')")" 1

check "unbounded flood: hundreds of thousands of packets are described by few records" \
    "$(ch "SELECT sum(packets) >= 30 * count() FROM labeled_flows WHERE run_id = $LAST_FLOOD AND direction = 'receive' AND src_ip = toIPv4('10.10.0.10')")" 1

check "unbounded flood: excess packets were counted in aggregated flows" \
    "$(ch "SELECT sum(packets) > 0 FROM flows WHERE aggregated = 1")" 1

check "ordinary client traffic stays within the new-flow budget" \
    "$(ch "SELECT count() = 0 FROM labeled_flows WHERE label = 'benign' AND aggregated = 1 AND src_ip = toIPv4('10.10.0.20')")" 1

check "the flow table never came close to its capacity" \
    "$(compose logs gateway 2>&1 | grep -c 'Flow table holds')" 0

check "the agent reported no dropped events or errors" \
    "$(compose logs gateway 2>&1 | grep -cE 'Dropped|ERROR')" 0

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
exit $FAILED
