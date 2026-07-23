# Formal Verification

This directory contains formal property files verified with [SymbiYosys](https://github.com/YosysHQ/sby).

## Prerequisites

- [Yosys](https://github.com/YosysHQ/yosys) 0.27+
- [SymbiYosys](https://github.com/YosysHQ/sby) 1.0+
- SMT solver: z3 or boolector

## Running

```bash
cd formal
sby -f fifo.sby
```

## Properties Verified

### axis_fifo (`fifo.sv`)

| Property | Status | Description |
|----------|--------|-------------|
| FIFO_NO_WRITE_WHEN_FULL | ✅ | Never write when full |
| FIFO_NO_READ_WHEN_EMPTY | ✅ | Never read when empty |
| S_TREADY_IMPLIES_NOT_FULL | ✅ | s_tready → not full |
| M_TVALID_IMPLIES_NOT_EMPTY | ✅ | m_tvalid → not empty |
| USED_EQUALS_OCCUPANCY | ✅ | used = push_count - pop_count |
| OCCUPANCY_LE_DEPTH | ✅ | Occupancy never exceeds DEPTH |
| NO_UNDERFLOW | ✅ | push_count ≥ pop_count |

## Future Work

- Add formal properties for parser state machines
- Verify match_table priority encoder correctness
- Prove no packet loss under backpressure
