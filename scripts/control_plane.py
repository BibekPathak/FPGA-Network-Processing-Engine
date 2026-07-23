#!/usr/bin/env python3
"""
NPE Control Plane — Python interface to the hardware model.

Usage:
    from control_plane import NpeControl
    npe = NpeControl(c_binary="./build/obj_dir/tb_pipeline")
    npe.start()
    npe.add_rule(protocol=17, dst_port=53, action=0, class_id=1)
    stats = npe.dump_stats()
    npe.stop()
"""

import subprocess
import struct
import sys
import os


class NpeControl:
    """Control plane for the NPE hardware model via stdin/stdout."""

    def __init__(self, c_binary=None, verbose=False):
        self.c_binary = c_binary or "./build/obj_dir/tb_pipeline"
        self.proc = None
        self.verbose = verbose

    def start(self):
        """Launch the hardware simulation in control mode."""
        env = os.environ.copy()
        env["NPE_CONTROL_MODE"] = "1"
        self.proc = subprocess.Popen(
            [self.c_binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=False,
        )
        # Wait for ready signal
        line = self._read_line()
        if self.verbose:
            print(f"[npe] {line}", file=sys.stderr)
        return line is not None

    def stop(self):
        """Stop the simulation."""
        if self.proc:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
            self.proc = None

    def _read_line(self):
        """Read a line from stdout."""
        if not self.proc:
            return None
        line = b""
        while True:
            c = self.proc.stdout.read(1)
            if not c or c == b'\n':
                break
            line += c
        return line.decode().strip() if line else None

    def _send_command(self, cmd):
        """Send a command string and read response."""
        if not self.proc:
            return None
        self.proc.stdin.write((cmd + "\n").encode())
        self.proc.stdin.flush()
        return self._read_line()

    def reg_write(self, addr: int, data: int):
        """Write a 32-bit register."""
        return self._send_command(f"REG_WRITE {addr:#04x} {data:#010x}")

    def reg_read(self, addr: int):
        """Read a 32-bit register. Returns integer or None."""
        resp = self._send_command(f"REG_READ {addr:#04x}")
        if resp and resp.startswith("OK"):
            return int(resp.split()[1], 16)
        return None

    def add_rule(self, protocol=0, src_ip=0, dst_ip=0,
                  src_port=0, dst_port=0, action=0, class_id=0,
                  mod_action=0, rule_idx=0):
        """
        Add or update a match-action rule.

        Rule registers (4 × 32-bit per rule at 0x10 + rule_idx*4):
          reg 0: {protocol[7:0], src_port[15:0], dst_port[15:0]}
          reg 1: src_ip
          reg 2: dst_ip
          reg 3: {valid, mod_action, action[1:0], class_id[7:0]}
        """
        base = 0x10 + rule_idx * 4
        reg0 = (protocol << 24) | (src_port << 8) | dst_port
        reg3 = (1 << 31) | (mod_action << 16) | (action << 6) | class_id
        self.reg_write(base, reg0)
        self.reg_write(base + 1, src_ip)
        self.reg_write(base + 2, dst_ip)
        self.reg_write(base + 3, reg3)
        return True

    def delete_rule(self, rule_idx: int):
        """Disable a rule by clearing its valid bit."""
        base = 0x10 + rule_idx * 4
        existing = self.reg_read(base + 3) or 0
        self.reg_write(base + 3, existing & ~(1 << 31))
        return True

    def dump_stats(self):
        """Read all statistics counters. Returns dict."""
        stats = {}
        base = 0x50
        names = ["packets", "bytes", "ipv4", "tcp", "udp", "arp", "drops", "errors"]
        for i, name in enumerate(names):
            lo = self.reg_read(base + i * 2)
            hi = self.reg_read(base + i * 2 + 1)
            if lo is not None and hi is not None:
                stats[name] = (hi << 32) | lo
        return stats
