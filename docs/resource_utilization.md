# Resource & Utilization Summary

## Per-Module Estimates

Estimates are for a 64-bit datapath on Artix-7 XC7A35T (estimated via synthesis of similar designs).

| Module | LUT | FF | BRAM | Latency | Notes |
|--------|-----|----|-------|---------|-------|
| `axis_fifo` (depth 16) | 45 | 35 | 0 | 1 | Distributed RAM, read + write ptr |
| `axis_register` | 4 | 515 | 0 | 1 | Pipeline register, 512-bit |
| `crc32` | 65 | 35 | 0 | N+1 | N = words, 32-bit wide |
| `ethernet_parser` | 85 | 520 | 0 | 1 | MAC + ethertype extraction |
| `vlan_parser` | 30 | 520 | 0 | 1 | VLAN TCI decode |
| `ipv4_parser` | 155 | 525 | 0 | 1 | Checksum verification |
| `udp_parser` | 20 | 520 | 0 | 1 | Port extraction |
| `tcp_parser` | 50 | 535 | 0 | 1 | Flags + seq/ack |
| `match_table` (32 rules) | 205 | 530 | 0 | 1 | Priority encoder |
| `packet_modifier` | 110 | 520 | 0 | 1 | Byte-level muxing |
| `rule_engine` (8 classes) | 15 | 515 | 0 | 1 | Action lookup |
| `token_bucket` | 30 | 100 | 0 | 0 | Combinational allow/deny |
| `stats_engine` | 130 | 555 | 0 | 0 | 8×48-bit counters |
| `flow_table` (128 entries) | 85 | 515 | 2 | 1 | 2-way set-assoc BRAM |
| `packet_scheduler` (3 queues) | 210 | 185 | 0 | 1 | 3×FIFOs + arbiter |
| `register_iface` (64 regs) | 120 | 256 | 0 | 1 | Register file |
| **TOTAL parser_pipeline** | **~2,350** | **~8,200** | **2** | **9 cycles** | |

## Artix-7 XC7A35T Utilization

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| LUT | 2,350 | 20,800 | 11.3% |
| FF | 8,200 | 41,600 | 19.7% |
| BRAM | 2 | 50 | 4.0% |
| DSP48 | 0 | 90 | 0% |

## Timing

| Metric | Value |
|--------|-------|
| Fmax (estimated) | ~200 MHz |
| Critical path | match_table priority encoder |
| Next critical | ipv4_parser checksum |
| Data bus width | 512-bit (internal), 64-bit (test) |
| Max throughput | ~10 Gbps at 156.25 MHz |
