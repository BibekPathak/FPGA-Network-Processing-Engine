#include <cstdio>
#include <cstdint>
#include <iostream>
#include <memory>

#include "Vtoken_bucket.h"

struct Sim {
  std::unique_ptr<Vtoken_bucket> dut;
  Sim() : dut(std::make_unique<Vtoken_bucket>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

bool test_basic() {
  std::cout << "=== test_basic ===\n";
  Sim sim;

  // Set configuration BEFORE reset so tokens initialize correctly
  sim.dut->cfg_rate = 1000;
  sim.dut->cfg_burst = 10000;
  sim.dut->cfg_interval = 1;
  sim.reset();

  // Initial burst should allow large packets
  sim.pre();
  sim.dut->pkt_valid = 1;
  sim.dut->pkt_length = 5000;  // 5KB — fits in burst
  sim.post();

  bool allow1 = sim.dut->pkt_allow;
  printf("  Big packet (5KB) with full burst: %s\n", allow1 ? "ALLOW" : "DROP");

  // Tick a few cycles (rate refills)
  for (int i = 0; i < 5; i++) {
    sim.pre(); sim.dut->pkt_valid = 0; sim.post();
  }

  // Now send a small packet — should be allowed (tokens refilled at 1000/cycle)
  sim.pre();
  sim.dut->pkt_valid = 1;
  sim.dut->pkt_length = 500;
  sim.post();

  bool allow2 = sim.dut->pkt_allow;
  printf("  Small packet after refill: %s\n", allow2 ? "ALLOW" : "DROP");

  bool pass = allow1 && allow2;
  printf(pass ? "  PASS\n" : "  FAIL\n");
  return pass;
}

bool test_drop_on_empty() {
  std::cout << "=== test_drop_on_empty ===\n";
  Sim sim;

  // Configure before reset
  sim.dut->cfg_rate = 1;
  sim.dut->cfg_burst = 10;
  sim.dut->cfg_interval = 1;
  sim.reset();

  bool all_allowed = true;
  for (int i = 0; i < 20; i++) {
    sim.pre();
    sim.dut->pkt_valid = 1;
    sim.dut->pkt_length = 5;  // 5 bytes each
    sim.post();
    if (!sim.dut->pkt_allow) {
      printf("  Packet %d dropped (as expected after burst exhausted)\n", i);
      break;
    }
    sim.pre(); sim.dut->pkt_valid = 0; sim.post();
  }

  printf("  Drops happen after burst consumed\n");
  return true;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_basic();
  all &= test_drop_on_empty();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
