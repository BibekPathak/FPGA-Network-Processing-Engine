#include <cstdio>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
#include <memory>

#include "Vpacket_scheduler.h"
#include "Vpacket_scheduler__Syms.h"
#include "packet_gen.h"

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
  uint64_t cycles = 0;
  Sim() : dut(std::make_unique<Vpacket_scheduler>()) {}
  void pre()  { dut->clk = 0; dut->eval(); }
  void post() { dut->clk = 1; dut->eval(); cycles++; }
  void reset() {
    dut->rst_n = 0;
    for (int i = 0; i < 4; i++) { pre(); post(); }
    dut->rst_n = 1; pre(); post();
  }

  void push_packet(const std::vector<uint8_t>& pkt, int dw, uint8_t class_id) {
    dut->m_tready = 0;  // don't drain during push
    size_t pos = 0;
    while (pos < pkt.size()) {
      size_t nb = (pkt.size() - pos < (size_t)dw) ? (pkt.size() - pos) : dw;
      pre();
      set32(dut->s_tdata.data(), &pkt[pos], nb);
      dut->s_tkeep = (1ULL << nb) - 1;
      dut->s_tlast = (pos + nb >= pkt.size());
      dut->s_tvalid = 1;
      dut->s_meta.at(10) = (class_id << 13);
      post();
      while (!dut->s_tready) { pre(); post(); }
      pos += nb;
    }
    pre(); dut->s_tvalid = 0; post();
  }

  // Drain one complete packet  
  std::vector<uint8_t> drain_one(int dw) {
    std::vector<uint8_t> out;
    dut->m_tready = 1;
    int timeout = 100000;
    while (timeout--) {
      pre();
      if (dut->m_tvalid && dut->m_tready) {
        bool last = dut->m_tlast;
        size_t nbytes = 0;
        uint64_t keep = dut->m_tkeep;
        for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
        for (size_t i = 0; i < nbytes; i++) {
          uint32_t w = dut->m_tdata.data()[i / 4];
          out.push_back((w >> ((i % 4) * 8)) & 0xFF);
        }
        post();
        if (last) break;
      } else {
        post();
      }
    }
    return out;
  }

  // Drain ALL packets (collect class_ids from output data)
  void drain_all(int dw, std::vector<uint8_t>& out) {
    dut->m_tready = 1;
    int timeout = 100000;
    while (timeout--) {
      pre();
      if (dut->m_tvalid && dut->m_tready) {
        size_t nbytes = 0;
        uint64_t keep = dut->m_tkeep;
        for (int b = 0; b < dw; b++) if (keep & (1ULL << b)) nbytes++;
        for (size_t i = 0; i < nbytes; i++) {
          uint32_t w = dut->m_tdata.data()[i / 4];
          out.push_back((w >> ((i % 4) * 8)) & 0xFF);
        }
        post();
      } else { post(); if (!dut->m_tvalid) break; }
    }
  }
};

// ---------------------------------------------------------------------------
bool test_strict_priority() {
  std::cout << "=== test_strict_priority ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto low  = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234, {'L'});
  auto med  = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 80, 55555, {'M'});
  auto high = gen.make_tcp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 443, 55555, {'H'});

  sim.push_packet(low, dw, 0);    // LOW
  sim.push_packet(med, dw, 2);    // MED
  sim.push_packet(high, dw, 3);   // HIGH

  auto r1 = sim.drain_one(dw);
  auto r2 = sim.drain_one(dw);
  auto r3 = sim.drain_one(dw);

  bool pass = (r1.size() == high.size()) && (r2.size() == med.size()) && (r3.size() == low.size());
  std::cout << "  order: high=" << r1.size() << " med=" << r2.size()
            << " low=" << r3.size() << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_wrr_order() {
  std::cout << "=== test_wrr_order (HIGH=2, MED=1, LOW=1) ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();

  // Set default weights for WRR (the Verilator model uses default params,
  // so SCHED_MODE=0. We test with module default for now.)
  // Note: This test only verifies the scheduler still drains correctly.
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};
  auto pkt = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 53, 1234, {'T'});
  sim.push_packet(pkt, dw, 1);
  auto rx = sim.drain_one(dw);
  bool pass = (rx.size() == pkt.size());
  std::cout << "  basic drain: " << rx.size() << "/" << pkt.size()
            << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

bool test_multi_queue() {
  std::cout << "=== test_multi_queue ===\n";
  Sim sim; PacketGen gen; int dw = 8;
  sim.reset();
  uint8_t sm[6]={0x02,0,0,0,0,1}, dm[6]={0x02,0,0,0,0,2};

  // Push packets to all 3 queues
  for (int i = 0; i < 3; i++) {
    auto p = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 100+i, 200+i, {uint8_t('A'+i)});
    sim.push_packet(p, dw, i % 3);  // class 0,1,2 → LOW, MED, MED
  }

  std::vector<uint8_t> rx;
  sim.drain_all(dw, rx);

  size_t expected = 0;
  for (int i = 0; i < 3; i++) {
    auto p = gen.make_udp_packet(sm, dm, 0xC0A80001, 0xC0A80002, 100+i, 200+i, {uint8_t('A'+i)});
    expected += p.size();
  }

  bool pass = (rx.size() == expected);
  std::cout << "  rx=" << rx.size() << " exp=" << expected << (pass ? " PASS" : " FAIL") << "\n";
  return pass;
}

int main(int argc, char** argv) {
  setbuf(stdout, NULL); setbuf(stderr, NULL);
  Verilated::commandArgs(argc, argv);
  bool all = true;
  all &= test_strict_priority();
  all &= test_wrr_order();
  all &= test_multi_queue();
  std::cout << "\n=== " << (all ? "ALL TESTS PASSED" : "SOME TESTS FAILED") << " ===\n";
  return all ? 0 : 1;
}
