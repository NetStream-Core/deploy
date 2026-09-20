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

echo "== running the scenarios"
./lab/run.sh syn_flood duration=12 rate=1000 | tail -1
./lab/run.sh port_scan ports=1-500 rate=100 | tail -1
./lab/run.sh dns_tunnel duration=12 rate=20 | tail -1
./lab/run.sh c2_beacon duration=10 rate=2 | tail -1
sleep 15

echo "== checking the labelled data"
check "four labelled runs" "$(ch "SELECT count() FROM labels")" 4

check "SYN flood: thousands of SYN on thousands of source ports" \
    "$(ch "SELECT sum(tcp_syn) >= 3000 AND uniqExact(src_port) >= 3000 FROM labeled_flows WHERE label = 'syn_flood' AND direction = 'receive'")" 1

check "SYN flood: the victim answers with SYN-ACK" \
    "$(ch "SELECT sum(tcp_synack) >= 3000 FROM labeled_flows WHERE label = 'syn_flood' AND direction = 'transmit'")" 1

check "port scan: at least 450 distinct destination ports from one source" \
    "$(ch "SELECT uniqExact(dst_port) >= 450 FROM labeled_flows WHERE label = 'port_scan' AND direction = 'receive' AND transport = 'tcp' AND src_ip = toIPv4('10.10.0.10')")" 1

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

check "the agent reported no dropped events or errors" \
    "$(compose logs gateway 2>&1 | grep -cE 'Dropped|ERROR')" 0

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
exit $FAILED
