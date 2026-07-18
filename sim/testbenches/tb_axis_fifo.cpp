#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>
#include <deque>
#include <memory>

#include "Vaxis_fifo.h"
#include "Vaxis_fifo__Syms.h"
#include "packet_gen.h"
#include "packet_mon.h"

// ---------------------------------------------------------------------------
// VlWide helpers
// ---------------------------------------------------------------------------
static void vlwide_set_bytes(void* dst_v, const uint8_t* src, size_t nbytes) {
  auto* dst = static_cast<uint32_t*>(dst_v);
  size_t nwords = (nbytes + 3) / 4;
  for (size_t i = 0; i < nwords; i++) {
    uint32_t w = 0;
    for (size_t j = 0; j < 4 && (i * 4 + j) < nbytes; j++)
      w |= static_cast<uint32_t>(src[i * 4 + j]) << (j * 8);
    dst[i] = w;
  }
}

static void vlwide_get_bytes(void* src_v, uint8_t* dst, size_t nbytes) {
  auto* src = static_cast<uint32_t*>(src_v);
  size_t nwords = (nbytes + 3) / 4;
  for (size_t i = 0; i < nwords; i++) {
    uint32_t w = src[i];
    for (size_t j = 0; j < 4 && (i * 4 + j) < nbytes; j++)
      dst[i * 4 + j] = (w >> (j * 8)) & 0xFF;
  }
}

// ---------------------------------------------------------------------------
// Simulation context
// ---------------------------------------------------------------------------
struct SimContext {
  std::unique_ptr<Vaxis_fifo> dut;
  uint64_t sim_cycles = 0;

  SimContext() : dut(std::make_unique<Vaxis_fifo>()) {}

  void set_clk(int val) { dut->clk = val; dut->eval(); }
  void eval_pre()  { set_clk(0); }
  void eval_post() { set_clk(1); sim_cycles++; }
  void tick()      { eval_pre(); eval_post(); }

  void reset(int cycles = 4) {
    dut->rst_n = 0;
    for (int i = 0; i < cycles; i++) tick();
    dut->rst_n = 1;
    tick();
  }
};

// ---------------------------------------------------------------------------
// Push a packet, draining beats into mon when FIFO is full
// ---------------------------------------------------------------------------
void push_packet(SimContext& sim, PacketMon& mon,
                 const std::vector<uint8_t>& pkt, int dw) {
  size_t pos = 0;
  while (pos < pkt.size()) {
    size_t nb = std::min<size_t>(dw, pkt.size() - pos);
    bool last = (pos + nb >= pkt.size());

    sim.eval_pre();
    vlwide_set_bytes(sim.dut->s_tdata.data(), &pkt[pos], nb);
    sim.dut->s_tkeep = (1ULL << nb) - 1;
    sim.dut->s_tlast = last ? 1 : 0;
    sim.dut->s_tvalid = 1;
    sim.eval_post();
    sim.sim_cycles++;

    while (!sim.dut->s_tready) {
      // FIFO full — deassert s_tvalid and drain one beat to make room
      sim.eval_pre();
      sim.dut->s_tvalid = 0;
      if (sim.dut->m_tvalid) {
        uint8_t bdata[64] = {};
        size_t  nbytes = 0;
        uint64_t keep = sim.dut->m_tkeep;
        for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
        vlwide_get_bytes(sim.dut->m_tdata.data(), bdata, nbytes);
        bool l = sim.dut->m_tlast;
        sim.dut->m_tready = 1;
        sim.eval_post();
        sim.sim_cycles++;
        mon.push_beat(bdata, nbytes, l);
      } else {
        // No output data yet — wait one cycle
        sim.dut->m_tready = 1;
        sim.eval_post();
        sim.sim_cycles++;
      }
    }

    // Restore s_tready to 0 after any drain that happened in the wait loop
    sim.dut->m_tready = 0;
    pos += nb;
  }

  sim.eval_pre();
  sim.dut->s_tvalid = 0;
  sim.dut->m_tready = 0;
  sim.eval_post();
  sim.sim_cycles++;
}

// ---------------------------------------------------------------------------
// Drain all remaining beats from FIFO
// ---------------------------------------------------------------------------
void drain_all(SimContext& sim, PacketMon& mon, int dw) {
  sim.dut->m_tready = 1;
  int timeout = 10000;
  while (timeout-- > 0) {
    sim.eval_pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      uint8_t bdata[64] = {};
      size_t  nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      vlwide_get_bytes(sim.dut->m_tdata.data(), bdata, nbytes);
      bool last = sim.dut->m_tlast;

      sim.eval_post();
      sim.sim_cycles++;
      mon.push_beat(bdata, nbytes, last);
    } else {
      sim.eval_post();
      sim.sim_cycles++;
      if (sim.dut->empty && !sim.dut->m_tvalid) break;
    }
  }
}

// ---------------------------------------------------------------------------
// Test 1: push known packets, drain, verify
// ---------------------------------------------------------------------------
bool test_fifo_basic() {
  std::cout << "=== test_fifo_basic ===\n";
  SimContext sim;
  PacketGen  gen;
  PacketMon  mon;
  int        dw = 8;

  sim.reset();
  sim.dut->m_tready = 0;
  sim.dut->s_tvalid = 0;

  uint8_t smac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
  uint8_t dmac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x02};

  auto pkt1 = gen.make_udp_packet(smac, dmac, 0xC0A80001, 0xC0A80002,
                                   1234, 80, {'H', 'e', 'l', 'l', 'o'});
  auto pkt2 = gen.make_udp_packet(smac, dmac, 0xC0A80001, 0xC0A80002,
                                   5678, 53, {'W', 'o', 'r', 'l', 'd'});

  mon.expect(pkt1);
  mon.expect(pkt2);

  push_packet(sim, mon, pkt1, dw);
  push_packet(sim, mon, pkt2, dw);

  drain_all(sim, mon, dw);

  bool pass = (mon.error_count() == 0 && mon.pending() == 0);
  std::cout << "  packets=" << mon.pkt_count()
            << " errors=" << mon.error_count()
            << " pending=" << mon.pending()
            << (pass ? " PASS\n" : " FAIL\n");
  return pass;
}

// ---------------------------------------------------------------------------
// Test 2: flag behavior
// ---------------------------------------------------------------------------
bool test_fifo_flags() {
  std::cout << "=== test_fifo_flags ===\n";
  SimContext sim;
  int dw = 8;

  sim.reset();
  sim.dut->m_tready = 0;
  sim.dut->s_tvalid = 0;
  sim.tick();
  std::cout << "  init: empty=" << sim.dut->empty << " full=" << sim.dut->full << "\n";

  // Push one beat
  uint8_t data[8] = {1,2,3,4,5,6,7,8};
  sim.eval_pre();
  vlwide_set_bytes(sim.dut->s_tdata.data(), data, 8);
  sim.dut->s_tkeep = 0xFF;
  sim.dut->s_tlast = 1;
  sim.dut->s_tvalid = 1;
  sim.eval_post(); sim.sim_cycles++;
  sim.eval_pre();
  sim.dut->s_tvalid = 0;
  sim.eval_post(); sim.sim_cycles++;

  std::cout << "  after push: empty=" << sim.dut->empty
            << " full=" << sim.dut->full
            << " used=" << sim.dut->used << "\n";

  // Drain
  sim.dut->m_tready = 1;
  int tries = 100;
  while (tries--) {
    sim.eval_pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      sim.eval_post(); sim.sim_cycles++;
      break;
    }
    sim.eval_post(); sim.sim_cycles++;
    if (sim.dut->empty) break;
  }

  std::cout << "  after drain: empty=" << sim.dut->empty
            << " full=" << sim.dut->full
            << " used=" << sim.dut->used << "\n";
  std::cout << "  PASS\n";
  return true;
}

// ---------------------------------------------------------------------------
// Test 3: random backpressure
// ---------------------------------------------------------------------------
bool test_fifo_backpressure() {
  std::cout << "=== test_fifo_backpressure ===\n";
  SimContext sim;
  PacketGen  gen(12345);
  PacketMon  mon;
  int        dw = 8;

  sim.reset();
  sim.dut->m_tready = 0;
  sim.dut->s_tvalid = 0;

  uint8_t smac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};
  uint8_t dmac[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x02};

  // 10 random packets
  for (int i = 0; i < 10; i++) {
    size_t len = 64 + (rand() % 500);
    auto pkt = gen.make_udp_packet(smac, dmac, 0xC0A80001, 0xC0A80002,
                                   1234 + i, 80 + i,
                                   std::vector<uint8_t>(len - 42, i & 0xFF));
    mon.expect(pkt);
    push_packet(sim, mon, pkt, dw);
  }

  drain_all(sim, mon, dw);

  bool pass = (mon.error_count() == 0 && mon.pending() == 0);
  std::cout << "  packets=" << mon.pkt_count()
            << " errors=" << mon.error_count()
            << " pending=" << mon.pending()
            << (pass ? " PASS\n" : " FAIL\n");
  return pass;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
  setbuf(stdout, NULL);
  setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);

  bool all = true;
  all &= test_fifo_basic();
  all &= test_fifo_flags();
  all &= test_fifo_backpressure();

  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED")
            << " ===\n";
  return all ? 0 : 1;
}
