# Waveform Gallery

This directory contains annotated GTKWave screenshots of key pipeline behaviors.

## Generating Waveforms

```bash
# Build + run with tracing enabled
make waves TOP=tb_pipeline

# The output VCD is at:
# build/obj_dir/waveform.vcd

# Open with GTKWave:
gtkwave build/obj_dir/waveform.vcd
```

## Annotated Screenshots

### 1. AXI-Stream Handshake

`waveforms/axi_handshake.png`

Shows `tvalid`/`tready`/`tdata`/`tlast` interaction across a packet transfer:
- **①** First beat: `tvalid` goes high, data on bus
- **②** Backpressure: `tready` goes low, data held
- **③** Transfer: both high, beat consumed, `tvalid` drops on next cycle
- **④** Last beat: `tlast` asserted with final data
- **⑤** Idle: `tvalid` low between packets

### 2. Backpressure Propagation

`waveforms/backpressure.png`

Shows a stall propagating from the scheduler back through the pipeline:
- **①** Scheduler output stalls (`m_tready`=0)
- **②** Flow table fills (1 cycle later)
- **③** Stats engine fills (2 cycles)
- **④** Modifier fills (3 cycles)
- **⑤** Match table fills (4 cycles)
- **⑥** All 9 stages stalled; input `tready` deasserted

### 3. Match Table Hit & Modifier Action

`waveforms/match_hit.png`

Shows a DNS packet (UDP port 53) matching rule 0 with `MOD_MAC_SWAP`:
- **①** `s_meta.ethertype` = 0x0800 (IPv4) enters match table
- **②** `s_meta.dst_port` = 53 matches rule 0
- **③** `m_mod_action` = `MOD_MAC_SWAP` (3'd2) output to modifier
- **④** Modifier applies swap: `m_tdata[0..5]` and `m_tdata[6..11]` exchanged
- **⑤** Output shows swapped MAC addresses

### 4. Flow Table Lookup

`waveforms/flow_lookup.png`

Shows Toeplitz hash computation and 2-way set-associative lookup:
- **①** 5-tuple extracted from metadata at `tlast`
- **②** Hash accumulation across 4 word-XOR stages
- **③** Set index computed, both ways read from BRAM
- **④** Key comparison: `way_hit[0]` or `way_hit[1]`
- **⑤** On hit: counters increment, `last_seen` updated

### 5. Scheduler Priority Arbitration

`waveforms/scheduler_priority.png`

Shows 3 packets (LOW, MED, HIGH) entering and draining in strict priority order:
- **①** All 3 packets queued simultaneously
- **②** Arbiter selects HIGH (queue 0) — drains first
- **③** HIGH empty — arbiter switches to MED (queue 1)
- **④** MED empty — arbiter switches to LOW (queue 2)
- **⑤** All queues empty — `m_tvalid` goes low

## Creating Screenshots

1. Run `make waves TOP=tb_pipeline`
2. Open in GTKWave: `gtkwave build/obj_dir/waveform.vcd`
3. Add relevant signals to the waveform viewer
4. Configure display (radix, grouping, colors) with `.gtkw` save files:
   ```
   gtkwave build/obj_dir/waveform.vcd --save=waveforms/axi_handshake.gtkw
   ```
5. Take screenshot and save to `waveforms/` directory
6. Add callout annotations using image editing software
