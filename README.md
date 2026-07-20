# FPGA Network Processing Engine (NPE)

A fully pipelined, configurable Layer 2–Layer 4 packet processing engine in SystemVerilog.

## Quick Start

```bash
# Install Verilator 5.x, then:
make          # build and run default test
make regression   # run all tests (~1700 cycles total)
make run TOP=tb_pipeline   # pipeline data integrity tests
make run TOP=tb_perf       # performance measurement
```

## Architecture

8-stage pipeline: **Eth** → **VLAN** → **IPv4** → **UDP/TCP** → **Classifier** → **Rule Engine** → **Statistics** → **Flow Table** + **Priority Scheduler**

See [docs/architecture.md](docs/architecture.md) for full details.

## Performance

| Metric | Value |
|--------|-------|
| Max throughput | ~10 Gbps (156.25 MHz, 64-bit bus) |
| Min latency | 8 cycles |
| Pipeline depth | 8 stages |
| Max packet size | 1518 bytes (jumbo frame) |

## Project Structure

| Directory | Contents |
|-----------|----------|
| `rtl/` | 15 SystemVerilog modules (interfaces, parsers, classifiers, filters, memory, schedulers, stats, top) |
| `sim/` | 6 testbenches, C++ packet generator, monitor with scoreboard |
| `docs/` | Architecture document with diagrams |
| `scripts/` | Python build runner |

## Testbenches

| Testbench | Tests | Status |
|-----------|-------|--------|
| `tb_axis_fifo` | FIFO data integrity, flags, backpressure | ✅ 3/3 |
| `tb_pipeline` | UDP, TCP, ARP through 8-stage pipeline | ✅ 6/6 |
| `tb_scheduler` | Queue routing, priority arbitration | ✅ 2/2 |
| `tb_random` | Constrained-random verification | ✅ 100-500 packets |
| `tb_perf` | Latency, throughput, cycle-accurate measurement | ✅ CSV output |

## Dependencies

- [Verilator](https://www.veripool.org/verilator/) 5.x (RTL simulation)
- C++17 compiler (g++ ≥ 11 or clang ≥ 14)
- Python 3 (optional, for `scripts/run.py`)
- GTKWave (optional, waveform viewing with `WAVES=1`)
