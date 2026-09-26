CREATE TABLE IF NOT EXISTS otel_metrics_gauge
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ResourceSchemaUrl  String CODEC(ZSTD(1)),
    ScopeName          String CODEC(ZSTD(1)),
    ScopeVersion       String CODEC(ZSTD(1)),
    ScopeAttributes    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
    ScopeSchemaUrl     String CODEC(ZSTD(1)),
    ServiceName        LowCardinality(String) CODEC(ZSTD(1)),
    MetricName          LowCardinality(String) CODEC(ZSTD(1)),
    MetricDescription   String CODEC(ZSTD(1)),
    MetricUnit          String CODEC(ZSTD(1)),
    Attributes           Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    StartTimeUnix        DateTime CODEC(Delta, ZSTD(1)),
    TimeUnix              DateTime CODEC(Delta, ZSTD(1)),
    Value                 Float64 CODEC(ZSTD(1)),
    Flags                 UInt32 CODEC(ZSTD(1)),
    Exemplars Nested (
        FilteredAttributes Map(LowCardinality(String), String),
        TimeUnix DateTime,
        Value Float64,
        SpanId String,
        TraceId String
    ) CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (MetricName, toStartOfFiveMinutes(TimeUnix), TimeUnix)
TTL toDateTime(TimeUnix) + INTERVAL 3 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS otel_metrics_sum
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ResourceSchemaUrl  String CODEC(ZSTD(1)),
    ScopeName          String CODEC(ZSTD(1)),
    ScopeVersion       String CODEC(ZSTD(1)),
    ScopeAttributes    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
    ScopeSchemaUrl     String CODEC(ZSTD(1)),
    ServiceName        LowCardinality(String) CODEC(ZSTD(1)),
    MetricName          LowCardinality(String) CODEC(ZSTD(1)),
    MetricDescription   String CODEC(ZSTD(1)),
    MetricUnit          String CODEC(ZSTD(1)),
    Attributes           Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    StartTimeUnix        DateTime CODEC(Delta, ZSTD(1)),
    TimeUnix              DateTime CODEC(Delta, ZSTD(1)),
    Value                 Float64 CODEC(ZSTD(1)),
    Flags                 UInt32 CODEC(ZSTD(1)),
    Exemplars Nested (
        FilteredAttributes Map(LowCardinality(String), String),
        TimeUnix DateTime,
        Value Float64,
        SpanId String,
        TraceId String
    ) CODEC(ZSTD(1)),
    AggregationTemporality Int32 CODEC(ZSTD(1)),
    IsMonotonic             Boolean CODEC(Delta, ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (MetricName, toStartOfFiveMinutes(TimeUnix), TimeUnix)
TTL toDateTime(TimeUnix) + INTERVAL 3 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS otel_metrics_histogram
(
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ResourceSchemaUrl  String CODEC(ZSTD(1)),
    ScopeName          String CODEC(ZSTD(1)),
    ScopeVersion       String CODEC(ZSTD(1)),
    ScopeAttributes    Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    ScopeDroppedAttrCount UInt32 CODEC(ZSTD(1)),
    ScopeSchemaUrl     String CODEC(ZSTD(1)),
    ServiceName        LowCardinality(String) CODEC(ZSTD(1)),
    MetricName          LowCardinality(String) CODEC(ZSTD(1)),
    MetricDescription   String CODEC(ZSTD(1)),
    MetricUnit          String CODEC(ZSTD(1)),
    Attributes           Map(LowCardinality(String), String) CODEC(ZSTD(1)),
    StartTimeUnix        DateTime CODEC(Delta, ZSTD(1)),
    TimeUnix              DateTime CODEC(Delta, ZSTD(1)),
    Count                 UInt64 CODEC(Delta, ZSTD(1)),
    Sum                   Float64 CODEC(ZSTD(1)),
    BucketCounts          Array(UInt64) CODEC(ZSTD(1)),
    ExplicitBounds        Array(Float64) CODEC(ZSTD(1)),
    Exemplars Nested (
        FilteredAttributes Map(LowCardinality(String), String),
        TimeUnix DateTime,
        Value Float64,
        SpanId String,
        TraceId String
    ) CODEC(ZSTD(1)),
    Flags                   UInt32 CODEC(ZSTD(1)),
    Min                     Float64 CODEC(ZSTD(1)),
    Max                     Float64 CODEC(ZSTD(1)),
    AggregationTemporality Int32 CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toDate(TimeUnix)
ORDER BY (MetricName, toStartOfFiveMinutes(TimeUnix), TimeUnix)
TTL toDateTime(TimeUnix) + INTERVAL 3 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE TABLE IF NOT EXISTS agent_metrics
(
    ts          DateTime CODEC(Delta, ZSTD(1)),
    host_id     LowCardinality(String),
    metric_name LowCardinality(String),
    unit        LowCardinality(String),
    kind        LowCardinality(String),
    value       Float64 CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toDate(ts)
ORDER BY (host_id, metric_name, ts)
TTL toDateTime(ts) + INTERVAL 30 DAY
SETTINGS ttl_only_drop_parts = 1;

CREATE MATERIALIZED VIEW IF NOT EXISTS agent_metrics_gauge_mv TO agent_metrics AS
SELECT
    TimeUnix AS ts,
    ResourceAttributes['host.id'] AS host_id,
    MetricName AS metric_name,
    MetricUnit AS unit,
    'gauge' AS kind,
    Value AS value
FROM otel_metrics_gauge;

CREATE MATERIALIZED VIEW IF NOT EXISTS agent_metrics_sum_mv TO agent_metrics AS
SELECT
    TimeUnix AS ts,
    ResourceAttributes['host.id'] AS host_id,
    MetricName AS metric_name,
    MetricUnit AS unit,
    'sum' AS kind,
    Value AS value
FROM otel_metrics_sum;
