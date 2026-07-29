# FPGA Network Processing Engine — Architecture

A fully pipelined Layer 2–Layer 4 packet processing engine in SystemVerilog with AXI-Stream interfaces, protocol parsing, programmable match-action processing, packet modification, flow tracking, runtime configuration, formal verification, and synthesis targeting an Artix-7 FPGA.

---

## System Overview

```
              512-bit AXI Stream In
                       │
                       ▼
              ┌─────────────────┐
              │ Stage 1: Eth    │  dst_mac, src_mac, ethertype
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 2: VLAN   │  vlan_id, prio, cfi
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 3: IPv4   │  src_ip, dst_ip, proto, TTL
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 4: UDP/   │  src_port, dst_port,
              │        TCP      │  flags, seq, ack
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 5: Match  │  class_id, action,
              │        Table    │  modifier_action
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 6: Packet │  TTL−, MAC swap/set,
              │        Modifier │  IP set, VLAN push/pop
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 7: Stats  │  8× 48-bit counters
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Stage 8: Flow   │  Toeplitz hash → BRAM
              │        Table    │  hit/miss, per-flow stats
              └────────┬────────┘
                       │
              ┌────────▼────────┐
              │ Scheduler: 3Q   │  HIGH > MED > LOW
              │ STRICT / WRR    │  or weighted round-robin
              └────────┬────────┘
                       │
              512-bit AXI Stream Out
```

**Total pipeline depth:** 9 stages (8 pipeline stages + scheduler).  
**Minimum latency:** 9 cycles (no backpressure).  
**Maximum throughput:** ~10 Gbps at 156.25 MHz, 64-bit bus.

---

## AXI-Stream Timing

Since Verilator does not support SystemVerilog `interface`/`modport`, signals use a bundled `axis_fwd_t` struct for the forward path plus a scalar `tready`:

```systemverilog
typedef struct packed {
  logic [511:0] tdata;   // 64 bytes
  logic [63:0]  tkeep;   // 1 bit per byte lane
  logic         tlast;   // end of packet
  logic         tvalid;  // data valid
} axis_fwd_t;
```

### Ready/Valid Handshake

```
clk      ────┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐   ┌───┐
             │   │   │   │   │   │   │   │   │   │   │
tvalid   ────────┘   └───────────────────────────────────
tready   ────────────────────────┘   └───────────────────
tdata    ────[Byte0..7]────[Byte8..15]──────────────────
tlast    ────────────────────────────────────────────┘

          ↑              ↑              ↑
      Cycle 0        Cycle 1        Cycle 2
   data valid     tready=1 →     tready=0 →
                  transfer       hold data
                  occurs
```

**Transfer rule:** A beat is consumed when `tvalid & tready` on the same rising edge.

---

## Pipeline Latency

The table below shows data moving through the 9-stage pipeline. Each row is one clock cycle.

| Cycle | Eth  | VLAN | IPv4 | UDP/TCP | Match | Modifier | Stats | Flow | Sched |
|-------|------|------|------|---------|-------|----------|-------|------|-------|
| 0 | Push | — | — | — | — | — | — | — | — |
| 1 | Hold | Eth | — | — | — | — | — | — | — |
| 2 | Hold | Hold | VLAN | — | — | — | — | — | — |
| 3 | Hold | Hold | Hold | IPv4 | — | — | — | — | — |
| 4 | Hold | Hold | Hold | Hold | L4 | — | — | — | — |
| 5 | Hold | Hold | Hold | Hold | Hold | Match | — | — | — |
| 6 | Hold | Hold | Hold | Hold | Hold | Hold | Mod | — | — |
| 7 | Hold | Hold | Hold | Hold | Hold | Hold | Hold | Stats | — |
| 8 | Hold | Hold | Hold | Hold | Hold | Hold | Hold | Hold | Flow |
| **9** | Hold | Hold | Hold | Hold | Hold | Hold | Hold | Hold | **Out** |

**Key:** "Push" = testbench drives first beat; "Hold" = stage holds valid data; numbered entries indicate which stage's output is active. Scheduler adds 1 cycle for arbitration.

---

## Memory Map (64 × 32-bit registers via AXI-Lite)

| Address | Name | Access | Description |
|---------|------|--------|-------------|
| `0x00` | CTRL | RW | Control register (bit 0 = reset, bit 1 = enable) |
| `0x10–0x4F` | RULE[n] | RW | Match rules (16 rules × 4 regs each) |
| `0x10 + 4×n` | RULE[n].key0 | RW | `{protocol[7:0], src_port[15:0], dst_port[15:0]}` |
| `0x11 + 4×n` | RULE[n].src_ip | RW | Source IP (32-bit) |
| `0x12 + 4×n` | RULE[n].dst_ip | RW | Destination IP (32-bit) |
| `0x13 + 4×n` | RULE[n].ctrl | RW | `{valid, mod_action[2:0], action[1:0], class_id[7:0]}` |
| `0x50` | STAT_PKTS_LO | RO | Packets counter [31:0] |
| `0x51` | STAT_PKTS_HI | RO | Packets counter [47:32] |
| `0x52` | STAT_BYTES_LO | RO | Bytes counter [31:0] |
| `0x53` | STAT_BYTES_HI | RO | Bytes counter [47:32] |
| `0x54–0x5F` | STAT_n | RO | IPv4, TCP, UDP, ARP, drops, error counters |
| `0x60` | SCHED_CFG | RW | Scheduler config (bit 0: 0=STRICT, 1=WRR) |

---

## Metadata Bus (`packet_metadata_t`, 360 bits)

The metadata struct flows alongside packet data through every stage. Each parser fills in its specific fields on the first beat.

```
Bit offset │ Width │ Field            │ Set by
───────────┼───────┼──────────────────┼──────────────
    0      │  48   │ dst_mac          │ Ethernet parser
   48      │  48   │ src_mac          │ Ethernet parser
   96      │  16   │ ethertype        │ Ethernet parser
  112      │   1   │ vlan_valid       │ Ethernet parser
  113      │  12   │ vlan_id          │ VLAN parser
  125      │   3   │ vlan_prio        │ VLAN parser
  128      │   1   │ vlan_cfi         │ VLAN parser
  129      │   1   │ ipv4_valid       │ IPv4 parser
  130      │  32   │ src_ip           │ IPv4 parser
  162      │  32   │ dst_ip           │ IPv4 parser
  194      │   8   │ protocol         │ IPv4 parser
  202      │   8   │ ttl              │ IPv4 parser
  210      │   4   │ ip_hdr_len       │ IPv4 parser
  214      │   1   │ ip_checksum_ok   │ IPv4 parser
  215      │   1   │ tcp_valid        │ TCP parser
  216      │   1   │ udp_valid        │ UDP parser
  217      │  16   │ src_port         │ UDP/TCP parser
  233      │  16   │ dst_port         │ UDP/TCP parser
  249      │   4   │ tcp_flags        │ TCP parser
  253      │  32   │ tcp_seq          │ TCP parser
  285      │  32   │ tcp_ack          │ TCP parser
  317      │  16   │ tcp_window       │ TCP parser
  333      │   8   │ class_id         │ Match table
  341      │   1   │ drop             │ Match table
  342      │   1   │ crc_error        │ Ethernet parser
  343      │   1   │ parse_error      │ Ethernet parser
  344      │  16   │ pkt_length       │ Ethernet parser
───────────┴───────┴──────────────────┴──────────────
```

---

## Performance

### Setup

- **Clock:** 156.25 MHz (simulated)
- **Data bus:** 64-bit (8 B/cycle)
- **Theoretical line rate:** 8 B × 156.25 MHz = **10.0 Gbps**
- **Measurement:** 1000 consecutive packets after warmup

### Results

| Packet Size | Protocol | Throughput | Mpps | Cycles/Pkt | % Line Rate | Overhead |
|-------------|----------|-----------|------|-------------|-------------|----------|
| 64 B | UDP | 8.85 Gbps | 17.3 | 9.0 | 88.5% | 1.15 cyc gap |
| 256 B | UDP | 9.67 Gbps | 4.7 | 33.0 | 96.7% | 1.08 cyc gap |
| 512 B | UDP | 9.82 Gbps | 2.4 | 65.0 | 98.2% | 1.04 cyc gap |
| 1518 B | UDP | 9.91 Gbps | 0.8 | 191.0 | 99.1% | 1.02 cyc gap |
| 76 B | TCP | 8.61 Gbps | 14.2 | 11.0 | 86.1% | 1.33 cyc gap |
| Mixed 64+1518 | — | 9.86 Gbps | 1.5 | 101.0 | 98.6% | — |

### Efficiency Analysis

The **minimum 1-cycle inter-packet gap** is the dominant inefficiency for small packets:

- **64 B UDP:** 9 data cycles + 1 gap = 10 total → 90% theoretical → 88.5% measured (pipeline fill overhead accounts for the remaining 1.5%)
- **1518 B UDP:** 190 data cycles + 1 gap = 191 total → 99.5% theoretical → 99.1% measured (Scheduler arbitration adds ~0.4%)

**Formula:** `efficiency = (packet_bits) / (total_cycles × 8 × freq)`

Small-packet throughput is bounded by the header processing overhead (42 B of headers per packet regardless of payload size). For 64 B packets, headers are 66% of the frame; for 1518 B, headers are 2.8%.

---

## Verification

All testbenches are self-checking with C++ scoreboards. Packets are generated with known content, pushed through the DUT, and compared byte-for-byte against expected values.

| Approach | Tests | Scope |
|----------|-------|-------|
| Directed | 16 | FIFO flags, backpressure, protocol parsing, queue routing |
| Constrained-random | 500 | Random IPs, ports, payloads across UDP/TCP/ARP |
| Stress | 400 | No backpressure, 30% stalls, large packets, batched |
| Performance | 5 | 1000-packet batches, cycle-accurate, CSV output |
| Formal (SymbiYosys) | 7 properties | FIFO: no overflow/underflow, occupancy tracking |

**Known limitations:**
- Metadata bus has a propagation issue (Phase 3) — match_table uses hardcoded defaults
- Packet modifier operates on individual beats; MAC/IP/VLAN modifications spanning multiple beats require a packet buffer (future work)
- Scheduler has 1-cycle arbitration delay when packets arrive simultaneously

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| No SV `interface` | Verilator limitation; bundled `axis_fwd_t` + split `tready` |
| Single clock domain | Simpler verification, no clock crossing FIFOs needed |
| Single always_ff per FIFO | Prevents eval-order race when `wren`+`rden` fire together |
| Combinational BRAM read | Avoids 1-cycle read latency for FIFOs (depth ≤ 64) |
| First-beat metadata | Prevents payload data from corrupting header fields |
| `prev_tlast` modifier detect | Avoids race between register update and combinational logic |
| Lazy flow expiration | Checks idle timeout on access (no background scan needed) |

---

## Project Structure

```
rtl/         20 SystemVerilog modules (interfaces, parsers, classifiers,
             modifiers, filters, memory, schedulers, stats, top)
sim/         10 C++ testbenches, packet generator, scoreboard
scripts/     Python control plane + build runner
synth/       Vivado Tcl script for Artix-7
formal/      SymbiYosys properties for FIFO correctness
docs/        Architecture, resource utilization, verification
waveforms/   Annotated GTKWave screenshots
```
