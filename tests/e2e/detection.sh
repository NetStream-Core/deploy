#!/usr/bin/env bash
# End-to-end check for the online detector (P1 from the external review):
# publish a real model -> `detect run` -> synthetic OTLP events through the
# edge collector -> a detection in `netstream.detections.v1` -> a row in
# ClickHouse's `detections` table. Also exercises the two failure modes the
# review called out: the consumer resuming from its committed offset after
# a restart (no replay, no loss), and surviving a brief Kafka outage
# without crashing.
#
# `detect run` is a host process (not a compose service): it reads the
# sibling `../ml` checkout via `uv run --project`, the same way this repo's
# own tooling (`tools/seed.py`) runs from the host rather than in a
# container.
set -u

cd "$(dirname "$0")/../.."
source tests/e2e/lib.sh

export EDGE_HTTP_PORT=$(free_port)
export KAFKA_HOST_PORT=$(free_port)
export CLICKHOUSE_HTTP_PORT=$(free_port)
export CLICKHOUSE_NATIVE_PORT=$(free_port)

PROJECT=netstream-e2e-detect
FAILED=0
MODEL_DIR=$(mktemp -d)
DETECTOR_LOG="$MODEL_DIR/detector.log"
DETECTOR_PID=""

compose() { docker compose -p "$PROJECT" "$@"; }

ch() {
    compose exec -T clickhouse clickhouse-client --user netstream --password netstream-dev --database netstream --format TSV --query "$1"
}

start_detector() {
    uv run --project ../ml netstream-ml detect run \
        --onnx-model "$MODEL_DIR/model.onnx" \
        --window 5 \
        --bootstrap-servers "127.0.0.1:$KAFKA_HOST_PORT" \
        --events-topic netstream.events.v1 \
        --detections-topic netstream.detections.v1 \
        --consumer-group e2e-detector \
        --idle-flush-seconds 30 \
        >>"$DETECTOR_LOG" 2>&1 &
    DETECTOR_PID=$!
}

stop_detector() {
    [ -n "$DETECTOR_PID" ] || return 0
    # SIGINT goes to `uv run` itself (the backgrounded PID) *and* to the
    # actual `netstream-ml` process it spawns as a child (`uv run` does not
    # reliably forward signals to it) - python's own SIGINT handler raises
    # KeyboardInterrupt, which unwinds the `finally: ...; consumer.close()`
    # in run_kafka_detector so the last flush/commit still runs.
    kill -INT "$DETECTOR_PID" 2>/dev/null
    pkill -INT -P "$DETECTOR_PID" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$DETECTOR_PID" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$DETECTOR_PID" 2>/dev/null; then
        echo "detect run did not exit within 10s of SIGINT; sending SIGKILL" >&2
        pkill -KILL -P "$DETECTOR_PID" 2>/dev/null
        kill -KILL "$DETECTOR_PID" 2>/dev/null
    fi
    wait "$DETECTOR_PID" 2>/dev/null
    DETECTOR_PID=""
}

detector_is_running() {
    [ -n "$DETECTOR_PID" ] && kill -0 "$DETECTOR_PID" 2>/dev/null
}

cleanup() {
    stop_detector
    if [ "${KEEP:-0}" = "1" ]; then
        echo "KEEP=1: leaving the stack running as project $PROJECT ($DETECTOR_LOG)"
    else
        compose down -v >/dev/null 2>&1
        rm -rf "$MODEL_DIR"
    fi
}
trap cleanup EXIT

# A window closes 5s (--window above) after it last saw a flow; two records
# `window_seconds + 1` apart for the same host/src_ip force exactly one
# detection per pair, deterministically, instead of relying on the idle
# flush's timing.
send_closed_window() {
    local host_id=$1 src_ip=$2 now
    now=$(date +%s%N)
    SEND_LOGS_HOST_ID="$host_id" send_logs "$(flow_record "$now" 1 "$src_ip")" >/dev/null
    sleep 6
    now=$(date +%s%N)
    SEND_LOGS_HOST_ID="$host_id" send_logs "$(flow_record "$now" 1 "$src_ip")" >/dev/null
}

echo "== starting Kafka, edge collector and ClickHouse"
compose up -d kafka kafka-init otel-edge clickhouse migrate >/dev/null 2>&1 \
    || { echo "docker compose up failed"; compose logs --tail 30; exit 1; }

check "migrations created the detections tables" \
    "$(eventually 120 "ch \"SELECT count() FROM system.tables WHERE database = 'netstream' AND name IN ('detections','detections_queue','detections_mv')\"" 3)" \
    3
check "edge collector is running" "$(eventually 60 "compose ps --status running --services | grep -c '^otel-edge$'" 1)" 1

echo "== publishing a real (if trivial) ONNX model"
uv run --project ../ml python tests/e2e/make_test_onnx_model.py "$MODEL_DIR/model.onnx" >/dev/null 2>&1
check "model file was written" "$([ -s "$MODEL_DIR/model.onnx" ] && echo yes)" yes

echo "== starting detect run against the live stack"
start_detector
sleep 3
check "detect run is running" "$(detector_is_running && echo yes)" yes

echo "== sending one synthetic window through the edge collector"
send_closed_window e2e-detect-1 10.50.0.1

check "a detection reaches netstream.detections.v1 via ClickHouse" \
    "$(eventually 60 "ch \"SELECT host_id, toString(src_ip), window_seconds, is_attack FROM detections\" | tr '\\t' ' '" "e2e-detect-1 10.50.0.1 5 true")" \
    "e2e-detect-1 10.50.0.1 5 true"

echo "== consumer-restart recovery: nothing is lost, nothing is replayed"
stop_detector
send_closed_window e2e-detect-2 10.50.0.2
sleep 3
check "no detection while the detector is stopped" "$(ch "SELECT count() FROM detections")" 1

start_detector
sleep 3
check "detect run is running again" "$(detector_is_running && echo yes)" yes
check "the window sent while stopped is picked up after restart" \
    "$(eventually 60 "ch \"SELECT count() FROM detections\"" 2)" \
    2
check "no detection was replayed for the first window" \
    "$(ch "SELECT count() FROM detections WHERE host_id = 'e2e-detect-1'")" \
    1

echo "== surviving a brief Kafka outage"
compose stop kafka >/dev/null 2>&1
sleep 5
check "detect run does not crash while Kafka is down" "$(detector_is_running && echo yes)" yes
compose start kafka >/dev/null 2>&1
check "Kafka is healthy again" "$(eventually 60 "compose ps --status running --services | grep -c '^kafka$'" 1)" 1
sleep 5

send_closed_window e2e-detect-3 10.50.0.3
check "detection flows again once Kafka recovers" \
    "$(eventually 90 "ch \"SELECT count() FROM detections\"" 3)" \
    3

echo
if [ $FAILED -eq 0 ]; then echo "RESULT: OK"; else echo "RESULT: FAILED"; echo "-- detector log --"; cat "$DETECTOR_LOG"; fi
exit $FAILED
