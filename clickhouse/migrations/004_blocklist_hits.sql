CREATE TABLE IF NOT EXISTS blocklist_hits
(
    ts      DateTime64(3) CODEC(Delta(8), ZSTD(1)),
    host_id LowCardinality(String),
    src_ip  IPv4,
    domain  String,
    action  LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (host_id, ts)
TTL toDateTime(ts) + INTERVAL 90 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS blocklist_hits_mv TO blocklist_hits AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    toIPv4OrZero(LogAttributes['source.address']) AS src_ip,
    LogAttributes['netstream.hit.domain'] AS domain,
    LogAttributes['netstream.hit.action'] AS action
FROM otel_logs
WHERE EventName = 'netstream.blocklist.hit';
