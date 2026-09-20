#!/usr/bin/env bash
set -u

cd "$(dirname "$0")/../.."

free_port() {
    python3 - <<'EOF'
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
EOF
}

export EDGE_GRPC_PORT=$(free_port)
export EDGE_HTTP_PORT=$(free_port)
export KAFKA_HOST_PORT=$(free_port)
export CLICKHOUSE_HTTP_PORT=$(free_port)
export CLICKHOUSE_NATIVE_PORT=$(free_port)
export GRAFANA_PORT=$(free_port)

PROJECT=netstream-e2e
FAILED=0

compose() { docker compose -p "$PROJECT" "$@"; }

ch() {
    compose exec -T clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream --format TSV --query "$1"
}

cleanup() {
    if [ "${KEEP:-0}" = "1" ]; then
        echo "KEEP=1: leaving the stack running as project $PROJECT"
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

eventually() {
    local seconds=$1 command=$2 expected=$3 actual=""
    for _ in $(seq 1 "$seconds"); do
        actual=$(eval "$command" 2>/dev/null)
        [ "$actual" = "$expected" ] && { echo "$actual"; return 0; }
        sleep 1
    done
    echo "$actual"
    return 1
}

attr_string() { printf '{"key":"%s","value":{"stringValue":"%s"}}' "$1" "$2"; }
attr_int() { printf '{"key":"%s","value":{"intValue":"%s"}}' "$1" "$2"; }
attr_double() { printf '{"key":"%s","value":{"doubleValue":%s}}' "$1" "$2"; }

send_logs() {
    local records=$1
    curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$EDGE_HTTP_PORT/v1/logs" \
        -H 'Content-Type: application/json' \
        -d "{\"resourceLogs\":[{\"resource\":{\"attributes\":[$(attr_string service.name netstream-monitor-agent),$(attr_string host.id e2e-host),$(attr_string network.interface.name eth0)]},\"scopeLogs\":[{\"scope\":{\"name\":\"e2e\"},\"logRecords\":[$records]}]}]}"
}

flow_record() {
    local now=$1 packets=$2
    printf '{"timeUnixNano":"%s","eventName":"netstream.flow","severityNumber":9,"attributes":[%s]}' "$now" \
        "$(attr_string network.io.direction receive),$(attr_string network.transport tcp),$(attr_string source.address 10.1.2.3),$(attr_string destination.address 10.9.8.7),$(attr_int source.port 44321),$(attr_int destination.port 443),$(attr_int netstream.flow.interval_ms 1000),$(attr_int netstream.flow.packets "$packets"),$(attr_int netstream.flow.bytes.ip 4200),$(attr_int netstream.flow.bytes.payload 3000),$(attr_int netstream.flow.tcp.syn 5),$(attr_int netstream.flow.tcp.synack 0),$(attr_int netstream.flow.tcp.fin 2),$(attr_int netstream.flow.tcp.rst 1)"
}

dns_record() {
    local now=$1
    printf '{"timeUnixNano":"%s","eventName":"netstream.dns.query","severityNumber":9,"attributes":[%s]}' "$now" \
        "$(attr_string network.io.direction transmit),$(attr_string source.address 192.168.1.10),$(attr_string destination.address 192.168.1.1),$(attr_string netstream.dns.question.type TXT),$(attr_string dns.question.name nb2xgzlsmvzgs3tfebzgk4tp.t.tunnel.test),$(attr_int netstream.dns.qname.length 38),$(attr_int netstream.dns.qname.labels 4),$(attr_int netstream.dns.qname.longest_label 24),$(attr_double netstream.dns.qname.entropy 3.87),$(attr_double netstream.dns.qname.digit_ratio 0.21),$(attr_int netstream.dns.unique_subdomains 30)"
}

hit_record() {
    local now=$1
    printf '{"timeUnixNano":"%s","eventName":"netstream.blocklist.hit","severityNumber":13,"attributes":[%s]}' "$now" \
        "$(attr_string source.address 10.0.0.7),$(attr_string netstream.hit.domain blocked-test.example),$(attr_string netstream.hit.action quarantined)"
}

echo "== starting the stack"
compose up -d >/dev/null 2>&1 || { echo "docker compose up failed"; compose logs --tail 30; exit 1; }

tables=$(eventually 120 "ch \"SELECT count() FROM system.tables WHERE database = 'netstream' AND name IN ('otel_logs','flows','dns_queries','blocklist_hits','flows_1m','schema_migrations','labels')\"" 7)
check "migrations created all tables" "$tables" 7
check "gateway is running" "$(eventually 60 "compose ps --status running --services | grep -c '^otel-gateway$'" 1)" 1
check "edge collector is running" "$(eventually 60 "compose ps --status running --services | grep -c '^otel-edge$'" 1)" 1
sleep 5

echo "== sending one flow, one DNS query and one blocklist hit through the edge collector"
now=$(date +%s%N)
check "edge accepts OTLP/HTTP" "$(send_logs "$(flow_record "$now" 42),$(dns_record "$now"),$(hit_record "$now")")" 200

check "flow row reaches ClickHouse" \
    "$(eventually 60 "ch \"SELECT host_id, interface, direction, transport, toString(src_ip), toString(dst_ip), src_port, dst_port, interval_ms, packets, ip_bytes, payload_bytes, tcp_syn, tcp_synack, tcp_fin, tcp_rst FROM flows\" | tr '\\t' ' '" "e2e-host eth0 receive tcp 10.1.2.3 10.9.8.7 44321 443 1000 42 4200 3000 5 0 2 1")" \
    "e2e-host eth0 receive tcp 10.1.2.3 10.9.8.7 44321 443 1000 42 4200 3000 5 0 2 1"

check "DNS row reaches ClickHouse" \
    "$(eventually 60 "ch \"SELECT host_id, direction, toString(src_ip), toString(dst_ip), qtype, qname, qname_length, label_count, longest_label, round(entropy, 2), round(digit_ratio, 2), unique_subdomains FROM dns_queries\" | tr '\\t' ' '" "e2e-host transmit 192.168.1.10 192.168.1.1 TXT nb2xgzlsmvzgs3tfebzgk4tp.t.tunnel.test 38 4 24 3.87 0.21 30")" \
    "e2e-host transmit 192.168.1.10 192.168.1.1 TXT nb2xgzlsmvzgs3tfebzgk4tp.t.tunnel.test 38 4 24 3.87 0.21 30"

check "blocklist hit reaches ClickHouse" \
    "$(eventually 60 "ch \"SELECT host_id, toString(src_ip), domain, action FROM blocklist_hits\" | tr '\\t' ' '" "e2e-host 10.0.0.7 blocked-test.example quarantined")" \
    "e2e-host 10.0.0.7 blocked-test.example quarantined"

check "per-minute aggregate is filled" \
    "$(eventually 30 "ch \"SELECT sum(packets), sum(ip_bytes) FROM flows_1m WHERE host_id = 'e2e-host'\" | tr '\\t' ' '" "42 4200")" \
    "42 4200"

check "raw staging table holds the three records" \
    "$(ch "SELECT count() FROM otel_logs WHERE ResourceAttributes['host.id'] = 'e2e-host'")" 3

echo "== migrations are idempotent"
rerun=$(compose run --rm -T migrate 2>&1)
check "second run skips every migration" "$(echo "$rerun" | grep -c '^skipping')" "$(ls clickhouse/migrations/*.sql | wc -l)"
check "second run applies nothing" "$(echo "$rerun" | grep -c '^applying')" 0

echo "== Kafka buffers data while the gateway is down"
compose stop otel-gateway >/dev/null 2>&1
now=$(date +%s%N)
check "edge still accepts data" "$(send_logs "$(flow_record "$now" 7)")" 200
sleep 6
check "nothing is written while the gateway is stopped" "$(ch "SELECT count() FROM flows")" 1
compose start otel-gateway >/dev/null 2>&1
check "buffered record arrives after the gateway restarts" "$(eventually 90 "ch \"SELECT count() FROM flows\"" 2)" 2
check "record content survived the outage" "$(ch "SELECT packets FROM flows ORDER BY packets LIMIT 1")" 7

echo "== Grafana"
grafana() { curl -sS -u admin:netstream-dev "http://127.0.0.1:$GRAFANA_PORT$1"; }
check "Grafana is healthy" "$(eventually 90 "grafana /api/health | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"database\"])'" ok)" ok
check "ClickHouse data source works" "$(grafana /api/datasources/uid/netstream-clickhouse/health | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"])')" OK
check "both dashboards are provisioned" "$(grafana '/api/search?type=dash-db' | python3 -c 'import sys,json; print(",".join(sorted(d["uid"] for d in json.load(sys.stdin))))')" "ns-dns,ns-traffic"

echo "== a large burst is not dropped"
seeded=$(python3 tools/seed.py --endpoint "http://127.0.0.1:$EDGE_HTTP_PORT" --hosts e2e-burst --minutes 10 --seed 1 | sed -n 's/^seeded \([0-9]*\) records.*/\1/p')
check "every seeded record is stored" "$(eventually 120 "ch \"SELECT count() FROM otel_logs WHERE ResourceAttributes['host.id'] = 'e2e-burst'\"" "$seeded")" "$seeded"

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
exit $FAILED
