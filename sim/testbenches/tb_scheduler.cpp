#include <cstdio>
#include <cstdint>
#include <iostream>
#include <vector>
#include <memory>

#include "Vpacket_scheduler.h"
#include "Vpacket_scheduler__Syms.h"

static void set32(uint32_t* dst, const uint8_t* src, size_t n) {
  for (size_t i = 0; i < (n + 3) / 4; i++) {
    uint32_t w = 0;
    for (size_t j = 0; j < 4 && i * 4 + j < n; j++)
      w |= static_cast<uint32_t>(src[i * 4 + j]) << (j * 8);
    dst[i] = w;
  }
}

struct Sim {
  std::unique_ptr<Vpacket_scheduler> dut;
  Sim() : dut(std::make_unique<Vpacket_scheduler>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }
};

// Push beats and capture all output into rx
std::vector<uint8_t> push_and_capture(Sim& sim, const std::vector<uint8_t>& pkt,
                                       int dw, uint8_t class_id) {
  sim.dut->m_tready = 1;
  std::vector<uint8_t> rx;
  size_t pos = 0;

  while (pos < pkt.size()) {
    size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
    bool last = (pos + nb >= pkt.size());

    sim.pre();
    // Capture any output beat
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
    }
    // Drive input
    set32(sim.dut->s_tdata.data(), &pkt[pos], nb);
    sim.dut->s_tkeep = (1ULL << nb) - 1;
    sim.dut->s_tlast = last;
    sim.dut->s_tvalid = 1;
    sim.dut->s_meta.at(10) = (class_id << 13);
    sim.post();
    while (!sim.dut->s_tready) { sim.pre(); sim.post(); }
    pos += nb;
  }

  // Idle cycle
  sim.pre();
  if (sim.dut->m_tvalid && sim.dut->m_tready) {
    size_t nbytes = 0;
    uint64_t keep = sim.dut->m_tkeep;
    for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
    for (size_t i = 0; i < nbytes; i++) {
      uint32_t w = sim.dut->m_tdata.data()[i / 4];
      rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
    }
  }
  sim.dut->s_tvalid = 0;
  sim.post();

  // Drain remaining
  int timeout = 100000;
  while (timeout--) {
    sim.pre();
    if (sim.dut->m_tvalid && sim.dut->m_tready) {
      bool last = sim.dut->m_tlast;
      size_t nbytes = 0;
      uint64_t keep = sim.dut->m_tkeep;
      for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
      for (size_t i = 0; i < nbytes; i++) {
        uint32_t w = sim.dut->m_tdata.data()[i / 4];
        rx.push_back((w >> ((i % 4) * 8)) & 0xFF);
      }
      sim.post();
      if (last) break;
    } else {
      sim.post();
      if (!sim.dut->m_tvalid) break;
    }
  }

  return rx;
}

// ---------------------------------------------------------------------------
bool test_basic() {
  std::cout << "=== test_basic ===\n";
  Sim sim; int dw = 8;
  sim.reset();
  uint8_t pkt[44]; for (int i = 0; i < 44; i++) pkt[i] = i;
  std::vector<uint8_t> pv(pkt, pkt + 44);
  auto rx = push_and_capture(sim, pv, dw, 1);
  bool pass = (rx.size() == 44);
  std::cout << "  rx=" << rx.size() << " exp=44" << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_routing_classes() {
  std::cout << "=== test_routing_classes ===\n";
  Sim sim; int dw = 8;
  sim.reset();
  uint8_t pkt[20]; for (int i = 0; i < 20; i++) pkt[i] = i;
  std::vector<uint8_t> pv(pkt, pkt + 20);

  auto r1 = push_and_capture(sim, pv, dw, 0);  // class 0 → LOW
  auto r2 = push_and_capture(sim, pv, dw, 2);  // class 2 → MED
  auto r3 = push_and_capture(sim, pv, dw, 3);  // class 3 → HIGH

  bool pass = (r1.size() == 20 && r2.size() == 20 && r3.size() == 20);
  std::cout << "  low=" << r1.size() << " med=" << r2.size()
            << " high=" << r3.size() << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_basic();
  all &= test_routing_classes();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
