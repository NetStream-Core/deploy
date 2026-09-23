#!/usr/bin/env python3
"""Runs a campaign of lab scenarios and writes a manifest of what happened."""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPOSE = ["docker", "compose", "-f", "compose.yml", "-f", "lab/compose.lab.yml"]
CLICKHOUSE_AUTH = ["--user", "netstream", "--password", "netstream-dev", "--database", "netstream"]


def compose(*args):
    subprocess.run([*COMPOSE, *args], cwd=ROOT, check=True)


def clickhouse(query, fmt="TSV"):
    result = subprocess.run(
        [*COMPOSE, "exec", "-T", "clickhouse", "clickhouse-client", *CLICKHOUSE_AUTH, "--format", fmt, "--query", query],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    return result.stdout


def git_info(path):
    try:
        rev = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(path), "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip() != ""
        return {"rev": rev, "dirty": dirty}
    except (OSError, subprocess.CalledProcessError):
        return None


def agent_build_info():
    marker = ROOT / "lab" / "gateway" / "artifacts" / "build_info.json"
    if not marker.exists():
        return None
    return json.loads(marker.read_text())


def wait_ready(timeout=120):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        tables = clickhouse(
            "SELECT count() FROM system.tables WHERE database = 'netstream' "
            "AND name IN ('flows', 'dns_queries', 'labels', 'labeled_flows', 'labeled_dns')"
        ).strip()
        ready = subprocess.run(
            [*COMPOSE, "logs", "gateway"], cwd=ROOT, capture_output=True, text=True
        ).stdout.count("Agent is ready")
        if tables == "5" and ready >= 1:
            return
        time.sleep(2)
    raise SystemExit("lab did not become ready in time")


def run_scenario(scenario, params):
    args = [f"{key}={value}" for key, value in params.items()]
    print(f"== {scenario} {' '.join(args)}", file=sys.stderr)
    subprocess.run(["./lab/run.sh", scenario, *args], cwd=ROOT, check=True, stdin=subprocess.DEVNULL)


def labelled_runs_since(started_at_ms):
    rows = clickhouse(
        "SELECT run_id, scenario, label, tool, params, attacker_ip, victim_ip, "
        "toUnixTimestamp64Milli(start_ts) AS start_ms, toUnixTimestamp64Milli(end_ts) AS end_ms "
        f"FROM labels WHERE toUnixTimestamp64Milli(start_ts) >= {started_at_ms} ORDER BY start_ts",
        fmt="JSONEachRow",
    )
    return [json.loads(line) for line in rows.splitlines() if line]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("campaign", type=pathlib.Path, help="path to a campaign YAML file")
    parser.add_argument("--gap-seconds", type=float, default=None, help="override the pause between runs")
    parser.add_argument("--skip-up", action="store_true", help="assume the lab is already running")
    parser.add_argument("--skip-down", action="store_true", help="leave the lab running afterwards")
    parser.add_argument("--out-dir", type=pathlib.Path, default=ROOT / "lab" / "campaigns" / "manifests")
    args = parser.parse_args()

    spec = yaml.safe_load(args.campaign.read_text())
    gap_seconds = args.gap_seconds if args.gap_seconds is not None else spec.get("gap_seconds", 20)
    runs = spec["runs"]

    if not args.skip_up:
        compose(
            "up", "-d", "--build",
            "kafka", "kafka-init", "clickhouse", "migrate", "otel-edge", "otel-gateway",
            "gateway", "victim", "tunnel", "attacker", "client",
        )
        wait_ready()
        print(f"== warming up background traffic for {spec.get('warmup_seconds', 20)}s", file=sys.stderr)
        time.sleep(spec.get("warmup_seconds", 20))

    started_at_ms = int(time.time() * 1000)
    planned = 0
    for entry in runs:
        scenario = entry["scenario"]
        params = entry.get("params", {})
        for _ in range(entry.get("repeat", 1)):
            run_scenario(scenario, params)
            planned += 1
            time.sleep(gap_seconds)

    labelled = labelled_runs_since(started_at_ms)
    if len(labelled) != planned:
        print(
            f"warning: planned {planned} runs but {len(labelled)} are labelled; "
            "check for overlapping labelling windows or a run.sh failure",
            file=sys.stderr,
        )

    manifest = {
        "campaign_file": args.campaign.name,
        "campaign_sha256": hashlib.sha256(args.campaign.read_bytes()).hexdigest(),
        "started_at_ms": started_at_ms,
        "ended_at_ms": int(time.time() * 1000),
        "gap_seconds": gap_seconds,
        "deploy": git_info(ROOT),
        "agent_build": agent_build_info(),
        "runs_planned": planned,
        "runs_labelled": labelled,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    out_path = args.out_dir / f"{args.campaign.stem}-{started_at_ms}.json"
    out_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(f"manifest written to {out_path}")

    if not args.skip_down:
        compose("down", "-v")


if __name__ == "__main__":
    main()
