CREATE TABLE IF NOT EXISTS flows
(
    ts            DateTime64(3) CODEC(Delta(8), ZSTD(1)),
    host_id       LowCardinality(String),
    interface     LowCardinality(String),
    direction     LowCardinality(String),
    transport     LowCardinality(String),
    src_ip        IPv4,
    dst_ip        IPv4,
    src_port      UInt16,
    dst_port      UInt16,
    interval_ms   UInt32,
    packets       UInt64,
    ip_bytes      UInt64,
    payload_bytes UInt64,
    tcp_syn       UInt64,
    tcp_synack    UInt64,
    tcp_fin       UInt64,
    tcp_rst       UInt64
)
ENGINE = MergeTree
PARTITION BY toDate(ts)
ORDER BY (host_id, toStartOfMinute(ts), src_ip, dst_ip)
TTL toDateTime(ts) + INTERVAL 14 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS flows_mv TO flows AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    ResourceAttributes['network.interface.name'] AS interface,
    LogAttributes['network.io.direction'] AS direction,
    LogAttributes['network.transport'] AS transport,
    toIPv4OrZero(LogAttributes['source.address']) AS src_ip,
    toIPv4OrZero(LogAttributes['destination.address']) AS dst_ip,
    toUInt16OrZero(LogAttributes['source.port']) AS src_port,
    toUInt16OrZero(LogAttributes['destination.port']) AS dst_port,
    toUInt32OrZero(LogAttributes['netstream.flow.interval_ms']) AS interval_ms,
    toUInt64OrZero(LogAttributes['netstream.flow.packets']) AS packets,
    toUInt64OrZero(LogAttributes['netstream.flow.bytes.ip']) AS ip_bytes,
    toUInt64OrZero(LogAttributes['netstream.flow.bytes.payload']) AS payload_bytes,
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.syn']) AS tcp_syn,
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.synack']) AS tcp_synack,
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.fin']) AS tcp_fin,
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.rst']) AS tcp_rst
FROM otel_logs
WHERE EventName = 'netstream.flow';
