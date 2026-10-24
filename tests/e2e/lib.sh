#!/usr/bin/env bash
# Shared helpers for tests/e2e/*.sh — a free-port picker, the OK/FAIL check
# harness, a poll-until-eventually loop, and OTLP/HTTP record builders for
# sending synthetic flow/DNS/blocklist events through the edge collector.
# Each e2e script still owns its own `compose()`/`cleanup()` (they differ
# per `$PROJECT` and per which services the trap needs to leave running).

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

# Requires $EDGE_HTTP_PORT and, optionally, $SEND_LOGS_HOST_ID (default
# e2e-host) in the caller's environment.
send_logs() {
    local records=$1 host_id=${SEND_LOGS_HOST_ID:-e2e-host}
    curl -sS -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$EDGE_HTTP_PORT/v1/logs" \
        -H 'Content-Type: application/json' \
        -d "{\"resourceLogs\":[{\"resource\":{\"attributes\":[$(attr_string service.name netstream-monitor-agent),$(attr_string host.id "$host_id"),$(attr_string network.interface.name eth0)]},\"scopeLogs\":[{\"scope\":{\"name\":\"e2e\"},\"logRecords\":[$records]}]}]}"
}

flow_record() {
    local now=$1 packets=$2 src_ip=${3:-10.1.2.3}
    printf '{"timeUnixNano":"%s","eventName":"netstream.flow","severityNumber":9,"attributes":[%s]}' "$now" \
        "$(attr_string network.io.direction receive),$(attr_string network.transport tcp),$(attr_string source.address "$src_ip"),$(attr_string destination.address 10.9.8.7),$(attr_int source.port 44321),$(attr_int destination.port 443),$(attr_int netstream.flow.interval_ms 1000),$(attr_int netstream.flow.packets "$packets"),$(attr_int netstream.flow.bytes.ip 4200),$(attr_int netstream.flow.bytes.payload 3000),$(attr_int netstream.flow.tcp.syn 5),$(attr_int netstream.flow.tcp.synack 0),$(attr_int netstream.flow.tcp.fin 2),$(attr_int netstream.flow.tcp.rst 1),$(attr_int netstream.flow.aggregated 0),$(attr_int netstream.flow.size.le64 0),$(attr_int netstream.flow.size.le128 0),$(attr_int netstream.flow.size.le256 0),$(attr_int netstream.flow.size.le512 0),$(attr_int netstream.flow.size.le1024 "$packets"),$(attr_int netstream.flow.size.gt1024 0),$(attr_int netstream.flow.iat.count 0),$(attr_int netstream.flow.iat.sum_us 0),$(attr_int netstream.flow.iat.sumsq_us 0)"
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
