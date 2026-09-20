CREATE TABLE IF NOT EXISTS labels
(
    run_id      String,
    scenario    LowCardinality(String),
    label       LowCardinality(String),
    tool        LowCardinality(String),
    params      String,
    attacker_ip IPv4,
    victim_ip   IPv4,
    start_ts    DateTime64(3),
    end_ts      DateTime64(3)
)
ENGINE = MergeTree
ORDER BY (start_ts, run_id);
