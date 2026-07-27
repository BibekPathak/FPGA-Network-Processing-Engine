# FPGA Network Processing Engine (NPE)

A fully pipelined, configurable Layer 2–Layer 4 packet processing engine written in SystemVerilog featuring protocol parsing, programmable match-action processing with packet modification, Toeplitz-hash flow tracking, weighted round-robin scheduling, runtime register configuration, Python control plane, formal verification with SymbiYosys, and synthesis targeting an Artix-7 FPGA.

---

## Project Structure

```
.
├── rtl/
│   ├── common/          # Types, constants, metadata struct
│   ├── interfaces/      # AXI-Stream FIFO, pipeline register
│   ├── parsers/         # Ethernet, VLAN, IPv4, UDP, TCP
│   ├── classifiers/     # 5-tuple packet classifier
│   ├── filters/         # Rule engine (ACL actions)
│   ├── memory/          # Flow table (hash-based lookup)
│   ├── schedulers/      # Priority queue scheduler
│   ├── stats/           # Per-protocol statistics counters
│   └── top/             # Parser pipeline (all stages)
├── sim/
│   ├── packet_generators/   # C++ packet builder
│   ├── packet_monitors/     # C++ scoreboard and checker
│   └── testbenches/         # 6 testbenches
├── scripts/             # Build runner
├── docs/                # Architecture documentation
├── Makefile             # Build system
└── README.md
```

---

## Pipeline Architecture

```
                  AXI Stream Input (512-bit)
                           │
                           ▼
              ┌───────────────────────┐
              │ Stage 1: Ethernet     │  dst_mac, src_mac,
              │        Parser         │  ethertype, vlan_detect
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 2: VLAN         │  vlan_id, vlan_prio,
              │        Parser         │  inner_ethertype
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 3: IPv4         │  src_ip, dst_ip, proto,
              │        Parser         │  ttl, checksum_verify
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 4: UDP / TCP    │  ports, flags, seq,
              │        Parsers        │  ack, window
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 5: Packet       │  class_id (DNS=1,
              │        Classifier     │  HTTP=2, HTTPS=3, SSH=4)
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 6: Rule Engine  │  ALLOW/DROP/REDIRECT
              │                       │  based on class_id
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 7: Statistics   │  per-protocol counters:
              │        Engine         │  pkt, byte, tcp, udp, etc.
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Stage 8: Flow Table   │  5-tuple hash → BRAM
              │                       │  hit/miss, per-flow stats
              └───────────┬───────────┘
                          │
              ┌───────────▼───────────┐
              │ Scheduler: 3 queues   │  HIGH > MED > LOW
              │ (HIGH/MED/LOW)        │  priority arbitration
              └───────────┬───────────┘
                          │
                  AXI Stream Output
```

### Pipeline Latency

Each stage is a single pipeline register. The total minimum latency is **8 cycles** (8 stages). With AXI-Stream ready/valid handshake, backpressure can stall any stage — the stall propagates upstream one stage per cycle.

---

## Modules

### Infrastructure (`rtl/interfaces/`)

| Module | Description |
|--------|-------------|
| `axis_fifo` | Configurable-depth BRAM FIFO with full/empty/almost flags. Supports simultaneous read+write on same cycle. |
| `axis_register` | Single-stage pipeline register with ready/valid handshake and skid protection. |

### Protocol Parsers (`rtl/parsers/`)

Each parser is a pipeline stage that:
1. Extracts header fields from the AXI-Stream data bus
2. Updates the metadata struct (`packet_metadata_t`)
3. Passes the raw data and metadata to the next stage

All parsers use **first-beat tracking** — metadata fields are only updated on the first beat of each packet. On subsequent beats, the existing metadata is preserved.

| Parser | Extracts | Key Fields |
|--------|----------|------------|
| Ethernet | Bytes 0–13 | dst_mac, src_mac, ethertype, VLAN detection |
| VLAN | Bytes 14–19 | VLAN ID, priority, CFI, inner EtherType |
| IPv4 | IP header @ offset 14/18 | src_ip, dst_ip, protocol, TTL, checksum |
| UDP | UDP header @ L4 offset | src_port, dst_port |
| TCP | TCP header @ L4 offset | ports, seq, ack, flags, window |

### Classifier (`rtl/classifiers/`)

Priority-encoded TCAM-like match over the 5-tuple:
```
(src_ip, dst_ip, protocol, src_port, dst_port)
```
Each rule has wildcard support (field = 0 matches any value). First match wins.

**Default rules:**

| Class ID | Protocol | Port | Name |
|----------|----------|------|------|
| 0 | — | — | Unmatched → LOW priority |
| 1 | UDP | 53 | DNS |
| 2 | TCP | 80 | HTTP |
| 3 | TCP | 443 | HTTPS |
| 4 | TCP | 22 | SSH |

### Rule Engine (`rtl/filters/`)

Maps `class_id` to an action:

| Action | Description |
|--------|-------------|
| `ALLOW` | Forward packet to output |
| `DROP` | Set `drop` flag in metadata |
| `REDIRECT` | Route to specific queue (future) |
| `MIRROR` | Copy to monitor port (future) |

### Statistics Engine (`rtl/stats/`)

48-bit saturating counters updated on each packet end (`tlast`):

| Counter | Condition |
|---------|-----------|
| `cnt_packets` | Every valid packet |
| `cnt_bytes` | Sum of `pkt_length` |
| `cnt_ipv4` | `ipv4_valid` |
| `cnt_tcp` | `tcp_valid` |
| `cnt_udp` | `udp_valid` |
| `cnt_arp` | `ethertype == 0x0806` |
| `cnt_drops` | `drop` flag |
| `cnt_errors` | `crc_error` or `parse_error` |

### Flow Table (`rtl/memory/`)

Direct-mapped hash table (64 entries) using XOR-based hash over the 5-tuple (104 bits). On each packet end:
- **Hit**: increment per-flow packet and byte counters
- **Miss**: allocate new entry (evicting old on collision)

### Packet Scheduler (`rtl/schedulers/`)

3 FIFO queues with strict priority arbitration:

| Queue | Class IDs | Priority |
|-------|-----------|----------|
| HIGH | 3, 4 (HTTPS, SSH) | Highest |
| MED | 1, 2 (DNS, HTTP) | Medium |
| LOW | 0 (unmatched) | Lowest |

---

## Metadata Bus (`packet_metadata_t`)

The metadata struct (360 bits) is the spine of the design:
- Carried alongside packet data through every pipeline stage
- Each parser updates its specific fields (validity per stage)
- Total width: 360 bits fits in a single 512-bit bus alongside data

```
 0:    dst_mac [47:0]
48:    src_mac [47:0]
96:    ethertype [15:0], vlan_valid, vlan_id, vlan_prio, cfi
129:   ipv4_valid, src_ip, dst_ip, protocol, ttl, hdr_len
215:   tcp_valid, udp_valid, src_port, dst_port
249:   tcp_flags, tcp_seq, tcp_ack, tcp_window
333:   class_id, drop, crc_error, parse_error
344:   pkt_length [15:0]
```

---

## AXI-Stream Bus Convention

Since Verilator does not support SystemVerilog `interface` / `modport`, we use a bundled struct for the forward path:

```systemverilog
typedef struct packed {
  logic [511:0] tdata;
  logic [63:0]  tkeep;
  logic         tlast;
  logic         tvalid;
} axis_fwd_t;
```

The reverse-direction `tready` is a separate scalar signal. This keeps the forward bus bundled (cleaner pipeline registers) while splitting the backpressure signal.

**Handshake rule:** A transfer occurs on any cycle where `tvalid` and `tready` are both asserted. Data must be stable while `tvalid` is asserted and `tready` is low.

---

## Build System

### Prerequisites

- Verilator 5.x (for simulation)
- C++17 compiler (g++ or clang)
- Python 3 (for scripts)
- GTKWave (optional, for waveform viewing)

### Build & Run

```bash
# Build and run default test (axis_fifo)
make

# Run a specific test
make run TOP=tb_pipeline

# Run all regression tests
make regression

# Build with waveform tracing
make waves TOP=tb_pipeline

# Run random verification
make run TOP=tb_random

# Run performance measurement
make run TOP=tb_perf
```

### Testbenches

| Testbench | Description | Top Module |
|-----------|-------------|------------|
| `tb_axis_fifo` | FIFO basic/flags/backpressure | `axis_fifo` |
| `tb_pipeline` | Data integrity: UDP, TCP, ARP, DNS, HTTP | `parser_pipeline` |
| `tb_scheduler` | Queue routing and arbitration | `packet_scheduler` |
| `tb_random` | Constrained-random verification (100–500 packets) | `parser_pipeline` |
| `tb_perf` | Latency, throughput, cycle-accurate metrics | `parser_pipeline` |

---

## Performance Results

At 156.25 MHz, 64-bit datapath (8 bytes/cycle):

| Packet Size | Protocol | Cycles/Beat | Throughput | Latency |
|-------------|----------|-------------|------------|---------|
| 64 B | UDP | 9.0 | 8.85 Gbps | 9 cycles |
| 256 B | UDP | 33.0 | 9.67 Gbps | 8 cycles |
| 512 B | UDP | 65.0 | 9.82 Gbps | 8 cycles |
| 1518 B | UDP | 191.0 | 9.91 Gbps | 8 cycles |
| 76 B | TCP | 11.0 | 8.61 Gbps | 8 cycles |

The pipeline approaches the theoretical maximum of **10 Gbps** for a 64-bit bus at 156.25 MHz. Small-packet throughput is limited by per-packet pipeline fill/drain overhead (~1 cycle minimum gap between packets).

---

## Verification

All testbenches are self-checking with C++ scoreboards. Each test generates packets with known content, pushes them through the DUT, and compares output data byte-for-byte against expected values.

**Test coverage:**
- Directed tests: FIFO flags, backpressure, queue routing
- Protocol tests: Ethernet, ARP, IPv4, UDP, TCP headers
- Classifier tests: DNS/HTTP/HTTPS/SSH classification
- Random tests: 500+ constrained-random packets with variable sizes
- Performance tests: 1000-packet batches with cycle-accurate timing

---

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| No SV `interface` | Verilator limitation; bundled struct + separate `tready` |
| Single clock domain | Simpler verification, no clock crossing FIFOs needed |
| Combinational BRAM read | Avoid 1-cycle read latency for smaller FIFOs (depth ≤ 64) |
| First-beat metadata update | Prevents payload data from corrupting header fields |
| Synced `wren`+`rden` in FIFO | Single always_ff block prevents eval-order race conditions |

---

## Future Work (Stretch Goals)

- **CAM-based lookup**: Content-Addressable Memory for parallel rule matching
- **Bloom filter**: Probabilistic packet filtering with low resource usage
- **Token bucket rate limiter**: Per-flow or per-queue rate limiting
- **Load balancer**: Hash-based distribution across output queues
- **NAT engine**: Source IP/port translation with checksum update
- **PCIe / DMA interface**: Host communication for register read/write
