ALTER TABLE otel_logs ADD COLUMN IF NOT EXISTS ingest_time DateTime DEFAULT now() CODEC(Delta, ZSTD(1));

ALTER TABLE flows
    ADD COLUMN IF NOT EXISTS boot_id LowCardinality(String) AFTER host_id,
    ADD COLUMN IF NOT EXISTS event_sequence UInt64 AFTER boot_id,
    ADD COLUMN IF NOT EXISTS event_id String AFTER event_sequence,
    ADD COLUMN IF NOT EXISTS ingest_time DateTime AFTER tcp_rst;

DROP VIEW IF EXISTS flows_mv;

CREATE MATERIALIZED VIEW flows_mv TO flows AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    ResourceAttributes['service.instance.id'] AS boot_id,
    toUInt64OrZero(LogAttributes['netstream.event.sequence']) AS event_sequence,
    LogAttributes['netstream.event.id'] AS event_id,
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
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.rst']) AS tcp_rst,
    ingest_time
FROM otel_logs
WHERE EventName = 'netstream.flow';

ALTER TABLE dns_queries
    ADD COLUMN IF NOT EXISTS boot_id LowCardinality(String) AFTER host_id,
    ADD COLUMN IF NOT EXISTS event_sequence UInt64 AFTER boot_id,
    ADD COLUMN IF NOT EXISTS event_id String AFTER event_sequence,
    ADD COLUMN IF NOT EXISTS ingest_time DateTime AFTER unique_subdomains;

DROP VIEW IF EXISTS dns_queries_mv;

CREATE MATERIALIZED VIEW dns_queries_mv TO dns_queries AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    ResourceAttributes['service.instance.id'] AS boot_id,
    toUInt64OrZero(LogAttributes['netstream.event.sequence']) AS event_sequence,
    LogAttributes['netstream.event.id'] AS event_id,
    LogAttributes['network.io.direction'] AS direction,
    LogAttributes['network.transport'] AS transport,
    toIPv4OrZero(LogAttributes['source.address']) AS src_ip,
    toIPv4OrZero(LogAttributes['destination.address']) AS dst_ip,
    LogAttributes['netstream.dns.question.type'] AS qtype,
    LogAttributes['dns.question.name'] AS qname,
    toUInt16OrZero(LogAttributes['netstream.dns.qname.length']) AS qname_length,
    toUInt8OrZero(LogAttributes['netstream.dns.qname.labels']) AS label_count,
    toUInt8OrZero(LogAttributes['netstream.dns.qname.longest_label']) AS longest_label,
    toFloat32OrZero(LogAttributes['netstream.dns.qname.entropy']) AS entropy,
    toFloat32OrZero(LogAttributes['netstream.dns.qname.digit_ratio']) AS digit_ratio,
    toUInt32OrZero(LogAttributes['netstream.dns.unique_subdomains']) AS unique_subdomains,
    ingest_time
FROM otel_logs
WHERE EventName = 'netstream.dns.query';

ALTER TABLE blocklist_hits
    ADD COLUMN IF NOT EXISTS boot_id LowCardinality(String) AFTER host_id,
    ADD COLUMN IF NOT EXISTS event_sequence UInt64 AFTER boot_id,
    ADD COLUMN IF NOT EXISTS event_id String AFTER event_sequence,
    ADD COLUMN IF NOT EXISTS ingest_time DateTime AFTER action;

DROP VIEW IF EXISTS blocklist_hits_mv;

CREATE MATERIALIZED VIEW blocklist_hits_mv TO blocklist_hits AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
    ResourceAttributes['service.instance.id'] AS boot_id,
    toUInt64OrZero(LogAttributes['netstream.event.sequence']) AS event_sequence,
    LogAttributes['netstream.event.id'] AS event_id,
    toIPv4OrZero(LogAttributes['source.address']) AS src_ip,
    LogAttributes['netstream.hit.domain'] AS domain,
    LogAttributes['netstream.hit.action'] AS action,
    ingest_time
FROM otel_logs
WHERE EventName = 'netstream.blocklist.hit';
