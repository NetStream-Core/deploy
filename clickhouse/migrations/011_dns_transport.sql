ALTER TABLE dns_queries ADD COLUMN IF NOT EXISTS transport LowCardinality(String) AFTER direction;

DROP VIEW IF EXISTS dns_queries_mv;

CREATE MATERIALIZED VIEW dns_queries_mv TO dns_queries AS
SELECT
    Timestamp AS ts,
    ResourceAttributes['host.id'] AS host_id,
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
    toUInt32OrZero(LogAttributes['netstream.dns.unique_subdomains']) AS unique_subdomains
FROM otel_logs
WHERE EventName = 'netstream.dns.query';

DROP VIEW IF EXISTS labeled_dns;

CREATE VIEW labeled_dns AS
WITH (SELECT groupArray((attacker_ip, start_ts, end_ts, label, run_id, scenario)) FROM labels) AS windows
SELECT
    *,
    arrayFirst(w -> (src_ip = w.1 OR dst_ip = w.1) AND ts >= w.2 AND ts <= w.3 + toIntervalMillisecond(500), windows) AS window,
    if(window.4 = '', 'benign', window.4) AS label,
    if(window.4 = '', 'background', window.6) AS scenario,
    window.5 AS run_id
FROM dns_queries;
