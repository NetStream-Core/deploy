cd "$(dirname "${BASH_SOURCE[0]}")/../.."

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

start_lab() {
    echo "== starting the stack and the lab"
    compose up -d --build kafka kafka-init clickhouse migrate otel-edge otel-gateway gateway victim tunnel attacker client >/dev/null 2>&1 \
        || { echo "docker compose up failed"; compose logs --tail 30; exit 1; }

    for _ in $(seq 1 90); do
        tables=$(ch "SELECT count() FROM system.tables WHERE database = 'netstream' AND name IN ('flows','dns_queries','labels','labeled_flows','labeled_dns')" 2>/dev/null)
        ready=$(compose logs gateway 2>/dev/null | grep -c "Agent is ready")
        [ "$tables" = "5" ] && [ "$ready" -ge 1 ] && break
        sleep 1
    done
    check "stack is ready and the agent runs on the gateway" "$tables/$ready" "5/1"

    tunnel_ready=0
    for _ in $(seq 1 30); do
        compose logs tunnel 2>/dev/null | grep -q "Listening to dns" && { tunnel_ready=1; break; }
        sleep 1
    done
    check "the tunnel server is listening" "$tunnel_ready" 1
}

finish() {
    echo
    if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; fi
    exit $FAILED
}
