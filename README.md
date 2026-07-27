# FPGA Network Processing Engine (NPE)

Designed and implemented a fully pipelined Layer 2–Layer 4 FPGA network processing engine in SystemVerilog featuring protocol parsing, programmable match-action processing with packet modification (TTL/MAC/IP/VLAN/DSCP/ECN rewrite), Toeplitz-hash flow tracking, weighted round-robin scheduling, runtime configuration via register interface, Python control plane, formal verification with SymbiYosys, and synthesis targeting an Artix-7 FPGA.

## Quick Start

```bash
# Install Verilator 5.x, then:
make                # build and run default test
make regression     # run all tests
make run TOP=tb_perf    # performance measurement
```

## Architecture

**9-stage pipeline:** Eth → VLAN → IPv4 → UDP/TCP → Match Table → Packet Modifier → Statistics → Flow Table → Scheduler

```
AXI In → [Parser Stages] → [Match-Action] → [Stats + Flow] → [Scheduler] → AXI Out
```

The pipeline processes one beat per cycle with AXI-Stream ready/valid backpressure. Minimum latency: 9 cycles. Maximum throughput: ~10 Gbps at 156.25 MHz.

See [docs/architecture.md](docs/architecture.md) for full block diagrams, timing diagrams, and metadata bus layout.

## Pipeline Stages

| Stage | Module | Function |
|-------|--------|----------|
| 1 | Ethernet Parser | Extract dst/src MAC, ethertype, detect VLAN |
| 2 | VLAN Parser | Extract VLAN ID, priority, inner ethertype |
| 3 | IPv4 Parser | Extract IPs, protocol, TTL, verify checksum |
| 4 | UDP / TCP Parsers | Extract ports, flags, sequence numbers |
| 5 | Match Table | 5-tuple TCAM match, priority encode, 32 rules |
| 6 | Packet Modifier | TTL decrement, MAC swap/set, IP set, VLAN push/pop, DSCP/ECN set |
| 7 | Statistics Engine | 8 × 48-bit counters (packets, bytes, TCP, UDP, ARP, drops, errors) |
| 8 | Flow Table | Toeplitz hash, 2-way set-associative, LRU eviction, 128 flows |
| 9 | Scheduler | 3 priority queues, strict priority or weighted round-robin |

## Verification

| Approach | Details |
|----------|---------|
| Directed tests | FIFO flags, backpressure, queue routing, protocol parsing |
| Constrained-random | 500+ packets with random IPs, ports, payloads, scoreboard |
| Stress tests | 400 packets through full pipeline, 100% data integrity |
| Performance | Latency, throughput, cycles/packet, CSV output |
| Formal (SymbiYosys) | FIFO: no write-when-full, no read-when-empty, occupancy tracking |

## Performance (156.25 MHz, 64-bit datapath)

| Packet Size | Throughput | Packets/sec | Cycles/Pkt |
|-------------|-----------|-------------|------------|
| 64 B | 8.85 Gbps | 17.3 Mpps | 9.0 |
| 256 B | 9.67 Gbps | 4.7 Mpps | 33.0 |
| 512 B | 9.82 Gbps | 2.4 Mpps | 65.0 |
| 1518 B | 9.91 Gbps | 0.8 Mpps | 191.0 |

## Resource Utilization (Artix-7 XC7A35T)

| Resource | Used | Available | % |
|----------|------|-----------|---|
| LUT | ~2,400 | 20,800 | 11.5% |
| FF | ~8,200 | 41,600 | 19.7% |
| BRAM | 2 | 50 | 4.0% |
| Fmax (est.) | ~200 MHz | — | — |

## Project Structure

| Directory | Contents |
|-----------|----------|
| `rtl/` | 20 SystemVerilog modules (1,800+ lines) |
| `sim/` | 10 C++ testbenches, packet generator, scoreboard |
| `scripts/` | Python control plane for runtime configuration |
| `synth/` | Vivado synthesis Tcl script targeting Artix-7 |
| `formal/` | SymbiYosys formal properties for FIFO correctness |
| `docs/` | Architecture document, resource utilization |

## Build Targets

```bash
make run TOP=tb_pipeline     # Data integrity (6 tests)
make run TOP=tb_random       # Constrained-random verification
make run TOP=tb_stress       # Stress test (400 packets)
make run TOP=tb_scheduler    # Queue scheduling tests
make run TOP=tb_perf         # Performance measurement + CSV
make run TOP=tb_crc          # CRC32 known-vector tests
make run TOP=tb_rate_limiter # Token bucket tests
make regression              # Run all testbenches
```

## Dependencies

- [Verilator](https://www.veripool.org/verilator/) 5.x (RTL simulation)
- C++17 compiler (g++ ≥ 11 or clang ≥ 14)
- Python 3 (optional, control plane)
- Vivado (optional, synthesis)
- Yosys + SymbiYosys (optional, formal verification)
