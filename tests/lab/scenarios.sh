#!/usr/bin/env bash
set -u

export COMPOSE_PROJECT_NAME=netstream-lab-scenarios
source "$(dirname "$0")/common.sh"

start_lab

ATTACKER="toIPv4('10.10.0.10')"
CLIENT="toIPv4('10.10.0.20')"

run_id() { ch "SELECT run_id FROM labels WHERE scenario = '$1' ORDER BY start_ts DESC LIMIT 1"; }
sent() { ch "SELECT JSONExtractInt(params, 'sent') FROM labels WHERE scenario = '$1' ORDER BY start_ts DESC LIMIT 1"; }
within() {
    echo "  measured $1, expected about $2" >&2
    python3 -c "print(int(abs($1 - $2) / $2 < $3))"
}

echo "== warming up the background traffic of an ordinary client"
sleep 15

echo "== attacks"
./lab/run.sh udp_flood duration=8 rate=1000 | tail -1
./lab/run.sh icmp_flood duration=8 rate=500 | tail -1
./lab/run.sh slow_scan | tail -1
./lab/run.sh slowloris duration=20 conns=200 rate=50 | tail -1
./lab/run.sh iodine_tunnel duration=15 | tail -1

echo "== benign profiles"
./lab/run.sh bulk_download duration=8 rate=100 | tail -1
./lab/run.sh udp_stream duration=8 rate=5 | tail -1
./lab/run.sh video_stream duration=8 rate=2000 | tail -1
./lab/run.sh web_burst duration=8 conns=50 | tail -1
./lab/run.sh ssh_session duration=8 | tail -1
./lab/run.sh backup duration=8 | tail -1
./lab/run.sh cdn_dns duration=8 rate=20 | tail -1
./lab/run.sh dkim_dns duration=8 rate=20 | tail -1
./lab/run.sh reputation_dns duration=8 rate=20 | tail -1
./lab/run.sh admin_scan ports=1-1024 | tail -1
sleep 15

echo "== labels"
check "fifteen labelled runs" "$(ch "SELECT count() FROM labels")" 15
check "every run is labelled with its class" \
    "$(ch "SELECT arrayStringConcat(arraySort(groupArray(concat(scenario, '=', label))), ',') FROM labels")" \
    "admin_scan=benign,backup=benign,bulk_download=benign,cdn_dns=benign,dkim_dns=benign,icmp_flood=icmp_flood,iodine_tunnel=dns_tunnel,reputation_dns=benign,slow_scan=port_scan,slowloris=slowloris,ssh_session=benign,udp_flood=udp_flood,udp_stream=benign,video_stream=benign,web_burst=benign"
check "unlabelled traffic is reported as background" \
    "$(ch "SELECT countIf(scenario = 'background') > 0 AND countIf(scenario = 'background' AND label != 'benign') = 0 FROM labeled_flows")" 1

echo "== UDP flood"
UDP=$(run_id udp_flood)
check "UDP flood: the UDP packet count matches what hping3 reports sending, within 5 percent" \
    "$(within "$(ch "SELECT sum(packets) FROM labeled_flows WHERE run_id = '$UDP' AND direction = 'receive' AND transport = 'udp' AND src_ip = $ATTACKER AND dst_port = 5000")" "$(sent udp_flood)" 0.05)" 1
check "UDP flood: full-size datagrams" \
    "$(ch "SELECT sum(ip_bytes) / sum(packets) > 500 FROM labeled_flows WHERE run_id = '$UDP' AND direction = 'receive' AND transport = 'udp' AND src_ip = $ATTACKER")" 1

echo "== ICMP flood"
ICMP=$(run_id icmp_flood)
check "ICMP flood: the ICMP packet count matches what hping3 reports sending, within 5 percent" \
    "$(within "$(ch "SELECT sum(packets) FROM labeled_flows WHERE run_id = '$ICMP' AND direction = 'receive' AND transport = 'icmp' AND src_ip = $ATTACKER")" "$(sent icmp_flood)" 0.05)" 1
check "ICMP flood: records carry no ports" \
    "$(ch "SELECT countIf(src_port != 0 OR dst_port != 0) = 0 FROM labeled_flows WHERE run_id = '$ICMP' AND transport = 'icmp'")" 1

echo "== slow port scan"
SLOW=$(run_id slow_scan)
check "slow scan: sixty distinct destination ports" \
    "$(ch "SELECT uniqExact(dst_port) >= 58 FROM labeled_flows WHERE run_id = '$SLOW' AND direction = 'receive' AND transport = 'tcp' AND src_ip = $ATTACKER")" 1
check "slow scan: spread over at least twenty seconds" \
    "$(ch "SELECT dateDiff('second', min(ts), max(ts)) >= 20 FROM labeled_flows WHERE run_id = '$SLOW' AND direction = 'receive' AND transport = 'tcp' AND src_ip = $ATTACKER")" 1
check "slow scan: never more than five packets a second" \
    "$(ch "SELECT max(p) <= 5 FROM (SELECT toStartOfSecond(ts) AS s, sum(packets) AS p FROM labeled_flows WHERE run_id = '$SLOW' AND direction = 'receive' AND src_ip = $ATTACKER GROUP BY s)")" 1

echo "== slowloris"
LORIS=$(run_id slowloris)
check "slowloris: at least 150 connections opened" \
    "$(ch "SELECT sum(tcp_syn) >= 150 FROM labeled_flows WHERE run_id = '$LORIS' AND direction = 'receive' AND src_ip = $ATTACKER")" 1
check "slowloris: tiny payloads on average" \
    "$(ch "SELECT sum(payload_bytes) / sum(packets) < 100 FROM labeled_flows WHERE run_id = '$LORIS' AND direction = 'receive' AND src_ip = $ATTACKER")" 1
check "slowloris: data keeps trickling in for most of the window" \
    "$(ch "SELECT dateDiff('second', min(ts), max(ts)) >= 15 FROM labeled_flows WHERE run_id = '$LORIS' AND direction = 'receive' AND src_ip = $ATTACKER AND payload_bytes > 0")" 1

echo "== real DNS tunnel (iodine)"
IODINE=$(run_id iodine_tunnel)
check "iodine: hundreds of queries" \
    "$(ch "SELECT count() >= 500 FROM labeled_dns WHERE run_id = '$IODINE' AND src_ip = $ATTACKER")" 1
check "iodine: long names" \
    "$(ch "SELECT avg(qname_length) > 50 FROM labeled_dns WHERE run_id = '$IODINE' AND src_ip = $ATTACKER")" 1
check "iodine: many unique subdomains" \
    "$(ch "SELECT max(unique_subdomains) >= 500 FROM labeled_dns WHERE run_id = '$IODINE' AND src_ip = $ATTACKER")" 1
check "iodine: tunnelled data moves over DNS ports only" \
    "$(ch "SELECT sum(ip_bytes) > 100000 AND countIf(dst_port != 53 AND src_port != 53) = 0 FROM labeled_flows WHERE run_id = '$IODINE' AND transport = 'udp' AND (src_ip = $ATTACKER OR dst_ip = $ATTACKER)")" 1

echo "== benign profiles that resemble attacks"
check "bulk download: at least 80 MB from one client" \
    "$(ch "SELECT sum(ip_bytes) >= 80000000 FROM labeled_flows WHERE scenario = 'bulk_download' AND direction = 'receive' AND src_ip = $CLIENT")" 1
check "UDP stream: at least 3 MB of UDP without an attack label" \
    "$(ch "SELECT sum(ip_bytes) >= 3000000 AND countIf(label != 'benign') = 0 FROM labeled_flows WHERE scenario = 'udp_stream' AND transport = 'udp' AND src_ip = $CLIENT")" 1
check "video stream: at least 12 MB towards the client" \
    "$(ch "SELECT sum(ip_bytes) >= 12000000 FROM labeled_flows WHERE scenario = 'video_stream' AND direction = 'transmit' AND dst_ip = $CLIENT")" 1
check "web burst: the SYN count matches the requests ab completed, within 2 percent" \
    "$(within "$(ch "SELECT sum(tcp_syn) FROM labeled_flows WHERE scenario = 'web_burst' AND direction = 'receive' AND dst_port = 80 AND src_ip = $CLIENT")" "$(sent web_burst)" 0.02)" 1
check "web burst: thousands of connections a second look like a SYN flood but are benign" \
    "$(ch "SELECT max(s) >= 3000 AND countIf(label != 'benign') = 0 FROM (SELECT any(label) AS label, toStartOfSecond(ts) AS t, sum(tcp_syn) AS s FROM labeled_flows WHERE scenario = 'web_burst' AND src_ip = $CLIENT GROUP BY t)")" 1
check "ssh session: a long, quiet flow to port 22" \
    "$(ch "SELECT sum(packets) >= 30 AND sum(ip_bytes) < 100000 FROM labeled_flows WHERE scenario = 'ssh_session' AND direction = 'receive' AND dst_port = 22 AND src_ip = $CLIENT")" 1
check "backup: at least 200 MB to port 22" \
    "$(ch "SELECT sum(ip_bytes) >= 200000000 FROM labeled_flows WHERE scenario = 'backup' AND direction = 'receive' AND dst_port = 22 AND src_ip = $CLIENT")" 1
check "CDN lookups: long, high-entropy names and dozens of unique subdomains" \
    "$(ch "SELECT avgIf(entropy, qname_length > 25) > 3.5 AND max(unique_subdomains) >= 50 FROM labeled_dns WHERE scenario = 'cdn_dns' AND src_ip = $CLIENT")" 1
check "DKIM and SPF lookups: mostly TXT" \
    "$(ch "SELECT countIf(qtype = 'TXT') >= 140 AND countIf(label != 'benign') = 0 FROM labeled_dns WHERE scenario = 'dkim_dns' AND src_ip = $CLIENT")" 1
check "reputation lookups: names as long as a tunnel's, with entropy above 3.7" \
    "$(ch "SELECT countIf(qname_length >= 55) >= 140 AND avgIf(entropy, qname_length >= 55) > 3.7 FROM labeled_dns WHERE scenario = 'reputation_dns' AND src_ip = $CLIENT")" 1
check "reputation lookups do not use tunnel record types" \
    "$(ch "SELECT countIf(qname_length >= 55 AND qtype IN ('TXT', 'NULL')) = 0 FROM labeled_dns WHERE scenario = 'reputation_dns' AND src_ip = $CLIENT")" 1
check "administrative scan: almost every port of 1-1024 probed and still labelled benign" \
    "$(ch "SELECT uniqExact(dst_port) >= 950 AND countIf(label != 'benign') = 0 FROM labeled_flows WHERE scenario = 'admin_scan' AND direction = 'receive' AND transport = 'tcp' AND src_ip = $CLIENT")" 1

echo "== flow shape features"
check "UDP flood: 540-byte packets fall into the 513-1024 bin" \
    "$(ch "SELECT sum(size_le1024) >= 0.95 * sum(packets) FROM labeled_flows WHERE run_id = '$UDP' AND direction = 'receive' AND transport = 'udp' AND src_ip = $ATTACKER")" 1
check "bulk download: full-size segments dominate" \
    "$(ch "SELECT sum(size_gt1024) >= 0.8 * sum(packets) FROM labeled_flows WHERE scenario = 'bulk_download' AND direction = 'receive' AND dst_port = 5201 AND src_ip = $CLIENT")" 1
check "SSH session: small interactive packets are the majority" \
    "$(ch "SELECT sum(size_le64 + size_le128) >= 0.6 * sum(packets) FROM labeled_flows WHERE scenario = 'ssh_session' AND direction = 'receive' AND dst_port = 22 AND src_ip = $CLIENT")" 1
check "every packet of every flow falls into exactly one size bin" \
    "$(ch "SELECT sum(size_le64 + size_le128 + size_le256 + size_le512 + size_le1024 + size_gt1024) = sum(packets) FROM flows WHERE ts > now() - INTERVAL 1 HOUR AND iat_count > 0")" 1
check "DNS lookups at 20 per second plus background: mean inter-arrival time of 30 to 60 ms" \
    "$(ch "SELECT sum(iat_sum_us) / sum(iat_count) BETWEEN 30000 AND 60000 FROM labeled_flows WHERE scenario = 'cdn_dns' AND direction = 'receive' AND transport = 'udp' AND dst_port = 53 AND src_ip = $CLIENT")" 1
check "inter-arrival moments are consistent: the standard deviation is never imaginary" \
    "$(ch "SELECT countIf(iat_count > 1 AND iat_sumsq_us * iat_count < iat_sum_us * iat_sum_us) = 0 FROM flows WHERE ts > now() - INTERVAL 1 HOUR")" 1

check "the agent reported no dropped events or errors" \
    "$(compose logs gateway 2>&1 | grep -cE 'Dropped|ERROR')" 0

finish
