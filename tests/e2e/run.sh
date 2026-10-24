#!/usr/bin/env bash
set -u

cd "$(dirname "$0")/../.."
source tests/e2e/lib.sh

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
check "all dashboards are provisioned" "$(grafana '/api/search?type=dash-db' | python3 -c 'import sys,json; print(",".join(sorted(d["uid"] for d in json.load(sys.stdin))))')" "ns-detections,ns-dns,ns-sensor-health,ns-traffic"

echo "== a large burst is not dropped"
seeded=$(python3 tools/seed.py --endpoint "http://127.0.0.1:$EDGE_HTTP_PORT" --hosts e2e-burst --minutes 10 --seed 1 | sed -n 's/^seeded \([0-9]*\) records.*/\1/p')
check "every seeded record is stored" "$(eventually 120 "ch \"SELECT count() FROM otel_logs WHERE ResourceAttributes['host.id'] = 'e2e-burst'\"" "$seeded")" "$seeded"

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
exit $FAILED
