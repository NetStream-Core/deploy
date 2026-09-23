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
