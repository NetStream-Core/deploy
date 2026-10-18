CREATE TABLE IF NOT EXISTS detections
(
    host_id        LowCardinality(String) CODEC(ZSTD(1)),
    src_ip         String CODEC(ZSTD(1)),
    window_start   DateTime CODEC(Delta(4), ZSTD(1)),
    window_seconds UInt16,
    score          Float64,
    is_attack      Bool,
    latency_ms     Float64,
    ingest_time    DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toDate(window_start)
ORDER BY (host_id, window_start)
TTL toDateTime(window_start) + INTERVAL 90 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS detections_queue
(
    host_id        String,
    src_ip         String,
    window_start   Int64,
    window_seconds UInt16,
    score          Float64,
    is_attack      Bool,
    latency_ms     Float64
)
ENGINE = Kafka
SETTINGS kafka_broker_list = 'kafka:29092',
         kafka_topic_list = 'netstream.detections.v1',
         kafka_group_name = 'clickhouse-detections',
         kafka_format = 'JSONEachRow',
         kafka_num_consumers = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS detections_mv TO detections AS
SELECT
    host_id,
    src_ip,
    toDateTime(window_start) AS window_start,
    window_seconds,
    score,
    is_attack,
    latency_ms
FROM detections_queue;
