#!/usr/bin/env python3
"""
NPE simulation runner.

Usage:
    python scripts/run.py [test_name] [--waves] [--list]

Examples:
    python scripts/run.py                         # run default (tb_axis_fifo)
    python scripts/run.py tb_axis_fifo             # run specific test
    python scripts/run.py tb_axis_fifo --waves     # with waveform dump
    python scripts/run.py --list                   # list available tests
"""

import subprocess
import sys
import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = PROJECT_ROOT / "build"

DEFAULT_TEST = "tb_axis_fifo"


def list_tests():
    tb_dir = PROJECT_ROOT / "sim" / "testbenches"
    tests = sorted(f.stem for f in tb_dir.glob("*.cpp") if f.stem.startswith("tb_"))
    print("Available tests:")
    for t in tests:
        print(f"  {t}")
    return tests


def run_test(test_name: str, waves: bool):
    cmd = ["make", "-C", str(PROJECT_ROOT), "-s"]
    if waves:
        cmd.append("waves")
    else:
        cmd.append("run")
    cmd.append(f"TOP={test_name}")

    env = os.environ.copy()
    env["TOP"] = test_name

    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, env=env, cwd=PROJECT_ROOT)

    if result.returncode != 0:
        print(f"FAIL: {test_name} (exit code {result.returncode})")
    else:
        print(f"PASS: {test_name}")

    return result.returncode


def main():
    args = sys.argv[1:]

    if "--list" in args:
        list_tests()
        return

    waves = "--waves" in args
    if waves:
        args.remove("--waves")

    test_name = args[0] if args else DEFAULT_TEST

    sys.exit(run_test(test_name, waves))


if __name__ == "__main__":
    main()
