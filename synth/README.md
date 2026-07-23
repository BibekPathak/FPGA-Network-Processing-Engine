# Synthesis

Target: **Artix-7 XC7A35T-1CPG236C** (xc7a35t)

## Prerequisites

- Vivado 2022.x or later
- bash shell

## Run Synthesis

```bash
cd synth
vivado -mode batch -source synth.tcl
```

## Expected Results

| Resource | Used | Available | % of Artix-7 |
|----------|------|-----------|--------------|
| LUT | ~2,500 | 20,800 | ~12% |
| FF | ~1,800 | 41,600 | ~4% |
| BRAM | ~4 | 50 | ~8% |
| DSP | 0 | 90 | 0% |

Timing: estimated Fmax ~200 MHz (critical path through match_table priority encoder)

## Pipeline Latency

| Module | Logic Depth (LUTs) | Latency (cycles) |
|--------|-------------------|------------------|
| axis_fifo | ~20 LUTs | 1 |
| ethernet_parser | ~80 LUTs | 1 |
| vlan_parser | ~30 LUTs | 1 |
| ipv4_parser | ~150 LUTs (checksum) | 1 |
| udp_parser | ~20 LUTs | 1 |
| tcp_parser | ~50 LUTs | 1 |
| match_table | ~200 LUTs (priority enc) | 1 |
| packet_modifier | ~100 LUTs | 1 |
| flow_table | ~60 LUTs + 2 BRAM | 1 |
| **Total pipeline** | **~710 LUTs** | **9 cycles** |
