CREATE TABLE IF NOT EXISTS dns_queries
(
    ts                DateTime64(3) CODEC(Delta(8), ZSTD(1)),
    host_id           LowCardinality(String),
    direction         LowCardinality(String),
    src_ip            IPv4,
    dst_ip            IPv4,
    qtype             LowCardinality(String),
    qname             String CODEC(ZSTD(1)),
    qname_length      UInt16,
    label_count       UInt8,
    longest_label     UInt8,
    entropy           Float32,
    digit_ratio       Float32,
    unique_subdomains UInt32
)
ENGINE = MergeTree
PARTITION BY toDate(ts)
ORDER BY (host_id, ts)
TTL toDateTime(ts) + INTERVAL 14 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS dns_queries_mv TO dns_queries AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    LogAttributes['network.io.direction'] AS direction,
    toIPv4OrZero(LogAttributes['source.address']) AS src_ip,
    toIPv4OrZero(LogAttributes['destination.address']) AS dst_ip,
    LogAttributes['netstream.dns.question.type'] AS qtype,
    LogAttributes['dns.question.name'] AS qname,
    toUInt16OrZero(LogAttributes['netstream.dns.qname.length']) AS qname_length,
    toUInt8OrZero(LogAttributes['netstream.dns.qname.labels']) AS label_count,
    toUInt8OrZero(LogAttributes['netstream.dns.qname.longest_label']) AS longest_label,
    toFloat32OrZero(LogAttributes['netstream.dns.qname.entropy']) AS entropy,
    toFloat32OrZero(LogAttributes['netstream.dns.qname.digit_ratio']) AS digit_ratio,
    toUInt32OrZero(LogAttributes['netstream.dns.unique_subdomains']) AS unique_subdomains
FROM otel_logs
WHERE EventName = 'netstream.dns.query';
