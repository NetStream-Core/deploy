#!/usr/bin/env python3
"""Records the git revision of the agent checkout used to build the lab artifacts."""

import json
import pathlib
import subprocess
import sys
import time


def git_info(path):
    rev = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", path, "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip() != ""
    return rev, dirty


def main():
    agent_dir, out_path = sys.argv[1], pathlib.Path(sys.argv[2])
    rev, dirty = git_info(agent_dir)
    out_path.write_text(json.dumps({"agent_rev": rev, "agent_dirty": dirty, "built_at_ms": int(time.time() * 1000)}, indent=2) + "\n")


if __name__ == "__main__":
    main()
