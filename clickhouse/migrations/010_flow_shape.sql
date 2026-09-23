ALTER TABLE flows
    ADD COLUMN IF NOT EXISTS size_le64 UInt64 AFTER aggregated,
    ADD COLUMN IF NOT EXISTS size_le128 UInt64 AFTER size_le64,
    ADD COLUMN IF NOT EXISTS size_le256 UInt64 AFTER size_le128,
    ADD COLUMN IF NOT EXISTS size_le512 UInt64 AFTER size_le256,
    ADD COLUMN IF NOT EXISTS size_le1024 UInt64 AFTER size_le512,
    ADD COLUMN IF NOT EXISTS size_gt1024 UInt64 AFTER size_le1024,
    ADD COLUMN IF NOT EXISTS iat_count UInt64 AFTER size_gt1024,
    ADD COLUMN IF NOT EXISTS iat_sum_us UInt64 AFTER iat_count,
    ADD COLUMN IF NOT EXISTS iat_sumsq_us UInt64 AFTER iat_sum_us;

DROP VIEW IF EXISTS flows_mv;

CREATE MATERIALIZED VIEW flows_mv TO flows AS
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
    toUInt64OrZero(LogAttributes['netstream.flow.tcp.rst']) AS tcp_rst,
    toUInt8OrZero(LogAttributes['netstream.flow.aggregated']) AS aggregated,
    toUInt64OrZero(LogAttributes['netstream.flow.size.le64']) AS size_le64,
    toUInt64OrZero(LogAttributes['netstream.flow.size.le128']) AS size_le128,
    toUInt64OrZero(LogAttributes['netstream.flow.size.le256']) AS size_le256,
    toUInt64OrZero(LogAttributes['netstream.flow.size.le512']) AS size_le512,
    toUInt64OrZero(LogAttributes['netstream.flow.size.le1024']) AS size_le1024,
    toUInt64OrZero(LogAttributes['netstream.flow.size.gt1024']) AS size_gt1024,
    toUInt64OrZero(LogAttributes['netstream.flow.iat.count']) AS iat_count,
    toUInt64OrZero(LogAttributes['netstream.flow.iat.sum_us']) AS iat_sum_us,
    toUInt64OrZero(LogAttributes['netstream.flow.iat.sumsq_us']) AS iat_sumsq_us
FROM otel_logs
WHERE EventName = 'netstream.flow';

CREATE OR REPLACE VIEW labeled_flows AS
WITH (SELECT groupArray((attacker_ip, start_ts, end_ts, label, run_id, scenario)) FROM labels) AS windows
SELECT
    *,
    arrayFirst(w -> (src_ip = w.1 OR dst_ip = w.1) AND ts >= w.2 AND ts - toIntervalMillisecond(interval_ms) <= w.3, windows) AS window,
    if(window.4 = '', 'benign', window.4) AS label,
    if(window.4 = '', 'background', window.6) AS scenario,
    window.5 AS run_id
FROM flows;

CREATE OR REPLACE VIEW labeled_dns AS
WITH (SELECT groupArray((attacker_ip, start_ts, end_ts, label, run_id, scenario)) FROM labels) AS windows
SELECT
    *,
    arrayFirst(w -> (src_ip = w.1 OR dst_ip = w.1) AND ts >= w.2 AND ts <= w.3 + toIntervalMillisecond(500), windows) AS window,
    if(window.4 = '', 'benign', window.4) AS label,
    if(window.4 = '', 'background', window.6) AS scenario,
    window.5 AS run_id
FROM dns_queries;
