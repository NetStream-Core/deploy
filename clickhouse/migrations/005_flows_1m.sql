CREATE TABLE IF NOT EXISTS flows_1m
(
    minute        DateTime,
    host_id       LowCardinality(String),
    direction     LowCardinality(String),
    transport     LowCardinality(String),
    packets       UInt64,
    ip_bytes      UInt64,
    payload_bytes UInt64,
    tcp_syn       UInt64,
    tcp_synack    UInt64,
    tcp_fin       UInt64,
    tcp_rst       UInt64
)
ENGINE = SummingMergeTree
PARTITION BY toDate(minute)
ORDER BY (host_id, direction, transport, minute)
TTL minute + INTERVAL 90 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS flows_1m_mv TO flows_1m AS
SELECT
    toStartOfMinute(toDateTime(ts)) AS minute,
    host_id,
    direction,
    transport,
    sum(packets) AS packets,
    sum(ip_bytes) AS ip_bytes,
    sum(payload_bytes) AS payload_bytes,
    sum(tcp_syn) AS tcp_syn,
    sum(tcp_synack) AS tcp_synack,
    sum(tcp_fin) AS tcp_fin,
    sum(tcp_rst) AS tcp_rst
FROM flows
GROUP BY minute, host_id, direction, transport;
