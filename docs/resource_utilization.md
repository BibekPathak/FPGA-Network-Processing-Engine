# Resource Utilization & Synthesis Report

## Target Device

**Artix-7 XC7A35T-1CPG236C** (20,800 LUTs, 41,600 FFs, 50 BRAM, 90 DSP48)

## Estimated Resource Usage (per module)

Estimates for 512-bit datapath on LUT+FF, approximate for Artix-7.

| Module | LUT | FF | BRAM | Latency | Critical Path (est.) |
|--------|-----|----|-------|---------|---------------------|
| `axis_fifo` (depth 16, 512-bit) | 78 | 575 | 0 | 1 | 2.1 ns |
| `axis_register` (512-bit) | 4 | 515 | 0 | 1 | 0.3 ns |
| `crc32` (32-bit) | 65 | 35 | 0 | N+1 | 3.2 ns |
| `ethernet_parser` | 85 | 520 | 0 | 1 | 1.8 ns |
| `vlan_parser` | 30 | 520 | 0 | 1 | 1.2 ns |
| `ipv4_parser` | 155 | 525 | 0 | 1 | **5.1 ns** |
| `udp_parser` | 20 | 520 | 0 | 1 | 0.8 ns |
| `tcp_parser` | 50 | 535 | 0 | 1 | 1.5 ns |
| `match_table` (32 rules) | 205 | 530 | 0 | 1 | **4.8 ns** |
| `packet_modifier` | 110 | 520 | 0 | 1 | 3.5 ns |
| `rule_engine` (legacy) | 15 | 515 | 0 | 1 | 0.5 ns |
| `token_bucket` | 30 | 100 | 0 | 0 | 1.2 ns |
| `stats_engine` | 130 | 555 | 0 | 0 | 1.0 ns |
| `flow_table` (128 entries) | 85 | 515 | 2 | 1 | 3.8 ns |
| `packet_scheduler` (3Q) | 210 | 185 | 0 | 1 | 2.5 ns |
| `register_iface` (64 regs) | 120 | 256 | 0 | 1 | 1.5 ns |
| **Total parser_pipeline** | **~2,350** | **~8,200** | **2** | **9 cyc** | **5.1 ns** |

## Critical Path Analysis

The longest combinational path is the **IPv4 checksum verification** in `ipv4_parser`:

```
s_tdata[byte_offset]
  → word16_be() extraction   ~0.5 ns
  → 10-word adder tree       ~2.5 ns
  → fold/compare             ~1.5 ns
  → pipeline register setup   ~0.6 ns
  ─────────────────────────────────
  Total:                      ~5.1 ns
```

The second-longest path is the **match_table priority encoder**:
```
s_meta fields
  → 32 parallel comparators  ~1.5 ns
  → priority encode           ~2.0 ns
  → pipeline register setup   ~0.6 ns
  ─────────────────────────────────
  Total:                      ~4.8 ns
```

## Timing

| Metric | Value |
|--------|-------|
| Target clock period | 5.0 ns (200 MHz) |
| Critical path | 5.1 ns (IPv4 checksum) |
| Slack | −0.1 ns at 200 MHz |
| Max safe Fmax | 196 MHz (1 / 5.1 ns) |
| Combinational depth | 20 LUT levels (checksum tree) |

At the operating frequency of **156.25 MHz** (6.4 ns period), the design has **1.3 ns positive slack**.

## Power Estimate

| Domain | Estimate |
|--------|----------|
| Dynamic (156.25 MHz) | ~420 mW |
| Static (Artix-7, 25°C) | ~95 mW |
| **Total** | **~515 mW** |

## Area vs. Speed Trade-offs

The design favors **pipeline depth over combinational breadth**:

- Each parsing stage is 1 cycle, keeping combinational depth to ~5 ns
- Wider stages (e.g., all headers parsed in 1 cycle) would save 4 cycles of latency but increase the critical path to ~15 ns (Fmax ~65 MHz)
- The 9-stage approach trades 9× latency for 3× frequency — a net win for throughput

| Architecture | Stages | Fmax | Throughput (1518B) |
|-------------|--------|------|-------------------|
| Current (9-stage) | 9 | 196 MHz | 9.91 Gbps |
| 1-stage (all combinational) | 1 | ~65 MHz | ~3.3 Gbps |
| 3-stage (grouped parsers) | 3 | ~110 MHz | ~5.5 Gbps |

## Resource Comparison: 64-bit vs 512-bit Datapath

| Metric | 64-bit bus (test config) | 512-bit bus (max config) |
|--------|--------------------------|--------------------------|
| LUT | ~2,350 | ~3,800 |
| FF | ~8,200 | ~12,500 |
| Throughput | 9.91 Gbps | ~40 Gbps |
| Fmax | 196 MHz | ~180 MHz |
